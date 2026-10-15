package com.nativOS.runtime

import android.net.LocalSocket
import android.net.LocalSocketAddress
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Small bounded X11 client for our own nested compositor. Runs as the app UID,
 * not through the privileged runtime or a shell. Never resizes ordinary apps.
 * Wire format: X.Org core protocol, connection setup/QueryTree/GetProperty/
 * GetWindowAttributes/ConfigureWindow/GetGeometry. */
internal object IntegratedDisplay {
    private fun buffer(size: Int) = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN)
    private fun bytes(input: InputStream, size: Int): ByteArray {
        require(size in 0..65536)
        val result = ByteArray(size)
        var offset = 0
        while (offset < size) {
            val count = input.read(result, offset, size - offset)
            check(count > 0) { "X11 connection closed" }
            offset += count
        }
        return result
    }
    private fun u16(data: ByteArray, offset: Int) =
        ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN).getShort(offset).toInt() and 65535
    private fun i32(data: ByteArray, offset: Int) =
        ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN).getInt(offset)

    @Synchronized fun resize(width: Int, height: Int): Boolean {
        require(width in 240..8192 && height in 240..8192 && width.toLong() * height <= 16777216L)
        LocalSocket().use { socket ->
            socket.connect(LocalSocketAddress(
                "${IntegratedRuntime.temporaryDirectory}/.X11-unix/X0", LocalSocketAddress.Namespace.FILESYSTEM))
            socket.soTimeout = 1500
            val input = socket.inputStream
            val output = socket.outputStream
            output.write(buffer(12).put('l'.code.toByte()).put(0).putShort(11).putShort(0)
                .putShort(0).putShort(0).putShort(0).array())
            output.flush()
            val setupHeader = bytes(input, 8)
            check(setupHeader[0].toInt() == 1) { "X11 setup rejected" }
            val setup = bytes(input, u16(setupHeader, 6) * 4)
            check(setup.size >= 32 && setup[20].toInt() == 1) { "Expected one X11 screen" }
            val screenOffset = 32 + ((u16(setup, 16) + 3) and -4) + (setup[21].toInt() and 255) * 8
            check(screenOffset + 40 <= setup.size)
            val root = i32(setup, screenOffset)
            var sequence = 0
            fun send(request: ByteArray) {
                sequence++
                output.write(request)
                output.flush()
            }
            fun reply(): ByteArray {
                repeat(64) {
                    val header = bytes(input, 32)
                    val type = header[0].toInt() and 127
                    check(type != 0) { "X11 request failed: ${header[1].toInt() and 255}" }
                    if (type == 1) {
                        check(u16(header, 2) == sequence) { "Unexpected X11 sequence" }
                        val length = i32(header, 4)
                        check(length in 0..16384)
                        return header + bytes(input, length * 4)
                    }
                    check(type != 35) { "Unexpected generic X11 event" }
                }
                error("Too many X11 events")
            }
            send(buffer(8).put(15).put(0).putShort(2).putInt(root).array())
            val tree = reply()
            val count = u16(tree, 16)
            check(count <= 32 && tree.size >= 32 + count * 4)
            val candidates = mutableListOf<Int>()
            repeat(count) { index ->
                val window = i32(tree, 32 + index * 4)
                send(buffer(8).put(3).put(0).putShort(2).putInt(window).array())
                val attributes = reply()
                if (attributes[26].toInt() == 2) {
                    // WM_CLASS is predefined atom 67. Phoc's undecorated nested
                    // output has no class; X11 application windows do.
                    send(buffer(24).put(20).put(0).putShort(6).putInt(window)
                        .putInt(67).putInt(0).putInt(0).putInt(64).array())
                    val property = reply()
                    if (i32(property, 8) == 0 && i32(property, 12) == 0 && i32(property, 16) == 0)
                        candidates.add(window)
                }
            }
            check(candidates.size == 1) { "Nested compositor not uniquely identified (${candidates.size})" }
            val window = candidates.single()
            send(buffer(28).put(12).put(0).putShort(7).putInt(window).putShort(15).putShort(0)
                .putInt(0).putInt(0).putInt(width).putInt(height).array())
            send(buffer(8).put(14).put(0).putShort(2).putInt(window).array())
            val geometry = reply()
            return u16(geometry, 16) == width && u16(geometry, 18) == height
        }
    }
}
