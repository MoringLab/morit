package com.luverse.morit

import android.app.DownloadManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.util.Log
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.URI
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors
import javax.net.ssl.HttpsURLConnection
import kotlin.math.roundToInt

private const val BACKEND_TRANSFER_PREFERENCES = "backend_transfers_v1"
private const val TRANSFER_PREFIX = "transfer."
private const val SCHEDULER_OWNER_PREFIX = "scheduler."
private const val NATIVE_OWNER_PREFIX = "native."
private const val STATUS_CONNECT_TIMEOUT_MILLIS = 15_000
private const val STATUS_READ_TIMEOUT_MILLIS = 20_000
private const val MAX_STATUS_RESPONSE_BYTES = 1024 * 1024
private const val MIN_BACKOFF_MILLIS = 10_000L
private const val DOWNLOAD_PREPARATION_CHANNEL_ID = "download_preparation"
private const val DOWNLOAD_LOG_TAG = "MoritDownload"

private val backendJobIdPattern = Regex("""^[A-Za-z0-9_-]{8,100}$""")
private val opaqueTicketPattern = Regex("""[A-Za-z0-9_-]{43,}""")
private val mimeTypePattern = Regex("""^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$""")
private val redactedUrlPattern = Regex("""https?://\S+""", RegexOption.IGNORE_CASE)
private val backendTransferLock = Any()

internal fun requireBackendTransferJobId(value: String): String {
    val normalized = value.trim()
    require(backendJobIdPattern.matches(normalized)) { "backendJobId is invalid" }
    return normalized
}

internal fun requireBackendTransferStatusUri(value: String): URI {
    val normalized = value.trim()
    val uri = try {
        URI(normalized)
    } catch (_: Exception) {
        throw IllegalArgumentException("statusUrl must be a valid https URL")
    }
    require(
        normalized.length <= 8192 &&
            uri.scheme.equals("https", ignoreCase = true) &&
            !uri.host.isNullOrBlank() &&
            uri.rawUserInfo == null &&
            uri.rawFragment == null,
    ) {
        "statusUrl must be a valid https URL"
    }
    require(
        opaqueTicketPattern.containsMatchIn(
            listOfNotNull(uri.rawPath, uri.rawQuery).joinToString("?"),
        ),
    ) {
        "statusUrl must contain an opaque transfer ticket"
    }
    return uri
}

internal fun backendTransferSchedulerId(backendJobId: String, salt: Int = 0): Int {
    val digest = MessageDigest.getInstance("SHA-256")
        .digest("$backendJobId#$salt".toByteArray(Charsets.UTF_8))
    val value =
        ((digest[0].toInt() and 0x7f) shl 24) or
            ((digest[1].toInt() and 0xff) shl 16) or
            ((digest[2].toInt() and 0xff) shl 8) or
            (digest[3].toInt() and 0xff)
    return value.takeIf { it != 0 } ?: 1
}

internal fun backendTransferFileName(backendJobId: String, value: String): String {
    val safeLeaf = value
        .substringAfterLast('/')
        .substringAfterLast('\\')
        .replace(Regex("""[\u0000-\u001f<>:"/\\|?*]"""), "_")
        .trim()
        .takeIf { it.isNotEmpty() && it != "." && it != ".." }
        ?: "download"
    val prefix = "${backendJobId.take(12)}_"
    if (prefix.length + safeLeaf.length <= 200) return prefix + safeLeaf
    val extension = safeLeaf
        .substringAfterLast('.', "")
        .takeIf { it.length in 1..12 }
        ?.let { ".$it" }
        .orEmpty()
    val stem = safeLeaf.removeSuffix(extension)
        .take((200 - prefix.length - extension.length).coerceAtLeast(1))
    return prefix + stem + extension
}

internal fun optionalBackendContentLength(value: Long): Long? =
    value.takeIf { it > 0 }

internal fun nativeDownloadStage(status: Int?, reason: Int): String =
    when (status) {
        DownloadManager.STATUS_PENDING -> "device_queued"
        DownloadManager.STATUS_RUNNING -> "device_download"
        DownloadManager.STATUS_PAUSED -> when (reason) {
            DownloadManager.PAUSED_WAITING_TO_RETRY -> "device_retrying"
            DownloadManager.PAUSED_WAITING_FOR_NETWORK -> "device_waiting_network"
            DownloadManager.PAUSED_QUEUED_FOR_WIFI -> "device_waiting_wifi"
            else -> "device_paused"
        }
        DownloadManager.STATUS_SUCCESSFUL -> "saved"
        DownloadManager.STATUS_FAILED -> "failed"
        else -> "device_download"
    }

