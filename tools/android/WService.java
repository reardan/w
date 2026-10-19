package org.wlang.androiddemo;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

/**
 * Optional foreground service started by wandroid_background(text) so a W app
 * can keep following remote work (timers and HTTP on the UI thread) while it is
 * in the background, instead of being cached and frozen. It shows one ongoing,
 * low-importance notification and does no work itself. Declared only by
 * android_build --notifications (dataSync type); Android 15 limits that type to six
 * hours a day, after which onTimeout stops it.
 */
public final class WService extends Service {
    static final String EXTRA_TEXT = "w_text", CHANNEL = "w_background";
    private static final int ID = 0x5753;

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        String text = intent == null ? null : intent.getStringExtra(EXTRA_TEXT);
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel(CHANNEL, "Background work", NotificationManager.IMPORTANCE_LOW));
        Notification notification = new Notification.Builder(this, CHANNEL)
            .setSmallIcon(WKit.notificationIcon(this))
            .setContentTitle(getApplicationInfo().loadLabel(getPackageManager()))
            .setContentText(text == null ? "" : text)
            .setOngoing(true)
            .setContentIntent(WKit.openApp(this, -1))
            .build();
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
            else startForeground(ID, notification);
        } catch (RuntimeException failure) {
            Log.w("WAndroid", "foreground service refused: " + failure);
            stopSelf();
        }
        return START_NOT_STICKY;
    }

    @Override public void onTimeout(int startId, int type) { stopSelf(); }
}
