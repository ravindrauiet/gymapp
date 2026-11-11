package com.fitkey.fitkey_user

import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.fitness.FitnessLocal
import com.google.android.gms.fitness.LocalRecordingClient
import com.google.android.gms.fitness.data.LocalDataType
import com.google.android.gms.fitness.data.LocalField
import com.google.android.gms.fitness.request.LocalDataReadRequest
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import java.util.concurrent.TimeUnit

/**
 * "fitkey/steps" channel: Google Play services Recording API on mobile.
 *
 * Play services records the phone's hardware step counter in the background, all day, even when FITKEY is closed
 * (no Health Connect, no Google sign-in; needs only the ACTIVITY_RECOGNITION permission). FITKEY subscribes once and
 * then reads per-day totals, so steps walked with the app closed are counted too.
 *
 *  isAvailable()            → Boolean  (Play services new enough for the Recording API)
 *  subscribe()              → Boolean  (start / keep recording step deltas)
 *  readDays({days: n})      → [{date: "yyyy-MM-dd", steps: Int}] for the last n local days incl. today
 */
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fitkey/steps").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "isAvailable" -> result.success(isAvailable())
                    "subscribe" -> {
                        if (!isAvailable()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        FitnessLocal.getLocalRecordingClient(this)
                            .subscribe(LocalDataType.TYPE_STEP_COUNT_DELTA)
                            .addOnSuccessListener { result.success(true) }
                            .addOnFailureListener { e -> result.error("subscribe_failed", e.message, null) }
                    }
                    "readDays" -> {
                        if (!isAvailable()) {
                            result.success(emptyList<Map<String, Any>>())
                            return@setMethodCallHandler
                        }
                        val days = (call.argument<Int>("days") ?: 1).coerceIn(1, 10)
                        readDays(days, result)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("steps_error", e.message, null)
            }
        }
    }

    private fun isAvailable(): Boolean =
        GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(
            this,
            LocalRecordingClient.LOCAL_RECORDING_CLIENT_MIN_VERSION_CODE,
        ) == ConnectionResult.SUCCESS

    private fun readDays(days: Int, result: MethodChannel.Result) {
        val fmt = SimpleDateFormat("yyyy-MM-dd", Locale.US)
        val first = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
            add(Calendar.DAY_OF_YEAR, -(days - 1))
        }
        val start = first.timeInMillis / 1000
        val end = System.currentTimeMillis() / 1000
        val request = LocalDataReadRequest.Builder()
            .aggregate(LocalDataType.TYPE_STEP_COUNT_DELTA)
            // One bucket per day, aligned to local midnight because the range starts at local midnight.
            .bucketByTime(1, TimeUnit.DAYS)
            .setTimeRange(start, end, TimeUnit.SECONDS)
            .build()
        FitnessLocal.getLocalRecordingClient(this).readData(request)
            .addOnSuccessListener { response ->
                val totals = LinkedHashMap<String, Int>()
                val day = first.clone() as Calendar
                for (i in 0 until days) {
                    totals[fmt.format(day.time)] = 0
                    day.add(Calendar.DAY_OF_YEAR, 1)
                }
                for (bucket in response.buckets) {
                    for (dataSet in bucket.dataSets) {
                        for (point in dataSet.dataPoints) {
                            val key = fmt.format(point.getStartTime(TimeUnit.MILLISECONDS))
                            val steps = point.getValue(LocalField.FIELD_STEPS).asInt()
                            if (totals.containsKey(key)) totals[key] = (totals[key] ?: 0) + steps
                        }
                    }
                }
                result.success(totals.map { (date, steps) -> mapOf("date" to date, "steps" to steps) })
            }
            .addOnFailureListener { e -> result.error("read_failed", e.message, null) }
    }
}