internal object BackendTransferScheduler {
    fun schedule(
        context: Context,
        statusUrl: String,
        backendJobId: String,
        title: String,
        description: String?,
        wifiOnly: Boolean,
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        val jobId = requireBackendTransferJobId(backendJobId)
        val statusUri = requireBackendTransferStatusUri(statusUrl)
        val safeTitle = title.trim()
        require(safeTitle.isNotEmpty() && safeTitle.length <= 200) { "title is invalid" }
        val safeDescription = description?.trim()?.takeIf(String::isNotEmpty)
        require(safeDescription == null || safeDescription.length <= 500) {
            "description is too long"
        }
        val appContext = context.applicationContext
        val preferences = preferences(appContext)
        val scheduler = appContext.getSystemService(JobScheduler::class.java)

        synchronized(backendTransferLock) {
            val existingStatus = preferences.string(jobId, "status")
            val existingNativeId = preferences.longOrNull(jobId, "native_id")
            if (existingNativeId != null ||
                existingStatus in setOf("complete", "canceled", "failed", "device_queued")
            ) {
                return true
            }
            val existingSchedulerId = preferences.getInt(
                key(jobId, "scheduler_id"),
                -1,
            )
            if (preferences.contains(key(jobId, "status_url")) &&
                existingStatus != "schedule_failed" &&
                existingSchedulerId >= 0 &&
                scheduler.getPendingJob(existingSchedulerId) != null
            ) {
                return true
            }

            val schedulerId = findSchedulerId(preferences, jobId)
            val existingUrl = preferences.string(jobId, "status_url")
            val selectedStatusUrl = existingUrl ?: statusUri.toASCIIString()
            if (!preferences.edit()
                    .putString(key(jobId, "status_url"), selectedStatusUrl)
                    .putString(key(jobId, "title"), safeTitle)
                    .putString(key(jobId, "description"), safeDescription)
                    .putBoolean(key(jobId, "wifi_only"), wifiOnly)
                    .putInt(key(jobId, "scheduler_id"), schedulerId)
                    .putString(key(jobId, "status"), "scheduled")
                    .putString(key(jobId, "stage"), "waiting_backend")
                    .putInt(key(jobId, "progress"), 0)
                    .remove(key(jobId, "error"))
                    .putLong(key(jobId, "updated_at"), System.currentTimeMillis())
                    .putString("$SCHEDULER_OWNER_PREFIX$schedulerId", jobId)
                    .commit()
            ) {
                return false
            }

            val info = JobInfo.Builder(
                schedulerId,
                ComponentName(appContext, BackendTransferJobService::class.java),
            )
                .setRequiredNetworkType(
                    if (wifiOnly) {
                        JobInfo.NETWORK_TYPE_UNMETERED
                    } else {
                        JobInfo.NETWORK_TYPE_ANY
                    },
                )
                .setPersisted(true)
                .setBackoffCriteria(MIN_BACKOFF_MILLIS, JobInfo.BACKOFF_POLICY_LINEAR)
                .build()
            val scheduled = scheduler.schedule(info) == JobScheduler.RESULT_SUCCESS
            if (!scheduled) {
                preferences.edit()
                    .putString(key(jobId, "status"), "schedule_failed")
                    .putString(key(jobId, "stage"), "waiting_system")
                    .putString(key(jobId, "error"), "Android could not schedule the transfer.")
                    .putLong(key(jobId, "updated_at"), System.currentTimeMillis())
                    .commit()
            } else {
                Log.i(
                    DOWNLOAD_LOG_TAG,
                    "event=scheduled job=$jobId scheduler=$schedulerId",
                )
                updateNotification(appContext, jobId)
            }
            return scheduled
        }
    }

