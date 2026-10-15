package com.nativOS.runtime

import android.content.Context
import android.os.Process
import android.os.SystemClock
import android.system.Os
import java.io.File

/** This source copy targets the integrated GSI, not the standalone root APK. */
object IntegratedRuntime {
    const val enabled = true
    val temporaryDirectory: File
        get() = File("/data/misc/nativos/display/${Process.myUid()}")
    val linuxRoot = File("/system/etc/nativos/linux")

    fun configureEnvironment(context: Context) {
        val prefix = File("/system/etc/nativos/x11")
        val helperTmp = File(context.cacheDir, "xkb-helper").apply { mkdirs() }
        val native = File(context.applicationInfo.nativeLibraryDir)
        Os.setenv("NATIVOS_NATIVE_LIBDIR", native.absolutePath, true)
        Os.setenv("PROOT_TMP_DIR", helperTmp.absolutePath, true)
        Os.setenv("XKB_BIN_DIRECTORY", File(prefix, "bin").absolutePath, true)
        Os.setenv("TMPDIR", temporaryDirectory.absolutePath, true)
        Os.setenv("XDG_RUNTIME_DIR", temporaryDirectory.absolutePath, true)
        Os.setenv("XKB_CONFIG_ROOT", File(linuxRoot, "usr/share/X11/xkb").absolutePath, true)
        Os.setenv("PREFIX", prefix.absolutePath, true)
        Os.setenv("HOME", context.filesDir.absolutePath, true)
    }

    private fun checked(operation: RuntimeClient.Operation, width: Int? = null, height: Int? = null): String =
        when (val reply = RuntimeClient().request(operation, width, height)) {
            is RuntimeClient.Reply.Success -> reply.state
            is RuntimeClient.Reply.Failure -> error("Linux service: ${reply.reason}")
        }

    // Called by the boot worker, never on the Android UI thread.
    fun prepare() {
        check(checked(RuntimeClient.Operation.PREPARE) == "PREPARED")
        check(File(linuxRoot, ".nativos-source-sha256").isFile) { "System Linux filesystem missing" }
        check(File(temporaryDirectory, ".X11-unix").isDirectory) { "Linux display storage unavailable" }
    }

    fun start(width: Int, height: Int) {
        // A killed launcher cannot run onDestroy. A fresh display must not reuse
        // the old compositor, which still holds its dead X11 connection.
        checked(RuntimeClient.Operation.STOP)
        val stopDeadline = SystemClock.elapsedRealtime() + 8000
        while (checked(RuntimeClient.Operation.STATUS) != "STOPPED") {
            check(SystemClock.elapsedRealtime() < stopDeadline) { "Previous Linux session did not stop" }
            SystemClock.sleep(100)
        }
        checked(RuntimeClient.Operation.START, width, height)
        SystemClock.sleep(500)
        check(checked(RuntimeClient.Operation.STATUS) == "RUNNING") { "Linux runner exited during startup" }
        // RUNNING is only process liveness; rendering must be verified separately.
    }

    fun stop() { checked(RuntimeClient.Operation.STOP) }

    fun resizeDisplay(width: Int, height: Int): Boolean = IntegratedDisplay.resize(width, height)
}
