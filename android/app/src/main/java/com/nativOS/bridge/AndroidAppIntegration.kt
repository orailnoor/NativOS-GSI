package com.nativOS.bridge

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ResolveInfo
import android.os.Process
import com.nativOS.runtime.IntegratedRuntime
import android.graphics.Bitmap
import android.graphics.Canvas
import android.util.Log
import com.nativOS.settings.NativOSPreferences
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest

/** Publishes Android launcher activities as applications in the Phosh drawer. */
object AndroidAppIntegration {
    private const val TAG = "NativOS.AndroidApps"
    const val LAUNCH_PIPE = "android-launch.fifo"
    @Volatile private var returningFromAndroidApp = false

    /** Records launches initiated by a Phosh Android-app shortcut. */
    fun markAndroidAppLaunched() {
        returningFromAndroidApp = true
    }

    /** Consumes the pending return so ordinary pause/resume events are untouched. */
    fun consumeAndroidAppReturn(): Boolean {
        if (!returningFromAndroidApp) return false
        returningFromAndroidApp = false
        return true
    }

    fun sync(context: Context) {
        try {
            val integrationDir = File(context.filesDir, "bridge/android-apps")
            val applicationsDir = File(integrationDir, "share/applications")
            val iconsDir = File(integrationDir, "icons")
            applicationsDir.mkdirs()
            iconsDir.mkdirs()

            File(integrationDir, "nativos-launch-android").writeText(
                """#!/bin/sh
                |[ "${'$'}#" -eq 2 ] || exit 2
                |printf '%s\t%s\n' "${'$'}1" "${'$'}2" > /run/nativOS/$LAUNCH_PIPE
                |""".trimMargin()
            )

            val activities = if (NativOSPreferences.showAndroidApps(context)) {
                val launcherIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                @Suppress("DEPRECATION")
                context.packageManager.queryIntentActivities(launcherIntent, 0)
                    .filter { it.activityInfo.packageName != context.packageName }
                    .distinctBy { ComponentName(it.activityInfo.packageName, it.activityInfo.name) }
                    .sortedBy { it.loadLabel(context.packageManager).toString().lowercase() }
            } else {
                emptyList()
            }
            if (IntegratedRuntime.enabled) publishIntegrated(context, activities)

            val expectedDesktopFiles = mutableSetOf<String>()
            val expectedIconFiles = mutableSetOf<String>()
            for (resolved in activities) {
                val packageName = resolved.activityInfo.packageName
                val activityName = resolved.activityInfo.name
                val id = stableId("$packageName/$activityName")
                val desktopName = "android-$id.desktop"
                val iconName = "android-$id.png"
                expectedDesktopFiles += desktopName
                expectedIconFiles += iconName

                val iconFile = File(iconsDir, iconName)
                if (!iconFile.exists()) writeIcon(resolved.loadIcon(context.packageManager), iconFile)

                val label = escapeDesktopValue(resolved.loadLabel(context.packageManager).toString())
                val desktop = """
                    [Desktop Entry]
                    Type=Application
                    Name=$label
                    Comment=Android application
                    Exec=/bin/sh /run/nativOS/android-apps/nativos-launch-android $packageName $activityName
                    Icon=/run/nativOS/android-apps/icons/$iconName
                    Terminal=false
                    StartupNotify=false
                    Categories=Android;
                    X-Android-Package=$packageName
                    X-Android-Activity=$activityName
                    X-Purism-FormFactor=Workstation;Mobile;
                """.trimIndent() + "\n"
                val desktopFile = File(applicationsDir, desktopName)
                if (!desktopFile.exists() || desktopFile.readText() != desktop) desktopFile.writeText(desktop)
            }

            applicationsDir.listFiles()?.filter { it.name !in expectedDesktopFiles }?.forEach { it.delete() }
            iconsDir.listFiles()?.filter { it.name !in expectedIconFiles }?.forEach { it.delete() }
            Log.i(TAG, "Published ${activities.size} Android apps to Phosh " +
                "(enabled=${NativOSPreferences.showAndroidApps(context)})")
        } catch (error: Throwable) {
            Log.e(TAG, "Could not publish Android apps", error)
        }
    }

    fun isLaunchable(context: Context, packageName: String, activityName: String): Boolean {
        val launcherIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        @Suppress("DEPRECATION")
        return context.packageManager.queryIntentActivities(launcherIntent, 0).any {
            it.activityInfo.packageName == packageName && it.activityInfo.name == activityName
        }
    }