    fun query(context: Context, backendJobId: String): Map<String, Any?>? {
        val jobId = requireBackendTransferJobId(backendJobId)
        val appContext = context.applicationContext
        val preferences = preferences(appContext)
        if (!preferences.contains(key(jobId, "status_url")) &&
            !preferences.contains(key(jobId, "status"))
        ) {
            return null
        }

        val nativeId = preferences.longOrNull(jobId, "native_id")
        val nativeState = nativeId?.let { queryNativeDownload(appContext, it) }
        val storedStatus = preferences.string(jobId, "status") ?: "scheduled"
        val status = when (nativeState?.status) {
            DownloadManager.STATUS_PENDING,
            DownloadManager.STATUS_RUNNING,
            DownloadManager.STATUS_PAUSED,
            -> "downloading"
            DownloadManager.STATUS_SUCCESSFUL -> "complete"
            DownloadManager.STATUS_FAILED -> "failed"
            else -> storedStatus
        }
        val progress = when {
            nativeState?.status == DownloadManager.STATUS_SUCCESSFUL -> 100
            nativeState != null &&
                nativeState.totalBytes > 0 &&
                nativeState.bytesDownloaded >= 0 ->
                (
                    nativeState.bytesDownloaded.toDouble() /
                        nativeState.totalBytes.toDouble() *
                        100
                ).roundToInt().coerceIn(0, 100)
            else -> preferences.getInt(key(jobId, "progress"), 0).coerceIn(0, 100)
        }
        val stage = when {
            nativeState != null -> nativeDownloadStage(nativeState.status, nativeState.reason)
            else -> preferences.string(jobId, "stage") ?: status
        }
        val error = when {
            nativeState?.status == DownloadManager.STATUS_FAILED ->
                "Android download failed (${nativeState.reason})."
            else -> preferences.string(jobId, "error")
        }
        return mapOf(
            "backendJobId" to jobId,
            "status" to status,
            "stage" to stage,
            "progress" to progress,
            "error" to error,
            "nativeId" to nativeId,
            "nativeStatus" to nativeState?.status,
            "nativeReason" to nativeState?.reason,
            "bytesDownloaded" to nativeState?.bytesDownloaded,
            "totalBytes" to nativeState?.totalBytes,
            "saveLocation" to preferences.string(jobId, "save_location"),
            "updatedAt" to preferences.getLong(key(jobId, "updated_at"), 0L),
        )
    }

    fun cancel(context: Context, backendJobId: String): Boolean {
        val jobId = requireBackendTransferJobId(backendJobId)
        val appContext = context.applicationContext
        val preferences = preferences(appContext)
        synchronized(backendTransferLock) {
            if (!preferences.contains(key(jobId, "status_url")) &&
                !preferences.contains(key(jobId, "status"))
            ) {
                return false
            }
            val schedulerId = preferences.getInt(key(jobId, "scheduler_id"), -1)
            val nativeId = preferences.longOrNull(jobId, "native_id")
            preferences.edit()
                .putString(key(jobId, "status"), "canceled")
                .putString(key(jobId, "stage"), "canceled")
                .putInt(key(jobId, "progress"), 0)
                .remove(key(jobId, "error"))
                .putLong(key(jobId, "updated_at"), System.currentTimeMillis())
                .also { editor ->
                    nativeId?.let { editor.remove("$NATIVE_OWNER_PREFIX$it") }
                    if (schedulerId >= 0) {
                        editor.remove("$SCHEDULER_OWNER_PREFIX$schedulerId")
                    }
                }
                .commit()
            if (schedulerId >= 0) {
                appContext.getSystemService(JobScheduler::class.java).cancel(schedulerId)
            }
            if (nativeId != null) {
                appContext.getSystemService(DownloadManager::class.java).remove(nativeId)
            }
            cancelNotification(appContext, jobId)
            return true
        }
    }

    fun onDownloadComplete(context: Context, nativeId: Long) {
        val appContext = context.applicationContext
        val preferences = preferences(appContext)
        val backendJobId =
            preferences.getString("$NATIVE_OWNER_PREFIX$nativeId", null) ?: return
        synchronized(backendTransferLock) {
            if (preferences.string(backendJobId, "status") == "canceled") return
            val nativeState = queryNativeDownload(appContext, nativeId) ?: return
            val editor = preferences.edit()
                .putLong(key(backendJobId, "updated_at"), System.currentTimeMillis())
                .remove("$NATIVE_OWNER_PREFIX$nativeId")
            when (nativeState.status) {
                DownloadManager.STATUS_SUCCESSFUL -> editor
                    .putString(key(backendJobId, "status"), "complete")
                    .putString(key(backendJobId, "stage"), "saved")
                    .putInt(key(backendJobId, "progress"), 100)
                    .remove(key(backendJobId, "error"))
                DownloadManager.STATUS_FAILED -> editor
                    .putString(key(backendJobId, "status"), "failed")
                    .putString(key(backendJobId, "stage"), "device_download")
                    .putString(
                        key(backendJobId, "error"),
                        "Android download failed (${nativeState.reason}).",
                    )
            }
            editor.commit()
        }
    }

