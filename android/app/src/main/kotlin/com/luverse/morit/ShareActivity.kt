package com.luverse.morit

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

private const val SHARE_CHANNEL = "com.luverse.morit/share"
private const val MAX_SHARED_URIS = 20
private const val MAX_SHARED_TOTAL_BYTES = 500L * 1024 * 1024
private const val MAX_SHARED_TEXT_CHARS = 100_000
private const val MAX_SHARED_SUBJECT_CHARS = 500

class ShareActivity : NativeFlutterActivity() {
    private lateinit var initialShare: Map<String, Any?>

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        initialShare = try {
            parseShare(intent)
        } catch (_: Exception) {
            mapOf("error" to "invalid_share_payload", "uris" to emptyList<String>())
        }
        super.onCreate(savedInstanceState)
    }

    override fun getInitialRoute() = "/share"

    override fun getBackgroundMode() = BackgroundMode.transparent

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "getInitialShare") result.success(initialShare)
                else result.notImplemented()
            }
    }

    private fun parseShare(intent: Intent): Map<String, Any?> {
        if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) {
            return emptyMap()
        }
        val uris = linkedSetOf<Uri>()
        intent.data?.let(uris::add)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)?.let(uris::addAll)
            } else {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)?.let(uris::add)
            }
        } else {
            addLegacyStreams(intent, uris)
        }
        intent.clipData?.let { clip ->
            require(clip.itemCount <= MAX_SHARED_URIS) { "too many shared items" }
            for (index in 0 until clip.itemCount) clip.getItemAt(index).uri?.let(uris::add)
        }
        require(uris.size <= MAX_SHARED_URIS) { "too many shared items" }
        var totalBytes = 0L
        val files = uris.map { uri ->
            require(uri.scheme == "content") { "shared files must use content URIs" }
            val metadata = contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null,
                null,
                null,
            )?.use { cursor ->
                if (!cursor.moveToFirst()) null
                else {
                    val name = if (cursor.isNull(0)) null else cursor.getString(0)
                    val size = if (cursor.isNull(1)) null else cursor.getLong(1)
                    name to size
                }
            }
            val size = metadata?.second
            require(size != null && size >= 0) { "shared file size is unavailable" }
            totalBytes += size
            require(totalBytes <= MAX_SHARED_TOTAL_BYTES) { "shared files exceed 500 MiB" }
            mapOf(
                "uri" to uri.toString(),
                "fileName" to (metadata.first?.take(255) ?: "shared-file"),
                "mimeType" to (contentResolver.getType(uri) ?: intent.type)?.take(255),
                "sizeBytes" to size,
            )
        }
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
        require(text == null || text.length <= MAX_SHARED_TEXT_CHARS) { "shared text is too long" }
        require(subject == null || subject.length <= MAX_SHARED_SUBJECT_CHARS) { "shared subject is too long" }
        return mapOf(
            "action" to intent.action,
            "mimeType" to intent.type,
            "text" to text,
            "subject" to subject,
            "uris" to uris.map(Uri::toString),
            "files" to files,
        )
    }

    @Suppress("DEPRECATION")
    private fun addLegacyStreams(intent: Intent, uris: MutableSet<Uri>) {
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let(uris::addAll)
        } else {
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let(uris::add)
        }
    }
}
