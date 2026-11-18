package com.shiyu.probe.shiyu_playback_probe

import android.app.Activity
import android.content.Intent
import android.database.Cursor
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.lang.ref.WeakReference
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.min

/** Single-document SAF input, isolated from playback hosts and storage grants.
 * Never allocates using provider SIZE. A blocked provider retains active/busy
 * ownership until its actual copy finally ends; cancellation is not a fake join.
 */
class BoundedDocumentImport(activity: Activity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {
    private val activityRef = WeakReference(activity)
    private val channel = MethodChannel(messenger, "shiyu/material_import")
    private val instanceId = Any()
    private var disposed = false

    init { channel.setMethodCallHandler(this) }

    private class Request(
        val id: String,
        val code: Int,
        val owner: Any,
        val result: MethodChannel.Result,
        val directory: File,
    ) {
        @Volatile var cancelled = false
        @Volatile var copying = false
        @Volatile var stream: InputStream? = null
        @Volatile var thread: Thread? = null
        @Volatile var closeRequested = false
        @Volatile var copyEnded = false
        var cleanupPending = false
        var replied = false
        var createdNext = false
        var createdSource = false
    }

    companion object {
        private const val MAX_SOURCE_BYTES = 20 * 1024 * 1024
        private val ids = Regex("^[a-f0-9]{32}$")
        private val gate = Any()
        private val main = Handler(Looper.getMainLooper())
        private val copyExecutor = Executors.newSingleThreadExecutor()
        private val closeExecutor = Executors.newSingleThreadExecutor()
        private val nextCode = AtomicInteger(0x5000)
        private var active: Request? = null
        private val stages = mutableMapOf<String, Request>()
    }

    private fun requestId(call: MethodCall): String? =
        call.argument<String>("requestId")?.takeIf { ids.matches(it) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val id = requestId(call)
        if (id == null) { result.error("invalid_request", "Import request invalid", null); return }
        when (call.method) {
            "pick" -> pick(id, result)
            "cancel" -> {
                val current = synchronized(gate) { active?.takeIf { it.id == id } }
                if (current != null) cancel(current)
                result.success(mapOf("idle" to synchronized(gate) { active?.id != id }))
            }
            "status" -> result.success(mapOf("idle" to synchronized(gate) { active?.id != id }))
            "discard" -> {
                val current = synchronized(gate) { active?.takeIf { it.id == id } }
                if (current != null && !current.copyEnded) {
                    result.success(mapOf("idle" to false)); return
                }
                val stage = synchronized(gate) { stages[id] } ?: current
                if (stage != null && !cleanupOwned(stage)) {
                    stage.cleanupPending = true
                    result.error("read_failed", "Temporary import cleanup unconfirmed", null); return
                }
                synchronized(gate) { stages.remove(id); if (active === stage) active = null }
                result.success(mapOf("idle" to true))
            }
            else -> result.notImplemented()
        }
    }

    private fun pick(id: String, result: MethodChannel.Result) {
        val activity = activityRef.get()
        if (disposed || activity == null || activity.isFinishing) {
            result.error("unavailable", "Import unavailable", null); return
        }
        val request = synchronized(gate) {
            if (active != null || stages.containsKey(id)) null
            else Request(id, nextCode.getAndIncrement() and 0x7fff, instanceId, result,
                File(activity.cacheDir, "material_import_v1")).also { active = it }
        }
        if (request == null) { result.error("busy", "Import already active", null); return }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("text/plain",
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document"))
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, false)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, request.code)
        } catch (_: Exception) { finish(request, "unavailable") }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val request = synchronized(gate) {
            active?.takeIf { it.owner === instanceId && it.code == requestCode }
        } ?: return false
        val uri = data?.data
        if (request.cancelled || resultCode != Activity.RESULT_OK || uri == null) {
            finish(request, null); return true
        }
        if (uri.scheme != "content") { finish(request, "denied"); return true }
        val activity = activityRef.get()
        if (activity == null) { finish(request, "unavailable"); return true }
        val resolver = activity.applicationContext.contentResolver
        request.copying = true
        copyExecutor.execute {
            request.thread = Thread.currentThread()
            var name = "imported-document"
            var total = 0
            var error: String? = null
            try {
                if (request.cancelled) throw Cancelled()
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                    null, null, null)?.use { cursor: Cursor ->
                    if (cursor.moveToFirst()) {
                        val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (nameColumn >= 0 && !cursor.isNull(nameColumn)) {
                            name = cursor.getString(nameColumn).substringAfterLast('/')
                                .replace('\\', '_').filter { it.code >= 32 }.take(256)
                        }
                        val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (sizeColumn >= 0 && !cursor.isNull(sizeColumn) &&
                            cursor.getLong(sizeColumn) > MAX_SOURCE_BYTES) throw TooLarge()
                    }
                }
                if (request.cancelled) throw Cancelled()
                if (!request.directory.exists() && !request.directory.mkdirs()) throw IllegalStateException()
                val next = File(request.directory, "${request.id}.next")
                val source = File(request.directory, "${request.id}.source")
                if (source.exists() || !next.createNewFile()) throw IllegalStateException()
                request.createdNext = true
                if (request.cancelled) throw Cancelled()
                val input = resolver.openInputStream(uri) ?: throw IllegalStateException()
                request.stream = input
                input.use { stream ->
                    FileOutputStream(next).use { output ->
                        val buffer = ByteArray(16 * 1024)
                        var emptyReads = 0
                        while (true) {
                            if (request.cancelled) throw Cancelled()
                            val count = stream.read(buffer, 0, min(buffer.size, MAX_SOURCE_BYTES - total + 1))
                            if (count < 0) break
                            if (count == 0) { if (++emptyReads > 10) throw IllegalStateException(); continue }
                            emptyReads = 0
                            if (total + count > MAX_SOURCE_BYTES) throw TooLarge()
                            output.write(buffer, 0, count)
                            total += count
                        }
                        if (request.cancelled) throw Cancelled()
                        output.flush()
                        output.fd.sync()
                    }
                }
                request.stream = null
                if (request.cancelled) throw Cancelled()
                if (!source.createNewFile()) throw IllegalStateException()
                request.createdSource = true
                if (!next.renameTo(source)) throw IllegalStateException()
                request.createdNext = false
            } catch (_: TooLarge) { error = "too_large"
            } catch (_: SecurityException) { error = "denied"
            } catch (_: Cancelled) { request.cancelled = true
            } catch (_: Exception) { error = if (request.cancelled) null else "read_failed"
            } finally {
                request.stream = null
                request.thread = null
                // This finally follows actual stream/use closure. Never retire
                // the active request just because interrupt/cancel was asked.
                finish(request, error, name, total)
                Thread.interrupted()
            }
        }
        return true
    }

    private class TooLarge : Exception()
    private class Cancelled : Exception()

    private fun cancel(request: Request) {
        request.cancelled = true
        if (request.copyEnded) {
            if (cleanupOwned(request)) {
                request.cleanupPending = false
                synchronized(gate) {
                    stages.remove(request.id)
                    if (active === request) active = null
                }
            }
            return
        }
        request.thread?.interrupt()
        if (!request.copying) {
            try { activityRef.get()?.finishActivity(request.code) } catch (_: Exception) {}
            // No provider input/copy exists yet. The unique activity request
            // code keeps a late picker result from attaching to a later import.
            finish(request, null)
        } else if (!request.closeRequested) {
            request.closeRequested = true
            closeExecutor.execute { try { request.stream?.close() } catch (_: Exception) {} }
        }
    }

    private fun finish(request: Request, error: String?, name: String = "", size: Int = 0) {
        request.copyEnded = true
        main.post {
            if (request.replied) return@post
            request.replied = true
            val success = error == null && !request.cancelled && request.createdSource
            val cleanupConfirmed = success || cleanupOwned(request)
            request.cleanupPending = !cleanupConfirmed
            synchronized(gate) {
                if (cleanupConfirmed && active === request) active = null
                if (success || !cleanupConfirmed) stages[request.id] = request
            }
            if (success) request.result.success(mapOf("requestId" to request.id,
                "handle" to request.id, "name" to name, "byteLength" to size))
            else if (!cleanupConfirmed) request.result.error("read_failed", "Temporary import cleanup unconfirmed", null)
            else if (request.cancelled || error == null) request.result.success(mapOf("cancelled" to true))
            else request.result.error(error, "Document import did not complete", null)
        }
    }

    private fun cleanupOwned(request: Request): Boolean {
        var confirmed = true
        if (request.createdNext) {
            val next = File(request.directory, "${request.id}.next")
            if (!next.exists() || next.delete()) request.createdNext = false
            else confirmed = false
        }
        if (request.createdSource) {
            val source = File(request.directory, "${request.id}.source")
            if (!source.exists() || source.delete()) request.createdSource = false
            else confirmed = false
        }
        return confirmed
    }

    fun dispose() {
        disposed = true
        synchronized(gate) { active?.takeIf { it.owner === instanceId } }?.let { cancel(it) }
        channel.setMethodCallHandler(null)
    }
}
