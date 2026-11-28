package org.localsend.localsend_app

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.BroadcastReceiver
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.Icon
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import android.system.Os
import android.system.OsConstants
import android.webkit.MimeTypeMap
import com.pravera.flutter_foreground_task.service.ForegroundService
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

private const val CHANNEL = "org.localsend.localsend_app/localsend"
private const val REQUEST_CODE_PICK_DIRECTORY = 1
private const val REQUEST_CODE_PICK_DIRECTORY_PATH = 2
private const val REQUEST_CODE_PICK_FILE = 3
private const val REQUEST_CODE_LOCAL_NETWORK = 4

private const val INCOMING_CHANNEL_ID = "landrop_incoming"
private const val INCOMING_NOTIFICATION_ID = 2001
private const val FOREGROUND_SERVICE_CHANNEL_ID = "localsend_foreground_service"
private const val FOREGROUND_SERVICE_NOTIFICATION_ID = 1
private const val TRANSFER_PROGRESS_CHANNEL_ID = "landrop_transfer_progress"
private const val TRANSFER_DONE_CHANNEL_ID = "landrop_transfer_done"
private const val TRANSFER_NOTIFICATION_ID = 2002
private const val ACTION_CANCEL_TRANSFER = "org.localsend.localsend_app.ACTION_CANCEL_TRANSFER"
private const val CANCEL_REQUEST_CODE = 3001

// Not available as a constant in compileSdk 36.
private const val PERMISSION_ACCESS_LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"
private const val API_LEVEL_ANDROID_17 = 37

object LanDropEngineManager {
    const val ENGINE_ID = "landrop_engine"
    const val SHORTCUT_ID_PREFIX = "device_"
    private const val SHARE_TARGET_CATEGORY = "org.localsend.localsend_app.category.SHARE_TARGET"
    private const val MAX_CUSTOM_SOUND_MS = 5000L
    private const val MAX_RETAINED_SHARE_FDS = 64
    private const val RETAINED_SHARE_FD_TTL_MS = 15 * 60 * 1000L

    private data class RetainedFd(val pfd: ParcelFileDescriptor, val createdAtMs: Long)

    private lateinit var appContext: Context
    private var activityRef: WeakReference<MainActivity>? = null
    private var methodChannel: MethodChannel? = null
    private var pendingResult: MethodChannel.Result? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var cancelReceiverRegistered: Boolean = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private var activeMediaPlayer: MediaPlayer? = null
    private var stopSoundRunnable: Runnable? = null
    private val shareLock = Any()
    private val pendingNativeShares = mutableListOf<Map<String, Any?>>()
    private val retainedShareFds = LinkedHashMap<String, RetainedFd>()

