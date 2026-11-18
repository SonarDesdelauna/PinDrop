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
import android.media.MediaRecorder;
import android.net.Uri;
import android.os.Build;
import android.provider.ContactsContract;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
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

    // ───── Voice messages (AAC in .m4a, plays on iPhone too) ─────

    private static MediaRecorder recorder;
    private static File voiceFile;
    private static long voiceStart;
    private static final ArrayList<Integer> levels = new ArrayList<>();
    private static Thread meter;

    public static boolean hasMic(Context ctx) {
        return Build.VERSION.SDK_INT < 23 || ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED;
    }

    public static void requestMic(Context ctx) {
        if (hasMic(ctx) || !(ctx instanceof Activity)) return;
        final Activity activity = (Activity) ctx;
        activity.runOnUiThread(() -> activity.requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, 7304));
    }

    /** Starts recording; false when the microphone isn't allowed or busy. */
    public static synchronized boolean startRecording(Context ctx) {
        if (!hasMic(ctx)) return false;
        releaseRecorder();
        try {
            voiceFile = new File(ctx.getCacheDir(), "voice-" + System.currentTimeMillis() + ".m4a");
            MediaRecorder r = Build.VERSION.SDK_INT >= 31 ? new MediaRecorder(ctx) : new MediaRecorder();
            r.setAudioSource(MediaRecorder.AudioSource.MIC);
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);
            r.setAudioChannels(1);
            r.setAudioSamplingRate(22050);
            r.setAudioEncodingBitRate(32000);
            r.setMaxDuration(180000);
            r.setOutputFile(voiceFile.getAbsolutePath());
            r.prepare();
            r.start();
            recorder = r;
            voiceStart = System.currentTimeMillis();
            synchronized (levels) { levels.clear(); }
            final MediaRecorder watched = r;
            meter = new Thread(() -> {
                while (recorder == watched) {
                    try {
                        int amp = watched.getMaxAmplitude();
                        double db = amp > 0 ? 20 * Math.log10(amp / 32767.0) : -60;
                        int level = (int) Math.round(Math.max(0, Math.min(1, (db + 50) / 50)) * 9);
                        synchronized (levels) { levels.add(level); }
                        Thread.sleep(100);
                    } catch (Exception e) {
                        break;
                    }
                }
            });
            meter.start();
            return true;
        } catch (Exception e) {
            releaseRecorder();
            return false;
        }
    }

    /** The current level (0–9) and the elapsed time, for the recording bar. */
    public static String recordingLevel(Context ctx) {
        int last = 0;
        synchronized (levels) { if (!levels.isEmpty()) last = levels.get(levels.size() - 1); }
        long ms = recorder == null ? 0 : System.currentTimeMillis() - voiceStart;
        return "{\"level\":" + last + ",\"ms\":" + ms + ",\"recording\":" + (recorder != null) + "}";
    }

    /** Stops and returns { data (base64), durationMs, waveform }, or null if too short. */
    public static synchronized String stopRecording(Context ctx) {
        if (recorder == null) return null;
        long duration = System.currentTimeMillis() - voiceStart;
        MediaRecorder r = recorder;
        recorder = null;
        try { r.stop(); } catch (Exception e) { duration = 0; }
        r.release();
        File file = voiceFile;
        voiceFile = null;
        try {
            if (file == null || duration < 600) return null;
            duration = Math.min(duration, 180000);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            FileInputStream in = new FileInputStream(file);
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            in.close();
            StringBuilder wave = new StringBuilder();
            synchronized (levels) {
                int count = levels.size();
                int bars = Math.min(40, Math.max(1, count));
                for (int b = 0; b < bars; b++) {
                    int from = count * b / bars, to = Math.max(from + 1, count * (b + 1) / bars);
                    int max = 0;
                    for (int k = from; k < to && k < count; k++) max = Math.max(max, levels.get(k));
                    wave.append(max);
                }
            }
            JSONObject o = new JSONObject();
            o.put("data", android.util.Base64.encodeToString(out.toByteArray(), android.util.Base64.NO_WRAP));
            o.put("durationMs", duration);
            o.put("waveform", wave.toString());
            return o.toString();
        } catch (Exception e) {
            return null;
        } finally {
            if (file != null) file.delete();
        }
    }

    public static synchronized void cancelRecording(Context ctx) {
        releaseRecorder();
    }

    private static void releaseRecorder() {
        MediaRecorder r = recorder;
        recorder = null;
        if (r != null) {
            try { r.stop(); } catch (Exception ignored) { }
            r.release();
        }
        if (voiceFile != null) { voiceFile.delete(); voiceFile = null; }
    }
}
