package com.nativOS.runtime

import android.net.LocalSocket
import android.net.LocalSocketAddress
import java.io.IOException

/** Call off the UI thread. This client never invokes su or sends shell commands. */
class RuntimeClient {
    enum class Operation { PREPARE, STATUS, START, STOP }
    sealed class Reply {
        data class Success(val state: String) : Reply()
        data class Failure(val reason: String) : Reply()
    }

    fun request(operation: Operation, width: Int? = null, height: Int? = null): Reply = try {
        require((width == null) == (height == null))
        require(width == null || (operation == Operation.START && width in 240..8192
            && height!! in 240..8192 && width.toLong() * height <= 16777216L))
        LocalSocket().use { socket ->
            socket.connect(LocalSocketAddress("nativos_runtime", LocalSocketAddress.Namespace.RESERVED))
            socket.soTimeout = 3000
            val geometry = if (width == null) "" else " $width $height"
            socket.outputStream.write("NATIVOS/1 ${operation.name}$geometry\n".toByteArray(Charsets.US_ASCII))
            socket.outputStream.flush()
            val response = StringBuilder()
            while (response.length < 64) {
                val byte = socket.inputStream.read()
                if (byte < 0) throw IOException("Truncated runtime response")
                if (byte == 10) break
                response.append(byte.toChar())
            }
            when (val text = response.toString()) {
                "OK PREPARED", "OK STOPPED", "OK STARTING", "OK RUNNING", "OK STOPPING", "OK FAILED" -> Reply.Success(text.removePrefix("OK "))
                "ERR STORAGE_UNAVAILABLE", "ERR UNAUTHORIZED", "ERR STOPPING", "ERR RUNNER_UNAVAILABLE", "ERR SPAWN_FAILED", "ERR BAD_REQUEST", "ERR SESSION_OWNED" -> Reply.Failure(text.removePrefix("ERR "))
                else -> if (text.startsWith("ERR RUNNER_EXIT_")) {
                    Reply.Failure(text.removePrefix("ERR "))
                } else {
                    Reply.Failure("INVALID_RESPONSE")
                }
            }
        }
    } catch (error: IOException) {
        val detail = error.message?.replace(Regex("[^A-Za-z0-9 ._:/()-]"), "?")
            ?.take(96).orEmpty()
        Reply.Failure(if (detail.isEmpty()) "SERVICE_UNAVAILABLE" else "SERVICE_UNAVAILABLE ($detail)")
    }
}
