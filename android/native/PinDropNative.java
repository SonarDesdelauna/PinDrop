package com.pindrop.app;

import android.Manifest;
import android.app.Activity;
import android.appwidget.AppWidgetManager;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.provider.ContactsContract;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Small native helpers for the PinDrop web UI, called from Rust through JNI: the address book
 * (read on the phone, only hashes leave it), the share sheet, SMS and the home screen widget.
 */
public class PinDropNative {
    static final String PREFS = "pindrop_widget";

    public static boolean hasContacts(Context ctx) {
        return Build.VERSION.SDK_INT < 23 || ctx.checkSelfPermission(Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED;
    }

    public static void requestContacts(Context ctx) {
        if (hasContacts(ctx) || !(ctx instanceof Activity)) return;
        final Activity activity = (Activity) ctx;
        activity.runOnUiThread(() -> activity.requestPermissions(new String[]{Manifest.permission.READ_CONTACTS}, 7303));
    }

    /** [{ id, name, phones: [], emails: [] }] */
    public static String readContacts(Context ctx) {
        JSONArray out = new JSONArray();
        if (!hasContacts(ctx)) return out.toString();
        Map<String, JSONObject> byId = new LinkedHashMap<>();
        try {
            Cursor c = ctx.getContentResolver().query(
                    ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                    new String[]{ContactsContract.CommonDataKinds.Phone.CONTACT_ID, ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME, ContactsContract.CommonDataKinds.Phone.NUMBER},
                    null, null, ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME + " ASC");
            if (c != null) {
                while (c.moveToNext()) {
                    JSONObject contact = contact(byId, c.getString(0), c.getString(1));
                    String number = c.getString(2);
                    if (number != null) contact.getJSONArray("phones").put(number);
                }
                c.close();
            }
            Cursor e = ctx.getContentResolver().query(
                    ContactsContract.CommonDataKinds.Email.CONTENT_URI,
                    new String[]{ContactsContract.CommonDataKinds.Email.CONTACT_ID, ContactsContract.CommonDataKinds.Email.DISPLAY_NAME, ContactsContract.CommonDataKinds.Email.ADDRESS},
                    null, null, null);
            if (e != null) {
                while (e.moveToNext()) {
                    JSONObject contact = contact(byId, e.getString(0), e.getString(1));
                    String address = e.getString(2);
                    if (address != null) contact.getJSONArray("emails").put(address);
                }
                e.close();
            }
            for (JSONObject contact : byId.values()) out.put(contact);
        } catch (Exception ignored) {
        }
        return out.toString();
    }

    private static JSONObject contact(Map<String, JSONObject> byId, String id, String name) throws Exception {
        JSONObject contact = byId.get(id);
        if (contact == null) {
            contact = new JSONObject();
            contact.put("id", id == null ? "" : id);
            contact.put("name", name == null ? "" : name);
            contact.put("phones", new JSONArray());
            contact.put("emails", new JSONArray());
            byId.put(id, contact);
        }
        return contact;
    }

    public static void shareText(Context ctx, String text) {
        Intent send = new Intent(Intent.ACTION_SEND);
        send.setType("text/plain");
        send.putExtra(Intent.EXTRA_TEXT, text);
        Intent chooser = Intent.createChooser(send, "PinDrop");
        chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        ctx.startActivity(chooser);
    }

    public static void sendSms(Context ctx, String number, String body) {
        Intent sms = new Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:" + (number == null ? "" : Uri.encode(number))));
        sms.putExtra("sms_body", body);
        sms.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            ctx.startActivity(sms);
        } catch (Exception e) {
            shareText(ctx, body);
        }
    }

    /** Saves what the widget shows and redraws it. */
    public static void updateWidget(Context ctx, String json) {
        SharedPreferences prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        prefs.edit().putString("data", json).apply();
        AppWidgetManager manager = AppWidgetManager.getInstance(ctx);
        int[] ids = manager.getAppWidgetIds(new ComponentName(ctx, PinDropWidget.class));
        if (ids != null && ids.length > 0) PinDropWidget.render(ctx, manager, ids);
    }
}
