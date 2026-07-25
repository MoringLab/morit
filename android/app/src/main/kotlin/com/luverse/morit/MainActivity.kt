package com.luverse.morit

import android.Manifest
import android.app.AlarmManager
import android.app.DownloadManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import android.webkit.URLUtil
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

private const val NATIVE_CHANNEL = "com.luverse.morit/native"
private const val REMINDER_CHANNEL_ID = "reminders"
private const val NOTIFICATION_PERMISSION_REQUEST = 7001
private const val STORAGE_PERMISSION_REQUEST = 7002
private const val MAX_SHARED_FILE_BYTES = 500L * 1024 * 1024
private const val DOWNLOAD_SUBDIRECTORY = "Morit"
private const val DOWNLOAD_PREFERENCES = "download_locations"
private const val LEGACY_DOWNLOADS_PUBLISHED = "legacy_downloads_published_v1"
private const val DOWNLOAD_MIME_SUFFIX = ".mime"
private const val DOWNLOAD_NAME_SUFFIX = ".name"
private const val DOWNLOAD_KIND_SUFFIX = ".kind"
private const val DOWNLOAD_EXPECTED_LENGTH_SUFFIX = ".expected_length"
private const val DOWNLOAD_COMPLETE_CHANNEL_ID = "download_complete"

