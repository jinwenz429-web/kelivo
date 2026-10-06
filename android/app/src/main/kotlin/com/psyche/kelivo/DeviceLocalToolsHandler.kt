package com.psyche.kelivo

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.CalendarContract
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Native backend for the AI assistant's device-local tools and companion
 * reality signals: screen time, calendar, one-shot location, explicit BLE
 * discovery, battery/network state and connected Bluetooth audio devices.
 *
 * All methods receive the tool arguments as a JSON string and return a JSON
 * string payload. Errors that the LLM should see (missing permission, bad
 * arguments) are returned as JSON payloads with an "error" field instead of
 * platform errors, so the model can relay them to the user.
 */
class DeviceLocalToolsHandler(private val context: Context) {
    private var attachedActivity: Activity? = context as? Activity
    private val activity: Activity get() = requireNotNull(attachedActivity) { "foreground_activity_required" }

    fun attachActivity(activity: Activity) { attachedActivity = activity }
    fun detachActivity(activity: Activity) {
        if (attachedActivity !== activity) return
        attachedActivity = null
        pendingCalendarPermissionCallback?.invoke(false)
        pendingCalendarPermissionCallback = null
        pendingLocationPermissionCallback?.invoke(false, false)
        pendingLocationPermissionCallback = null
        pendingBlePermissionCallback?.invoke(false)
        pendingBlePermissionCallback = null
    }

