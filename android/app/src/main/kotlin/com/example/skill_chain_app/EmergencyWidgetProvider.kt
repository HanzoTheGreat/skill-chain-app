package com.example.skill_chain_app

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.view.WindowManager
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat

class EmergencyWidgetProvider : AppWidgetProvider() {

    companion object {
        const val PREFS_NAME = "skill_chain_widget_prefs"
        const val KEY_IS_PUBLIC = "is_out_in_public"
        const val KEY_DIRTY_FROM_WIDGET = "dirty_from_widget"
        const val KEY_LOCKSCREEN_ENABLED = "lockscreen_trigger_enabled"
        const val CHANNEL_ID = "emergency_lockscreen_channel_v4"
        const val NOTIFICATION_ID = 99112

        fun updateAllWidgets(context: Context) {
            val appContext = context.applicationContext
            val manager = AppWidgetManager.getInstance(appContext)
            val ids = manager.getAppWidgetIds(
                ComponentName(appContext, EmergencyWidgetProvider::class.java)
            )
            for (id in ids) {
                updateSingleWidget(appContext, manager, id)
            }
            refreshLockscreenTrigger(appContext)
        }

        fun refreshLockscreenTrigger(context: Context) {
            val appContext = context.applicationContext
            val prefs = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val enabled = prefs.getBoolean(KEY_LOCKSCREEN_ENABLED, true)
            val isPublic = prefs.getBoolean(KEY_IS_PUBLIC, false)
            val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                nm.deleteNotificationChannel("emergency_lockscreen_channel")
                nm.deleteNotificationChannel("emergency_lockscreen_channel_v2")
                nm.deleteNotificationChannel("emergency_lockscreen_channel_v3")
            }

            if (!enabled) {
                nm.cancel(NOTIFICATION_ID)
                return
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "Sperrbildschirm Notfall-Direktstart",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Ein-Klick-Start auf dem Sperrbildschirm ohne PIN"
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    setSound(null, null)
                    enableVibration(false)
                    setShowBadge(false)
                }
                nm.createNotificationChannel(channel)
            }

            // NUR EIN EINZIGER CONTENT-INTENT (Keine Action-Buttons, keine RemoteViews!).
            // Genau das lässt Xiaomi/MIUI auf dem Sperrbildschirm OHNE PIN durch!
            val launchIntent = Intent(appContext, MainActivity::class.java).apply {
                action = "ACTION_START_EMERGENCY_CASCADE"
                putExtra("START_EMERGENCY", true)
                data = Uri.parse("skillchain://lockscreen_direct_launch")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            val mainLaunchPending = PendingIntent.getActivity(
                appContext,
                9500,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val modeInfo = if (isPublic) "🌍 Aktuell: UNTERWEGS" else "🏠 Aktuell: ZUHAUSE"

            val notification = NotificationCompat.Builder(appContext, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_dialog_alert)
                .setContentTitle("🚨 NOTFALL-KASKADE STARTEN ($modeInfo)")
                .setContentText("Hier aufs Banner tippen -> Startet sofort ohne PIN (Modus im Screen wechselbar)")
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setSilent(true)
                .setOngoing(true)
                .setAutoCancel(false)
                .setColor(Color.parseColor("#D32F2F"))
                .setContentIntent(mainLaunchPending)
                .build()

            notification.flags = notification.flags or
                    Notification.FLAG_ONGOING_EVENT or
                    Notification.FLAG_NO_CLEAR

            nm.notify(NOTIFICATION_ID, notification)
        }

        fun updateSingleWidget(
            context: Context,
            appWidgetManager: AppWidgetManager,
            appWidgetId: Int
        ) {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val isPublic = prefs.getBoolean(KEY_IS_PUBLIC, false)

            val views = RemoteViews(context.packageName, R.layout.emergency_widget)

            if (isPublic) {
                views.setTextViewText(R.id.widget_mode_icon, "🌍")
                views.setTextViewText(R.id.widget_mode_label, "UNTERWEGS")
                views.setTextColor(R.id.widget_mode_label, Color.parseColor("#FFD740"))
                views.setTextViewText(R.id.widget_subtitle_text, "Startet: 🌍 Unterwegs-Kette")
            } else {
                views.setTextViewText(R.id.widget_mode_icon, "🏠")
                views.setTextViewText(R.id.widget_mode_label, "ZUHAUSE")
                views.setTextColor(R.id.widget_mode_label, Color.parseColor("#69F0AE"))
                views.setTextViewText(R.id.widget_subtitle_text, "Startet: 🏠 Zuhause-Kette")
            }

            // Auf dem entsperrten Homescreen-Widget funktionieren beide Buttons wie gewohnt:
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                action = "ACTION_START_EMERGENCY_CASCADE"
                putExtra("START_EMERGENCY", true)
                data = Uri.parse("skillchain://launch/$appWidgetId")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            val launchPending = PendingIntent.getActivity(
                context,
                appWidgetId * 10 + 1,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.emergency_widget_trigger, launchPending)

            val toggleIntent = Intent(context, WidgetToggleActivity::class.java).apply {
                action = "ACTION_TOGGLE_MODE"
                data = Uri.parse("skillchain://toggle/$appWidgetId")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
            }
            val togglePending = PendingIntent.getActivity(
                context,
                appWidgetId * 10 + 2,
                toggleIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.emergency_widget_mode_toggle, togglePending)

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (appWidgetId in appWidgetIds) {
            updateSingleWidget(context, appWidgetManager, appWidgetId)
        }
        refreshLockscreenTrigger(context)
    }
}

class WidgetToggleActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        @Suppress("DEPRECATION")
        window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
        )

        super.onCreate(savedInstanceState)

        val prefs = applicationContext.getSharedPreferences(
            EmergencyWidgetProvider.PREFS_NAME,
            Context.MODE_PRIVATE
        )
        val nextMode = !prefs.getBoolean(EmergencyWidgetProvider.KEY_IS_PUBLIC, false)

        prefs.edit()
            .putBoolean(EmergencyWidgetProvider.KEY_IS_PUBLIC, nextMode)
            .putBoolean(EmergencyWidgetProvider.KEY_DIRTY_FROM_WIDGET, true)
            .commit()

        EmergencyWidgetProvider.updateAllWidgets(applicationContext)
        MainActivity.notifyModeChangedFromWidget(nextMode)

        finish()
        overridePendingTransition(0, 0)
    }
}

class EmergencyTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        val prefs = getSharedPreferences(EmergencyWidgetProvider.PREFS_NAME, Context.MODE_PRIVATE)
        val isPublic = prefs.getBoolean(EmergencyWidgetProvider.KEY_IS_PUBLIC, false)
        qsTile?.apply {
            state = Tile.STATE_ACTIVE
            label = "Notfall-Kaskade"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                subtitle = if (isPublic) "🌍 Unterwegs" else "🏠 Zuhause"
            }
            updateTile()
        }
    }

    override fun onClick() {
        super.onClick()
        val intent = Intent(this, MainActivity::class.java).apply {
            action = "ACTION_START_EMERGENCY_CASCADE"
            putExtra("START_EMERGENCY", true)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        try {
            startActivity(intent)
        } catch (_: Exception) {}
    }
}