internal fun mediaSignatureError(
    bytes: ByteArray,
    mimeType: String?,
    fileName: String?,
    mediaKind: String?,
): String? {
    val mime = mimeType?.substringBefore(';')?.trim()?.lowercase().orEmpty()
    val extension = fileName?.substringAfterLast('.', "")?.lowercase().orEmpty()
    val mediaExpected =
        mediaKind in setOf("image", "video", "audio") ||
            mime.startsWith("image/") ||
            mime.startsWith("video/") ||
            mime.startsWith("audio/")
    if (mediaExpected) {
        val text = bytes.toString(Charsets.US_ASCII).trimStart().lowercase()
        if (text.startsWith("<!doctype html") || text.startsWith("<html")) {
            return "서버가 미디어 대신 HTML 오류 페이지를 반환했습니다."
        }
        if (text.startsWith("{") || text.startsWith("[")) {
            return "서버가 미디어 대신 JSON 오류 응답을 반환했습니다."
        }
    }

    val format = when {
        mime in setOf("image/jpeg", "image/jpg") || extension in setOf("jpg", "jpeg") ->
            "JPEG"
        mime == "image/png" || extension == "png" -> "PNG"
        mime == "image/gif" || extension == "gif" -> "GIF"
        mime == "image/webp" || extension == "webp" -> "WebP"
        mime in setOf("video/mp4", "video/quicktime", "audio/mp4", "audio/x-m4a") ||
            extension in setOf("mp4", "m4v", "mov", "m4a") -> "MP4/M4A"
        mime in setOf("video/webm", "audio/webm") || extension == "webm" -> "WebM"
        mime in setOf("audio/mpeg", "audio/mp3") || extension == "mp3" -> "MP3"
        mime in setOf("audio/ogg", "application/ogg") || extension in setOf("ogg", "oga") ->
            "Ogg"
        mime in setOf("audio/wav", "audio/x-wav", "audio/wave") || extension == "wav" ->
            "WAV"
        else -> return null
    }
    val valid = when (format) {
        "JPEG" -> bytes.hasPrefix(0xFF, 0xD8, 0xFF)
        "PNG" -> bytes.hasPrefix(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
        "GIF" -> bytes.hasAsciiPrefix("GIF87a") || bytes.hasAsciiPrefix("GIF89a")
        "WebP" ->
            bytes.hasAsciiPrefix("RIFF") &&
                bytes.size >= 12 &&
                bytes.copyOfRange(8, 12).hasAsciiPrefix("WEBP")
        "MP4/M4A" ->
            bytes.size >= 8 &&
                bytes.copyOfRange(4, 8).hasAsciiPrefix("ftyp")
        "WebM" -> bytes.hasPrefix(0x1A, 0x45, 0xDF, 0xA3)
        "MP3" ->
            bytes.hasAsciiPrefix("ID3") ||
                (
                    bytes.size >= 2 &&
                        (bytes[0].toInt() and 0xFF) == 0xFF &&
                        (bytes[1].toInt() and 0xE0) == 0xE0 &&
                        (bytes[1].toInt() and 0x18) != 0x08 &&
                        (bytes[1].toInt() and 0x06) != 0
                )
        "Ogg" -> bytes.hasAsciiPrefix("OggS")
        "WAV" ->
            bytes.hasAsciiPrefix("RIFF") &&
                bytes.size >= 12 &&
                bytes.copyOfRange(8, 12).hasAsciiPrefix("WAVE")
        else -> false
    }
    return if (valid) null else "다운로드된 파일의 내용이 예상한 $format 형식과 일치하지 않습니다."
}

private fun ByteArray.hasPrefix(vararg expected: Int): Boolean =
    size >= expected.size &&
        expected.indices.all { index -> (this[index].toInt() and 0xFF) == expected[index] }

private fun ByteArray.hasAsciiPrefix(expected: String): Boolean =
    size >= expected.length &&
        expected.indices.all { index -> this[index].toInt() == expected[index].code }

internal data class PublicDownloadRequest(
    val url: String,
    val fileName: String?,
    val title: String?,
    val mediaKind: String,
    val description: String?,
    val mimeType: String?,
    val wifiOnly: Boolean,
    val headers: Map<String, String> = emptyMap(),
    val expectedContentLength: Long? = null,
)

internal fun enqueuePublicDownload(
    context: Context,
    value: PublicDownloadRequest,
): Map<String, Any> {
    val url = value.url.trim()
    val uri = Uri.parse(url)
    require(
        url.length <= 8192 &&
            uri.scheme.equals("https", ignoreCase = true) &&
            !uri.host.isNullOrBlank() &&
            uri.userInfo.isNullOrEmpty() &&
            uri.fragment.isNullOrEmpty(),
    ) {
        "url must be a valid https URL"
    }

    val mimeType = value.mimeType
        ?.substringBefore(';')
        ?.trim()
        ?.lowercase()
        ?.takeIf(String::isNotBlank)
    require(
        mimeType == null ||
            (
                mimeType.length <= 127 &&
                    '\n' !in mimeType &&
                    '\r' !in mimeType &&
                    Regex("""^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$""").matches(mimeType)
            ),
    ) {
        "mimeType is invalid"
    }
    require(value.mediaKind in setOf("image", "video", "audio", "file")) {
        "mediaKind is invalid"
    }
    require(value.expectedContentLength == null || value.expectedContentLength > 0) {
        "expectedContentLength must be positive"
    }

    val requestedName = value.fileName?.trim()
    val guessedName = requestedName
        ?.substringAfterLast('/')
        ?.substringAfterLast('\\')
        ?: URLUtil.guessFileName(url, null, mimeType)
    val fileName = guessedName
        .replace(Regex("""[\u0000-\u001f<>:"/\\|?*]"""), "_")
        .trim()
        .take(200)
        .takeIf(String::isNotBlank)
        ?: throw IllegalArgumentException("fileName is empty")
    require(fileName != "." && fileName != "..") { "fileName is invalid" }

    val directory = publicDownloadDirectory(mimeType, fileName, value.mediaKind)
    val request = DownloadManager.Request(uri)
        .setTitle(value.title?.trim()?.takeIf(String::isNotBlank)?.take(200) ?: fileName)
        .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE)
        .setDestinationInExternalPublicDir(
            directory,
            "$DOWNLOAD_SUBDIRECTORY/$fileName",
        )
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
        request.allowScanningByMediaScanner()
    }
    if (value.wifiOnly) {
        request.setAllowedOverMetered(false)
    }
    listOfNotNull(
        value.description?.trim()?.takeIf(String::isNotEmpty),
        "Saved to: $directory/$DOWNLOAD_SUBDIRECTORY",
    ).joinToString(" · ").take(500).let(request::setDescription)
    (mimeType ?: value.mediaKind.takeIf { it != "file" }?.let { "$it/*" })
        ?.let(request::setMimeType)
    value.headers.forEach { (key, headerValue) ->
        require(key.isNotBlank()) { "headers must contain strings" }
        require(key.lowercase() in setOf("referer", "user-agent") && headerValue.length <= 1000) {
            "header is not allowed"
        }
        require(
            '\n' !in key &&
                '\r' !in key &&
                '\n' !in headerValue &&
                '\r' !in headerValue,
        ) {
            "headers must not contain line breaks"
        }
        request.addRequestHeader(key, headerValue)
    }

    val manager = context.getSystemService(DownloadManager::class.java)
    val id = manager.enqueue(request)
    context.getSharedPreferences(DOWNLOAD_PREFERENCES, Context.MODE_PRIVATE)
        .edit()
        .putString(id.toString(), directory)
        .putString("$id$DOWNLOAD_MIME_SUFFIX", mimeType)
        .putString("$id$DOWNLOAD_NAME_SUFFIX", fileName)
        .putString("$id$DOWNLOAD_KIND_SUFFIX", value.mediaKind)
        .also { editor ->
            value.expectedContentLength?.let {
                editor.putLong("$id$DOWNLOAD_EXPECTED_LENGTH_SUFFIX", it)
            } ?: editor.remove("$id$DOWNLOAD_EXPECTED_LENGTH_SUFFIX")
        }
        .apply()
    return mapOf(
        "id" to id,
        "saveLocation" to "$directory/$DOWNLOAD_SUBDIRECTORY",
    )
}

internal fun publicDownloadDirectory(
    mimeType: String?,
    fileName: String?,
    mediaKind: String?,
): String {
    val resolvedMimeType = mimeType?.substringBefore(';')?.trim()?.lowercase()
        ?: fileName
            ?.substringAfterLast('.', "")
            ?.lowercase()
            ?.takeIf(String::isNotEmpty)
            ?.let(MimeTypeMap.getSingleton()::getMimeTypeFromExtension)
    return when {
        resolvedMimeType?.startsWith("image/") == true -> Environment.DIRECTORY_PICTURES
        resolvedMimeType?.startsWith("video/") == true -> Environment.DIRECTORY_MOVIES
        resolvedMimeType?.startsWith("audio/") == true -> Environment.DIRECTORY_MUSIC
        mediaKind == "image" -> Environment.DIRECTORY_PICTURES
        mediaKind == "video" -> Environment.DIRECTORY_MOVIES
        mediaKind == "audio" -> Environment.DIRECTORY_MUSIC
        else -> Environment.DIRECTORY_DOWNLOADS
    }
}

