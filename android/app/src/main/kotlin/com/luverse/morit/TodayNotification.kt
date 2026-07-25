package com.luverse.morit

import android.Manifest
import android.app.AlarmManager
import android.app.AlertDialog
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.view.View
import android.view.WindowManager
import android.widget.RemoteViews
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import java.util.UUID

private const val TODAY_CHANNEL_ID = "today_tasks"
private const val TODAY_NOTIFICATION_TAG = "morit_today"
private const val TODAY_NOTIFICATION_ID = 0x544F4441
private const val PREFS_NAME = "morit_today_notifications"
private const val SNAPSHOT_KEY = "snapshot"
private const val ACTIONS_KEY = "actions"
private const val EXTRA_USER_ID = "user_id"
private const val EXTRA_ITEM_ID = "item_id"
private const val ACTION_COMPLETE = "TODAY_COMPLETE"
private const val ACTION_ROLLOVER = "TODAY_ROLLOVER"
private const val OVERLAY_CHANNEL = "com.luverse.morit/today_overlay"
private const val OVERLAY_UNLOCK_REQUEST = 8201
private const val MAX_TASKS = 50
private const val MAX_TEXT_LENGTH = 500
private const val MAX_QUEUED_ACTIONS = 200
private const val MAX_NOTIFICATION_TASKS = 4
private const val MAX_CONFIGURED_VISIBLE_TASKS = 8
private const val LOCK_DEVICE_UNLOCK = "device_unlock"
private const val LOCK_ALLOW = "allow_locked"
private const val LOCK_APP_PIN = "morit_pin"
private val validId = Regex("[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")
private val validDayKey = Regex("\\d{4}-\\d{2}-\\d{2}")
private val todayLock = Any()

private data class TodayTask(
    val id: String,
    val text: String,
    val completed: Boolean,
    val dayKey: String,
) {
    fun toMap(): Map<String, Any> = mapOf(
        "id" to id,
        "text" to text,
        "completed" to completed,
        "dayKey" to dayKey,
    )
}

private data class TodaySnapshot(
    val userId: String,
    val tasks: List<TodayTask>,
    val lockPolicy: String,
    val maxVisible: Int,
    val showCompleted: Boolean,
    val overlayEnabled: Boolean,
    val carryOver: Boolean,
)

private data class TodayAction(
    val id: String,
    val userId: String,
    val itemId: String,
    val type: String,
    val text: String?,
    val dayKey: String?,
    val createdAt: Long,
) {
    fun toMap(): Map<String, Any?> = buildMap {
        put("id", id)
        put("userId", userId)
        put("itemId", itemId)
        put("type", type)
        put("text", text)
        put("dayKey", dayKey)
        put("createdAt", createdAt)
    }
}

private data class RolloverResult(
    val snapshot: TodaySnapshot,
    val actions: List<TodayAction>,
    val status: String? = null,
)

fun updateTodayNotification(
    context: Context,
    userId: String,
    tasks: List<Map<*, *>>,
    lockPolicy: String = LOCK_DEVICE_UNLOCK,
    maxVisible: Int = 3,
    showCompleted: Boolean = true,
    overlayEnabled: Boolean = true,
    carryOver: Boolean = true,
): Boolean {
    requireValidId(userId, "userId")
    val normalizedLockPolicy = normalizeLockPolicy(lockPolicy)
    require(maxVisible in 1..MAX_CONFIGURED_VISIBLE_TASKS) {
        "maxVisible must be between 1 and $MAX_CONFIGURED_VISIBLE_TASKS"
    }
    require(tasks.size <= MAX_TASKS) { "tasks must contain at most $MAX_TASKS items" }
    val normalized = tasks.map(::normalizeTask)
    require(normalized.map(TodayTask::id).toSet().size == normalized.size) {
        "task IDs must be unique"
    }

    val result = synchronized(todayLock) {
        val preferences = preferences(context)
        val previousUserId = readSnapshot(preferences)?.userId
        val actions = if (previousUserId == null || previousUserId == userId) {
            readActions(preferences)
        } else {
            emptyList()
        }
        val rolled = rollOver(
            TodaySnapshot(
                userId = userId,
                tasks = normalized,
                lockPolicy = normalizedLockPolicy,
                maxVisible = maxVisible,
                showCompleted = showCompleted,
                overlayEnabled = overlayEnabled,
                carryOver = carryOver,
            ),
            actions,
        )
        check(
            preferences
                .edit()
                .putString(SNAPSHOT_KEY, rolled.snapshot.toJson().toString())
                .putString(ACTIONS_KEY, rolled.actions.toJson().toString())
                .commit(),
        ) {
            "could not persist today tasks"
        }
        rolled
    }

    if (result.snapshot.tasks.isEmpty()) {
        cancelTodayNotification(context)
        cancelTodayRollover(context)
        return true
    }
    scheduleTodayRollover(context)
    return postTodayNotification(context, result.snapshot, result.status)
}

