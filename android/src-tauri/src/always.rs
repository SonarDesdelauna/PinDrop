//! "Always" location on Android: asks for "Allow all the time" and runs `LocationService`
//! (android/native/LocationService.java), which reports your position while the app is closed.

use super::{AppData, Res};
use serde_json::{json, Value};
use std::sync::OnceLock;
use tauri::{AppHandle, Manager};

static APP: OnceLock<AppHandle> = OnceLock::new();

pub fn remember(app: &AppHandle) {
    let _ = APP.set(app.clone());
}

/// Sends a position on behalf of the background service.
async fn report(app: AppHandle, lat: f64, lon: f64) {
    let state = app.state::<AppData>();
    if state.session.lock().unwrap().is_none() {
        return;
    }
    let _ = state
        .rpc("report_location", json!({ "lat": lat, "lon": lon, "perm": "always" }))
        .await;
}

#[cfg(target_os = "android")]
mod native {
    use jni::objects::{JClass, JObject, JValue};
    use jni::sys::jdouble;
    use jni::JNIEnv;

    /// Called by `LocationService.nativeReport` on every new position.
    #[no_mangle]
    pub extern "system" fn Java_com_pindrop_app_LocationService_nativeReport(_env: JNIEnv, _class: JClass, lat: jdouble, lon: jdouble) {
        if let Some(app) = super::APP.get() {
            let app = app.clone();
            tauri::async_runtime::spawn(super::report(app, lat, lon));
        }
    }

