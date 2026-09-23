package com.example.tinode_flutter_test.tinode

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Base64
import androidx.core.content.FileProvider
import co.tinode.tinodesdk.Tinode
import co.tinode.tinodesdk.model.Drafty
import co.tinode.tinodesdk.model.ServerMessage
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.UUID
import java.util.concurrent.Executors

/** Owns Android pickers, bounded cache files, recording and authenticated media transfer. */
class MediaBridge(private val activity: Activity, private val bridge: TinodeBridge) {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val directory = File(activity.cacheDir, "attachments").apply {
        mkdirs()
        listFiles()?.filter { it.lastModified() < System.currentTimeMillis() - 7L * 24 * 60 * 60 * 1000 }
            ?.forEach { it.delete() }
    }
    private var picker: MethodChannel.Result? = null
    private var capture: File? = null
    private var permission: MethodChannel.Result? = null
    private var recorder: MediaRecorder? = null
    private var recording: File? = null
    private var started = 0L
    private var player: MediaPlayer? = null
    private var playerId: String? = null
    private var closed = false
    private val samples = mutableListOf<Byte>()
    private val sample = object : Runnable {
        override fun run() {
            val r = recorder ?: return
            samples.add((r.maxAmplitude / 256).coerceIn(0, 127).toByte())
            if (SystemClock.elapsedRealtime() - started >= 600_000) {
                bridge.emit(mapOf("type" to "recordingLimit"))
                return
            }
            main.postDelayed(this, 100)
        }
    }
    private fun limit() = bridge.tinode?.getServerLimit(Tinode.MAX_FILE_UPLOAD_SIZE, 8L * 1024 * 1024)
        ?: (8L * 1024 * 1024)
    private fun local(path: String): File {
        val file = File(path).canonicalFile
        require(file.parentFile == directory.canonicalFile && file.isFile) { "附件文件不存在" }
        return file
    }
    private fun file(name: String): File = File(directory, UUID.randomUUID().toString() + "-" +
        name.substringAfterLast('/').substringAfterLast('\\').replace(Regex("[^\\p{L}\\p{N}._-]"), "_").takeLast(100))
    private fun background(result: MethodChannel.Result, action: () -> Any?) {
        worker.execute {
            try {
                val value = action()
                main.post { if (!closed) result.success(value) }
            } catch (e: Exception) {
                main.post { if (!closed) result.error("MEDIA_ERROR", e.message ?: "附件操作失败", null) }
            }
        }
    }
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "pick" -> pick(call.argument<String>("source") ?: "file", result)
                "startRecording" -> {
                    check(permission == null && recorder == null) { "录音已启动" }
                    if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                        permission = result
                        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 7102)
                    } else startRecording(result)
                }
                "stopRecording" -> result.success(stopRecording(call.argument<Boolean>("cancel") == true))
                "send" -> background(result) { send(call) }
                "resolve" -> background(result) { resolve(call).absolutePath }
                "open" -> {
                    val f = local(requireNotNull(call.argument<String>("path")))
                    val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.attachments", f)
                    activity.startActivity(Intent.createChooser(Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, call.argument<String>("mime") ?: "application/octet-stream")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }, "打开附件"))
                    result.success(null)
                }
                "play" -> {
                    val f = local(requireNotNull(call.argument<String>("path")))
                    stopPlayback()
                    val id = call.argument<String>("id") ?: f.path
                    val p = MediaPlayer()
                    player = p
                    playerId = id
                    p.setDataSource(f.path)
                    p.setOnPreparedListener { if (player === it) it.start() }
                    p.setOnCompletionListener { stopPlayback() }
                    p.setOnErrorListener { _, _, _ ->
                        bridge.emit(mapOf("type" to "playback", "id" to id, "error" to "音频播放失败"))
                        stopPlayback()
                        true
                    }
                    p.prepareAsync()
                    result.success(null)
                }
                "stopPlayback" -> { stopPlayback(); result.success(null) }
                "delete" -> { local(requireNotNull(call.argument<String>("path"))).delete(); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("MEDIA_ERROR", e.message ?: "附件操作失败", null)
        }
    }
    private fun pick(source: String, result: MethodChannel.Result) {
        check(picker == null) { "请先完成当前文件选择" }
        val intent = when (source) {
            "camera", "video" -> {
                capture = file(if (source == "camera") "photo.jpg" else "video.mp4")
                val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.attachments", capture!!)
                Intent(if (source == "camera") MediaStore.ACTION_IMAGE_CAPTURE else MediaStore.ACTION_VIDEO_CAPTURE).apply {
                    putExtra(MediaStore.EXTRA_OUTPUT, uri)
                    putExtra(MediaStore.EXTRA_SIZE_LIMIT, limit())
                    putExtra(MediaStore.EXTRA_DURATION_LIMIT, 60)
                    clipData = android.content.ClipData.newRawUri("capture", uri)
                    addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            }
            else -> Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                if (source == "gallery") putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
            }
        }
        picker = result
        try { activity.startActivityForResult(intent, 7101) } catch (e: Exception) {
            picker = null
            capture?.delete(); capture = null
            throw e
        }
    }
    fun onActivityResult(request: Int, code: Int, data: Intent?): Boolean {
        if (request != 7101) return false
        val result = picker ?: return true
        picker = null
        val captured = capture
        capture = null
        if (code != Activity.RESULT_OK) { captured?.delete(); result.success(null); return true }
        background(result) {
            if (captured != null && captured.length() > 0) {
                try { describe(captured, captured.name.substringAfterLast('-'), if (captured.extension == "jpg") "image/jpeg" else "video/mp4") }
                catch (e: Exception) { captured.delete(); throw e }
            } else {
                captured?.delete()
                val uri = requireNotNull(data?.data) { "未取得文件" }
                val resolver = activity.contentResolver
                var name = "attachment"
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) name = it.getString(0) ?: name
                }
                val dest = file(name)
                try {
                    resolver.openInputStream(uri)!!.use { input -> dest.outputStream().use { out ->
                        val buffer = ByteArray(65536)
                        var total = 0L
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            require(total <= limit()) { "文件超过服务器允许的大小" }
                            out.write(buffer, 0, count)
                        }
                    } }
                    describe(dest, name, resolver.getType(uri) ?: "application/octet-stream")
                } catch (e: Exception) { dest.delete(); throw e }
            }
        }
        return true
    }
    private fun describe(f: File, name: String, mime: String): Map<String, Any?> {
        require(f.length() in 1..limit()) { "文件为空或超过服务器允许的大小" }
        var width = 0; var height = 0; var duration = 0
        val kind = when {
            mime.startsWith("image/") -> {
                val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(f.path, options)
                width = options.outWidth; height = options.outHeight
                require(width > 0 && height > 0) { "无法读取此图片" }
                "IM"
            }
            mime.startsWith("video/") -> {
                val retriever = MediaMetadataRetriever()
                try {
                    retriever.setDataSource(f.path)
                    width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                    height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                    duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toIntOrNull() ?: 0
                } finally { retriever.release() }
                "VD"
            }
            else -> "EX"
        }
        return mapOf("path" to f.path, "name" to name, "mime" to mime, "kind" to kind,
            "size" to f.length(), "width" to width, "height" to height, "duration" to duration)
    }
    fun onPermissionResult(request: Int, grants: IntArray): Boolean {
        if (request != 7102) return false
        val result = permission ?: return true
        permission = null
        if (grants.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            try { startRecording(result) } catch (e: Exception) { result.error("MEDIA_ERROR", e.message, null) }
        } else result.error("MIC_PERMISSION", "需要麦克风权限才能录音", null)
        return true
    }
    @Suppress("DEPRECATION")
    private fun startRecording(result: MethodChannel.Result) {
        stopPlayback()
        val f = file("voice.m4a")
        val r = MediaRecorder()
        try {
            r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioEncodingBitRate(24000)
            r.setAudioSamplingRate(16000)
            r.setOutputFile(f.path)
            r.prepare(); r.start()
            recorder = r; recording = f; started = SystemClock.elapsedRealtime()
            samples.clear(); main.post(sample)
            result.success(null)
        } catch (e: Exception) { r.release(); f.delete(); throw e }
    }
    private fun stopRecording(cancel: Boolean): Map<String, Any?>? {
        val r = recorder ?: return null
        val f = recording!!
        recorder = null; recording = null
        main.removeCallbacks(sample)
        val duration = (SystemClock.elapsedRealtime() - started).toInt()
        try { r.stop() } catch (e: Exception) { f.delete(); if (!cancel) throw IllegalStateException("录音太短，请重试", e) }
        finally { r.release() }
        if (cancel || duration < 1000) { f.delete(); if (!cancel) error("录音至少需要 1 秒"); return null }
        // Tinode uses a compact array of amplitude bytes for its waveform.
        val waveform = ByteArray(64) { i -> samples.getOrElse(i * samples.size / 64) { 0 } }
        return mapOf("path" to f.path, "name" to "voice.m4a", "mime" to "audio/mp4",
            "kind" to "AU", "duration" to duration, "preview" to waveform, "size" to f.length())
    }
    private fun send(call: MethodCall): Map<String, Any?> {
        val client = requireNotNull(bridge.tinode) { "请先登录" }
        check(client.isAuthenticated) { "请先登录" }
        val topicName = requireNotNull(call.argument<String>("topic"))
        val topic = requireNotNull(client.getTopic(topicName)) { "会话不存在" }
        val args = requireNotNull(call.argument<Map<String, Any?>>("attachment"))
        val f = local(args["path"] as String)
        require(f.length() in 1..limit()) { "文件为空或超过服务器允许的大小" }
        val rawMime = args["mime"] as? String ?: "application/octet-stream"
        // application/json is reserved by Drafty for form responses.
        val mime = if (rawMime == "application/json") "application/octet-stream" else rawMime
        val name = (args["name"] as? String ?: f.name).replace(Regex("[\\r\\n\"]"), "_")
        val id = call.argument<String>("id") ?: f.name
        val uploaded = f.inputStream().use { input ->
            client.largeFileHelper.upload(input, name, mime, f.length(), topicName) { sent, size ->
                bridge.emit(mapOf("type" to "upload", "id" to id, "sent" to sent, "size" to size))
            }
        }
        check(uploaded.ctrl?.code == 200) { uploaded.ctrl?.text ?: "上传失败" }
        val ref = requireNotNull(uploaded.ctrl.getStringParam("url", null)) { "服务器未返回附件地址" }
        val draft = Drafty()
        fun number(key: String) = (args[key] as? Number)?.toInt() ?: 0
        when (args["kind"]) {
            "IM" -> draft.insertImage(0, mime, null, number("width"), number("height"), name, URI(ref), f.length())
            "AU" -> draft.insertAudio(0, mime, null, args["preview"] as? ByteArray, number("duration"), name, URI(ref), f.length())
            "VD" -> draft.insertVideo(0, mime, null, number("width"), number("height"), null, null, null,
                number("duration"), name, URI(ref), f.length())
            else -> draft.attachFile(mime, name, ref, f.length())
        }
        // getTopic returns a raw Java Topic, so Kotlin sees this result as Any.
        val reply = topic.publish(draft).getResult() as? ServerMessage<*, *, *, *>
            ?: error("服务器未返回有效的发送回执")
        return mapOf("topic" to topicName, "seq" to (reply.ctrl?.getIntParam("seq", 0) ?: 0),
            "self" to true, "from" to client.myId, "content" to "", "time" to java.time.Instant.now().toString(),
            "attachments" to bridge.attachments(draft))
    }
    private fun resolve(call: MethodCall): File {
        val a = requireNotNull(call.argument<Map<String, Any?>>("attachment"))
        (a["path"] as? String)?.let { return local(it) }
        val dest = file(a["name"] as? String ?: "attachment")
        try {
            val ref = a["ref"] as? String
            if (!ref.isNullOrBlank()) {
                val client = requireNotNull(bridge.tinode) { "请先登录" }
                val base = client.baseUrl
                val url = URL(base, ref)
                require(url.protocol == "https" || url.protocol == "http") { "附件地址无效" }
                val conn = url.openConnection() as HttpURLConnection
                try {
                    conn.instanceFollowRedirects = false
                    conn.connectTimeout = 15000; conn.readTimeout = 30000
                    // Never forward session credentials to an external attachment host.
                    if (url.protocol == base.protocol && url.host == base.host && url.port == base.port) {
                        client.largeFileHelper.headers().forEach { (k, v) -> conn.setRequestProperty(k, v) }
                    }
                    require(conn.responseCode in 200..299) { "附件下载失败：${conn.responseCode}" }
                    conn.inputStream.use { input -> dest.outputStream().use { output ->
                        val buffer = ByteArray(65536); var total = 0L
                        while (true) {
                            val n = input.read(buffer); if (n < 0) break
                            total += n; require(total <= limit()) { "附件过大" }
                            output.write(buffer, 0, n)
                        }
                    } }
                } finally { conn.disconnect() }
            } else {
                val value = a["val"]
                val bytes = when (value) {
                    is ByteArray -> value
                    is String -> Base64.decode(value, Base64.DEFAULT)
                    else -> error("附件内容不存在")
                }
                require(bytes.size.toLong() <= limit()) { "附件过大" }
                dest.writeBytes(bytes)
            }
            return dest
        } catch (e: Exception) { dest.delete(); throw e }
    }
    private fun stopPlayback() {
        player?.release(); player = null
        playerId?.let { bridge.emit(mapOf("type" to "playback", "id" to it)) }
        playerId = null
    }
    fun pause() {
        stopPlayback()
        if (recorder != null) {
            stopRecording(true)
            bridge.emit(mapOf("type" to "recordingCancelled"))
        }
    }
    fun dispose() {
        pause(); closed = true
        picker?.error("CANCELLED", "页面已关闭", null); picker = null
        permission?.error("CANCELLED", "页面已关闭", null); permission = null
        worker.shutdownNow()
    }
}