fun readTodayActions(context: Context, userId: String): List<Map<String, Any?>> {
    requireValidId(userId, "userId")
    return synchronized(todayLock) {
        readActions(preferences(context))
            .filter { it.userId == userId }
            .map(TodayAction::toMap)
    }
}

fun ackTodayActions(
    context: Context,
    userId: String,
    ids: Collection<String>,
): Int {
    requireValidId(userId, "userId")
    require(ids.size <= MAX_QUEUED_ACTIONS) { "too many action IDs" }
    ids.forEach { requireValidId(it, "action id") }
    if (ids.isEmpty()) return 0

    return synchronized(todayLock) {
        val preferences = preferences(context)
        val actions = readActions(preferences)
        val acknowledged = actions.count { it.userId == userId && it.id in ids }
        val remaining = actions.filterNot { it.userId == userId && it.id in ids }
        check(preferences.edit().putString(ACTIONS_KEY, remaining.toJson().toString()).commit()) {
            "could not acknowledge today actions"
        }
        acknowledged
    }
}

fun clearTodayNotification(context: Context) {
    cancelTodayNotification(context)
    cancelTodayRollover(context)
    synchronized(todayLock) {
        check(preferences(context).edit().clear().commit()) {
            "could not clear today notification state"
        }
    }
}

class TodayActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "${context.packageName}.$ACTION_COMPLETE") return
        val data = intent.data ?: return
        val path = data.pathSegments
        if (data.scheme != "morit" ||
            data.authority != "today-action" ||
            path.size != 3 ||
            path[1] != "complete"
        ) {
            return
        }
        val userId = path[0].takeIf(::isValidId) ?: return
        val itemId = path[2].takeIf(::isValidId) ?: return
        if (intent.getStringExtra(EXTRA_USER_ID) != userId ||
            intent.getStringExtra(EXTRA_ITEM_ID) != itemId
        ) {
            return
        }

        var updatedSnapshot: TodaySnapshot? = null
        var status: String? = null
        synchronized(todayLock) {
            val preferences = preferences(context)
            val snapshot = readSnapshot(preferences) ?: return
            if (snapshot.userId != userId) return
            val locked = context
                .getSystemService(KeyguardManager::class.java)
                .isKeyguardLocked
            if (locked && snapshot.lockPolicy != LOCK_ALLOW) {
                updatedSnapshot = snapshot
                status = if (snapshot.lockPolicy == LOCK_APP_PIN) {
                    "목록에서 Morit PIN 확인 후 완료해 주세요"
                } else {
                    "기기 잠금 해제 후 완료할 수 있어요"
                }
                return@synchronized
            }
            val index = snapshot.tasks.indexOfFirst { it.id == itemId }
            if (index < 0) return
            if (snapshot.tasks[index].completed) return
            val actions = readActions(preferences)
            if (actions.size >= MAX_QUEUED_ACTIONS) {
                updatedSnapshot = snapshot
                status = "앱을 열어 변경사항을 동기화해 주세요"
                return@synchronized
            }

            val tasks = snapshot.tasks.toMutableList()
            val current = tasks[index]
            tasks[index] = current.copy(completed = true)
            val action = TodayAction(
                id = UUID.randomUUID().toString(),
                userId = userId,
                itemId = current.id,
                type = "complete",
                text = null,
                dayKey = current.dayKey,
                createdAt = System.currentTimeMillis(),
            )
            val nextSnapshot = snapshot.copy(tasks = tasks)
            if (!preferences
                    .edit()
                    .putString(SNAPSHOT_KEY, nextSnapshot.toJson().toString())
                    .putString(ACTIONS_KEY, (actions + action).toJson().toString())
                    .commit()
            ) {
                updatedSnapshot = snapshot
                status = "변경사항을 저장하지 못했어요"
                return@synchronized
            }
            updatedSnapshot = nextSnapshot
            status = "완료로 표시했어요"
        }
        updatedSnapshot?.let { postTodayNotification(context, it, status) }
    }
}

class TodayBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in setOf(
                Intent.ACTION_BOOT_COMPLETED,
                Intent.ACTION_MY_PACKAGE_REPLACED,
                Intent.ACTION_DATE_CHANGED,
                Intent.ACTION_TIME_CHANGED,
                Intent.ACTION_TIMEZONE_CHANGED,
            )
        ) {
            return
        }
        refreshTodayForDate(context)
    }
}

class TodayRolloverReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "${context.packageName}.$ACTION_ROLLOVER" ||
            intent.data?.toString() != "morit://today-rollover"
        ) {
            return
        }
        refreshTodayForDate(context)
    }
}

class TodayOverlayActivity : NativeFlutterActivity() {
    private var overlayChannel: MethodChannel? = null
    private var deviceUnlockDialog: AlertDialog? = null
    private var unlockResult: MethodChannel.Result? = null
    private var unlockInProgress = false
    private var deviceUnlockGate = false
    private var validLaunch = false

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        val initialPayload = todayIntentPayload(this, intent)
        validLaunch = initialPayload != null
        deviceUnlockGate = initialPayload?.get("requiresDeviceUnlock") == true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
            )
        }
        super.onCreate(savedInstanceState)
        if (!validLaunch) {
            finish()
        } else if (deviceUnlockGate) {
            engageDeviceUnlockGate()
        }
    }

    override fun getInitialRoute() = todayRoute(this, intent) ?: "/today-overlay/list"

    override fun getBackgroundMode() = BackgroundMode.transparent

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        overlayChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            OVERLAY_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialTodayOverlay" ->
                        result.success(todayIntentPayload(this, intent))
                    "requestDeviceUnlock" -> requestDeviceUnlock(result)
                    "closeTodayOverlay" -> {
                        result.success(null)
                        finish()
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val payload = todayIntentPayload(this, intent) ?: return
        setIntent(intent)
        overlayChannel?.invokeMethod("todayOverlayChanged", payload)
    }

    override fun onResume() {
        super.onResume()
        if (!validLaunch) return
        val payload = todayIntentPayload(this, intent)
        if (payload?.get("requiresDeviceUnlock") == true) {
            engageDeviceUnlockGate()
            showDeviceUnlockDialog()
        } else if (!keyguardManager().isKeyguardLocked) {
            releaseDeviceUnlockGate()
        }
    }

    override fun onPause() {
        super.onPause()
        val payload = todayIntentPayload(this, intent)
        if (payload?.get("lockPolicy") == LOCK_APP_PIN &&
            keyguardManager().isKeyguardLocked
        ) {
            finish()
        }
    }

    override fun onPostResume() {
        super.onPostResume()
        if (deviceUnlockGate && !unlockInProgress) showDeviceUnlockDialog()
    }

    private fun requestDeviceUnlock(result: MethodChannel.Result) {
        if (unlockInProgress) {
            result.error("request_in_progress", "device unlock is already open", null)
            return
        }
        val payload = todayIntentPayload(this, intent)
        if (payload == null) {
            result.error("invalid_intent", "today overlay intent is invalid", null)
            return
        }
        val locked = payload["locked"] == true
        val policy = payload["lockPolicy"]
        if (!locked || policy == LOCK_ALLOW) {
            releaseDeviceUnlockGate()
            result.success(true)
            return
        }
        if (policy != LOCK_DEVICE_UNLOCK) {
            result.success(false)
            return
        }

        beginDeviceUnlock(result)
    }

    private fun beginDeviceUnlock(result: MethodChannel.Result?) {
        if (unlockInProgress) {
            result?.error("request_in_progress", "device unlock is already open", null)
            return
        }
        if (!keyguardManager().isKeyguardLocked) {
            releaseDeviceUnlockGate()
            result?.success(true)
            return
        }
        unlockInProgress = true
        unlockResult = result
        val keyguard = keyguardManager()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            keyguard.requestDismissKeyguard(
                this,
                object : KeyguardManager.KeyguardDismissCallback() {
                    override fun onDismissSucceeded() = finishUnlock(true)
                    override fun onDismissCancelled() = finishUnlock(false)
                    override fun onDismissError() = finishUnlock(false)
                },
            )
        } else {
            @Suppress("DEPRECATION")
            val credentialIntent = keyguard.createConfirmDeviceCredentialIntent(
                "기기 잠금 해제",
                "오늘 할 일을 변경하려면 잠금을 해제해 주세요.",
            )
            if (credentialIntent == null) {
                finishUnlock(false)
            } else {
                @Suppress("DEPRECATION")
                startActivityForResult(credentialIntent, OVERLAY_UNLOCK_REQUEST)
            }
        }
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == OVERLAY_UNLOCK_REQUEST) {
            finishUnlock(resultCode == RESULT_OK)
        }
    }

    override fun onDestroy() {
        deviceUnlockDialog?.dismiss()
        deviceUnlockDialog = null
        unlockResult?.success(false)
        unlockResult = null
        unlockInProgress = false
        overlayChannel = null
        super.onDestroy()
    }

    private fun finishUnlock(unlocked: Boolean) {
        unlockResult?.success(unlocked)
        unlockResult = null
        unlockInProgress = false
        if (unlocked) {
            releaseDeviceUnlockGate()
        } else if (deviceUnlockGate) {
            window.decorView.post(::showDeviceUnlockDialog)
        }
    }

    private fun releaseDeviceUnlockGate() {
        deviceUnlockDialog?.dismiss()
        deviceUnlockDialog = null
        if (deviceUnlockGate) {
            deviceUnlockGate = false
            window.clearFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE)
            window.decorView.alpha = 1f
            window.decorView.importantForAccessibility =
                View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
        }
        overlayChannel?.invokeMethod(
            "todayOverlayAuthorizationChanged",
            mapOf(
                "authorized" to true,
                "locked" to false,
                "requiresDeviceUnlock" to false,
            ),
        )
    }

    private fun engageDeviceUnlockGate() {
        deviceUnlockGate = true
        window.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE)
        window.decorView.alpha = 0f
        window.decorView.importantForAccessibility =
            View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
    }

    private fun showDeviceUnlockDialog() {
        if (!deviceUnlockGate ||
            unlockInProgress ||
            isFinishing ||
            deviceUnlockDialog?.isShowing == true
        ) {
            return
        }
        deviceUnlockDialog = AlertDialog.Builder(this)
            .setTitle("기기 잠금 확인")
            .setMessage("오늘 할 일을 변경하려면 기기 잠금을 해제해 주세요.")
            .setNegativeButton("취소") { _, _ -> finish() }
            .setPositiveButton("잠금 해제") { _, _ -> beginDeviceUnlock(null) }
            .setCancelable(false)
            .create()
            .also { dialog ->
                dialog.setOnDismissListener {
                    if (deviceUnlockDialog === dialog) deviceUnlockDialog = null
                }
                dialog.show()
            }
    }

    private fun keyguardManager() = getSystemService(KeyguardManager::class.java)
}