    fun releaseSchedulerOwner(
        context: Context,
        backendJobId: String,
        schedulerId: Int,
    ) {
        val preferences = preferences(context.applicationContext)
        synchronized(backendTransferLock) {
            if (preferences.getString("$SCHEDULER_OWNER_PREFIX$schedulerId", null) ==
                backendJobId
            ) {
                preferences.edit()
                    .remove("$SCHEDULER_OWNER_PREFIX$schedulerId")
                    .apply()
            }
        }
    }

    fun backendJobId(context: Context, schedulerId: Int): String? =
        preferences(context.applicationContext)
            .getString("$SCHEDULER_OWNER_PREFIX$schedulerId", null)

    fun shouldRetry(context: Context, backendJobId: String): Boolean {
        val status = preferences(context.applicationContext).string(backendJobId, "status")
        return status !in setOf("complete", "canceled", "failed", "device_queued")
    }

    fun updateNotification(context: Context, backendJobId: String) {
        val state = query(context, backendJobId)
        val manager = context.getSystemService(NotificationManager::class.java)
        if (state == null ||
            state["nativeId"] != null ||
            state["status"] in setOf("complete", "canceled", "failed", "device_queued")
        ) {
            cancelNotification(context, backendJobId)
            return
        }
        if (!manager.areNotificationsEnabled()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    DOWNLOAD_PREPARATION_CHANNEL_ID,
                    "다운로드 진행",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "백그라운드 미디어 준비와 다운로드 진행 상태"
                    lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                },
            )
        }
        val preferences = preferences(context)
        val progress = (state["progress"] as? Int ?: 0).coerceIn(0, 100)
        val remaining = preferences.all.count { (key, value) ->
            key.startsWith(TRANSFER_PREFIX) &&
                key.endsWith(".status") &&
                value is String &&
                value !in setOf("complete", "canceled", "failed", "device_queued")
        }
        val stage = when (state["stage"]) {
            "downloading" -> "원본 다운로드 중"
            "processing", "merging", "converting" -> "미디어 처리 중"
            "verifying", "validating" -> "파일 확인 중"
            else -> "다운로드 준비 중"
        }
        val contentIntent = PendingIntent.getActivity(
            context,
            backendTransferSchedulerId(backendJobId),
            Intent(context, MainActivity::class.java)
                .setAction("${context.packageName}.OPEN_DOWNLOADS")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, DOWNLOAD_PREPARATION_CHANNEL_ID)
        } else {
            Notification.Builder(context)
        }
        manager.notify(
            notificationId(backendJobId),
            builder
                .setSmallIcon(R.drawable.ic_launcher_foreground)
                .setContentTitle(preferences.string(backendJobId, "title") ?: "Morit 다운로드")
                .setContentText(
                    listOfNotNull(
                        stage,
                        progress.takeIf { it > 0 }?.let { "$it%" },
                        remaining.takeIf { it > 1 }?.let { "남은 작업 ${it}개" },
                    ).joinToString(" · "),
                )
                .setProgress(100, progress, progress <= 0)
                .setContentIntent(contentIntent)
                .setOnlyAlertOnce(true)
                .setOngoing(true)
                .setCategory(Notification.CATEGORY_PROGRESS)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .build(),
        )
    }

    fun cancelNotification(context: Context, backendJobId: String) {
        context.getSystemService(NotificationManager::class.java)
            .cancel(notificationId(backendJobId))
    }

    private fun notificationId(backendJobId: String): Int =
        backendTransferSchedulerId(backendJobId) xor 0x2D0A0000

    fun poll(
        context: Context,
        backendJobId: String,
        isActive: () -> Boolean,
    ): Boolean {
        val appContext = context.applicationContext
        val preferences = preferences(appContext)
        if (!isActive() || !shouldRetry(appContext, backendJobId)) return false
        val statusUrl = preferences.string(backendJobId, "status_url") ?: return false
        val statusUri = try {
            requireBackendTransferStatusUri(statusUrl)
        } catch (_: IllegalArgumentException) {
            storeFailure(preferences, backendJobId, "Saved transfer metadata is invalid.")
            return false
        }

        val response = fetchStatus(statusUri)
        if (!isActive()) return false
        when (response) {
            is StatusResponse.Retry -> {
                updateWaiting(preferences, backendJobId, response.message)
                return true
            }
            is StatusResponse.Failure -> {
                storeFailure(preferences, backendJobId, response.message)
                return false
            }
            is StatusResponse.Success -> Unit
        }

        val json = response.value
        val previousStatus = preferences.string(backendJobId, "status") ?: "scheduled"
        val previousProgress = preferences.getInt(key(backendJobId, "progress"), 0)
        val status = json.optString("status").trim().lowercase()
        val stage = safeStage(json.optString("stage"), status)
        val rawProgress = json.optDouble("progress", 0.0)
        val progress = (
            if (rawProgress in 0.0..1.0) rawProgress * 100 else rawProgress
        ).roundToInt().coerceIn(0, 100)
        val publicError = safePublicError(json.opt("error"))

        if (status in setOf("queued", "pending", "running", "processing", "downloading")) {
            preferences.edit()
                .putString(key(backendJobId, "status"), status)
                .putString(key(backendJobId, "stage"), stage)
                .putInt(key(backendJobId, "progress"), progress)
                .also { editor ->
                    if (publicError == null) {
                        editor.remove(key(backendJobId, "error"))
                    } else {
                        editor.putString(key(backendJobId, "error"), publicError)
                    }
                }
                .putLong(key(backendJobId, "updated_at"), System.currentTimeMillis())
                .commit()
            Log.i(
                DOWNLOAD_LOG_TAG,
                "event=backend_transition job=$backendJobId " +
                    "state=$previousStatus->$status progress=$previousProgress->$progress " +
                    "stage=$stage",
            )
            return true
        }
        if (status in setOf("failed", "error")) {
            storeFailure(
                preferences,
                backendJobId,
                publicError ?: "The backend download failed.",
            )
            return false
        }
        if (status in setOf("canceled", "cancelled")) {
            synchronized(backendTransferLock) {
                preferences.edit()
                    .putString(key(backendJobId, "status"), "canceled")
                    .putString(key(backendJobId, "stage"), "canceled")
                    .putInt(key(backendJobId, "progress"), progress)
                    .putLong(key(backendJobId, "updated_at"), System.currentTimeMillis())
                    .commit()
            }
            return false
        }
        if (status !in setOf("complete", "completed", "ready", "succeeded")) {
            storeFailure(preferences, backendJobId, "The backend returned an unknown status.")
            return false
        }

        val file = json.optJSONObject("file")
        if (file == null) {
            storeFailure(preferences, backendJobId, "The completed job did not include a file.")
            return false
        }
        val fileUri = try {
            requireBackendFileUri(statusUri, file.optString("url"))
        } catch (_: IllegalArgumentException) {
            storeFailure(preferences, backendJobId, "The backend returned an invalid file URL.")
            return false
        }
        val mimeType = file.optString("mime_type")
            .substringBefore(';')
            .trim()
            .lowercase()
        val mediaKind = file.optString("kind").trim().lowercase()
        val contentLength = optionalBackendContentLength(
            file.optLong("content_length", -1L),
        )
        if (!mimeTypePattern.matches(mimeType) ||
            mediaKind !in setOf("image", "video", "audio", "file")
        ) {
            storeFailure(preferences, backendJobId, "The backend returned invalid file metadata.")
            return false
        }
        val fileName = backendTransferFileName(
            backendJobId,
            file.optString("file_name"),
        )

        synchronized(backendTransferLock) {
            if (!isActive() ||
                preferences.string(backendJobId, "status") == "canceled"
            ) {
                return false
            }
            if (preferences.longOrNull(backendJobId, "native_id") != null) {
                return false
            }
            return try {
                val enqueued = enqueuePublicDownload(
                    appContext,
                    PublicDownloadRequest(
                        url = fileUri.toASCIIString(),
                        fileName = fileName,
                        title = preferences.string(backendJobId, "title") ?: fileName,
                        mediaKind = mediaKind,
                        description = preferences.string(backendJobId, "description"),
                        mimeType = mimeType,
                        wifiOnly = preferences.getBoolean(
                            key(backendJobId, "wifi_only"),
                            false,
                        ),
                        expectedContentLength = contentLength,
                    ),
                )
                val nativeId = (enqueued["id"] as Number).toLong()
                val saveLocation = enqueued["saveLocation"] as String
                preferences.edit()
                    .putLong(key(backendJobId, "native_id"), nativeId)
                    .putString(key(backendJobId, "save_location"), saveLocation)
                    .putString(key(backendJobId, "status"), "device_queued")
                    .putString(key(backendJobId, "stage"), "device_download")
                    .putInt(key(backendJobId, "progress"), 0)
                    .remove(key(backendJobId, "error"))
                    .putLong(key(backendJobId, "updated_at"), System.currentTimeMillis())
                    .putString("$NATIVE_OWNER_PREFIX$nativeId", backendJobId)
                    .commit()
                Log.i(
                    DOWNLOAD_LOG_TAG,
                    "event=device_enqueued job=$backendJobId native=$nativeId " +
                        "expected_bytes=${contentLength ?: -1}",
                )
                false
            } catch (_: Exception) {
                updateWaiting(
                    preferences,
                    backendJobId,
                    "Android could not start the file download.",
                )
                true
            }
        }
    }

    private fun findSchedulerId(
        preferences: SharedPreferences,
        backendJobId: String,
    ): Int {
        repeat(32) { salt ->
            val candidate = backendTransferSchedulerId(backendJobId, salt)
            val owner = preferences.getString("$SCHEDULER_OWNER_PREFIX$candidate", null)
            if (owner == null || owner == backendJobId) return candidate
        }
        throw IllegalStateException("No scheduler id is available")
    }

    private fun updateWaiting(
        preferences: SharedPreferences,
        backendJobId: String,
        message: String?,
    ) {
        if (preferences.string(backendJobId, "status") == "canceled") return
        Log.w(
            DOWNLOAD_LOG_TAG,
            "event=backend_poll_retry job=$backendJobId " +
                "state=${preferences.string(backendJobId, "status") ?: "unknown"} " +
                "detail=${safePublicError(message) ?: "-"}",
        )
        preferences.edit()
            .remove(key(backendJobId, "error"))
            .putLong(key(backendJobId, "updated_at"), System.currentTimeMillis())
            .commit()
    }

    private fun storeFailure(
        preferences: SharedPreferences,
        backendJobId: String,
        message: String,
    ) {
        synchronized(backendTransferLock) {
            if (preferences.string(backendJobId, "status") == "canceled") return
            val previousStatus =
                preferences.string(backendJobId, "status") ?: "unknown"
            val safeMessage = safePublicError(message) ?: "The transfer failed."
            preferences.edit()
                .putString(key(backendJobId, "status"), "failed")
                .putString(key(backendJobId, "stage"), "failed")
                .putString(key(backendJobId, "error"), safeMessage)
                .putLong(key(backendJobId, "updated_at"), System.currentTimeMillis())
                .commit()
            Log.e(
                DOWNLOAD_LOG_TAG,
                "event=backend_failed job=$backendJobId " +
                    "state=$previousStatus->failed detail=$safeMessage",
            )
        }
    }
}

