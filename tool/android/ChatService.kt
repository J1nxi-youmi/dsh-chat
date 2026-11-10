package __PKG__

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * 只干一件事：把 App 进程钉在后台，让 SSE 连接在锁屏/切后台时还能活着。
 * 真正的消息处理仍在 Dart 侧，这里不碰网络。
 */
class ChatService : Service() {
    override fun onCreate() {
        super.onCreate()
        startForeground(SERVICE_ID, Notifications.serviceNotification(this))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(SERVICE_ID, Notifications.serviceNotification(this))
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val SERVICE_ID = 1001

        fun start(context: Context) {
            val intent = Intent(context, ChatService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ChatService::class.java))
        }
    }
}
