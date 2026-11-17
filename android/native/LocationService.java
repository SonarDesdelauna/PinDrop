package com.pindrop.app;

import android.Manifest;
import android.app.Activity;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Looper;
import android.provider.Settings;

/**
 * "Always" location for PinDrop: a small foreground service (with its notification) that keeps
 * sending your position to your friends while the app is closed. The position is handed to the
 * Rust side, which already holds the signed-in session.
 */
public class LocationService extends Service implements LocationListener {
    private static final String CHANNEL = "pindrop_location";
    private static final long MIN_INTERVAL_MS = 60_000L;
    private static final float MIN_DISTANCE_M = 25f;
    private long lastSent = 0;

    /** Implemented in Rust (lib.rs). */
    public static native void nativeReport(double lat, double lon);

    // ───── Helpers called from Rust ─────

    public static boolean hasForeground(Context ctx) {
        return ctx.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
                || ctx.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    public static boolean hasBackground(Context ctx) {
        if (Build.VERSION.SDK_INT < 29) return hasForeground(ctx);
        return ctx.checkSelfPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    /** Asks for "Allow all the time". From Android 11 the system opens the location permission page. */
    public static void requestBackground(Context ctx) {
        if (Build.VERSION.SDK_INT >= 29 && ctx instanceof Activity) {
            try {
                ((Activity) ctx).requestPermissions(new String[]{Manifest.permission.ACCESS_BACKGROUND_LOCATION}, 7301);
                return;
            } catch (Throwable ignored) {
            }
        }
        openSettings(ctx);
    }

    /** The app's page in the system settings (Permissions → Location → Allow all the time). */
    public static void openSettings(Context ctx) {
        Intent intent = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", ctx.getPackageName(), null));
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        ctx.startActivity(intent);
    }

    public static void start(Context ctx) {
        if (!hasForeground(ctx)) return;
        Intent intent = new Intent(ctx, LocationService.class);
        if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(intent);
        else ctx.startService(intent);
    }

    public static void stop(Context ctx) {
        ctx.stopService(new Intent(ctx, LocationService.class));
    }

    // ───── Notifications for what friends do (called from Rust) ─────

    private static final String SOCIAL_CHANNEL = "pindrop_social";

    /** Asks for the notification permission (Android 13+). */
    public static void requestNotifications(Context ctx) {
        if (Build.VERSION.SDK_INT >= 33 && ctx instanceof Activity
                && ctx.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            try {
                ((Activity) ctx).requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 7302);
            } catch (Throwable ignored) {
            }
        }
    }

    /** Shows a message, pin, capsule or story notification. Tapping it opens the app. */
    public static void notify(Context ctx, int id, String title, String body) {
        try {
            if (Build.VERSION.SDK_INT >= 33
                    && ctx.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                return;
            }
            NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
            if (Build.VERSION.SDK_INT >= 26) {
                NotificationChannel channel = new NotificationChannel(SOCIAL_CHANNEL, "Amici e messaggi", NotificationManager.IMPORTANCE_HIGH);
                channel.setDescription("Messaggi, pin, capsule e storie dei tuoi amici");
                nm.createNotificationChannel(channel);
            }
            Intent open = ctx.getPackageManager().getLaunchIntentForPackage(ctx.getPackageName());
            if (open != null) open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
            PendingIntent tap = open == null ? null : PendingIntent.getActivity(ctx, id, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
            Notification.Builder builder = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(ctx, SOCIAL_CHANNEL) : new Notification.Builder(ctx);
            builder.setContentTitle(title)
                    .setContentText(body)
                    .setStyle(new Notification.BigTextStyle().bigText(body))
                    .setSmallIcon(ctx.getApplicationInfo().icon)
                    .setAutoCancel(true)
                    .setWhen(System.currentTimeMillis())
                    .setShowWhen(true);
            if (Build.VERSION.SDK_INT < 26) builder.setPriority(Notification.PRIORITY_HIGH).setDefaults(Notification.DEFAULT_ALL);
            if (tap != null) builder.setContentIntent(tap);
            nm.notify(id, builder.build());
        } catch (Throwable ignored) {
        }
    }

    // ───── Service ─────

    @Override
    public void onCreate() {
        super.onCreate();
        NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel channel = new NotificationChannel(CHANNEL, "Posizione condivisa", NotificationManager.IMPORTANCE_LOW);
            channel.setShowBadge(false);
            nm.createNotificationChannel(channel);
        }
        Intent open = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent tap = open == null ? null : PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification.Builder builder = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(this, CHANNEL) : new Notification.Builder(this);
        builder.setContentTitle("PinDrop")
                .setContentText("I tuoi amici vedono dove sei")
                .setSmallIcon(getApplicationInfo().icon)
                .setOngoing(true);
        if (tap != null) builder.setContentIntent(tap);
        Notification notification = builder.build();
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(7300, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION);
            else startForeground(7300, notification);
        } catch (Throwable e) {
            stopSelf();
            return;
        }
        LocationManager lm = (LocationManager) getSystemService(Context.LOCATION_SERVICE);
        try {
            for (String provider : new String[]{LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER}) {
                if (lm.isProviderEnabled(provider)) {
                    lm.requestLocationUpdates(provider, MIN_INTERVAL_MS, MIN_DISTANCE_M, this, Looper.getMainLooper());
                }
            }
        } catch (SecurityException e) {
            stopSelf();
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // Not sticky: the Rust side (and the session) live with the app process.
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        try {
            ((LocationManager) getSystemService(Context.LOCATION_SERVICE)).removeUpdates(this);
        } catch (Throwable ignored) {
        }
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onLocationChanged(Location location) {
        long now = System.currentTimeMillis();
        if (now - lastSent < MIN_INTERVAL_MS / 2) return;
        lastSent = now;
        try {
            nativeReport(location.getLatitude(), location.getLongitude());
        } catch (Throwable ignored) {
        }
    }

    @Override
    public void onStatusChanged(String provider, int status, Bundle extras) {
    }

    @Override
    public void onProviderEnabled(String provider) {
    }

    @Override
    public void onProviderDisabled(String provider) {
    }
}
