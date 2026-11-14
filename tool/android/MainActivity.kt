package __PKG__

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    /** 冷启动时通知带进来的会话 id，Flutter 起来后会来取一次。 */
    private var pendingConversation: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingConversation = intent?.getStringExtra("dsh_conversation")
        // Android 13+ 要先拿到通知权限，否则消息通知不会显示。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val conversationId = intent.getStringExtra("dsh_conversation")
        if (!conversationId.isNullOrEmpty()) {
            // App 已经在后台：直接把会话 id 送回 Flutter，让它跳过去。
            channel?.invokeMethod("opened", conversationId)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val methodChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dsh/chat_service")
        channel = methodChannel
        methodChannel.setMethodCallHandler { call, result ->
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
                    val conversationId = call.argument<String>("conversationId")
                    Notifications.showMessage(this, title, body, conversationId)
                    result.success(true)
                }
                "initialConversation" -> {
                    val id = pendingConversation
                    pendingConversation = null
                    result.success(id)
                }
                else -> result.notImplemented()
            }
        }
    }
}