internal fun todayIntentPayload(context: Context, intent: Intent): Map<String, Any?>? {
    if (intent.action != "${context.packageName}.TODAY_OVERLAY" &&
        intent.action != "${context.packageName}.OPEN_TODAY"
    ) {
        return null
    }
    val data = intent.data ?: return null
    val path = data.pathSegments
    if (data.scheme != "morit" || data.authority != "today-overlay" || path.size != 3) {
        return null
    }
    val userId = path[0].takeIf(::isValidId) ?: return null
    val action = path[1].takeIf { it in setOf("add", "list", "edit", "toggle") } ?: return null
    val itemId = path[2].takeUnless { it == "none" }?.takeIf(::isValidId)
    if ((action == "add" || action == "list") != (itemId == null)) return null

    val snapshot = synchronized(todayLock) {
        readSnapshot(preferences(context))
    } ?: return null
    if (snapshot.userId != userId) return null
    if (itemId != null && snapshot.tasks.none { it.id == itemId }) return null

    val locked = context
        .getSystemService(KeyguardManager::class.java)
        .isKeyguardLocked
    return mapOf(
        "action" to action,
        "userId" to userId,
        "itemId" to itemId,
        "lockPolicy" to snapshot.lockPolicy,
        "locked" to locked,
        "authorized" to (!locked || snapshot.lockPolicy == LOCK_ALLOW),
        "requiresDeviceUnlock" to (locked && snapshot.lockPolicy == LOCK_DEVICE_UNLOCK),
        "requiresPin" to (locked && snapshot.lockPolicy == LOCK_APP_PIN),
        "maxVisible" to snapshot.maxVisible,
        "showCompleted" to snapshot.showCompleted,
        "overlayEnabled" to snapshot.overlayEnabled,
        "carryOverIncomplete" to snapshot.carryOver,
        "tasks" to snapshot.tasks.map(TodayTask::toMap),
    )
}

internal fun todayRoute(
    context: Context,
    intent: Intent,
    expectedOverlayEnabled: Boolean? = null,
): String? {
    val payload = todayIntentPayload(context, intent) ?: return null
    if (expectedOverlayEnabled != null &&
        payload["overlayEnabled"] != expectedOverlayEnabled
    ) {
        return null
    }
    val action = payload["action"] as? String ?: return null
    val itemId = payload["itemId"] as? String
    return if (itemId == null) {
        "/today-overlay/$action"
    } else {
        "/today-overlay/$action/${Uri.encode(itemId)}"
    }
}