class MainActivity : NativeFlutterActivity() {
    override fun getInitialRoute(): String = when (intent?.action) {
        "$packageName.OPEN_DOWNLOADS" -> "/downloads"
        "$packageName.OPEN_TODAY" ->
            todayRoute(this, intent, expectedOverlayEnabled = false) ?: "/"
        else -> "/"
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        when (intent.action) {
            "$packageName.OPEN_DOWNLOADS" -> notifyOpenDownloads()
            "$packageName.OPEN_TODAY" ->
                todayIntentPayload(this, intent)
                    ?.takeIf { it["overlayEnabled"] == false }
                    ?.let(::notifyOpenToday)
        }
    }
}

class DownloadNotificationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != DownloadManager.ACTION_NOTIFICATION_CLICKED) return
        context.startActivity(
            Intent(context, MainActivity::class.java)
                .setAction("${context.packageName}.OPEN_DOWNLOADS")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
        )
    }
}

class DownloadCompleteReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != DownloadManager.ACTION_DOWNLOAD_COMPLETE) return
        val id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L)
        if (id < 0) return
        val manager = context.getSystemService(DownloadManager::class.java)
        BackendTransferScheduler.onDownloadComplete(context, id)
        manager.query(DownloadManager.Query().setFilterById(id)).use { cursor ->
            if (!cursor.moveToFirst() ||
                cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)) !=
                DownloadManager.STATUS_SUCCESSFUL
            ) return
            val localUri = cursor.getString(
                cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI),
            ) ?: return
            Uri.parse(localUri).takeIf { it.scheme == "file" }?.path?.let { path ->
                MediaScannerConnection.scanFile(
                    context,
                    arrayOf(path),
                    arrayOf(manager.getMimeTypeForDownloadedFile(id) ?: "*/*"),
                    null,
                )
            }
            postDownloadCompleteNotification(context, manager, id)
        }
    }
}

private fun postDownloadCompleteNotification(
    context: Context,
    manager: DownloadManager,
    id: Long,
) {
    val notificationManager = context.getSystemService(NotificationManager::class.java)
    if (!notificationManager.areNotificationsEnabled()) return
    val uri = manager.getUriForDownloadedFile(id) ?: return
    val mimeType = manager.getMimeTypeForDownloadedFile(id) ?: "*/*"
    val preferences = context.getSharedPreferences(DOWNLOAD_PREFERENCES, Context.MODE_PRIVATE)
    val fileName = preferences.getString("$id$DOWNLOAD_NAME_SUFFIX", null) ?: "다운로드 파일"
    val directory = preferences.getString(id.toString(), Environment.DIRECTORY_DOWNLOADS)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        notificationManager.createNotificationChannel(
            NotificationChannel(
                DOWNLOAD_COMPLETE_CHANNEL_ID,
                "다운로드 완료",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "완료된 파일 열기, 위치 보기, 공유"
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            },
        )
    }
    fun activity(requestCode: Int, intent: Intent): PendingIntent =
        PendingIntent.getActivity(
            context,
            requestCode,
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    val requestCode = (id xor (id ushr 32)).toInt() and 0x3fffffff
    val open = activity(
        requestCode,
        Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, mimeType)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
    )
    val share = activity(
        requestCode xor 0x10000000,
        Intent.createChooser(
            Intent(Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                clipData = ClipData.newUri(context.contentResolver, fileName, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            },
            "파일 공유",
        ),
    )
    val folder = activity(
        requestCode xor 0x20000000,
        Intent(DownloadManager.ACTION_VIEW_DOWNLOADS),
    )
    val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        Notification.Builder(context, DOWNLOAD_COMPLETE_CHANNEL_ID)
    } else {
        Notification.Builder(context)
    }
    notificationManager.notify(
        requestCode xor 0x3D0A0000,
        builder
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentTitle("다운로드 완료")
            .setContentText("$fileName · $directory/$DOWNLOAD_SUBDIRECTORY")
            .setContentIntent(open)
            .addAction(android.R.drawable.ic_menu_view, "열기", open)
            .addAction(android.R.drawable.ic_menu_agenda, "폴더", folder)
            .addAction(android.R.drawable.ic_menu_share, "공유", share)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_STATUS)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .build(),
    )
}

