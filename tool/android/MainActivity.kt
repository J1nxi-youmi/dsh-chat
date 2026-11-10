package __PKG__

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 13+ 要先拿到通知权限，否则消息通知不会显示。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dsh/chat_service")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        ChatService.start(this)
                        result.success(true)
                    }
                    "stop" -> {
                        ChatService.stop(this)
                        result.success(true)
                    }
                    "notify" -> {
                        val title = call.argument<String>("title") ?: "新消息"
                        val body = call.argument<String>("body") ?: ""
                        Notifications.showMessage(this, title, body)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
