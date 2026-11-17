package com.pindrop.app;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.util.Base64;
import android.view.View;
import android.widget.RemoteViews;

import org.json.JSONObject;

/** Home screen widget: the newest drop of your friends (blurred until you post yours). */
public class PinDropWidget extends AppWidgetProvider {
    @Override
    public void onUpdate(Context ctx, AppWidgetManager manager, int[] ids) {
        render(ctx, manager, ids);
    }

    private static int id(Context ctx, String name, String type) {
        return ctx.getResources().getIdentifier(name, type, ctx.getPackageName());
    }

    static void render(Context ctx, AppWidgetManager manager, int[] ids) {
        String raw = ctx.getSharedPreferences(PinDropNative.PREFS, Context.MODE_PRIVATE).getString("data", null);
        JSONObject data;
        try {
            data = raw == null ? new JSONObject() : new JSONObject(raw);
        } catch (Exception e) {
            data = new JSONObject();
        }
        RemoteViews views = new RemoteViews(ctx.getPackageName(), id(ctx, "pindrop_widget", "layout"));
        String title = data.optString("title", "");
        boolean empty = title.isEmpty();
        views.setTextViewText(id(ctx, "widget_title", "id"), empty ? "PinDrop" : title);
        views.setTextViewText(id(ctx, "widget_subtitle", "id"), empty ? "Apri PinDrop per vedere i drop degli amici" : data.optString("subtitle", ""));
        String caption = data.optString("caption", "");
        views.setTextViewText(id(ctx, "widget_caption", "id"), caption);
        views.setViewVisibility(id(ctx, "widget_caption", "id"), caption.isEmpty() ? View.GONE : View.VISIBLE);
        String status = data.optString("status", "");
        views.setTextViewText(id(ctx, "widget_status", "id"), status);
        views.setViewVisibility(id(ctx, "widget_status", "id"), status.isEmpty() ? View.GONE : View.VISIBLE);
        int photo = id(ctx, "widget_photo", "id");
        Bitmap bitmap = null;
        try {
            String image = data.optString("image", "");
            if (!image.isEmpty()) {
                byte[] bytes = Base64.decode(image, Base64.DEFAULT);
                bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
            }
        } catch (Exception ignored) {
        }
        if (bitmap != null) {
            views.setImageViewBitmap(photo, bitmap);
            views.setViewVisibility(photo, View.VISIBLE);
        } else {
            views.setViewVisibility(photo, View.GONE);
        }
        Intent open = ctx.getPackageManager().getLaunchIntentForPackage(ctx.getPackageName());
        if (open != null) {
            PendingIntent tap = PendingIntent.getActivity(ctx, 41, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
            views.setOnClickPendingIntent(id(ctx, "widget_root", "id"), tap);
        }
        for (int widget : ids) manager.updateAppWidget(widget, views);
    }
}