open class NativeFlutterActivity : FlutterActivity() {
    private var notificationPermissionResult: MethodChannel.Result? = null
    private var pendingDownloadPermission: Pair<MethodCall, MethodChannel.Result>? = null
    private var nativeChannel: MethodChannel? = null
    @Volatile private var legacyDownloadMigrationRunning = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nativeChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NATIVE_CHANNEL)
            .also { channel ->
                channel.setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "getAppFilesPath" -> result.success(filesDir.absolutePath)
                        "deleteOwnedFile" -> result.success(deleteOwnedFile(call))
                        "enqueueDownload" -> enqueueDownload(call, result)
                        "cancelDownload" -> result.success(cancelDownload(requiredLong(call, "id")))
                        "queryDownload" -> result.success(queryDownload(requiredLong(call, "id")))
                        "scheduleBackendTransfer" -> {
                            result.success(
                                BackendTransferScheduler.schedule(
                                    context = this,
                                    statusUrl = requiredString(call, "statusUrl"),
                                    backendJobId = requiredString(call, "backendJobId"),
                                    title = requiredString(call, "title"),
                                    description = call.argument<String>("description"),
                                    wifiOnly = call.argument<Boolean>("wifiOnly") == true,
                                ),
                            )
                        }
                        "queryBackendTransfer" ->
                            result.success(
                                BackendTransferScheduler.query(
                                    this,
                                    requiredString(call, "backendJobId"),
                                ),
                            )
                        "cancelBackendTransfer" ->
                            result.success(
                                BackendTransferScheduler.cancel(
                                    this,
                                    requiredString(call, "backendJobId"),
                                ),
                            )
                        "openDownload" -> result.success(openDownload(call))
                        "copyContentUriToAppFiles" -> copyContentUriToAppFiles(call, result)
                        "openFile" -> result.success(openFile(call))
                        "requestNotificationPermission" -> requestNotificationPermission(result)
                        "scheduleReminder" -> result.success(scheduleReminder(call))
                        "cancelReminder" -> result.success(cancelReminder(call))
                        "setTodayTasks" -> {
                            result.success(
                                updateTodayNotification(
                                    this,
                                    requiredString(call, "userId"),
                                    requiredMaps(call, "tasks"),
                                    call.argument<String>("lockPolicy") ?: "device_unlock",
                                    optionalInt(call, "maxVisible", 3),
                                    call.argument<Boolean>("showCompleted") ?: true,
                                    call.argument<Boolean>("overlayEnabled") ?: true,
                                    call.argument<Boolean>("carryOverIncomplete")
                                        ?: call.argument<Boolean>("carryOver")
                                        ?: true,
                                ),
                            )
                        }
                        "readTodayActions" ->
                            result.success(readTodayActions(this, requiredString(call, "userId")))
                        "ackTodayActions" -> {
                            ackTodayActions(
                                this,
                                requiredString(call, "userId"),
                                requiredStrings(call, "ids"),
                            )
                            result.success(null)
                        }
                        "clearTodayNotification" -> {
                            clearTodayNotification(this)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: IllegalArgumentException) {
                    result.error("invalid_args", error.message, null)
                } catch (error: SecurityException) {
                    result.error("permission_denied", error.message, null)
                } catch (error: Exception) {
                    result.error("native_error", error.message ?: error.javaClass.simpleName, null)
                }
            }
            }
        publishLegacyDownloadsOnce()
    }

    protected fun notifyOpenDownloads() {
        nativeChannel?.invokeMethod("openDownloads", null)
    }

    protected fun notifyOpenToday(payload: Map<String, Any?>) {
        nativeChannel?.invokeMethod("openToday", payload)
    }

    private fun downloadManager() = getSystemService(DownloadManager::class.java)

    private fun enqueueDownload(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            if (pendingDownloadPermission != null) {
                result.error(
                    "request_in_progress",
                    "storage permission request is already open",
                    null,
                )
                return
            }
            pendingDownloadPermission = call to result
            requestPermissions(
                arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                STORAGE_PERMISSION_REQUEST,
            )
            return
        }
        result.success(enqueueDownload(call))
    }

    private fun enqueueDownload(call: MethodCall): Map<String, Any> {
        val headers = buildMap<String, String> {
            (call.argument<Map<*, *>>("headers") ?: emptyMap<Any, Any>())
                .forEach { (key, value) ->
                    require(key is String && value is String) {
                        "headers must contain strings"
                    }
                    put(key, value)
                }
        }
        return enqueuePublicDownload(
            this,
            PublicDownloadRequest(
                url = call.argument<String>("url").orEmpty(),
                fileName = call.argument<String>("fileName"),
                title = call.argument<String>("title"),
                mediaKind = call.argument<String>("mediaKind").orEmpty(),
                description = call.argument<String>("description"),
                mimeType = call.argument<String>("mimeType"),
                wifiOnly = call.argument<Boolean>("wifiOnly") == true,
                headers = headers,
                expectedContentLength =
                    call.argument<Number>("expectedContentLength")?.toLong(),
            ),
        )
    }

    private fun cancelDownload(id: Long): Int {
        val removed = downloadManager().remove(id)
        clearDownloadPreferences(id)
        return removed
    }

    private fun publishLegacyDownloadsOnce() {
        val preferences = getSharedPreferences(DOWNLOAD_PREFERENCES, Context.MODE_PRIVATE)
        if (preferences.getBoolean(LEGACY_DOWNLOADS_PUBLISHED, false) ||
            legacyDownloadMigrationRunning ||
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
                checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
                PackageManager.PERMISSION_GRANTED)
        ) return
        legacyDownloadMigrationRunning = true
        Thread {
            var completed = false
            try {
                val legacyRoot = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                    ?.canonicalFile
                    ?: return@Thread
                val downloads = mutableListOf<Triple<Long, File, String?>>()
                downloadManager()
                    .query(
                        DownloadManager.Query().setFilterByStatus(
                            DownloadManager.STATUS_SUCCESSFUL,
                        ),
                    )
                    .use { cursor ->
                        val idColumn = cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_ID)
                        val uriColumn = cursor.getColumnIndexOrThrow(
                            DownloadManager.COLUMN_LOCAL_URI,
                        )
                        while (cursor.moveToNext()) {
                            val id = cursor.getLong(idColumn)
                            val file = Uri.parse(cursor.getString(uriColumn))
                                .takeIf { it.scheme == "file" }
                                ?.path
                                ?.let(::File)
                                ?.canonicalFile
                                ?: continue
                            if (!file.isFile ||
                                !file.path.startsWith(legacyRoot.path + File.separator)
                            ) continue
                            downloads += Triple(
                                id,
                                file,
                                downloadManager().getMimeTypeForDownloadedFile(id),
                            )
                        }
                    }
                for ((id, file, mimeType) in downloads) {
                    val directory = downloadDirectory(mimeType, file.name, null)
                    publishLegacyFile(file, mimeType, directory)
                    preferences.edit().putString(id.toString(), directory).apply()
                }
                completed = true
            } catch (_: Exception) {
                // Retry next launch; originals stay untouched.
            } finally {
                if (completed) {
                    preferences.edit().putBoolean(LEGACY_DOWNLOADS_PUBLISHED, true).apply()
                }
                legacyDownloadMigrationRunning = false
            }
        }.start()
    }

    private fun publishLegacyFile(file: File, mimeType: String?, directory: String) {
        val resolvedMimeType = mimeType
            ?: file.extension
                .lowercase()
                .takeIf(String::isNotEmpty)
                ?.let(MimeTypeMap.getSingleton()::getMimeTypeFromExtension)
            ?: when (directory) {
                Environment.DIRECTORY_PICTURES -> "image/*"
                Environment.DIRECTORY_MOVIES -> "video/*"
                Environment.DIRECTORY_MUSIC -> "audio/*"
                else -> "application/octet-stream"
            }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            val targetDirectory = File(
                Environment.getExternalStoragePublicDirectory(directory),
                DOWNLOAD_SUBDIRECTORY,
            )
            require(targetDirectory.isDirectory || targetDirectory.mkdirs()) {
                "cannot create public download directory"
            }
            val target = File(targetDirectory, file.name)
            if (!target.isFile || target.length() != file.length()) {
                file.copyTo(target, overwrite = true)
            }
            MediaScannerConnection.scanFile(
                this,
                arrayOf(target.absolutePath),
                arrayOf(resolvedMimeType),
                null,
            )
            return
        }

        val relativePath = "$directory/$DOWNLOAD_SUBDIRECTORY/"
        val collection = when (directory) {
            Environment.DIRECTORY_PICTURES ->
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            Environment.DIRECTORY_MOVIES ->
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            Environment.DIRECTORY_MUSIC ->
                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
            else -> MediaStore.Downloads.EXTERNAL_CONTENT_URI
        }
        contentResolver.query(
            collection,
            arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND " +
                "${MediaStore.MediaColumns.RELATIVE_PATH} = ?",
            arrayOf(file.name, relativePath),
            null,
        )?.use { if (it.moveToFirst()) return }

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
            put(MediaStore.MediaColumns.MIME_TYPE, resolvedMimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = contentResolver.insert(collection, values)
            ?: throw IllegalStateException("cannot create public media")
        try {
            contentResolver.openOutputStream(uri, "w")?.use { output ->
                file.inputStream().use { input -> input.copyTo(output) }
            } ?: throw IllegalStateException("cannot open public media")
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
        } catch (error: Exception) {
            contentResolver.delete(uri, null, null)
            throw error
        }
    }

    private fun copyContentUriToAppFiles(call: MethodCall, result: MethodChannel.Result) {
        // ponytail: one worker per user-triggered copy; use an executor if bulk parallel imports are added.
        Thread {
            try {
                val uri = Uri.parse(call.argument<String>("uri") ?: "")
                require(uri.scheme == "content") { "uri must use the content scheme" }
                val maxBytes = call.argument<Number>("maxBytes")?.toLong()
                    ?: throw IllegalArgumentException("maxBytes is required")
                require(maxBytes in 1..MAX_SHARED_FILE_BYTES) { "maxBytes is out of range" }
                val requestedName = call.argument<String>("fileName")?.takeIf(String::isNotBlank)
                val displayName = requestedName ?: contentResolver.query(
                    uri,
                    arrayOf(OpenableColumns.DISPLAY_NAME),
                    null,
                    null,
                    null,
                )?.use { cursor ->
                    if (cursor.moveToFirst()) cursor.getString(0) else null
                }
                val extension = displayName
                    ?.substringAfterLast('.', "")
                    ?.takeIf { it.length in 1..10 && it.all(Char::isLetterOrDigit) }
                val directory = File(filesDir, "shared")
                require(directory.isDirectory || directory.mkdirs()) { "cannot create shared files directory" }
                val target = File.createTempFile("share-", extension?.let { ".$it" }, directory)
                try {
                    contentResolver.openInputStream(uri)?.use { input ->
                        target.outputStream().use { output ->
                            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                            var copied = 0L
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                copied += count
                                require(copied <= maxBytes) { "shared files exceed 500 MiB total" }
                                output.write(buffer, 0, count)
                            }
                        }
                    } ?: throw IllegalArgumentException("cannot open uri")
                    result.success(target.absolutePath)
                } catch (error: Exception) {
                    target.delete()
                    throw error
                }
            } catch (error: IllegalArgumentException) {
                result.error("invalid_args", error.message, null)
            } catch (error: SecurityException) {
                result.error("permission_denied", error.message, null)
            } catch (error: Exception) {
                result.error("native_error", error.message ?: error.javaClass.simpleName, null)
            }
        }.start()
    }

    private fun ownedFile(rawPath: String): File {
        val file = File(Uri.parse(rawPath).takeIf { it.scheme == "file" }?.path ?: rawPath).canonicalFile
        val roots = listOfNotNull(
            File(filesDir, "imports"),
            File(filesDir, "shared"),
            getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS),
        ).map(File::getCanonicalFile)
        require(roots.any { file.path.startsWith(it.path + File.separator) }) {
            "path must be an app-owned file"
        }
        return file
    }

    private fun deleteOwnedFile(call: MethodCall): Boolean {
        val file = ownedFile(call.argument<String>("path") ?: "")
        return !file.exists() || (file.isFile && file.delete())
    }

    private fun openFile(call: MethodCall): Boolean {
        val file = ownedFile(call.argument<String>("path") ?: "")
        require(file.isFile) { "path must be an existing app file" }
        val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, call.argument<String>("mimeType") ?: "*/*")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return try {
            startActivity(intent)
            true
        } catch (_: android.content.ActivityNotFoundException) {
            false
        }
    }

    private fun openDownload(call: MethodCall): Boolean {
        val id = requiredLong(call, "id")
        val uri = downloadManager().getUriForDownloadedFile(id) ?: return false
        val mimeType = downloadManager().getMimeTypeForDownloadedFile(id)
            ?: call.argument<String>("mimeType")
            ?: "*/*"
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, mimeType)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return try {
            startActivity(intent)
            true
        } catch (_: android.content.ActivityNotFoundException) {
            false
        }
    }

    private fun queryDownload(id: Long): Map<String, Any?>? =
        downloadManager().query(DownloadManager.Query().setFilterById(id)).use { cursor ->
            if (!cursor.moveToFirst()) {
                clearDownloadPreferences(id)
                return@use null
            }
            val status = cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
            val mimeType = downloadManager().getMimeTypeForDownloadedFile(id)
            val localUri = cursor.getString(
                cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI),
            )
            val downloadPreferences =
                getSharedPreferences(DOWNLOAD_PREFERENCES, Context.MODE_PRIVATE)
            val storedDirectory = downloadPreferences.getString(id.toString(), null)
            val expectedMime =
                downloadPreferences.getString("$id$DOWNLOAD_MIME_SUFFIX", null)
            val expectedName =
                downloadPreferences.getString("$id$DOWNLOAD_NAME_SUFFIX", null)
            val expectedKind =
                downloadPreferences.getString("$id$DOWNLOAD_KIND_SUFFIX", null)
            val expectedContentLength =
                if (downloadPreferences.contains("$id$DOWNLOAD_EXPECTED_LENGTH_SUFFIX")) {
                    downloadPreferences.getLong("$id$DOWNLOAD_EXPECTED_LENGTH_SUFFIX", -1L)
                        .takeIf { it > 0 }
                } else {
                    null
                }
            val bytesDownloaded = cursor.getLong(
                cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR),
            )
            val totalBytes = cursor.getLong(
                cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES),
            )
            val lastModifiedMillis = cursor.getLong(
                cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_LAST_MODIFIED_TIMESTAMP),
            )
            val legacyRoot = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                ?.absolutePath
            val saveLocation = when {
                storedDirectory != null -> "$storedDirectory/$DOWNLOAD_SUBDIRECTORY"
                legacyRoot != null &&
                    localUri?.let(Uri::parse)?.path
                        ?.startsWith(legacyRoot + File.separator) == true ->
                    "Morit 앱 저장소"
                else -> "${downloadDirectory(mimeType, null, null)}/$DOWNLOAD_SUBDIRECTORY"
            }
            if (status == DownloadManager.STATUS_SUCCESSFUL) {
                val integrityError = validateDownloadedMedia(
                    id = id,
                    expectedMime = expectedMime ?: mimeType,
                    expectedName = expectedName ?: localUri?.let(Uri::parse)?.lastPathSegment,
                    expectedKind = expectedKind,
                    bytesDownloaded = bytesDownloaded,
                    totalBytes = totalBytes,
                    expectedContentLength = expectedContentLength,
                )
                if (integrityError != null) {
                    downloadManager().remove(id)
                    clearDownloadPreferences(id)
                    return@use mapOf(
                        "id" to id,
                        "status" to DownloadManager.STATUS_FAILED,
                        "reason" to 0,
                        "bytesDownloaded" to bytesDownloaded,
                        "totalBytes" to totalBytes,
                        "localUri" to null,
                        "lastModifiedMillis" to lastModifiedMillis,
                        "saveLocation" to saveLocation,
                        "integrityFailure" to true,
                        "errorMessage" to integrityError,
                    )
                }
            }
            mapOf(
                "id" to id,
                "status" to status,
                "reason" to cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON)),
                "bytesDownloaded" to bytesDownloaded,
                "totalBytes" to totalBytes,
                "localUri" to localUri,
                "lastModifiedMillis" to lastModifiedMillis,
                "saveLocation" to saveLocation,
            )
        }

    private fun clearDownloadPreferences(id: Long) {
        getSharedPreferences(DOWNLOAD_PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .remove(id.toString())
            .remove("$id$DOWNLOAD_MIME_SUFFIX")
            .remove("$id$DOWNLOAD_NAME_SUFFIX")
            .remove("$id$DOWNLOAD_KIND_SUFFIX")
            .remove("$id$DOWNLOAD_EXPECTED_LENGTH_SUFFIX")
            .apply()
    }

    private fun validateDownloadedMedia(
        id: Long,
        expectedMime: String?,
        expectedName: String?,
        expectedKind: String?,
        bytesDownloaded: Long,
        totalBytes: Long,
        expectedContentLength: Long?,
    ): String? {
        val uri = downloadManager().getUriForDownloadedFile(id)
            ?: return "완료된 다운로드 파일을 기기에서 찾을 수 없습니다."
        val firstBytes = ByteArray(32)
        val firstByteCount = try {
            contentResolver.openInputStream(uri)?.use { it.read(firstBytes) } ?: -1
        } catch (_: Exception) {
            -1
        }
        if (firstByteCount <= 0) return "다운로드된 파일이 비어 있거나 읽을 수 없습니다."

        val descriptorSize = try {
            contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: -1
        } catch (_: Exception) {
            -1
        }
        val actualSize = descriptorSize.takeIf { it >= 0 } ?: bytesDownloaded
        if (actualSize <= 0) return "다운로드된 파일의 실제 크기가 0바이트입니다."
        if (totalBytes > 0 && actualSize != totalBytes) {
            return "다운로드된 파일의 실제 크기가 서버 응답 크기와 일치하지 않습니다."
        }
        if (expectedContentLength != null && actualSize != expectedContentLength) {
            return "다운로드된 파일 크기가 백엔드 검증 결과와 일치하지 않습니다."
        }

        mediaSignatureError(
            bytes = firstBytes.copyOf(firstByteCount),
            mimeType = expectedMime,
            fileName = expectedName,
            mediaKind = expectedKind,
        )?.let { return it }

        if (expectedKind == "video" || expectedKind == "audio") {
            val trackFormats = try {
                contentResolver.openFileDescriptor(uri, "r")?.use { descriptor ->
                    val extractor = MediaExtractor()
                    try {
                        extractor.setDataSource(descriptor.fileDescriptor)
                        (0 until extractor.trackCount).mapNotNull { index ->
                            extractor.getTrackFormat(index).takeIf { format ->
                                format
                                    .getString(MediaFormat.KEY_MIME)
                                    ?.startsWith("$expectedKind/") == true
                            }
                        }
                    } finally {
                        extractor.release()
                    }
                }.orEmpty()
            } catch (_: Exception) {
                emptyList()
            }
            if (trackFormats.isEmpty()) {
                return if (expectedKind == "video") {
                    "다운로드된 파일에서 재생 가능한 영상 트랙을 확인하지 못했습니다."
                } else {
                    "다운로드된 파일에서 재생 가능한 오디오 트랙을 확인하지 못했습니다."
                }
            }
            val hasDecoder = try {
                val codecs = MediaCodecList(MediaCodecList.ALL_CODECS)
                trackFormats.any { codecs.findDecoderForFormat(it) != null }
            } catch (_: Exception) {
                true
            }
            if (!hasDecoder) {
                return "다운로드된 파일은 이 기기에서 지원하지 않는 코덱을 사용합니다."
            }
        }
        return null
    }

    private fun downloadDirectory(
        mimeType: String?,
        fileName: String?,
        mediaKind: String?,
    ): String = publicDownloadDirectory(mimeType, fileName, mediaKind)

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        if (notificationPermissionResult != null) {
            result.error("request_in_progress", "notification permission request is already open", null)
            return
        }
        notificationPermissionResult = result
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode == NOTIFICATION_PERMISSION_REQUEST) {
            notificationPermissionResult?.success(
                grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED,
            )
            notificationPermissionResult = null
        }
        if (requestCode == STORAGE_PERMISSION_REQUEST) {
            val pending = pendingDownloadPermission
            pendingDownloadPermission = null
            if (pending != null) {
                if (grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
                ) {
                    try {
                        pending.second.success(enqueueDownload(pending.first))
                        publishLegacyDownloadsOnce()
                    } catch (error: IllegalArgumentException) {
                        pending.second.error("invalid_args", error.message, null)
                    } catch (error: SecurityException) {
                        pending.second.error("permission_denied", error.message, null)
                    } catch (error: Exception) {
                        pending.second.error(
                            "native_error",
                            error.message ?: error.javaClass.simpleName,
                            null,
                        )
                    }
                } else {
                    pending.second.error(
                        "permission_denied",
                        "공용 저장소에 저장하려면 저장소 권한이 필요합니다.",
                        null,
                    )
                }
            }
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    private fun scheduleReminder(call: MethodCall): Map<String, Any> {
        val id = requiredInt(call, "id")
        val key = requiredReminderKey(call)
        val title = call.argument<String>("title")?.trim().orEmpty()
        val body = call.argument<String>("body")?.trim().orEmpty()
        val atMillis = requiredLong(call, "atMillis")
        require(id >= 0) { "id must be non-negative" }
        require(title.isNotEmpty()) { "title is required" }
        require(atMillis > System.currentTimeMillis()) { "atMillis must be in the future" }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return mapOf("scheduled" to false, "status" to "notification_permission_required")
        }
        val notifications = getSystemService(NotificationManager::class.java)
        if (!notifications.areNotificationsEnabled()) {
            return mapOf("scheduled" to false, "status" to "notifications_disabled")
        }
        ensureReminderChannel(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            notifications.getNotificationChannel(REMINDER_CHANNEL_ID)?.importance == NotificationManager.IMPORTANCE_NONE
        ) {
            return mapOf("scheduled" to false, "status" to "reminder_channel_disabled")
        }

        val intent = Intent(this, ReminderReceiver::class.java)
            .setAction("$packageName.REMINDER")
            .setData(reminderUri(key))
            .putExtra("id", id)
            .putExtra("title", title)
            .putExtra("body", body)
        val pendingIntent = PendingIntent.getBroadcast(
            this,
            id,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        // ponytail: inexact alarms avoid special-access UX; use exact alarms only if minute precision is required.
        getSystemService(AlarmManager::class.java)
            .setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pendingIntent)
        return mapOf("scheduled" to true, "status" to "scheduled")
    }

    private fun cancelReminder(call: MethodCall): Boolean {
        val id = requiredInt(call, "id")
        val key = requiredReminderKey(call)
        require(id >= 0) { "id must be non-negative" }
        val intent = Intent(this, ReminderReceiver::class.java)
            .setAction("$packageName.REMINDER")
            .setData(reminderUri(key))
        val pendingIntent = PendingIntent.getBroadcast(
            this,
            id,
            intent,
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
        ) ?: return false
        getSystemService(AlarmManager::class.java).cancel(pendingIntent)
        pendingIntent.cancel()
        getSystemService(NotificationManager::class.java).cancel(id)
        return true
    }

    private fun requiredReminderKey(call: MethodCall): String =
        call.argument<String>("key")?.takeIf { it.isNotBlank() && it.length <= 128 }
            ?: throw IllegalArgumentException("key is required")

    private fun reminderUri(key: String): Uri = Uri.Builder()
        .scheme("morit")
        .authority("reminder")
        .appendPath(key)
        .build()

    private fun requiredLong(call: MethodCall, name: String): Long =
        call.argument<Number>(name)?.toLong()
            ?: throw IllegalArgumentException("$name is required")

    private fun requiredString(call: MethodCall, name: String): String =
        call.argument<String>(name)?.takeIf(String::isNotBlank)
            ?: throw IllegalArgumentException("$name is required")

    private fun requiredMaps(call: MethodCall, name: String): List<Map<*, *>> =
        (call.argument<List<*>>(name) ?: throw IllegalArgumentException("$name is required"))
            .map {
                it as? Map<*, *>
                    ?: throw IllegalArgumentException("$name must contain maps")
            }

    private fun requiredStrings(call: MethodCall, name: String): List<String> =
        (call.argument<List<*>>(name) ?: throw IllegalArgumentException("$name is required"))
            .map {
                it as? String
                    ?: throw IllegalArgumentException("$name must contain strings")
            }

    private fun requiredInt(call: MethodCall, name: String): Int {
        val value = requiredLong(call, name)
        require(value in Int.MIN_VALUE..Int.MAX_VALUE) { "$name is out of range" }
        return value.toInt()
    }

    private fun optionalInt(call: MethodCall, name: String, defaultValue: Int): Int {
        val value = call.argument<Number>(name)?.toLong() ?: return defaultValue
        require(value in Int.MIN_VALUE..Int.MAX_VALUE) { "$name is out of range" }
        return value.toInt()
    }
}

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return

        val id = intent.getIntExtra("id", -1)
        val title = intent.getStringExtra("title") ?: return
        if (id < 0) return
        val notifications = context.getSystemService(NotificationManager::class.java)
        if (!notifications.areNotificationsEnabled()) return
        ensureReminderChannel(context)

        val openApp = PendingIntent.getActivity(
            context,
            id,
            Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, REMINDER_CHANNEL_ID)
        } else {
            Notification.Builder(context)
        }
        notifications.notify(
            id,
            builder
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle(title)
                .setContentText(intent.getStringExtra("body").orEmpty())
                .setContentIntent(openApp)
                .setAutoCancel(true)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .build(),
        )
    }
}

private fun ensureReminderChannel(context: Context) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(
                REMINDER_CHANNEL_ID,
                "Reminders",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            },
        )
    }
}