class BackendTransferJobService : JobService() {
    override fun onStartJob(params: JobParameters): Boolean {
        val backendJobId =
            BackendTransferScheduler.backendJobId(this, params.jobId) ?: return false
        val generation = Any()
        synchronized(generationLock) {
            generations[params.jobId] = generation
        }
        executor.execute {
            fun active(): Boolean = synchronized(generationLock) {
                generations[params.jobId] === generation
            }
            val retry = try {
                var polls = 0
                while (active() &&
                    BackendTransferScheduler.shouldRetry(this, backendJobId)
                ) {
                    val keepPolling = BackendTransferScheduler.poll(
                        this,
                        backendJobId,
                        ::active,
                    )
                    BackendTransferScheduler.updateNotification(this, backendJobId)
                    if (!keepPolling) break
                    polls += 1
                    Thread.sleep(if (polls < 3) 750L else 2_000L)
                }
                !active() && BackendTransferScheduler.shouldRetry(this, backendJobId)
            } catch (_: InterruptedException) {
                BackendTransferScheduler.shouldRetry(this, backendJobId)
            } catch (error: Exception) {
                Log.w(
                    DOWNLOAD_LOG_TAG,
                    "event=job_service_error job=$backendJobId " +
                        "type=${error.javaClass.simpleName}",
                )
                BackendTransferScheduler.shouldRetry(this, backendJobId)
            }
            val shouldFinish = synchronized(generationLock) {
                if (generations[params.jobId] === generation) {
                    generations.remove(params.jobId)
                    true
                } else {
                    false
                }
            }
            if (shouldFinish) {
                if (!retry) {
                    BackendTransferScheduler.releaseSchedulerOwner(
                        this,
                        backendJobId,
                        params.jobId,
                    )
                }
                Log.i(
                    DOWNLOAD_LOG_TAG,
                    "event=job_service_finish job=$backendJobId retry=$retry",
                )
                jobFinished(params, retry)
            }
        }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        synchronized(generationLock) {
            generations.remove(params.jobId)
        }
        val backendJobId =
            BackendTransferScheduler.backendJobId(this, params.jobId) ?: return false
        return BackendTransferScheduler.shouldRetry(this, backendJobId)
    }