private fun postTodayNotification(
    context: Context,
    snapshot: TodaySnapshot,
    status: String? = null,
): Boolean {
    if (snapshot.tasks.isEmpty()) {
        cancelTodayNotification(context)
        return true
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
        context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
        PackageManager.PERMISSION_GRANTED
    ) {
        return false
    }

    val manager = context.getSystemService(NotificationManager::class.java)
    if (!manager.areNotificationsEnabled()) return false
    ensureTodayChannel(manager)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
        manager.getNotificationChannel(TODAY_CHANNEL_ID)?.importance ==
        NotificationManager.IMPORTANCE_NONE
    ) {
        return false
    }

    val compact = compactViews(context, snapshot)
    val expanded = expandedViews(context, snapshot, status)
    val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        Notification.Builder(context, TODAY_CHANNEL_ID)
    } else {
        @Suppress("DEPRECATION")
        Notification.Builder(context)
    }
    builder
        .setSmallIcon(R.drawable.ic_launcher_foreground)
        .setColor(context.getColor(R.color.morit_launcher_background))
        .setContentTitle("오늘 할 일 · ${snapshot.tasks.size}")
        .setContentText(visibleNotificationTasks(snapshot).firstOrNull()?.text ?: "오늘 할 일을 모두 마쳤어요")
        .setStyle(Notification.DecoratedCustomViewStyle())
        .setCustomContentView(compact)
        .setCustomBigContentView(expanded)
        .setContentIntent(activityPendingIntent(context, snapshot, "list", null))
        .setCategory(Notification.CATEGORY_REMINDER)
        .setVisibility(Notification.VISIBILITY_PRIVATE)
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setShowWhen(false)
        .setNumber(snapshot.tasks.count { !it.completed })
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
        @Suppress("DEPRECATION")
        builder.setPriority(Notification.PRIORITY_LOW)
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        builder.setAllowSystemGeneratedContextualActions(false)
    }

    return try {
        manager.notify(TODAY_NOTIFICATION_TAG, TODAY_NOTIFICATION_ID, builder.build())
        true
    } catch (_: SecurityException) {
        false
    }
}

private fun compactViews(context: Context, snapshot: TodaySnapshot) =
    RemoteViews(context.packageName, R.layout.notification_today_compact).apply {
        val task = visibleNotificationTasks(snapshot).firstOrNull()
        if (task == null) {
            setViewVisibility(R.id.today_compact_check, View.GONE)
            setTextViewText(R.id.today_compact_text, "오늘 할 일을 모두 마쳤어요")
            setTextColor(
                R.id.today_compact_text,
                context.getColor(R.color.today_text_completed),
            )
            setInt(
                R.id.today_compact_row,
                "setBackgroundResource",
                R.drawable.today_task_done_background,
            )
        } else {
            bindTask(
                context,
                snapshot,
                this,
                task,
                R.id.today_compact_row,
                R.id.today_compact_check,
                R.id.today_compact_text,
            )
        }
        setContentDescription(R.id.today_compact_add, "오늘 할 일 추가")
        setContentDescription(R.id.today_compact_list, "오늘 할 일 전체 목록")
        setOnClickPendingIntent(
            R.id.today_compact_add,
            activityPendingIntent(context, snapshot, "add", null),
        )
        setOnClickPendingIntent(
            R.id.today_compact_list,
            activityPendingIntent(context, snapshot, "list", null),
        )
    }

private fun expandedViews(
    context: Context,
    snapshot: TodaySnapshot,
    status: String?,
) = RemoteViews(context.packageName, R.layout.notification_today_expanded).apply {
    setTextViewText(R.id.today_title, "오늘 할 일")
    setTextViewText(
        R.id.today_count,
        "${snapshot.tasks.count { !it.completed }}개 남음",
    )
    setContentDescription(R.id.today_add, "오늘 할 일 추가")
    setContentDescription(R.id.today_list, "오늘 할 일 전체 목록")
    setOnClickPendingIntent(
        R.id.today_add,
        activityPendingIntent(context, snapshot, "add", null),
    )
    setOnClickPendingIntent(
        R.id.today_list,
        activityPendingIntent(context, snapshot, "list", null),
    )

    val rowIds = intArrayOf(
        R.id.today_row_1,
        R.id.today_row_2,
        R.id.today_row_3,
        R.id.today_row_4,
    )
    val checkIds = intArrayOf(
        R.id.today_check_1,
        R.id.today_check_2,
        R.id.today_check_3,
        R.id.today_check_4,
    )
    val textIds = intArrayOf(
        R.id.today_text_1,
        R.id.today_text_2,
        R.id.today_text_3,
        R.id.today_text_4,
    )
    val notificationTasks = visibleNotificationTasks(snapshot)
    val visibleTasks = notificationTasks.take(
        minOf(snapshot.maxVisible, MAX_NOTIFICATION_TASKS),
    )
    rowIds.indices.forEach { index ->
        val task = visibleTasks.getOrNull(index)
        if (task == null) {
            setViewVisibility(rowIds[index], View.GONE)
        } else {
            bindTask(
                context,
                snapshot,
                this,
                task,
                rowIds[index],
                checkIds[index],
                textIds[index],
            )
        }
    }

    val hidden = notificationTasks.size - visibleTasks.size
    val completed = snapshot.tasks.count(TodayTask::completed)
    val summary = status ?: buildString {
        if (completed > 0) append("완료 ${completed}개")
        if (completed > 0 && hidden > 0) append(" · ")
        if (hidden > 0) append("외 ${hidden}개 · 모두 보기")
        if (isEmpty()) append("체크하면 오늘 동안 완료 상태로 남아요")
    }
    setTextViewText(R.id.today_summary, summary)
    setOnClickPendingIntent(
        R.id.today_summary,
        activityPendingIntent(context, snapshot, "list", null),
    )
}