    private val cancelTransferReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_CANCEL_TRANSFER) {
                restoreIdleForegroundNotification()
                cancelIncomingRequestNotification()
                Handler(Looper.getMainLooper()).post {
                    methodChannel?.invokeMethod("cancelActiveTransfer", null)
                }
            }
        }
    }

    @Volatile
    var shareIntentReady: Boolean = false

    @Synchronized
    fun ensureEngine(context: Context): FlutterEngine {
        appContext = context.applicationContext
        registerCancelReceiverIfNeeded()
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { existing ->
            return existing
        }

        val engine = FlutterEngine(appContext)
        setupMethodChannel(engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    private fun registerCancelReceiverIfNeeded() {
        if (cancelReceiverRegistered) {
            return
        }
        cancelReceiverRegistered = true
        val filter = IntentFilter(ACTION_CANCEL_TRANSFER)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            appContext.registerReceiver(cancelTransferReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            appContext.registerReceiver(cancelTransferReceiver, filter)
        }
    }

    fun attachActivity(activity: MainActivity) {
        activityRef = WeakReference(activity)
    }

    fun detachActivity(activity: MainActivity) {
        if (activityRef?.get() === activity) {
            activityRef = null
        }
    }

    private fun setupMethodChannel(engine: FlutterEngine) {
        val channel = MethodChannel(
            engine.dartExecutor.binaryMessenger,
            CHANNEL
        )
        methodChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickDirectory" -> {
                    val activity = activityRef?.get()
                    if (activity == null) {
                        result.error("NO_ACTIVITY", "Cannot open directory picker without an active window", null)
                    } else {
                        pendingResult = result
                        openDirectoryPicker(activity, onlyPath = false)
                    }
                }

                "pickFiles" -> {
                    val activity = activityRef?.get()
                    if (activity == null) {
                        result.error("NO_ACTIVITY", "Cannot open file picker without an active window", null)
                    } else {
                        pendingResult = result
                        openFilePicker(activity)
                    }
                }

                "pickDirectoryPath" -> {
                    val activity = activityRef?.get()
                    if (activity == null) {
                        result.error("NO_ACTIVITY", "Cannot open directory picker without an active window", null)
                    } else {
                        pendingResult = result
                        openDirectoryPicker(activity, onlyPath = true)
                    }
                }

                "createDirectory" -> handleCreateDirectory(call, result)

                "getFileDescriptor" -> handleGetFileDescriptor(call, result)

                "createFile" -> handleCreateFile(call, result)

                "openFileForWriting" -> handleOpenFileForWriting(call, result)

                "scanFile" -> handleScanFile(call, result)

                "openContentUri" -> {
                    val uri = call.argument<String>("uri")
                    val activity = activityRef?.get()
                    if (uri != null) {
                        if (activity != null) {
                            openUri(activity, uri)
                        } else {
                            openUriFromBackground(uri)
                        }
                    }
                    result.success(null)
                }

                "openGallery" -> {
                    openGallery()
                    result.success(null)
                }

                "playCompletionSound" -> {
                    val path = call.argument<String>("path")
                    if (!path.isNullOrBlank()) {
                        playCompletionSound(path)
                    }
                    result.success(null)
                }

                "showIncomingRequestNotification" -> {
                    val senderAlias = call.argument<String>("senderAlias") ?: "Someone"
                    val fileCount = call.argument<Int>("fileCount") ?: 1
                    showIncomingRequestNotification(senderAlias, fileCount)
                    result.success(null)
                }

                "cancelIncomingRequestNotification" -> {
                    cancelIncomingRequestNotification()
                    result.success(null)
                }

                "showTransferProgressNotification" -> {
                    val title = call.argument<String>("title") ?: "Transferring"
                    val body = call.argument<String>("body") ?: ""
                    val progress = call.argument<Int>("progress") ?: 0
                    val max = call.argument<Int>("max") ?: 100
                    val indeterminate = call.argument<Boolean>("indeterminate") ?: false
                    showTransferProgressNotification(title, body, progress, max, indeterminate)
                    result.success(null)
                }

                "showTransferCompletedNotification" -> {
                    val title = call.argument<String>("title") ?: "Transfer complete"
                    val body = call.argument<String>("body") ?: ""
                    showTransferCompletedNotification(title, body)
                    result.success(null)
                }

                "cancelTransferProgressNotification" -> {
                    cancelTransferProgressNotification()
                    result.success(null)
                }

                "shareIntentReady" -> {
                    flushPendingNativeShares()
                    result.success(null)
                }

                "moveTaskToBack" -> {
                    activityRef?.get()?.moveTaskToBack(true)
                    result.success(null)
                }

                "updateShareShortcuts" -> {
                    @Suppress("UNCHECKED_CAST")
                    val devices = call.argument<List<Map<String, Any?>>>("devices") ?: emptyList()
                    updateShareShortcuts(devices)
                    result.success(null)
                }

                "isAnimationsEnabled" -> {
                    result.success(isAnimationsEnabled())
                }

                "getDownloadsDirectory" -> {
                    result.success(getDownloadsDirectory())
                }

                "getDeviceName" -> {
                    result.success(getDeviceName())
                }

                "requestLocalNetworkPermission" -> {
                    if (hasLocalNetworkPermission()) {
                        result.success(true)
                    } else {
                        val activity = activityRef?.get()
                        if (activity == null) {
                            result.success(false)
                        } else {
                            pendingPermissionResult = result
                            activity.requestPermissions(arrayOf(PERMISSION_ACCESS_LOCAL_NETWORK), REQUEST_CODE_LOCAL_NETWORK)
                        }
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun buildLaunchPendingIntent(requestCode: Int): PendingIntent? {
        val launchIntent = appContext.packageManager.getLaunchIntentForPackage(appContext.packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        } ?: return null
        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        return PendingIntent.getActivity(appContext, requestCode, launchIntent, pendingFlags)
    }

    private fun showIncomingRequestNotification(senderAlias: String, fileCount: Int) {
        try {
            val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    INCOMING_CHANNEL_ID,
                    "Incoming transfers",
                    NotificationManager.IMPORTANCE_HIGH
                )
                nm.createNotificationChannel(channel)
            }

            val contentIntent = buildLaunchPendingIntent(INCOMING_NOTIFICATION_ID)

            val body = if (fileCount == 1) {
                "1 file — tap to accept or decline"
            } else {
                "$fileCount files — tap to accept or decline"
            }

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(appContext, INCOMING_CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(appContext)
            }

            builder
                .setAutoCancel(true)
                .setSmallIcon(appContext.applicationInfo.icon)
                .setContentTitle("Incoming transfer from $senderAlias")
                .setContentText(body)

            if (contentIntent != null) {
                builder.setContentIntent(contentIntent)
            }

            nm.notify(INCOMING_NOTIFICATION_ID, builder.build())
        } catch (_: Exception) {
            // Notification failure must never break incoming transfers.
        }
    }

    private fun cancelIncomingRequestNotification() {
        try {
            val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            nm?.cancel(INCOMING_NOTIFICATION_ID)
        } catch (_: Exception) {
            // Ignore cleanup errors.
        }
    }

    private fun buildCancelPendingIntent(): PendingIntent {
        val cancelIntent = Intent(ACTION_CANCEL_TRANSFER).apply {
            setPackage(appContext.packageName)
        }
        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        return PendingIntent.getBroadcast(appContext, CANCEL_REQUEST_CODE, cancelIntent, pendingFlags)
    }

    private fun restoreIdleForegroundNotification() {
        try {
            val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            if (!ForegroundService.isRunningServiceState.value) {
                nm.cancel(FOREGROUND_SERVICE_NOTIFICATION_ID)
                return
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nm.getNotificationChannel(FOREGROUND_SERVICE_CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    FOREGROUND_SERVICE_CHANNEL_ID,
                    "LanDrop Background",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    setSound(null, null)
                    enableVibration(false)
                }
                nm.createNotificationChannel(channel)
            }

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(appContext, FOREGROUND_SERVICE_CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(appContext)
            }

            builder
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setSmallIcon(appContext.applicationInfo.icon)
                .setContentTitle("LanDrop ready")
                .setContentText("Listening on local network")
                .setProgress(0, 0, false)

            buildLaunchPendingIntent(FOREGROUND_SERVICE_NOTIFICATION_ID)?.let { builder.setContentIntent(it) }
            nm.notify(FOREGROUND_SERVICE_NOTIFICATION_ID, builder.build())
        } catch (_: Exception) {
            // Ignore cleanup errors.
        }
    }

    private fun showTransferProgressNotification(
        title: String,
        body: String,
        progress: Int,
        max: Int,
        indeterminate: Boolean
    ) {
        try {
            val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    TRANSFER_PROGRESS_CHANNEL_ID,
                    "Transfer progress",
                    NotificationManager.IMPORTANCE_DEFAULT
                ).apply {
                    setSound(null, null)
                    enableVibration(false)
                }
                nm.createNotificationChannel(channel)
            }

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(appContext, TRANSFER_PROGRESS_CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(appContext)
            }

            val cancelPending = buildCancelPendingIntent()
            val cancelAction = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                Notification.Action.Builder(null, "Cancel", cancelPending).build()
            } else {
                @Suppress("DEPRECATION")
                Notification.Action.Builder(0, "Cancel", cancelPending).build()
            }

            builder
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setSmallIcon(appContext.applicationInfo.icon)
                .setContentTitle(title)
                .setContentText(body)
                .setProgress(max, progress, indeterminate)
                .addAction(cancelAction)

            buildLaunchPendingIntent(FOREGROUND_SERVICE_NOTIFICATION_ID)?.let { builder.setContentIntent(it) }
            nm.notify(FOREGROUND_SERVICE_NOTIFICATION_ID, builder.build())
        } catch (_: Exception) {
            // Progress notification failure must never break transfers.
        }
    }

    private fun showTransferCompletedNotification(title: String, body: String) {
        try {
            restoreIdleForegroundNotification()
            val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    TRANSFER_DONE_CHANNEL_ID,
                    "Transfer completed",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    // Sound is played cleanly via MediaPlayer according to user settings.
                    setSound(null, null)
                    enableVibration(false)
                }
                nm.createNotificationChannel(channel)
            }

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(appContext, TRANSFER_DONE_CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(appContext)
            }

            builder
                .setOngoing(false)
                .setAutoCancel(true)
                .setProgress(0, 0, false)
                .setSmallIcon(appContext.applicationInfo.icon)
                .setContentTitle(title)
                .setContentText(body)

            buildLaunchPendingIntent(TRANSFER_NOTIFICATION_ID)?.let { builder.setContentIntent(it) }
            nm.notify(TRANSFER_NOTIFICATION_ID, builder.build())
        } catch (_: Exception) {
            // Completion notification failure must never break transfers.
        }
    }

    private fun cancelTransferProgressNotification() {
        restoreIdleForegroundNotification()
        try {
            val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            nm?.cancel(TRANSFER_NOTIFICATION_ID)
        } catch (_: Exception) {
            // Ignore cleanup errors.
        }
    }

    /// Android 17+ gates local network access behind a runtime permission; older versions grant it implicitly.
    private fun hasLocalNetworkPermission(): Boolean {
        if (Build.VERSION.SDK_INT < API_LEVEL_ANDROID_17) {
            return true
        }
        return appContext.checkSelfPermission(PERMISSION_ACCESS_LOCAL_NETWORK) == PackageManager.PERMISSION_GRANTED
    }

    fun handleRequestPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode == REQUEST_CODE_LOCAL_NETWORK) {
            pendingPermissionResult?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            pendingPermissionResult = null
        }
    }

    /// Absolute path of the shared "Download" directory (usually /storage/emulated/0/Download).
    @Suppress("DEPRECATION")
    private fun getDownloadsDirectory(): String {
        return Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).absolutePath
    }

    private fun getDeviceName(): String? {
        return try {
            listOfNotNull(
                Settings.Global.getString(appContext.contentResolver, Settings.Global.DEVICE_NAME)?.trim(),
                Settings.Secure.getString(appContext.contentResolver, "bluetooth_name")?.trim(),
                Build.MODEL?.trim()
            ).firstOrNull { it.isNotEmpty() }
        } catch (_: Exception) {
            Build.MODEL?.trim()?.takeIf { it.isNotEmpty() }
        }
    }

    private fun isAnimationsEnabled(): Boolean {
        return Settings.Global.getFloat(
            appContext.contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1.0f
        ) != 0.0f
    }

    private fun playCompletionSound(path: String) {
        try {
            stopSoundRunnable?.let { mainHandler.removeCallbacks(it) }
            stopSoundRunnable = null
            activeMediaPlayer?.let { prev ->
                runCatching {
                    if (prev.isPlaying) {
                        prev.stop()
                    }
                }
                runCatching { prev.release() }
            }
            activeMediaPlayer = null

            val player = MediaPlayer()
            activeMediaPlayer = player
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_EVENT)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            player.setDataSource(path)
            player.setOnCompletionListener { mp ->
                stopSoundRunnable?.let { mainHandler.removeCallbacks(it) }
                stopSoundRunnable = null
                if (activeMediaPlayer === mp) {
                    activeMediaPlayer = null
                }
                runCatching { mp.release() }
            }
            player.setOnErrorListener { mp, _, _ ->
                stopSoundRunnable?.let { mainHandler.removeCallbacks(it) }
                stopSoundRunnable = null
                if (activeMediaPlayer === mp) {
                    activeMediaPlayer = null
                }
                runCatching { mp.release() }
                true
            }
            player.prepareAsync()
            player.setOnPreparedListener { mp ->
                if (activeMediaPlayer !== mp) {
                    runCatching { mp.release() }
                    return@setOnPreparedListener
                }
                mp.start()
                val cutoff = Runnable {
                    if (activeMediaPlayer === mp) {
                        activeMediaPlayer = null
                        stopSoundRunnable = null
                        runCatching {
                            if (mp.isPlaying) {
                                mp.stop()
                            }
                        }
                        runCatching { mp.release() }
                    }
                }
                stopSoundRunnable = cutoff
                mainHandler.postDelayed(cutoff, MAX_CUSTOM_SOUND_MS)
            }
        } catch (_: Exception) {
            // Audio feedback must never break file transfers.
        }
    }

    private fun updateShareShortcuts(devices: List<Map<String, Any?>>) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return
        }
        try {
            val sm = appContext.getSystemService(ShortcutManager::class.java) ?: return
            val limit = sm.maxShortcutCountPerActivity.coerceIn(1, 4)
            val shortcuts = mutableListOf<ShortcutInfo>()
            val desiredIds = mutableSetOf<String>()

            for ((index, item) in devices.take(limit).withIndex()) {
                val fingerprint = (item["fingerprint"] as? String)?.trim() ?: continue
                if (fingerprint.isEmpty()) {
                    continue
                }
                val alias = ((item["alias"] as? String)?.trim().orEmpty()).ifEmpty { "Device" }
                val deviceType = (item["deviceType"] as? String)?.trim().orEmpty()
                val shortcutId = "$SHORTCUT_ID_PREFIX$fingerprint"
                desiredIds.add(shortcutId)

                val launchIntent = Intent(appContext, MainActivity::class.java).apply {
                    action = Intent.ACTION_MAIN
                }
                val info = ShortcutInfo.Builder(appContext, shortcutId)
                    .setShortLabel(alias)
                    .setLongLabel(alias)
                    .setLongLived(true)
                    .setCategories(setOf(SHARE_TARGET_CATEGORY))
                    .setPerson(Person.Builder().setName(alias).build())
                    .setIcon(createShortcutIcon(alias, deviceType))
                    .setRank(index)
                    .setIntent(launchIntent)
                    .build()
                shortcuts.add(info)
            }

            val staleIds = sm.dynamicShortcuts
                .map { it.id }
                .filter { it.startsWith(SHORTCUT_ID_PREFIX) && !desiredIds.contains(it) }
            if (staleIds.isNotEmpty()) {
                sm.removeDynamicShortcuts(staleIds)
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                for (info in shortcuts.asReversed()) {
                    sm.pushDynamicShortcut(info)
                }
            } else {
                sm.dynamicShortcuts = shortcuts
            }
        } catch (_: Exception) {
            // Share shortcut registration must never break discovery or transfers.
        }
    }

    private fun createShortcutIcon(alias: String, deviceType: String): Icon {
        val size = 108
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val bgColor = when (deviceType.lowercase(Locale.ROOT)) {
            "desktop", "laptop" -> Color.parseColor("#0F766E")
            "mobile", "tablet" -> Color.parseColor("#1D4ED8")
            else -> Color.parseColor("#334155")
        }

        val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = bgColor
            style = Paint.Style.FILL
        }
        canvas.drawCircle(size / 2f, size / 2f, size / 2f, bgPaint)

        val trimmed = alias.trim()
        val initial = if (trimmed.isNotEmpty()) {
            trimmed.substring(0, 1).uppercase(Locale.ROOT)
        } else {
            "L"
        }
        val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = 46f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            textAlign = Paint.Align.CENTER
        }
        val textY = size / 2f - (textPaint.descent() + textPaint.ascent()) / 2f
        canvas.drawText(initial, size / 2f, textY, textPaint)
        return Icon.createWithAdaptiveBitmap(bitmap)
    }

    private fun flushPendingNativeShares() {
        val toSend: List<Map<String, Any?>>
        val channel: MethodChannel?
        synchronized(shareLock) {
            shareIntentReady = true
            channel = methodChannel
            toSend = pendingNativeShares.toList()
            pendingNativeShares.clear()
        }
        if (channel != null && toSend.isNotEmpty()) {
            mainHandler.post {
                for (payload in toSend) {
                    channel.invokeMethod("incomingShare", payload)
                }
            }
        }
    }

    fun handleIncomingShareIntent(context: Context, intent: Intent, fromDirectShare: Boolean) {
        val shortcutId = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            intent.getStringExtra(Intent.EXTRA_SHORTCUT_ID)
        } else {
            null
        }
        val directShareFingerprint = if (shortcutId != null && shortcutId.startsWith(SHORTCUT_ID_PREFIX)) {
            shortcutId.removePrefix(SHORTCUT_ID_PREFIX)
        } else {
            null
        }

        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        val uris = extractShareUris(intent)
        val fileMaps = uris.mapNotNull { uri -> buildZeroCopyFileInfo(context, uri)?.toMap() }
        if (text.isNullOrBlank() && fileMaps.isEmpty()) {
            return
        }

        val payload = mapOf<String, Any?>(
            "directShareFingerprint" to directShareFingerprint,
            "fromDirectShare" to fromDirectShare,
            "text" to text,
            "files" to fileMaps,
        )

        val channelToSend: MethodChannel?
        synchronized(shareLock) {
            if (shareIntentReady && methodChannel != null) {
                channelToSend = methodChannel
            } else {
                pendingNativeShares.add(payload)
                channelToSend = null
            }
        }
        if (channelToSend != null) {
            mainHandler.post {
                channelToSend.invokeMethod("incomingShare", payload)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun extractShareUris(intent: Intent): List<Uri> {
        val uris = LinkedHashSet<Uri>()
        when (intent.action) {
            Intent.ACTION_SEND -> {
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.forEach { uris.add(it) }
            }
        }
        if (uris.isEmpty()) {
            val clipData = intent.clipData
            if (clipData != null) {
                for (i in 0 until clipData.itemCount) {
                    clipData.getItemAt(i).uri?.let { uris.add(it) }
                }
            }
        }
        return uris.toList()
    }

    private fun buildZeroCopyFileInfo(context: Context, uri: Uri): FileInfo? {
        if (uri.scheme == ContentResolver.SCHEME_FILE) {
            val path = uri.path ?: return null
            val file = File(path)
            if (!file.exists()) {
                return null
            }
            val lastMod = if (file.lastModified() > 0L) file.lastModified().toRfc3339() else null
            return FileInfo(
                name = file.name.ifBlank { "file_${System.currentTimeMillis()}" },
                size = file.length(),
                uri = file.absolutePath,
                lastModified = lastMod,
            )
        }

        if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
            return null
        }

        val resolver = context.contentResolver
        var displayName: String? = null
        var size = -1L

        runCatching {
            resolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIdx != -1 && !cursor.isNull(nameIdx)) {
                        displayName = cursor.getString(nameIdx)
                    }
                    val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (sizeIdx != -1 && !cursor.isNull(sizeIdx)) {
                        size = cursor.getLong(sizeIdx)
                    }
                }
            }
        }

        val pfd = runCatching { resolver.openFileDescriptor(uri, "r") }.getOrNull()
        if (pfd != null) {
            if (size <= 0L && pfd.statSize > 0L) {
                size = pfd.statSize
            }
            retainShareFd(uri.toString(), pfd)
        }

        val finalName = if (!displayName.isNullOrBlank()) {
            displayName!!
        } else {
            val mimeType = runCatching { resolver.getType(uri) }.getOrNull()
            val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType)
            if (!ext.isNullOrBlank()) "file_${System.currentTimeMillis()}.$ext" else "file_${System.currentTimeMillis()}"
        }

        return FileInfo(
            name = finalName,
            size = size.coerceAtLeast(0L),
            uri = uri.toString(),
            lastModified = null,
        )
    }

    private fun retainShareFd(uriKey: String, pfd: ParcelFileDescriptor) {
        val now = System.currentTimeMillis()
        synchronized(shareLock) {
            retainedShareFds.remove(uriKey)?.let { old -> runCatching { old.pfd.close() } }
            val expiredKeys = retainedShareFds.entries
                .filter { now - it.value.createdAtMs > RETAINED_SHARE_FD_TTL_MS }
                .map { it.key }
            for (k in expiredKeys) {
                retainedShareFds.remove(k)?.let { old -> runCatching { old.pfd.close() } }
            }
            while (retainedShareFds.size >= MAX_RETAINED_SHARE_FDS) {
                val eldestKey = retainedShareFds.entries.firstOrNull()?.key ?: break
                retainedShareFds.remove(eldestKey)?.let { old -> runCatching { old.pfd.close() } }
            }
            retainedShareFds[uriKey] = RetainedFd(pfd, now)
        }
    }

    private fun handleScanFile(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrBlank() || !File(path).isAbsolute) {
            result.error("INVALID_ARGUMENT", "Expected an absolute filesystem path", null)
            return
        }

        try {
            MediaScannerConnection.scanFile(appContext, arrayOf(path), null) { _, uri ->
                result.success(uri != null)
            }
        } catch (e: Exception) {
            result.error("SCAN_FAILED", e.message ?: "Failed to scan file", null)
        }
    }

    private fun handleGetFileDescriptor(call: MethodCall, result: MethodChannel.Result) {
        val uriString = call.argument<String>("uri")
        if (uriString == null) {
            result.error("INVALID_ARGUMENT", "Missing content URI", null)
            return
        }

        val uri = Uri.parse(uriString)
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
            result.error("INVALID_ARGUMENT", "Expected a content:// URI", null)
            return
        }

        val directPfd = runCatching { appContext.contentResolver.openFileDescriptor(uri, "r") }.getOrNull()
        if (directPfd != null) {
            // Ownership of the detached descriptor is transferred to the caller. It must be
            // closed by Rust (or whichever native consumer receives it) after use.
            directPfd.use {
                result.success(it.detachFd())
            }
            return
        }

        val retainedDup = synchronized(shareLock) {
            val retained = retainedShareFds[uriString] ?: return@synchronized null
            runCatching {
                Os.lseek(retained.pfd.fileDescriptor, 0L, OsConstants.SEEK_SET)
                ParcelFileDescriptor.dup(retained.pfd.fileDescriptor)
            }.getOrNull()
        }
        if (retainedDup != null) {
            retainedDup.use {
                result.success(it.detachFd())
            }
            return
        }

        result.error("OPEN_FAILED", "Could not open content URI", null)
    }

    /// Creates a new file inside a SAF directory and opens it for writing.
    ///
    /// Returns the URI of the created document (Android may rename the file on
    /// collisions) and an owned writable file descriptor. The descriptor must be
    /// closed by the native consumer it is passed to.
    private fun handleCreateFile(call: MethodCall, result: MethodChannel.Result) {
        val parentUriString = call.argument<String>("parentUri")
        val fileName = call.argument<String>("fileName")
        if (parentUriString == null || fileName == null) {
            result.error("INVALID_ARGUMENT", "Missing parentUri or fileName", null)
            return
        }

        try {
            val parentUri = Uri.parse(parentUriString)

            // A pure tree URI (content://…/tree/X) must be converted to its
            // document form before it can be used as a parent document.
            val segments = parentUri.pathSegments
            val parentDocumentUri = if (segments.size == 2 && segments[0] == "tree") {
                DocumentsContract.buildDocumentUriUsingTree(
                    parentUri,
                    DocumentsContract.getTreeDocumentId(parentUri)
                )
            } else {
                parentUri
            }

            // Providers append an extension when the MIME type does not match the one Android maps the
            // file's extension to (e.g. "test.conf" as text/plain becomes "test.conf.txt"), so derive it
            // from the same map. application/octet-stream keeps the name as-is for unknown extensions.
            val extension = fileName.substringAfterLast('.', "").lowercase(Locale.ROOT)
            val mimeType = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
                ?: "application/octet-stream"

            val documentUri =
                DocumentsContract.createDocument(appContext.contentResolver, parentDocumentUri, mimeType, fileName)
            if (documentUri == null) {
                result.error("CREATE_FAILED", "Could not create $fileName in $parentUriString", null)
                return
            }

            // "wt" is write + truncate: the document is new, unless the provider
            // handed out an existing one instead of creating a second document.
            val parcelFileDescriptor = appContext.contentResolver.openFileDescriptor(documentUri, "wt")
            if (parcelFileDescriptor == null) {
                result.error("OPEN_FAILED", "The content provider did not return a file descriptor", null)
                return
            }

            parcelFileDescriptor.use {
                result.success(
                    mapOf(
                        "uri" to documentUri.toString(),
                        "fd" to it.detachFd(),
                    )
                )
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message ?: "Permission denied for content URI", null)
        } catch (e: Exception) {
            result.error("CREATE_FAILED", e.message ?: "Failed to create file", null)
        }
    }

    /// Opens an existing document created by [handleCreateFile] for writing,
    /// discarding its current content.
    ///
    /// Used to write a file again after a failed attempt, so that it keeps its
    /// name instead of being created a second time under a numbered one.
    ///
    /// Returns an owned writable file descriptor. It stays open after this call
    /// and must be closed by the native consumer it is passed to.
    private fun handleOpenFileForWriting(call: MethodCall, result: MethodChannel.Result) {
        val uriString = call.argument<String>("uri")
        if (uriString == null) {
            result.error("INVALID_ARGUMENT", "Missing content URI", null)
            return
        }

        val uri = Uri.parse(uriString)
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
            result.error("INVALID_ARGUMENT", "Expected a content:// URI", null)
            return
        }

        try {
            // "wt" is write + truncate. A document provider may ignore the
            // truncation, so the writer additionally shortens the file itself.
            val parcelFileDescriptor = appContext.contentResolver.openFileDescriptor(uri, "wt")
            if (parcelFileDescriptor == null) {
                result.error("OPEN_FAILED", "The content provider did not return a file descriptor", null)
                return
            }

            parcelFileDescriptor.use {
                result.success(it.detachFd())
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message ?: "Permission denied for content URI", null)
        } catch (e: Exception) {
            result.error("OPEN_FAILED", e.message ?: "Failed to open content URI", null)
        }
    }

    private fun openDirectoryPicker(activity: Activity, onlyPath: Boolean) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        activity.startActivityForResult(
            intent,
            if (onlyPath) REQUEST_CODE_PICK_DIRECTORY_PATH else REQUEST_CODE_PICK_DIRECTORY
        )
    }

    private fun openFilePicker(activity: Activity) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            putExtra("multi-pick", true)
            type = "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        activity.startActivityForResult(intent, REQUEST_CODE_PICK_FILE)
    }

    @SuppressLint("WrongConstant")
    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_CODE_PICK_DIRECTORY &&
            requestCode != REQUEST_CODE_PICK_DIRECTORY_PATH &&
            requestCode != REQUEST_CODE_PICK_FILE
        ) {
            return
        }

        if (resultCode == Activity.RESULT_CANCELED) {
            pendingResult?.error("CANCELED", "Canceled", null)
            pendingResult = null
            return
        }

        if (resultCode != Activity.RESULT_OK || data == null) {
            pendingResult?.error("Error $resultCode", "Failed to access directory or file", null)
            pendingResult = null
            return
        }

        when (requestCode) {
            REQUEST_CODE_PICK_DIRECTORY -> {
                val uri: Uri? = data.data
                val takeFlags: Int =
                    data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                if (uri != null) {
                    appContext.contentResolver.takePersistableUriPermission(uri, takeFlags)

                    val files = mutableListOf<FileInfo>()
                    listFiles(uri, files)
                    val resultData = PickDirectoryResult(uri.toString(), files)
                    pendingResult?.success(resultData.toMap())
                    pendingResult = null
                } else {
                    pendingResult?.error("Error", "Failed to access directory", null)
                    pendingResult = null
                }
            }

            REQUEST_CODE_PICK_DIRECTORY_PATH -> {
                val uri: Uri? = data.data
                val takeFlags: Int =
                    data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                if (uri != null) {
                    appContext.contentResolver.takePersistableUriPermission(uri, takeFlags)
                    pendingResult?.success(uri.toString())
                    pendingResult = null
                } else {
                    pendingResult?.error("Error", "Failed to access directory", null)
                    pendingResult = null
                }
            }

            REQUEST_CODE_PICK_FILE -> {
                val uriList: List<Uri> = when {
                    data.clipData != null -> {
                        val clipData = data.clipData
                        val uris = mutableListOf<Uri>()
                        for (i in 0 until clipData!!.itemCount) {
                            uris.add(clipData.getItemAt(i).uri)
                        }
                        uris
                    }

                    data.data != null -> listOf(data.data!!)
                    else -> {
                        pendingResult?.error("Error", "Failed to access file", null)
                        return
                    }
                }

                val takeFlags: Int =
                    data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)

                val resultList = mutableListOf<FileInfo>()
                for (uri in uriList) {
                    appContext.contentResolver.takePersistableUriPermission(uri, takeFlags)
                    val documentFile = FastDocumentFile.fromDocumentUri(appContext, uri)
                    if (documentFile == null) {
                        pendingResult?.error("Error", "Failed to access file", null)
                        return
                    }
                    resultList.add(
                        FileInfo(
                            name = documentFile.name,
                            size = documentFile.size,
                            uri = uri.toString(),
                            lastModified = documentFile.lastModified?.toRfc3339(),
                        )
                    )
                }

                pendingResult?.success(resultList.map { it.toMap() })
                pendingResult = null
            }
        }
    }

    private fun listFiles(uri: Uri, files: MutableList<FileInfo>) {
        val pickedDir: FastDocumentFile = FastDocumentFile.fromTreeUri(appContext, uri)

        for (file in pickedDir.listFiles()) {
            if (file.isDirectory) {
                listFiles(file.uri, files)
            } else if (file.isFile) {
                files.add(
                    FileInfo(
                        name = file.name,
                        size = file.size,
                        uri = file.uri.toString(),
                        lastModified = file.lastModified?.toRfc3339(),
                    ),
                )
            }
        }
    }

    @SuppressLint("WrongConstant")
    private fun handleCreateDirectory(call: MethodCall, result: MethodChannel.Result) {
        val documentUri = Uri.parse(call.argument<String>("documentUri")!!)
        val directoryName = call.argument<String>("directoryName")!!

        if (folderExists(documentUri, directoryName)) {
            result.success(null)
            return
        }

        DocumentsContract.createDocument(
            appContext.contentResolver,
            documentUri,
            DocumentsContract.Document.MIME_TYPE_DIR,
            directoryName
        )

        result.success(null)
    }

    private fun folderExists(documentUri: Uri, folderName: String): Boolean {
        var cursor: Cursor? = null
        try {
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(documentUri, DocumentsContract.getDocumentId(documentUri))
            cursor = appContext.contentResolver.query(
                childrenUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE
                ),
                null,
                null,
                null,
            )

            if (cursor != null) {
                while (cursor.moveToNext()) {
                    val displayName = cursor.getString(0)
                    val mimeType = cursor.getString(1)

                    if (folderName == displayName && DocumentsContract.Document.MIME_TYPE_DIR == mimeType) {
                        return true
                    }
                }
            }
        } finally {
            cursor?.close()
        }
        return false
    }

    private fun openGallery() {
        val intent = Intent().apply {
            action = Intent.ACTION_VIEW
            type = "image/*"
        }
        val activity = activityRef?.get()
        if (activity != null) {
            activity.startActivity(intent)
        } else {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            appContext.startActivity(intent)
        }
    }

    private fun openUriFromBackground(uriStr: String) {
        val uri = Uri.parse(uriStr)
        val intent = Intent(Intent.ACTION_VIEW, uri).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        appContext.startActivity(intent)
    }
}

data class PickDirectoryResult(
    val directoryUri: String,
    val files: List<FileInfo>,
) {
    fun toMap(): Map<String, Any> {
        return mapOf(
            "directoryUri" to directoryUri,
            "files" to files.map { it.toMap() }
        )
    }
}

data class FileInfo(
    val name: String,
    val size: Long,
    val uri: String,
    val lastModified: String?
) {
    fun toMap(): Map<String, Any?> {
        return mapOf(
            "name" to name,
            "size" to size,
            "uri" to uri,
            "lastModified" to lastModified
        )
    }
}

/// Formats milliseconds since epoch as an RFC 3339 string in UTC.
private fun Long.toRfc3339(): String {
    val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
    format.timeZone = TimeZone.getTimeZone("UTC")
    return format.format(Date(this))
}