    private companion object {
        val executor = Executors.newFixedThreadPool(2)
        val generationLock = Any()
        val generations = mutableMapOf<Int, Any>()
    }
}

private sealed interface StatusResponse {
    data class Success(val value: JSONObject) : StatusResponse
    data class Retry(val message: String) : StatusResponse
    data class Failure(val message: String) : StatusResponse
}

private fun fetchStatus(uri: URI): StatusResponse {
    val connection = try {
        URL(uri.toASCIIString()).openConnection() as HttpsURLConnection
    } catch (_: Exception) {
        return StatusResponse.Failure("The saved status URL is invalid.")
    }
    return try {
        connection.requestMethod = "GET"
        connection.instanceFollowRedirects = false
        connection.connectTimeout = STATUS_CONNECT_TIMEOUT_MILLIS
        connection.readTimeout = STATUS_READ_TIMEOUT_MILLIS
        connection.setRequestProperty("Accept", "application/json")
        val statusCode = connection.responseCode
        if (statusCode in setOf(408, 425, 429) || statusCode in 500..599) {
            return StatusResponse.Retry("The download server is temporarily unavailable.")
        }
        if (statusCode !in 200..299) {
            return StatusResponse.Failure(
                when (statusCode) {
                    401, 403 -> "The transfer ticket was rejected."
                    404, 410 -> "The backend transfer expired or no longer exists."
                    else -> "The download server rejected the status request ($statusCode)."
                },
            )
        }
        val contentType = connection.contentType
            ?.substringBefore(';')
            ?.trim()
            ?.lowercase()
            .orEmpty()
        if (!contentType.endsWith("/json") && !contentType.endsWith("+json")) {
            return StatusResponse.Failure("The download server returned a non-JSON response.")
        }
        val declaredLength = connection.contentLengthLong
        if (declaredLength > MAX_STATUS_RESPONSE_BYTES) {
            return StatusResponse.Failure("The download status response was too large.")
        }
        val bytes = connection.inputStream.use { input ->
            val output = ByteArrayOutputStream(
                declaredLength.coerceIn(0, MAX_STATUS_RESPONSE_BYTES.toLong()).toInt(),
            )
            val buffer = ByteArray(8192)
            var total = 0
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                total += count
                if (total > MAX_STATUS_RESPONSE_BYTES) {
                    return StatusResponse.Failure("The download status response was too large.")
                }
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
        val json = try {
            JSONObject(bytes.toString(Charsets.UTF_8))
        } catch (_: Exception) {
            return StatusResponse.Failure("The download server returned invalid JSON.")
        }
        StatusResponse.Success(json)
    } catch (_: java.net.SocketTimeoutException) {
        StatusResponse.Retry("The download server did not respond in time.")
    } catch (_: java.io.IOException) {
        StatusResponse.Retry("The download server could not be reached.")
    } finally {
        connection.disconnect()
    }
}

private fun requireBackendFileUri(statusUri: URI, value: String): URI {
    val fileUri = try {
        URI(value.trim())
    } catch (_: Exception) {
        throw IllegalArgumentException("file url is invalid")
    }
    require(
        value.length <= 8192 &&
            fileUri.scheme.equals("https", ignoreCase = true) &&
            !fileUri.host.isNullOrBlank() &&
            fileUri.rawUserInfo == null &&
            fileUri.rawFragment == null &&
            opaqueTicketPattern.containsMatchIn(
                listOfNotNull(fileUri.rawPath, fileUri.rawQuery).joinToString("?"),
            ) &&
            sameOrigin(statusUri, fileUri),
    ) {
        "file url is invalid"
    }
    return fileUri
}

private fun sameOrigin(first: URI, second: URI): Boolean =
    first.scheme.equals(second.scheme, ignoreCase = true) &&
        first.host.equals(second.host, ignoreCase = true) &&
        effectivePort(first) == effectivePort(second)

private fun effectivePort(uri: URI): Int =
    uri.port.takeIf { it >= 0 } ?: if (uri.scheme.equals("https", true)) 443 else 80

private fun preferences(context: Context): SharedPreferences =
    context.getSharedPreferences(BACKEND_TRANSFER_PREFERENCES, Context.MODE_PRIVATE)

private fun key(backendJobId: String, field: String): String =
    "$TRANSFER_PREFIX$backendJobId.$field"

private fun SharedPreferences.string(backendJobId: String, field: String): String? =
    getString(key(backendJobId, field), null)

private fun SharedPreferences.longOrNull(backendJobId: String, field: String): Long? =
    if (contains(key(backendJobId, field))) {
        getLong(key(backendJobId, field), -1L).takeIf { it >= 0 }
    } else {
        null
    }

private data class NativeDownloadState(
    val status: Int,
    val reason: Int,
    val bytesDownloaded: Long,
    val totalBytes: Long,
)

private fun queryNativeDownload(context: Context, nativeId: Long): NativeDownloadState? {
    val manager = context.getSystemService(DownloadManager::class.java)
    return manager.query(DownloadManager.Query().setFilterById(nativeId)).use { cursor ->
        if (!cursor.moveToFirst()) return@use null
        NativeDownloadState(
            status = cursor.getInt(
                cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS),
            ),
            reason = cursor.getInt(
                cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON),
            ),
            bytesDownloaded = cursor.getLong(
                cursor.getColumnIndexOrThrow(
                    DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR,
                ),
            ),
            totalBytes = cursor.getLong(
                cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES),
            ),
        )
    }
}