    /** The integrated runtime shares only the desktop user's existing home.
     * No private Android data mount, host command, root operation or policy grant.
     */
    private fun publishIntegrated(context: Context, activities: List<ResolveInfo>) {
        val home = File("/data/misc/nativos/homes/${Process.myUid()}")
        check(home.isDirectory && home.canonicalFile == home.absoluteFile) { "Desktop home not ready or redirected" }
        fun ownedDirectory(directory: File): File {
            check(directory.canonicalFile == directory.absoluteFile) { "Redirected desktop directory" }
            check(directory.isDirectory || directory.mkdirs()) { "Cannot create desktop directory" }
            check(directory.canonicalFile == directory.absoluteFile) { "Desktop directory changed" }
            return directory
        }
        val appDir = ownedDirectory(File(home, ".local/share/applications"))
        val assets = ownedDirectory(File(home, ".local/share/nativos-android"))
        val icons = ownedDirectory(File(assets, "icons"))
        val helper = File(assets, "launch.py")
        check(helper.canonicalFile == helper.absoluteFile) { "Redirected launch helper" }
        helper.writeText("""
            import os, socket, struct, sys
            if len(sys.argv) != 3 or os.geteuid() == 0:
                raise SystemExit(2)
            fields = sys.argv[1:]
            if any(not field or any(c in field for c in '\r\n\t\x00') for field in fields):
                raise SystemExit(2)
            request = ('\t'.join(fields) + '\n').encode()
            if len(request) > 512:
                raise SystemExit(2)
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(5)
                client.connect('\x00nativos_android_apps_' + str(os.getuid()))
                peer = struct.unpack('3i', client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                if peer[1] != os.getuid():
                    raise SystemExit('Android bridge UID mismatch')
                client.sendall(request)
                if client.recv(64) != b'OK\n':
                    raise SystemExit('Android launch rejected')
        """.trimIndent() + "\n")
        helper.setReadable(false, false)
        helper.setReadable(true, true)
        helper.setWritable(false, false)
        helper.setWritable(true, true)
        val expected = mutableSetOf<String>()
        for (resolved in activities) {
            val pkg = resolved.activityInfo.packageName
            val activity = resolved.activityInfo.name
            check(Regex("[A-Za-z0-9_.]+") .matches(pkg) && Regex("[A-Za-z0-9_.$]+") .matches(activity))
            val id = stableId("$pkg/$activity")
            val name = "android-$id.desktop"
            expected += name
            val icon = File(icons, "android-$id.png")
            check(icon.canonicalFile == icon.absoluteFile) { "Redirected desktop icon" }
            if (!icon.exists()) writeIcon(resolved.loadIcon(context.packageManager), icon)
            val entry = """
                [Desktop Entry]
                Type=Application
                Name=${escapeDesktopValue(resolved.loadLabel(context.packageManager).toString())}
                Comment=Android application
                Exec=/usr/bin/python3 /home/nativos/.local/share/nativos-android/launch.py $pkg $activity
                Icon=/home/nativos/.local/share/nativos-android/icons/${icon.name}
                Terminal=false
                StartupNotify=false
                Categories=Android;
                X-NativOS-Android-Managed=true
                X-Purism-FormFactor=Workstation;Mobile;
            """.trimIndent() + "\n"
            val target = File(appDir, name)
            check(target.canonicalFile.parentFile == appDir.canonicalFile) { "Redirected launcher" }
            if (!target.exists() || target.readText().contains("X-NativOS-Android-Managed=true")) target.writeText(entry)
        }
        appDir.listFiles()?.filter {
            it.name.matches(Regex("android-[0-9a-f]{20}\\.desktop")) && it.name !in expected &&
                it.canonicalFile.parentFile == appDir.canonicalFile &&
                it.readText().contains("X-NativOS-Android-Managed=true")
        }?.forEach { it.delete() }
        Log.i(TAG, "Published ${activities.size} integrated Android shortcuts")
    }

    private fun writeIcon(drawable: android.graphics.drawable.Drawable, file: File) {
        val size = 192
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        FileOutputStream(file).use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }

    private fun stableId(value: String): String {
        val bytes = MessageDigest.getInstance("SHA-256").digest(value.toByteArray())
        return bytes.take(10).joinToString("") { "%02x".format(it) }
    }

    private fun escapeDesktopValue(value: String): String = value
        .replace("\\", "\\\\")
        .replace("\n", " ")
        .replace("\r", " ")
}
