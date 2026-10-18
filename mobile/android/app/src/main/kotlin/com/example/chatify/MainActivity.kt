package com.example.chatify

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val mpesaChannel = "com.example.chatify/mpesa"
    private val mpesaPackage = "com.safaricom.mpesa.lifestyle"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Safaricom's current M-PESA app is distributed as My OneApp.
        // Launch its installed main activity rather than relying on the unsupported mpesa:// URI.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, mpesaChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openMpesa" -> {
                        try {
                            val launchIntent = packageManager.getLaunchIntentForPackage(mpesaPackage)
                            if (launchIntent == null) {
                                result.success(false)
                            } else {
                                launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(launchIntent)
                                result.success(true)
                            }
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