private fun safeStage(value: String?, fallback: String): String {
    val normalized = value
        ?.trim()
        ?.lowercase()
        ?.take(64)
        ?.takeIf { Regex("""^[a-z0-9_.-]+$""").matches(it) }
    return normalized ?: fallback.take(64)
}

internal fun safePublicError(value: Any?): String? {
    if (value == null || value == JSONObject.NULL) return null
    if (value is JSONObject) {
        return formatBackendPublicError(
            message = value.optString("message"),
            platform = value.optString("platform"),
            engine = value.optString("engine"),
            code = value.optString("code"),
            logId = value.optString("log_id"),
        )
    }
    return sanitizePublicError(value.toString())
}

internal fun formatBackendPublicError(
    message: String?,
    platform: String?,
    engine: String?,
    code: String?,
    logId: String?,
): String? {
    val summary = message
        ?.trim()
        ?.take(160)
        ?.takeIf(String::isNotEmpty)
        ?: "The backend download failed."
    val context = listOf(
        "platform" to platform,
        "engine" to engine,
        "code" to code,
        "log_id" to logId,
    ).mapNotNull { (name, value) ->
        value
            ?.trim()
            ?.take(64)
            ?.takeIf {
                it.isNotEmpty() &&
                    Regex("""^[A-Za-z0-9_.-]+$""").matches(it)
            }
            ?.let { "$name=$it" }
    }
    return sanitizePublicError(
        if (context.isEmpty()) summary else "$summary [${context.joinToString(" / ")}]",
    )
}

private fun sanitizePublicError(raw: String): String? =
    raw
        .replace(redactedUrlPattern, "[link]")
        .replace(opaqueTicketPattern, "[redacted]")
        .replace(Regex("""[\u0000-\u001f]+"""), " ")
        .trim()
        .take(300)
        .takeIf(String::isNotEmpty)