    /// Calls a static `LocationService.<name>(Context)` method.
    pub fn call(name: &str, sig: &str) -> Result<Option<bool>, String> {
        let ctx = ndk_context::android_context();
        let vm = unsafe { jni::JavaVM::from_raw(ctx.vm().cast()) }.map_err(|e| e.to_string())?;
        let mut env = vm.attach_current_thread().map_err(|e| e.to_string())?;
        let context = unsafe { JObject::from_raw(ctx.context().cast()) };
        let result = (|| -> jni::errors::Result<Option<bool>> {
            // App classes are only visible through the app's class loader on this thread.
            let loader = env.call_method(&context, "getClassLoader", "()Ljava/lang/ClassLoader;", &[])?.l()?;
            let class_name = env.new_string("com.pindrop.app.LocationService")?;
            let class = env
                .call_method(&loader, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;", &[JValue::Object(&class_name)])?
                .l()?;
            let class = JClass::from(class);
            let value = env.call_static_method(&class, name, sig, &[JValue::Object(&context)])?;
            Ok(if sig.ends_with('Z') { Some(value.z()?) } else { None })
        })();
        if env.exception_check().unwrap_or(false) {
            let _ = env.exception_clear();
        }
        result.map_err(|e| e.to_string())
    }

    /// Calls `LocationService.notify(Context, int, String, String)`.
    pub fn notify(id: i32, title: &str, body: &str) -> Result<(), String> {
        let ctx = ndk_context::android_context();
        let vm = unsafe { jni::JavaVM::from_raw(ctx.vm().cast()) }.map_err(|e| e.to_string())?;
        let mut env = vm.attach_current_thread().map_err(|e| e.to_string())?;
        let context = unsafe { JObject::from_raw(ctx.context().cast()) };
        let result = (|| -> jni::errors::Result<()> {
            let loader = env.call_method(&context, "getClassLoader", "()Ljava/lang/ClassLoader;", &[])?.l()?;
            let class_name = env.new_string("com.pindrop.app.LocationService")?;
            let class = env
                .call_method(&loader, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;", &[JValue::Object(&class_name)])?
                .l()?;
            let class = JClass::from(class);
            let title = env.new_string(title)?;
            let body = env.new_string(body)?;
            env.call_static_method(
                &class,
                "notify",
                "(Landroid/content/Context;ILjava/lang/String;Ljava/lang/String;)V",
                &[JValue::Object(&context), JValue::Int(id), JValue::Object(&title), JValue::Object(&body)],
            )?;
            Ok(())
        })();
        if env.exception_check().unwrap_or(false) {
            let _ = env.exception_clear();
        }
        result.map_err(|e| e.to_string())
    }
}

// ───── Notifications for what friends do ─────

/// Polls `pending_push` while the process is alive (the app is open, or kept alive by the
/// background location service) and shows each new event as a system notification.
pub fn start_push(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || loop {
        tauri::async_runtime::block_on(check_push(&app));
        std::thread::sleep(std::time::Duration::from_secs(20));
    });
}

fn cursor_path(app: &AppHandle, uid: &str) -> Option<std::path::PathBuf> {
    app.path().app_data_dir().ok().map(|dir| dir.join(format!("push_cursor_{uid}.txt")))
}

async fn check_push(app: &AppHandle) {
    let state = app.state::<AppData>();
    let Some(uid) = state.session.lock().unwrap().as_ref().map(|s| s.user_id.clone()) else {
        return;
    };
    let Some(path) = cursor_path(app, &uid) else { return };
    let stored: Option<i64> = std::fs::read_to_string(&path).ok().and_then(|t| t.trim().parse().ok());
    let Ok(rows) = state.rpc("pending_push", json!({ "after": stored })).await else {
        return;
    };
    let rows = rows.as_array().cloned().unwrap_or_default();
    let Some(cursor) = stored else {
        // First run: start from now without replaying old events.
        let latest = rows.iter().find(|r| r["kind"] == "cursor").and_then(|r| r["id"].as_i64()).unwrap_or(0);
        let _ = std::fs::write(&path, latest.to_string());
        return;
    };
    let fresh: Vec<&Value> = rows.iter().filter(|r| r["kind"] != "cursor").collect();
    let Some(last) = fresh.last().and_then(|r| r["id"].as_i64()) else { return };
    if last <= cursor {
        return;
    }
    let _ = std::fs::write(&path, last.to_string());
    for row in fresh {
        if let Some((title, body)) = push_text(row) {
            let id = (row["id"].as_i64().unwrap_or(0) % 1_000_000) as i32 + 1000;
            show_notification(id, &title, &body);
        }
    }
}

fn push_text(row: &Value) -> Option<(String, String)> {
    let s = |key: &str| row[key].as_str().unwrap_or("").trim().to_string();
    let name = { let n = s("actor_name"); if n.is_empty() { "Qualcuno".to_string() } else { n } };
    let detail = s("detail");
    let sub = s("sub");
    let with_place = |body: &str| if detail.is_empty() { body.to_string() } else { format!("{body} · 📍 {detail}") };
    Some(match s("kind").as_str() {
        "message" => {
            let content = match sub.as_str() {
                "photo" => "📷 Foto".to_string(),
                "location" => "📍 Ha condiviso la posizione".to_string(),
                "pin_reply" => if detail.is_empty() { "Ha risposto al tuo pin".to_string() } else { format!("Ha risposto al tuo pin: {detail}") },
                "story_reply" => if detail.is_empty() { "Ha risposto alla tua storia".to_string() } else { format!("Ha risposto alla tua storia: {detail}") },
                _ => detail.clone(),
            };
            let title = s("thread_title");
            if s("thread_kind") == "direct" || title.is_empty() {
                (name, content)
            } else {
                (format!("{} {}", s("thread_emoji"), title).trim().to_string(), format!("{name}: {content}"))
            }
        }
        "pin" => (format!("{name} ha pubblicato un pin"), with_place(if sub == "video" { "🎬 Nuovo video sulla mappa" } else { "Nuova foto sulla mappa" })),
        "capsule" if sub == "for_you" => (format!("{name} ti ha lasciato una capsula 🎁"), "Raggiungila per aprirla".to_string()),
        "capsule" => (format!("Nuova capsula di {name}"), "Trovala sulla mappa".to_string()),
        "story" => (format!("{name} ha pubblicato una storia"), with_place(if sub == "video" { "🎬 Storia video · tocca per guardarla" } else { "Tocca per guardarla" })),
        "friend_request" => ("Nuova richiesta di amicizia".to_string(), format!("{name} vuole essere tuo amico")),
        "friend_accepted" => ("Ora siete amici 🎉".to_string(), format!("{name} ha accettato la tua richiesta")),
        "ping" => (name, "👋 Ti ha mandato un ping".to_string()),
        "place_reached" => (format!("Sei a {detail}"), format!("Un luogo pubblico di {name}: aggiungilo ai tuoi luoghi")),
        "relay_baton" => (format!("🏃 {name} ti ha passato il testimone"), format!("{detail} · hai 24 ore per correre la tua tappa")),
        "relay_leg" => (format!("{name} ha corso una tappa"), if sub.is_empty() { detail.clone() } else { format!("{detail} · 📍 {sub}") }),
        "relay_reminder" => ("⏰ Ultime 3 ore per la staffetta".to_string(), format!("{detail}: corri la tua tappa o la catena si spezza")),
        "relay_broken" => ("💥 Staffetta spezzata".to_string(), format!("{name} ha fatto cadere {detail}")),
        "relay_finished" => ("🏁 Staffetta arrivata!".to_string(), format!("{name} ha tagliato il traguardo di {detail} dopo {sub} tappe")),
        "best_friend" => ("Nuovo migliore amico 💜".to_string(), format!("Tu e {name} avete passato 2 ore insieme")),
        _ => return None,
    })
}

#[cfg(target_os = "android")]
fn show_notification(id: i32, title: &str, body: &str) {
    let _ = native::notify(id, title, body);
}

#[cfg(not(target_os = "android"))]
fn show_notification(_id: i32, _title: &str, _body: &str) {}

/// Asks for the notification permission (Android 13+).
#[tauri::command]
pub fn enable_notifications() -> Res<()> {
    #[cfg(target_os = "android")]
    native::call("requestNotifications", "(Landroid/content/Context;)V")?;
    Ok(())
}

#[cfg(target_os = "android")]
fn status() -> Value {
    let foreground = native::call("hasForeground", "(Landroid/content/Context;)Z").ok().flatten().unwrap_or(false);
    let background = native::call("hasBackground", "(Landroid/content/Context;)Z").ok().flatten().unwrap_or(false);
    json!({ "supported": true, "foreground": foreground, "background": background })
}

#[cfg(not(target_os = "android"))]
fn status() -> Value {
    json!({ "supported": false, "foreground": false, "background": false })
}

/// { supported, foreground, background }
#[tauri::command]
pub fn always_location_status() -> Value {
    status()
}

/// Shows "Allow all the time" (Android 11+: the location permission page of the app).
#[tauri::command]
pub fn request_always_location() -> Res<()> {
    #[cfg(target_os = "android")]
    native::call("requestBackground", "(Landroid/content/Context;)V")?;
    Ok(())
}

#[tauri::command]
pub fn open_app_settings() -> Res<()> {
    #[cfg(target_os = "android")]
    native::call("openSettings", "(Landroid/content/Context;)V")?;
    Ok(())
}

/// Starts or stops the background service.
#[tauri::command]
pub fn set_always_location(on: bool) -> Res<()> {
    #[cfg(target_os = "android")]
    native::call(if on { "start" } else { "stop" }, "(Landroid/content/Context;)V")?;
    let _ = on;
    Ok(())
}