private fun bindTask(
    context: Context,
    snapshot: TodaySnapshot,
    views: RemoteViews,
    task: TodayTask,
    rowId: Int,
    checkId: Int,
    textId: Int,
) {
    views.setViewVisibility(rowId, View.VISIBLE)
    views.setTextViewText(textId, task.text)
    views.setImageViewResource(
        checkId,
        if (task.completed) R.drawable.ic_today_check_done else R.drawable.ic_today_check_empty,
    )
    views.setInt(
        rowId,
        "setBackgroundResource",
        if (task.completed) R.drawable.today_task_done_background else android.R.color.transparent,
    )
    views.setTextColor(
        textId,
        context.getColor(
            if (task.completed) R.color.today_text_completed else R.color.today_text_primary,
        ),
    )
    views.setContentDescription(
        checkId,
        if (task.completed) "${task.text}, 완료됨" else "${task.text}, 완료",
    )
    views.setOnClickPendingIntent(
        checkId,
        completePendingIntent(context, snapshot, task.id),
    )
}

private fun visibleNotificationTasks(snapshot: TodaySnapshot): List<TodayTask> =
    if (snapshot.showCompleted) snapshot.tasks else snapshot.tasks.filterNot(TodayTask::completed)

private fun completePendingIntent(
    context: Context,
    snapshot: TodaySnapshot,
    itemId: String,
): PendingIntent {
    val data = todayUri(snapshot.userId, "complete", itemId, "today-action")
    val intent = Intent(context, TodayActionReceiver::class.java)
        .setAction("${context.packageName}.$ACTION_COMPLETE")
        .setData(data)
        .putExtra(EXTRA_USER_ID, snapshot.userId)
        .putExtra(EXTRA_ITEM_ID, itemId)
    return PendingIntent.getBroadcast(
        context,
        8300,
        intent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}

private fun activityPendingIntent(
    context: Context,
    snapshot: TodaySnapshot,
    action: String,
    itemId: String?,
): PendingIntent {
    val intent = Intent(context, TodayOverlayActivity::class.java)
        .setAction("${context.packageName}.TODAY_OVERLAY")
        .setData(todayUri(snapshot.userId, action, itemId ?: "none", "today-overlay"))
        .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    return PendingIntent.getActivity(
        context,
        8200,
        intent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}

private fun todayUri(
    userId: String,
    action: String,
    itemId: String,
    authority: String,
): Uri = Uri.Builder()
    .scheme("morit")
    .authority(authority)
    .appendPath(userId)
    .appendPath(action)
    .appendPath(itemId)
    .build()

private fun ensureTodayChannel(manager: NotificationManager) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    manager.createNotificationChannel(
        NotificationChannel(
            TODAY_CHANNEL_ID,
            "오늘 할 일",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "오늘 처리할 메모와 빠른 입력"
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            setShowBadge(false)
        },
    )
}

private fun cancelTodayNotification(context: Context) {
    context
        .getSystemService(NotificationManager::class.java)
        .cancel(TODAY_NOTIFICATION_TAG, TODAY_NOTIFICATION_ID)
}

private fun scheduleTodayRollover(context: Context) {
    val nextMidnight = Calendar.getInstance().apply {
        add(Calendar.DAY_OF_YEAR, 1)
        set(Calendar.HOUR_OF_DAY, 0)
        set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 5)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis
    // ponytail: inexact midnight is battery-safe; use exact-alarm special access only if a delayed rollover is proven harmful.
    context.getSystemService(AlarmManager::class.java).setAndAllowWhileIdle(
        AlarmManager.RTC_WAKEUP,
        nextMidnight,
        todayRolloverPendingIntent(context, PendingIntent.FLAG_UPDATE_CURRENT)!!,
    )
}

private fun cancelTodayRollover(context: Context) {
    val pendingIntent = todayRolloverPendingIntent(
        context,
        PendingIntent.FLAG_NO_CREATE,
    ) ?: return
    context.getSystemService(AlarmManager::class.java).cancel(pendingIntent)
    pendingIntent.cancel()
}

private fun todayRolloverPendingIntent(
    context: Context,
    lookupFlag: Int,
): PendingIntent? = PendingIntent.getBroadcast(
    context,
    8400,
    Intent(context, TodayRolloverReceiver::class.java)
        .setAction("${context.packageName}.$ACTION_ROLLOVER")
        .setData(Uri.parse("morit://today-rollover")),
    lookupFlag or PendingIntent.FLAG_IMMUTABLE,
)

private fun refreshTodayForDate(context: Context) {
    val result = synchronized(todayLock) {
        val preferences = preferences(context)
        val snapshot = readSnapshot(preferences) ?: return
        val actions = readActions(preferences)
        val rolled = rollOver(snapshot, actions)
        if (rolled.snapshot != snapshot || rolled.actions != actions) {
            if (!preferences
                    .edit()
                    .putString(SNAPSHOT_KEY, rolled.snapshot.toJson().toString())
                    .putString(ACTIONS_KEY, rolled.actions.toJson().toString())
                    .commit()
            ) {
                return@synchronized RolloverResult(
                    snapshot,
                    actions,
                    "날짜 변경을 저장하지 못했어요",
                )
            }
        }
        rolled
    }
    if (result.snapshot.tasks.isEmpty()) {
        cancelTodayNotification(context)
        cancelTodayRollover(context)
    } else {
        scheduleTodayRollover(context)
        postTodayNotification(context, result.snapshot, result.status)
    }
}

private fun preferences(context: Context) =
    context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

private fun normalizeTask(value: Map<*, *>): TodayTask {
    val id = value["id"] as? String
    requireValidId(id, "task id")
    val text = sequenceOf(value["text"], value["note"], value["title"])
        .filterIsInstance<String>()
        .map(String::trim)
        .firstOrNull(String::isNotEmpty)
    require(isValidText(text)) { "task text must contain 1 to $MAX_TEXT_LENGTH characters" }
    val completed = value["completed"] as? Boolean ?: false
    val dayKey = (value["dayKey"] as? String)?.trim() ?: currentDayKey()
    require(isValidDayKey(dayKey)) { "task dayKey is invalid" }
    return TodayTask(id!!, text!!, completed, dayKey)
}

private fun rollOver(
    snapshot: TodaySnapshot,
    currentActions: List<TodayAction>,
): RolloverResult {
    val today = currentDayKey()
    val actions = currentActions.toMutableList()
    var queueFull = false
    val tasks = buildList {
        snapshot.tasks.forEach { task ->
            if (task.dayKey >= today) {
                add(task)
                return@forEach
            }
            val type = if (!task.completed && snapshot.carryOver) "rollover" else "expire"
            val exists = actions.any {
                it.userId == snapshot.userId &&
                    it.itemId == task.id &&
                    it.type == type &&
                    it.dayKey == today
            }
            if (!exists) {
                if (actions.size < MAX_QUEUED_ACTIONS) {
                    actions += TodayAction(
                        id = UUID.randomUUID().toString(),
                        userId = snapshot.userId,
                        itemId = task.id,
                        type = type,
                        text = if (type == "rollover") today else null,
                        dayKey = today,
                        createdAt = System.currentTimeMillis(),
                    )
                } else {
                    queueFull = true
                }
            }
            if (type == "rollover") add(task.copy(dayKey = today))
        }
    }
    return RolloverResult(
        snapshot = snapshot.copy(tasks = tasks),
        actions = actions,
        status = if (queueFull) "앱을 열어 날짜 변경을 동기화해 주세요" else null,
    )
}

private fun requireValidId(value: String?, name: String) {
    require(value != null && isValidId(value)) { "$name is invalid" }
}

private fun normalizeLockPolicy(value: String): String = when (value) {
    LOCK_DEVICE_UNLOCK -> LOCK_DEVICE_UNLOCK
    LOCK_ALLOW, "allow" -> LOCK_ALLOW
    LOCK_APP_PIN, "app_pin" -> LOCK_APP_PIN
    else -> throw IllegalArgumentException("lockPolicy is invalid")
}

private fun isValidId(value: String): Boolean = validId.matches(value)

private fun isValidText(value: String?): Boolean =
    value != null &&
        value.length in 1..MAX_TEXT_LENGTH &&
        value.all { !it.isISOControl() || it == '\n' || it == '\t' }

private fun currentDayKey(): String =
    SimpleDateFormat("yyyy-MM-dd", Locale.ROOT).format(System.currentTimeMillis())

private fun isValidDayKey(value: String): Boolean {
    if (!validDayKey.matches(value)) return false
    return try {
        SimpleDateFormat("yyyy-MM-dd", Locale.ROOT)
            .apply { isLenient = false }
            .parse(value) != null
    } catch (_: Exception) {
        false
    }
}

private fun TodaySnapshot.toJson() = JSONObject()
    .put("userId", userId)
    .put("lockPolicy", lockPolicy)
    .put("maxVisible", maxVisible)
    .put("showCompleted", showCompleted)
    .put("overlayEnabled", overlayEnabled)
    .put("carryOverIncomplete", carryOver)
    .put(
        "tasks",
        JSONArray().apply {
            tasks.forEach { task ->
                put(
                    JSONObject()
                        .put("id", task.id)
                        .put("text", task.text)
                        .put("completed", task.completed)
                        .put("dayKey", task.dayKey),
                )
            }
        },
    )

private fun readSnapshot(
    preferences: android.content.SharedPreferences,
): TodaySnapshot? {
    val raw = preferences.getString(SNAPSHOT_KEY, null) ?: return null
    return try {
        val value = JSONObject(raw)
        val userId = value.getString("userId").takeIf(::isValidId) ?: return null
        val lockPolicy = try {
            normalizeLockPolicy(value.optString("lockPolicy", LOCK_DEVICE_UNLOCK))
        } catch (_: IllegalArgumentException) {
            return null
        }
        val maxVisible = value.optInt("maxVisible", 3)
            .takeIf { it in 1..MAX_CONFIGURED_VISIBLE_TASKS } ?: return null
        val jsonTasks = value.getJSONArray("tasks")
        if (jsonTasks.length() > MAX_TASKS) return null
        val tasks = buildList {
            for (index in 0 until jsonTasks.length()) {
                val task = jsonTasks.getJSONObject(index)
                val id = task.getString("id")
                val text = task.getString("text")
                val dayKey = task.optString("dayKey", currentDayKey())
                if (!isValidId(id) || !isValidText(text) || !isValidDayKey(dayKey)) return null
                add(
                    TodayTask(
                        id = id,
                        text = text,
                        completed = task.optBoolean("completed", false),
                        dayKey = dayKey,
                    ),
                )
            }
        }
        if (tasks.map(TodayTask::id).toSet().size != tasks.size) return null
        TodaySnapshot(
            userId = userId,
            tasks = tasks,
            lockPolicy = lockPolicy,
            maxVisible = maxVisible,
            showCompleted = value.optBoolean("showCompleted", true),
            overlayEnabled = value.optBoolean("overlayEnabled", true),
            carryOver = if (value.has("carryOverIncomplete")) {
                value.optBoolean("carryOverIncomplete", true)
            } else {
                value.optBoolean("carryOver", true)
            },
        )
    } catch (_: Exception) {
        null
    }
}

private fun TodayAction.toJson() = JSONObject()
    .put("id", id)
    .put("userId", userId)
    .put("itemId", itemId)
    .put("type", type)
    .put("createdAt", createdAt)
    .apply {
        text?.let { put("text", it) }
        dayKey?.let { put("dayKey", it) }
    }

private fun Collection<TodayAction>.toJson() = JSONArray().apply {
    forEach { put(it.toJson()) }
}

private fun readActions(
    preferences: android.content.SharedPreferences,
): List<TodayAction> {
    val raw = preferences.getString(ACTIONS_KEY, null) ?: return emptyList()
    return try {
        val values = JSONArray(raw)
        buildList {
            for (index in 0 until minOf(values.length(), MAX_QUEUED_ACTIONS)) {
                val value = values.optJSONObject(index) ?: continue
                val id = value.optString("id")
                val userId = value.optString("userId")
                val itemId = value.optString("itemId")
                val type = value.optString("type")
                val text = value.optString("text").takeIf(String::isNotEmpty)
                val dayKey = value.optString("dayKey").takeIf(String::isNotEmpty)
                val createdAt = value.optLong("createdAt", -1)
                if (!isValidId(id) ||
                    !isValidId(userId) ||
                    !isValidId(itemId) ||
                    type !in setOf(
                        "add",
                        "edit",
                        "complete",
                        "uncomplete",
                        "rollover",
                        "expire",
                    ) ||
                    createdAt < 0 ||
                    (type in setOf("add", "edit") && !isValidText(text)) ||
                    (dayKey != null && !isValidDayKey(dayKey)) ||
                    (type == "rollover" && dayKey == null)
                ) {
                    continue
                }
                add(
                    TodayAction(
                        id = id,
                        userId = userId,
                        itemId = itemId,
                        type = type,
                        text = text,
                        dayKey = dayKey,
                        createdAt = createdAt,
                    ),
                )
            }
        }
    } catch (_: Exception) {
        emptyList()
    }
}