    companion object {
        const val CHANNEL_NAME = "app.device_tools"
        const val CALENDAR_PERMISSION_REQUEST_CODE = 4201
        const val LOCATION_PERMISSION_REQUEST_CODE = 4202
        const val BLE_PERMISSION_REQUEST_CODE = 4203
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var realitySignalsStarted = false
    private var lastBatterySignature: String? = null
    private var lastNetworkSignature: String? = null
    private var batteryReceiver: BroadcastReceiver? = null
    private var networkReceiver: BroadcastReceiver? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var observedDefaultNetwork: Network? = null
    private var audioDeviceCallback: AudioDeviceCallback? = null
    private val knownBluetoothAudioDeviceIds = mutableSetOf<Int>()
    private var pendingCalendarPermissionCallback: ((Boolean) -> Unit)? = null
    private var pendingLocationPermissionCallback: ((Boolean, Boolean) -> Unit)? = null
    private var pendingBlePermissionCallback: ((Boolean) -> Unit)? = null
    private var pendingBleScanResult: MethodChannel.Result? = null
    private var bleScanCallback: ScanCallback? = null
    private var bleScanFinishRunnable: Runnable? = null
    private val bleScanResults = linkedMapOf<String, JSONObject>()
    private val bleOpaqueIds = mutableMapOf<String, String>()
    private val locationHandler = LocationToolHandler(context)

    fun configure(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL_NAME)
        channel!!.setMethodCallHandler { call, result ->
            val argsJson = call.arguments as? String ?: "{}"
            when (call.method) {
                "phoneControlStatus" -> result.success(PhoneControlService.status(context))
                "phoneControl" -> PhoneControlService.execute(argsJson) { result.success(it) }
                "startRealitySignals" -> {
                    startRealitySignals()
                    result.success(null)
                }
                "stopRealitySignals" -> {
                    stopRealitySignals()
                    result.success(null)
                }
                "openAccessibilitySettings" -> {
                    try {
                        activity.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("SETTINGS_UNAVAILABLE", e.message, null)
                    }
                }
                "hasUsageStatsPermission" -> result.success(hasUsageStatsPermission())
                "openUsageAccessSettings" -> {
                    openUsageAccessSettings()
                    result.success(null)
                }
                "hasCalendarPermission" -> result.success(hasCalendarPermission())
                "requestCalendarPermission" -> requestCalendarPermission(result)
                "hasLocationPermission" -> result.success(locationHandler.hasPermission())
                "hasBleScanPermission" -> result.success(hasBleScanPermission())
                "requestBleScanPermission" -> requestBleScanPermission { granted ->
                    result.success(granted)
                }
                "scanBluetoothLe" -> scanBluetoothLe(argsJson, result)
                "requestLocationPermission" -> requestLocationPermission { granted, permanentlyDenied ->
                    if (permanentlyDenied) {
                        result.error(
                            "LOCATION_PERMISSION_PERMANENTLY_DENIED",
                            "Allow location permission in system Settings.",
                            null,
                        )
                    } else {
                        result.success(granted)
                    }
                }
                "openAppSettings" -> {
                    try {
                        activity.startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.fromParts("package", context.packageName, null),
                            ),
                        )
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("SETTINGS_UNAVAILABLE", e.message, null)
                    }
                }
                "getCurrentLocation" -> {
                    if (locationHandler.hasPermission()) {
                        locationHandler.getCurrentLocation(result)
                    } else {
                        requestLocationPermission { granted, _ ->
                            if (granted) {
                                locationHandler.getCurrentLocation(result)
                            } else {
                                result.success(
                                    errorPayload(
                                        "NO_PERMISSION",
                                        "Location permission is not granted. Please allow location " +
                                            "while using the app in system Settings and try again.",
                                    ),
                                )
                            }
                        }
                    }
                }
                "getScreenTime" -> handleScreenTime(argsJson, result)
                "queryCalendar" -> withCalendarPermission(
                    arrayOf(Manifest.permission.READ_CALENDAR),
                    result,
                ) { runAsync(result) { queryCalendar(JSONObject(argsJson)) } }
                "createCalendarEvent" -> withCalendarPermission(
                    arrayOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR),
                    result,
                ) { runAsync(result) { createCalendarEvent(JSONObject(argsJson)) } }
                else -> result.notImplemented()
            }
        }
    }

    /** Forwarded from the Activity. Returns true when the request was ours. */
    fun onRequestPermissionsResult(
        requestCode: Int,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode == BLE_PERMISSION_REQUEST_CODE) {
            val callback = pendingBlePermissionCallback
            pendingBlePermissionCallback = null
            callback?.invoke(hasBleScanPermission())
            return true
        }
        if (requestCode == LOCATION_PERMISSION_REQUEST_CODE) {
            val callback = pendingLocationPermissionCallback
            pendingLocationPermissionCallback = null
            // Approximate (coarse) permission alone is sufficient.
            val granted = locationHandler.hasPermission()
            // Check after a completed request: false before the first request
            // does not mean permanent denial. Empty results indicate cancellation.
            val permanentlyDenied = attachedActivity != null && !granted && grantResults.isNotEmpty() &&
                !ActivityCompat.shouldShowRequestPermissionRationale(activity, Manifest.permission.ACCESS_COARSE_LOCATION) &&
                !ActivityCompat.shouldShowRequestPermissionRationale(activity, Manifest.permission.ACCESS_FINE_LOCATION)
            callback?.invoke(granted, permanentlyDenied)
            return true
        }
        if (requestCode != CALENDAR_PERMISSION_REQUEST_CODE) return false
        val callback = pendingCalendarPermissionCallback ?: return true
        pendingCalendarPermissionCallback = null
        val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        callback(granted)
        return true
    }

    fun dispose() {
        stopRealitySignals()
        cancelBleScan(
            errorPayload(
                "BLE_SCAN_CANCELLED",
                "Bluetooth scan cancelled because the host was destroyed.",
            ),
        )
        locationHandler.dispose()
        pendingLocationPermissionCallback?.invoke(false, false)
        pendingLocationPermissionCallback = null
        pendingBlePermissionCallback?.invoke(false)
        pendingBlePermissionCallback = null
        channel?.setMethodCallHandler(null)
        channel = null
    }

    // ---------------------------------------------------------------------
    // Passive reality signals
    // ---------------------------------------------------------------------

    private fun startRealitySignals() {
        if (realitySignalsStarted) {
            emitCurrentBatterySnapshot(force = false)
            emitNetworkSnapshot(force = false)
            return
        }
        realitySignalsStarted = true

        val batteryFilter = IntentFilter().apply {
            addAction(Intent.ACTION_BATTERY_CHANGED)
            addAction(Intent.ACTION_POWER_CONNECTED)
            addAction(Intent.ACTION_POWER_DISCONNECTED)
        }
        batteryReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent == null) return
                if (intent.action == Intent.ACTION_BATTERY_CHANGED) {
                    emitBatteryIntent(intent, force = false)
                } else {
                    emitCurrentBatterySnapshot(force = false)
                }
            }
        }.also { receiver ->
            val sticky = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(
                    receiver,
                    batteryFilter,
                    Context.RECEIVER_NOT_EXPORTED,
                )
            } else {
                @Suppress("DEPRECATION")
                context.registerReceiver(receiver, batteryFilter)
            }
            sticky?.let { emitBatteryIntent(it, force = true) }
        }

        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            networkCallback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    observedDefaultNetwork = network
                }

                override fun onLost(network: Network) {
                    if (observedDefaultNetwork != network) return
                    observedDefaultNetwork = null
                    emitNetworkState(
                        online = false,
                        transport = "none",
                        metered = false,
                        force = false,
                    )
                }

                override fun onCapabilitiesChanged(
                    network: Network,
                    networkCapabilities: NetworkCapabilities,
                ) {
                    observedDefaultNetwork = network
                    emitNetworkCapabilities(networkCapabilities, force = false)
                }
            }.also { callback ->
                runCatching { connectivity.registerDefaultNetworkCallback(callback) }
                    .onFailure { networkCallback = null }
            }
        } else {
            @Suppress("DEPRECATION")
            val filter = IntentFilter(ConnectivityManager.CONNECTIVITY_ACTION)
            networkReceiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    emitNetworkSnapshot(force = false)
                }
            }.also { receiver ->
                @Suppress("DEPRECATION")
                context.registerReceiver(receiver, filter)
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            knownBluetoothAudioDeviceIds.clear()
            audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                .filter(::isBluetoothAudioDevice)
                .forEach { device ->
                    knownBluetoothAudioDeviceIds.add(device.id)
                    emitBluetoothAudioDevice(device, connected = true)
                }
            audioDeviceCallback = object : AudioDeviceCallback() {
                override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
                    for (device in addedDevices) {
                        if (!isBluetoothAudioDevice(device)) continue
                        if (knownBluetoothAudioDeviceIds.add(device.id)) {
                            emitBluetoothAudioDevice(device, connected = true)
                        }
                    }
                }

                override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                    for (device in removedDevices) {
                        if (knownBluetoothAudioDeviceIds.remove(device.id)) {
                            emitBluetoothAudioDevice(device, connected = false)
                        }
                    }
                }
            }.also { callback ->
                audioManager.registerAudioDeviceCallback(callback, mainHandler)
            }
        }

        emitCurrentBatterySnapshot(force = false)
        emitNetworkSnapshot(force = false)
    }

    private fun stopRealitySignals() {
        if (!realitySignalsStarted) return
        realitySignalsStarted = false

        batteryReceiver?.let { receiver ->
            runCatching { context.unregisterReceiver(receiver) }
        }
        batteryReceiver = null

        networkReceiver?.let { receiver ->
            runCatching { context.unregisterReceiver(receiver) }
        }
        networkReceiver = null

        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        networkCallback?.let { callback ->
            runCatching { connectivity.unregisterNetworkCallback(callback) }
        }
        networkCallback = null
        observedDefaultNetwork = null

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioDeviceCallback?.let { callback ->
                runCatching { audioManager.unregisterAudioDeviceCallback(callback) }
            }
        }
        audioDeviceCallback = null
        knownBluetoothAudioDeviceIds.clear()

        lastBatterySignature = null
        lastNetworkSignature = null
    }

    private fun emitCurrentBatterySnapshot(force: Boolean) {
        @Suppress("DEPRECATION")
        val sticky = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            ?: return
        emitBatteryIntent(sticky, force)
    }

    private fun emitBatteryIntent(intent: Intent, force: Boolean) {
        val rawLevel = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        if (rawLevel < 0 || scale <= 0) return

        val level = ((rawLevel.toDouble() / scale.toDouble()) * 100.0)
            .toInt()
            .coerceIn(0, 100)
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        val plugged = intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)
        val charging =
            status == BatteryManager.BATTERY_STATUS_CHARGING ||
                status == BatteryManager.BATTERY_STATUS_FULL ||
                plugged != 0
        val bucket = when {
            level <= 10 -> "critical"
            level <= 20 -> "low"
            level <= 50 -> "medium"
            else -> "high"
        }
        val signature = "$bucket:$charging"
        val retryUntilDelivered = !charging && (bucket == "low" || bucket == "critical")
        if (!force && signature == lastBatterySignature && !retryUntilDelivered) return
        lastBatterySignature = signature

        emitRealitySignal(
            "battery",
            mapOf(
                "level" to level,
                "charging" to charging,
                "bucket" to bucket,
            ),
        )
    }

    private fun emitNetworkSnapshot(force: Boolean) {
        val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val network = connectivity.activeNetwork
            observedDefaultNetwork = network
            val capabilities = network?.let(connectivity::getNetworkCapabilities)
            emitNetworkCapabilities(capabilities, force)
            return
        }

        @Suppress("DEPRECATION")
        val info = connectivity.activeNetworkInfo
        @Suppress("DEPRECATION")
        val transport = when (info?.type) {
            ConnectivityManager.TYPE_WIFI -> "wifi"
            ConnectivityManager.TYPE_MOBILE -> "cellular"
            ConnectivityManager.TYPE_ETHERNET -> "ethernet"
            ConnectivityManager.TYPE_BLUETOOTH -> "bluetooth"
            else -> if (info == null) "none" else "other"
        }
        @Suppress("DEPRECATION")
        val online = info?.isConnected == true
        val metered = runCatching { connectivity.isActiveNetworkMetered }.getOrDefault(false)
        emitNetworkState(online, transport, metered, force)
    }

    private fun emitNetworkCapabilities(
        capabilities: NetworkCapabilities?,
        force: Boolean,
    ) {
        if (capabilities == null) {
            emitNetworkState(
                online = false,
                transport = "none",
                metered = false,
                force = force,
            )
            return
        }
        val online =
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        val transport = when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) -> "bluetooth"
            else -> "other"
        }
        val metered =
            !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        emitNetworkState(online, transport, metered, force)
    }

    private fun emitNetworkState(
        online: Boolean,
        transport: String,
        metered: Boolean,
        force: Boolean,
    ) {
        val signature = "$online:$transport:$metered"
        if (!force && signature == lastNetworkSignature) return
        lastNetworkSignature = signature

        emitRealitySignal(
            "network",
            mapOf(
                "online" to online,
                "transport" to transport,
                "metered" to metered,
            ),
        )
    }

    private fun isBluetoothAudioDevice(device: AudioDeviceInfo): Boolean {
        if (device.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
            device.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
        ) {
            return true
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            device.type == AudioDeviceInfo.TYPE_HEARING_AID
        ) {
            return true
        }
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            (device.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                device.type == AudioDeviceInfo.TYPE_BLE_SPEAKER)
    }

    private fun bluetoothAudioType(device: AudioDeviceInfo): String = when {
        device.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "a2dp"
        device.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "sco"
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            device.type == AudioDeviceInfo.TYPE_HEARING_AID -> "hearing_aid"
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            device.type == AudioDeviceInfo.TYPE_BLE_HEADSET -> "ble_headset"
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            device.type == AudioDeviceInfo.TYPE_BLE_SPEAKER -> "ble_speaker"
        else -> "bluetooth"
    }

    private fun emitBluetoothAudioDevice(
        device: AudioDeviceInfo,
        connected: Boolean,
    ) {
        val type = bluetoothAudioType(device)
        val name = device.productName.toString().trim()
        emitRealitySignal(
            "bluetooth_audio",
            mapOf(
                "connected" to connected,
                "deviceId" to device.id,
                "deviceType" to type,
                "deviceName" to name,
                "deviceKey" to "$type:$name",
            ),
        )
    }

    private fun emitRealitySignal(kind: String, payload: Map<String, Any>) {
        if (!realitySignalsStarted) return
        mainHandler.post {
            channel?.invokeMethod(
                "realitySignal",
                mapOf(
                    "kind" to kind,
                    "payload" to payload,
                ),
            )
        }
    }

    // ---------------------------------------------------------------------
    // Permission helpers
    // ---------------------------------------------------------------------

    private fun requestLocationPermission(completion: (Boolean, Boolean) -> Unit) {
        if (locationHandler.hasPermission()) {
            completion(true, false)
            return
        }
        if (pendingCalendarPermissionCallback != null ||
            pendingLocationPermissionCallback != null ||
            pendingBlePermissionCallback != null
        ) {
            completion(false, false)
            return
        }
        if (attachedActivity == null) {
            completion(false, false)
            return
        }
        pendingLocationPermissionCallback = completion
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION),
            LOCATION_PERMISSION_REQUEST_CODE,
        )
    }

    private fun bleScanPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun hasBleScanPermission(): Boolean =
        bleScanPermissions().all {
            ContextCompat.checkSelfPermission(context, it) ==
                PackageManager.PERMISSION_GRANTED
        }

    private fun requestBleScanPermission(completion: (Boolean) -> Unit) {
        if (hasBleScanPermission()) {
            completion(true)
            return
        }
        if (pendingCalendarPermissionCallback != null ||
            pendingLocationPermissionCallback != null ||
            pendingBlePermissionCallback != null
        ) {
            completion(false)
            return
        }
        if (attachedActivity == null) {
            completion(false)
            return
        }
        val missing = bleScanPermissions().filter {
            ContextCompat.checkSelfPermission(context, it) !=
                PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            completion(true)
            return
        }
        pendingBlePermissionCallback = completion
        ActivityCompat.requestPermissions(
            activity,
            missing.toTypedArray(),
            BLE_PERMISSION_REQUEST_CODE,
        )
    }

    private fun calendarPermissions(): Array<String> = arrayOf(
        Manifest.permission.READ_CALENDAR,
        Manifest.permission.WRITE_CALENDAR,
    )

    private fun hasCalendarPermission(): Boolean {
        return calendarPermissions().all {
            ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
        }
    }

    /** Used by the assistant settings toggle — returns a boolean grant result. */
    private fun requestCalendarPermission(result: MethodChannel.Result) {
        val missing = calendarPermissions().filter {
            ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            result.success(true)
            return
        }
        if (pendingCalendarPermissionCallback != null ||
            pendingLocationPermissionCallback != null ||
            pendingBlePermissionCallback != null
        ) {
            result.success(false)
            return
        }
        if (attachedActivity == null) {
            result.success(false)
            return
        }
        pendingCalendarPermissionCallback = { granted -> result.success(granted) }
        ActivityCompat.requestPermissions(
            activity,
            missing.toTypedArray(),
            CALENDAR_PERMISSION_REQUEST_CODE,
        )
    }

    private fun withCalendarPermission(
        permissions: Array<String>,
        result: MethodChannel.Result,
        action: () -> Unit,
    ) {
        val missing = permissions.filter {
            ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            action()
            return
        }
        if (pendingCalendarPermissionCallback != null ||
            pendingLocationPermissionCallback != null ||
            pendingBlePermissionCallback != null
        ) {
            result.success(
                errorPayload(
                    "PERMISSION_REQUEST_IN_PROGRESS",
                    "Another permission request is already in progress. Please try again.",
                ),
            )
            return
        }
        if (attachedActivity == null) {
            result.success(errorPayload("FOREGROUND_REQUIRED", "Open Kelivo to grant calendar permission."))
            return
        }
        pendingCalendarPermissionCallback = { granted ->
            if (granted) {
                action()
            } else {
                result.success(
                    errorPayload(
                        "NO_PERMISSION",
                        "Calendar permission is not granted. Please ask the user to grant the " +
                            "calendar permission to this app and try again.",
                    ),
                )
            }
        }
        ActivityCompat.requestPermissions(activity, missing.toTypedArray(), CALENDAR_PERMISSION_REQUEST_CODE)
    }

    private fun hasUsageStatsPermission(): Boolean {
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                context.packageName,
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                context.packageName,
            )
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun openUsageAccessSettings() {
        try {
            activity.startActivity(
                Intent(
                    Settings.ACTION_USAGE_ACCESS_SETTINGS,
                    Uri.fromParts("package", context.packageName, null),
                ),
            )
        } catch (_: Exception) {
            try {
                activity.startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
            } catch (_: Exception) {
                // Settings page unavailable; the error payload still informs the model.
            }
        }
    }


    // ---------------------------------------------------------------------
    // Explicit Bluetooth LE discovery
    // ---------------------------------------------------------------------

    @SuppressLint("MissingPermission")
    private fun scanBluetoothLe(argsJson: String, result: MethodChannel.Result) {
        if (!hasBleScanPermission()) {
            result.success(
                errorPayload(
                    "NO_PERMISSION",
                    "Bluetooth nearby-device permission is not granted. Enable the Bluetooth LE tool in Assistant settings first.",
                ),
            )
            return
        }
        if (pendingBleScanResult != null) {
            result.success(
                errorPayload(
                    "BLE_SCAN_BUSY",
                    "A Bluetooth LE scan is already running. Wait for it to finish and try again.",
                ),
            )
            return
        }

        val adapter = context
            .getSystemService(BluetoothManager::class.java)
            ?.adapter
        if (adapter == null) {
            result.success(errorPayload("BLE_UNAVAILABLE", "This device does not support Bluetooth."))
            return
        }
        if (!adapter.isEnabled) {
            result.success(errorPayload("BLE_DISABLED", "Bluetooth is turned off on this device."))
            return
        }
        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) {
            result.success(errorPayload("BLE_UNAVAILABLE", "Bluetooth LE scanning is not available."))
            return
        }

        val params = try {
            JSONObject(argsJson)
        } catch (_: Exception) {
            JSONObject()
        }
        val durationMs = params.optLong("duration_ms", 4000L).coerceIn(1000L, 10_000L)
        val includeUnnamed = params.optBoolean("include_unnamed", false)
        val nameFilter = params.optString("name_contains")
            .trim()
            .lowercase()
            .takeIf { it.isNotEmpty() }
        val limit = params.optInt("limit", 20).coerceIn(1, 50)

        pendingBleScanResult = result
        bleScanResults.clear()

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, scanResult: ScanResult) {
                recordBleScanResult(scanResult, includeUnnamed, nameFilter)
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                for (scanResult in results) {
                    recordBleScanResult(scanResult, includeUnnamed, nameFilter)
                }
            }

            override fun onScanFailed(errorCode: Int) {
                finishBleScan(
                    errorPayload(
                        "BLE_SCAN_FAILED",
                        "Bluetooth LE scan failed with Android error code " + errorCode + ".",
                    ),
                )
            }
        }
        bleScanCallback = callback

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        try {
            scanner.startScan(null, settings, callback)
        } catch (_: SecurityException) {
            finishBleScan(
                errorPayload(
                    "NO_PERMISSION",
                    "Bluetooth scan permission was revoked. Re-enable the Bluetooth LE tool and try again.",
                ),
            )
            return
        } catch (error: Exception) {
            finishBleScan(
                errorPayload(
                    "BLE_SCAN_FAILED",
                    error.message ?: "Bluetooth LE scan could not start.",
                ),
            )
            return
        }

        val finish = Runnable {
            finishBleScan(buildBleScanPayload(durationMs, limit))
        }
        bleScanFinishRunnable = finish
        mainHandler.postDelayed(finish, durationMs)
    }

    @SuppressLint("MissingPermission")
    private fun recordBleScanResult(
        scanResult: ScanResult,
        includeUnnamed: Boolean,
        nameFilter: String?,
    ) {
        if (pendingBleScanResult == null) return
        val record = scanResult.scanRecord
        val advertisedName = record?.deviceName?.trim().orEmpty()
        val systemName = runCatching { scanResult.device.name?.trim().orEmpty() }.getOrDefault("")
        val name = advertisedName.ifEmpty { systemName }
        if (name.isEmpty() && !includeUnnamed) return
        if (nameFilter != null && !name.lowercase().contains(nameFilter)) return

        val address = runCatching { scanResult.device.address }
            .getOrNull()
            ?.takeIf { it.isNotBlank() }
            ?: return
        val existing = bleScanResults[address]
        if (existing != null && existing.optInt("rssi", -999) >= scanResult.rssi) return

        val services = JSONArray()
        record?.serviceUuids?.forEach { parcelUuid ->
            services.put(parcelUuid.uuid.toString())
        }

        // Never expose the Bluetooth MAC address to the model. The
        // opaque id is random and process-local; a future connect/read flow must
        // resolve it through this in-memory map instead of reversing a hash.
        val opaqueId = bleOpaqueIds.getOrPut(address) {
            UUID.randomUUID().toString()
        }
        val payload = JSONObject()
            .put("device_id", opaqueId)
            .put("name", if (name.isEmpty()) JSONObject.NULL else name)
            .put("rssi", scanResult.rssi)
            .put("service_uuids", services)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            payload.put("connectable", scanResult.isConnectable)
        }
        val txPower = record?.txPowerLevel ?: Int.MIN_VALUE
        if (txPower != Int.MIN_VALUE) {
            payload.put("tx_power", txPower)
        }
        bleScanResults[address] = payload
    }

    private fun buildBleScanPayload(durationMs: Long, limit: Int): String {
        val devices = JSONArray()
        bleScanResults.values
            .sortedByDescending { it.optInt("rssi", -999) }
            .take(limit)
            .forEach { devices.put(it) }
        return JSONObject()
            .put("devices", devices)
            .put("count", devices.length())
            .put("duration_ms", durationMs)
            .toString()
    }

    @SuppressLint("MissingPermission")
    private fun finishBleScan(payload: String) {
        val result = pendingBleScanResult ?: return
        val callback = bleScanCallback
        val finish = bleScanFinishRunnable

        pendingBleScanResult = null
        bleScanCallback = null
        bleScanFinishRunnable = null
        if (finish != null) mainHandler.removeCallbacks(finish)

        if (callback != null) {
            runCatching {
                context
                    .getSystemService(BluetoothManager::class.java)
                    ?.adapter
                    ?.bluetoothLeScanner
                    ?.stopScan(callback)
            }
        }
        result.success(payload)
        bleScanResults.clear()
    }

    private fun cancelBleScan(payload: String) {
        finishBleScan(payload)
    }

    // ---------------------------------------------------------------------
    // Async plumbing
    // ---------------------------------------------------------------------

    private fun runAsync(result: MethodChannel.Result, block: () -> String) {
        executor.execute {
            val payload = try {
                block()
            } catch (e: Exception) {
                errorPayload("EXECUTION_ERROR", e.message ?: "Tool execution failed.")
            }
            mainHandler.post { result.success(payload) }
        }
    }

    private fun errorPayload(error: String, message: String): String {
        return JSONObject().put("error", error).put("message", message).toString()
    }

    // ---------------------------------------------------------------------
    // Screen time
    // ---------------------------------------------------------------------

    private fun handleScreenTime(argsJson: String, result: MethodChannel.Result) {
        if (!hasUsageStatsPermission()) {
            openUsageAccessSettings()
            result.success(
                errorPayload(
                    "NO_PERMISSION",
                    "Usage access permission is not granted. The system settings page has been " +
                        "opened; please ask the user to enable 'Usage access' for this app and try again.",
                ),
            )
            return
        }
        runAsync(result) { computeScreenTime(JSONObject(argsJson)) }
    }

    private fun computeScreenTime(params: JSONObject): String {
        val top = params.optString("top").toIntOrNull()?.coerceIn(1, 50)
            ?: params.optInt("top", 10).coerceIn(1, 50)

        val now = ZonedDateTime.now()
        val zone = now.zone
        val beginRaw = params.optString("begin").takeIf { it.isNotBlank() }
        val endRaw = params.optString("end").takeIf { it.isNotBlank() }
        val rangePreset = params.optString("range").takeIf { it.isNotBlank() } ?: "today"

        val startTime: ZonedDateTime
        val endTime: ZonedDateTime
        try {
            endTime = endRaw?.let { parseTime(it, zone) } ?: now
            startTime = if (beginRaw != null) {
                parseTime(beginRaw, zone)
            } else when (rangePreset) {
                "week" -> now.minusDays(7)
                else -> now.toLocalDate().atStartOfDay(zone)
            }
        } catch (e: Exception) {
            return errorPayload("INVALID_TIME", e.message ?: "Invalid time format for begin/end.")
        }
        if (!startTime.isBefore(endTime)) {
            return errorPayload("INVALID_RANGE", "begin must be earlier than end.")
        }

        val isCustom = beginRaw != null || endRaw != null
        val startMs = startTime.toInstant().toEpochMilli()
        val endMs = endTime.toInstant().toEpochMilli()

        val usageStatsManager =
            context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val pm = context.packageManager

        val launcherPackages = resolveLauncherPackages(pm)
        val foregroundMs = computeForegroundTime(usageStatsManager, startMs, endMs, launcherPackages)

        val sorted = foregroundMs.entries
            .filter { it.value > 0 }
            .sortedByDescending { it.value }
        val totalMs = sorted.sumOf { it.value }

        val apps = JSONArray()
        sorted.take(top).forEach { entry ->
            apps.put(
                JSONObject()
                    .put("package", entry.key)
                    .put("app_name", resolveAppName(pm, entry.key))
                    .put("total_ms", entry.value)
                    .put("total_minutes", entry.value / 60000),
            )
        }

        return JSONObject()
            .put("range", if (isCustom) "custom" else rangePreset)
            .put("start", startTime.withNano(0).toString())
            .put("end", endTime.withNano(0).toString())
            .put("total_ms", totalMs)
            .put("total_minutes", totalMs / 60000)
            .put("apps", apps)
            .toString()
    }

    // 计算屏幕时间时向前回看的窗口(12h), 用于还原区间开始时刻已在前台的 App.
    private val lookbackMs = 12L * 60 * 60 * 1000

    /**
     * 用"全局单一前台"模型计算 [startMs, endMs) 区间内每个 App 的前台时长(毫秒).
     * 任意时刻只有一个 App 计时: 新 App 进前台先结算上一个, 息屏停止计时;
     * 区间起点向前回看以补回"开始前已在前台"的使用段, 结算时裁剪回区间内.
     */
    @Suppress("DEPRECATION")
    private fun computeForegroundTime(
        usageStatsManager: UsageStatsManager,
        startMs: Long,
        endMs: Long,
        excludedPackages: Set<String>,
    ): Map<String, Long> {
        val foregroundMs = HashMap<String, Long>()
        val events = usageStatsManager.queryEvents(startMs - lookbackMs, endMs)
        val event = UsageEvents.Event()

        var currentPkg: String? = null
        var currentStart = 0L

        fun settle(until: Long) {
            val pkg = currentPkg
            currentPkg = null
            if (pkg == null || pkg in excludedPackages) return
            val from = maxOf(currentStart, startMs)
            val duration = until - from
            if (duration > 0) {
                foregroundMs[pkg] = (foregroundMs[pkg] ?: 0L) + duration
            }
        }

        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            when (event.eventType) {
                UsageEvents.Event.MOVE_TO_FOREGROUND -> {
                    if (event.packageName != currentPkg) {
                        settle(event.timeStamp)
                        currentPkg = event.packageName
                        currentStart = event.timeStamp
                    }
                }

                UsageEvents.Event.MOVE_TO_BACKGROUND -> {
                    if (event.packageName == currentPkg) {
                        settle(event.timeStamp)
                    }
                }

                UsageEvents.Event.SCREEN_NON_INTERACTIVE -> {
                    settle(event.timeStamp)
                }
            }
        }
        settle(endMs)
        return foregroundMs
    }

    private fun resolveLauncherPackages(pm: PackageManager): Set<String> {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        return runCatching {
            pm.queryIntentActivities(intent, 0)
                .mapNotNull { it.activityInfo?.packageName }
                .toSet()
        }.getOrDefault(emptySet())
    }

    private fun resolveAppName(pm: PackageManager, packageName: String): String {
        return runCatching {
            pm.getApplicationLabel(pm.getApplicationInfo(packageName, 0)).toString()
        }.getOrDefault(packageName)
    }

    // ---------------------------------------------------------------------
    // Calendar query
    // ---------------------------------------------------------------------

    private fun queryCalendar(params: JSONObject): String {
        val limit = params.optString("limit").toIntOrNull()?.coerceIn(1, 100)
            ?: params.optInt("limit", 20).coerceIn(1, 100)
        val query = params.optString("query").takeIf { it.isNotBlank() }

        val now = ZonedDateTime.now()
        val zone = now.zone
        val beginRaw = params.optString("begin").takeIf { it.isNotBlank() }
        val endRaw = params.optString("end").takeIf { it.isNotBlank() }
        val rangePreset = params.optString("range").takeIf { it.isNotBlank() } ?: "today"

        val startTime: ZonedDateTime
        val endTime: ZonedDateTime
        try {
            startTime = if (beginRaw != null) {
                parseTime(beginRaw, zone)
            } else when (rangePreset) {
                "week" -> now.toLocalDate().atStartOfDay(zone).minusDays(now.dayOfWeek.value.toLong() - 1)
                "month" -> now.toLocalDate().withDayOfMonth(1).atStartOfDay(zone)
                else -> now.toLocalDate().atStartOfDay(zone)
            }
            endTime = if (endRaw != null) {
                parseTime(endRaw, zone)
            } else if (beginRaw != null) {
                // Custom interval: 'range' is ignored per the tool contract, and
                // the end defaults to now (matches iOS).
                now
            } else when (rangePreset) {
                "week" -> startTime.plusDays(7)
                "month" -> startTime.plusMonths(1)
                else -> now.toLocalDate().plusDays(1).atStartOfDay(zone)
            }
        } catch (e: Exception) {
            return errorPayload("INVALID_TIME", e.message ?: "Invalid time format for begin/end.")
        }
        if (!startTime.isBefore(endTime)) {
            return errorPayload("INVALID_RANGE", "begin must be earlier than end.")
        }

        val startMs = startTime.toInstant().toEpochMilli()
        val endMs = endTime.toInstant().toEpochMilli()

        val projection = arrayOf(
            CalendarContract.Instances.EVENT_ID,
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.DESCRIPTION,
            CalendarContract.Instances.EVENT_LOCATION,
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
            CalendarContract.Instances.ALL_DAY,
            CalendarContract.Instances.CALENDAR_DISPLAY_NAME,
        )
        // Escape LIKE wildcards so the keyword is matched literally as a
        // substring (e.g. searching "100%" must not act as a wildcard).
        val selection = if (query != null) "${CalendarContract.Instances.TITLE} LIKE ? ESCAPE '\\'" else null
        val selectionArgs = if (query != null) {
            val escaped = query
                .replace("\\", "\\\\")
                .replace("%", "\\%")
                .replace("_", "\\_")
            arrayOf("%$escaped%")
        } else null

        val uri = CalendarContract.Instances.CONTENT_URI.buildUpon()
            .appendPath(startMs.toString())
            .appendPath(endMs.toString())
            .build()

        val events = JSONArray()
        context.contentResolver.query(
            uri,
            projection,
            selection,
            selectionArgs,
            "${CalendarContract.Instances.BEGIN} ASC",
        )?.use { cursor ->
            var count = 0
            while (cursor.moveToNext() && count < limit) {
                val dtStart = cursor.getLong(4)
                val dtEnd = cursor.getLong(5)
                val allDay = cursor.getInt(6) == 1
                val obj = JSONObject()
                    .put("id", cursor.getLong(0))
                    .put("title", cursor.getString(1) ?: "")
                    .put("description", cursor.getString(2) ?: "")
                    .put("location", cursor.getString(3) ?: "")
                if (allDay) {
                    obj.put("start", Instant.ofEpochMilli(dtStart).atZone(ZoneOffset.UTC).toLocalDate().toString())
                    obj.put(
                        "end",
                        if (dtEnd > 0) Instant.ofEpochMilli(dtEnd).atZone(ZoneOffset.UTC).toLocalDate().toString() else "",
                    )
                } else {
                    obj.put("start", Instant.ofEpochMilli(dtStart).atZone(zone).withNano(0).toString())
                    obj.put(
                        "end",
                        if (dtEnd > 0) Instant.ofEpochMilli(dtEnd).atZone(zone).withNano(0).toString() else "",
                    )
                }
                obj.put("all_day", allDay)
                obj.put("calendar", cursor.getString(7) ?: "")
                events.put(obj)
                count++
            }
        }

        return JSONObject()
            .put("range_start", startTime.withNano(0).toString())
            .put("range_end", endTime.withNano(0).toString())
            .put("count", events.length())
            .put("events", events)
            .toString()
    }

    // ---------------------------------------------------------------------
    // Calendar create
    // ---------------------------------------------------------------------

    private fun createCalendarEvent(params: JSONObject): String {
        val title = params.optString("title").takeIf { it.isNotBlank() }
        val startRaw = params.optString("start").takeIf { it.isNotBlank() }
        val endRaw = params.optString("end").takeIf { it.isNotBlank() }
        val allDay = params.optBoolean("all_day", false)

        if (title == null || startRaw == null) {
            return errorPayload("MISSING_REQUIRED", "Both 'title' and 'start' are required.")
        }

        val zone = ZoneId.systemDefault()
        val startTime: ZonedDateTime
        val endTime: ZonedDateTime
        try {
            startTime = parseTime(startRaw, zone)
            endTime = if (endRaw != null) {
                parseTime(endRaw, zone)
            } else if (allDay) {
                startTime.toLocalDate().plusDays(1).atStartOfDay(zone)
            } else {
                startTime.plusHours(1)
            }
        } catch (e: Exception) {
            return errorPayload("INVALID_TIME", e.message ?: "Invalid time format.")
        }
        if (!startTime.isBefore(endTime)) {
            return errorPayload("INVALID_RANGE", "end must be later than start.")
        }

        val description = params.optString("description")
        val location = params.optString("location")
        val reminderMinutes = parseReminderMinutes(params.opt("reminders"))

        val eventStartMillis: Long
        val eventEndMillis: Long
        val eventTimeZone: String
        if (allDay) {
            val startDate = startTime.toLocalDate()
            val endDate = endTime.toLocalDate()
            if (!startDate.isBefore(endDate)) {
                return errorPayload("INVALID_RANGE", "all-day event end date must be later than start date.")
            }
            eventStartMillis = startDate.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
            eventEndMillis = endDate.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
            eventTimeZone = "UTC"
        } else {
            eventStartMillis = startTime.toInstant().toEpochMilli()
            eventEndMillis = endTime.toInstant().toEpochMilli()
            eventTimeZone = zone.id
        }

        val calendarId = getDefaultCalendarId()
            ?: return errorPayload(
                "NO_CALENDAR",
                "No calendar account found on this device. Please add a calendar account first.",
            )

        val values = ContentValues().apply {
            put(CalendarContract.Events.CALENDAR_ID, calendarId)
            put(CalendarContract.Events.TITLE, title)
            put(CalendarContract.Events.DESCRIPTION, description)
            put(CalendarContract.Events.EVENT_LOCATION, location)
            put(CalendarContract.Events.DTSTART, eventStartMillis)
            put(CalendarContract.Events.DTEND, eventEndMillis)
            put(CalendarContract.Events.EVENT_TIMEZONE, eventTimeZone)
            if (allDay) {
                put(CalendarContract.Events.ALL_DAY, 1)
            }
        }

        val uri = context.contentResolver.insert(CalendarContract.Events.CONTENT_URI, values)
            ?: return errorPayload("INSERT_FAILED", "Failed to insert calendar event.")

        val eventId = ContentUris.parseId(uri)
        val savedReminders = insertReminders(eventId, reminderMinutes)
        if (savedReminders.isNotEmpty()) {
            // 只有提醒真的写进去了才置 HAS_ALARM, 否则事件行会谎称有闹钟.
            runCatching {
                context.contentResolver.update(
                    ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId),
                    ContentValues().apply { put(CalendarContract.Events.HAS_ALARM, 1) },
                    null,
                    null,
                )
            }
        }

        val payload = JSONObject()
            .put("success", true)
            .put("event_id", eventId)
            .put("title", title)
            .put("start", startTime.withNano(0).toString())
            .put("end", endTime.withNano(0).toString())
            .put("all_day", allDay)
            .put("location", location)
            .put("reminders", JSONArray(savedReminders))
        if (savedReminders.size < reminderMinutes.size) {
            // 事件已经建好了, 但部分/全部提醒被日历账户拒绝; 必须让模型看见,
            // 否则它会告诉用户提醒已设置.
            payload
                .put("reminders_requested", JSONArray(reminderMinutes))
                .put(
                    "warning",
                    "The event was created, but the calendar account rejected some reminders. " +
                        "Tell the user which reminders were actually saved.",
                )
        }
        return payload.toString()
    }

    /**
     * 提醒偏移(事件开始前多少分钟). 兼容数组、单个数字/字符串; 负值按绝对值处理,
     * 去重后最多保留 5 条.
     */
    private fun parseReminderMinutes(raw: Any?): List<Int> {
        if (raw == null || raw == JSONObject.NULL) return emptyList()
        val items: List<Any?> = when (raw) {
            is JSONArray -> (0 until raw.length()).map { raw.opt(it) }
            else -> listOf(raw)
        }
        val minutes = LinkedHashSet<Int>()
        for (item in items) {
            val value = when (item) {
                is Number -> item.toDouble()
                is String -> item.trim().toDoubleOrNull()
                else -> null
            } ?: continue
            if (value.isNaN() || value.isInfinite()) continue
            // 用 Double 中转: Math.abs(Int.MIN_VALUE) 仍是负数, 会被当成"事件开始之后"提醒.
            minutes.add(Math.abs(value).coerceAtMost(40320.0).toInt()) // 上限 4 周
            if (minutes.size == 5) break
        }
        return minutes.toList()
    }

    /** 写入提醒, 返回实际成功写入的偏移分钟数. */
    private fun insertReminders(eventId: Long, minutes: List<Int>): List<Int> {
        if (minutes.isEmpty()) return emptyList()
        val saved = mutableListOf<Int>()
        for (minute in minutes) {
            val values = ContentValues().apply {
                put(CalendarContract.Reminders.EVENT_ID, eventId)
                put(CalendarContract.Reminders.MINUTES, minute)
                put(CalendarContract.Reminders.METHOD, CalendarContract.Reminders.METHOD_ALERT)
            }
            val inserted = runCatching {
                context.contentResolver.insert(CalendarContract.Reminders.CONTENT_URI, values)
            }.getOrNull()
            if (inserted != null) saved.add(minute)
        }
        return saved
    }

    private fun getDefaultCalendarId(): Long? {
        val projection = arrayOf(CalendarContract.Calendars._ID)
        val writableSelection =
            "${CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL} >= ? AND ${CalendarContract.Calendars.SYNC_EVENTS} = 1"
        val writableArgs = arrayOf(CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR.toString())
        context.contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            projection,
            "$writableSelection AND ${CalendarContract.Calendars.IS_PRIMARY} = 1",
            writableArgs,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) return cursor.getLong(0)
        }
        context.contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            projection,
            writableSelection,
            writableArgs,
            "${CalendarContract.Calendars.VISIBLE} DESC",
        )?.use { cursor ->
            if (cursor.moveToFirst()) return cursor.getLong(0)
        }
        return null
    }

    // ---------------------------------------------------------------------
    // Time parsing
    // ---------------------------------------------------------------------

    /**
     * 依次尝试: epoch 毫秒 -> 带偏移日期时间 -> Instant -> 本地日期时间 -> 本地日期(当天 0 点).
     */
    private fun parseTime(raw: String, zone: ZoneId): ZonedDateTime {
        val text = raw.trim()
        text.toLongOrNull()?.let { return Instant.ofEpochMilli(it).atZone(zone) }
        runCatching { return OffsetDateTime.parse(text).atZoneSameInstant(zone) }
        runCatching { return Instant.parse(text).atZone(zone) }
        runCatching { return LocalDateTime.parse(text).atZone(zone) }
        runCatching { return LocalDate.parse(text).atStartOfDay(zone) }
        error("Invalid time format: '$text'. Use ISO-8601 date/date-time or epoch milliseconds.")
    }
}
