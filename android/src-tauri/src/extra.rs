//! What iOS has and Android was missing: a generic call to the database (protected by Row
//! Level Security, with your own session), the profile photo, the address book, sharing,
//! texting a friend and the home screen widget.

use super::{finish, AppData, Res, B64};
use base64::Engine;
use reqwest::Method;
use serde_json::{json, Value};
use tauri::State;

/// A PostgREST call (`/rest/v1/...`) with your session: tables and RPC functions.
#[tauri::command]
pub async fn api(
    state: State<'_, AppData>,
    method: String,
    path: String,
    query: Option<Vec<(String, String)>>,
    body: Option<Value>,
    prefer: Option<String>,
) -> Res<Value> {
    if !path.starts_with("/rest/v1/") || path.contains("..") {
        return Err("invalid path".into());
    }
    let method = match method.to_uppercase().as_str() {
        "GET" => Method::GET,
        "POST" => Method::POST,
        "PATCH" => Method::PATCH,
        "DELETE" => Method::DELETE,
        _ => return Err("invalid method".into()),
    };
    let query: Vec<(String, String)> = query.unwrap_or_default();
    let pairs: Vec<(&str, String)> = query.iter().map(|(k, v)| (k.as_str(), v.clone())).collect();
    state.rest(method, &path, &pairs, body, prefer.as_deref()).await
}

/// Uploads a new profile photo (JPEG, base64) to avatars/{me}/avatar-{time}.jpg.
#[tauri::command]
pub async fn upload_avatar(state: State<'_, AppData>, data: String) -> Res<String> {
    let session = state.token().await?;
    let uid = session.user_id.to_lowercase();
    let path = format!("{uid}/avatar-{}.jpg", chrono::Utc::now().timestamp());
    let bytes = B64.decode(data).map_err(|e| e.to_string())?;
    state.upload_as(&session, "avatars", &path, bytes, "image/jpeg").await?;
    Ok(path)
}

#[tauri::command]
pub async fn delete_avatar(state: State<'_, AppData>, path: String) -> Res<()> {
    let session = state.token().await?;
    if !path.starts_with(&session.user_id.to_lowercase()) {
        return Ok(());
    }
    let request = state.authed(Method::DELETE, &format!("/storage/v1/object/avatars/{path}"), &session);
    finish(request).await.map(|_| ())
}

// ───── Native (contacts, share, SMS, widget) ─────

#[cfg(target_os = "android")]
mod native {
    use jni::objects::{JClass, JObject, JString, JValue};

    /// Calls `PinDropNative.<name>(Context, String...)`; returns the String result, if any.
    pub fn call(name: &str, args: &[&str], returns_string: bool, returns_bool: bool) -> Result<Option<String>, String> {
        let ctx = ndk_context::android_context();
        let vm = unsafe { jni::JavaVM::from_raw(ctx.vm().cast()) }.map_err(|e| e.to_string())?;
        let mut env = vm.attach_current_thread().map_err(|e| e.to_string())?;
        let context = unsafe { JObject::from_raw(ctx.context().cast()) };
        let mut sig = String::from("(Landroid/content/Context;");
        for _ in args {
            sig.push_str("Ljava/lang/String;");
        }
        sig.push(')');
        sig.push_str(if returns_string { "Ljava/lang/String;" } else if returns_bool { "Z" } else { "V" });
        let result = (|| -> jni::errors::Result<Option<String>> {
            let loader = env.call_method(&context, "getClassLoader", "()Ljava/lang/ClassLoader;", &[])?.l()?;
            let class_name = env.new_string("com.pindrop.app.PinDropNative")?;
            let class = env
                .call_method(&loader, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;", &[JValue::Object(&class_name)])?
                .l()?;
            let class = JClass::from(class);
            let mut strings = Vec::new();
            for a in args {
                strings.push(env.new_string(a)?);
            }
            let mut values: Vec<JValue> = vec![JValue::Object(&context)];
            for s in &strings {
                values.push(JValue::Object(s));
            }
            let value = env.call_static_method(&class, name, &sig, &values)?;
            if returns_string {
                let obj = value.l()?;
                if obj.is_null() {
                    return Ok(None);
                }
                let text: String = env.get_string(&JString::from(obj))?.into();
                Ok(Some(text))
            } else if returns_bool {
                Ok(Some(if value.z()? { "1".into() } else { "0".into() }))
            } else {
                Ok(None)
            }
        })();
        if env.exception_check().unwrap_or(false) {
            let _ = env.exception_clear();
        }
        result.map_err(|e| e.to_string())
    }
}

#[cfg(target_os = "android")]
fn call(name: &str, args: &[&str], returns_string: bool, returns_bool: bool) -> Res<Option<String>> {
    native::call(name, args, returns_string, returns_bool)
}

#[cfg(not(target_os = "android"))]
fn call(_name: &str, _args: &[&str], _returns_string: bool, _returns_bool: bool) -> Res<Option<String>> {
    Ok(None)
}

/// true when PinDrop can read the address book.
#[tauri::command]
pub fn contacts_status() -> bool {
    matches!(call("hasContacts", &[], false, true), Ok(Some(v)) if v == "1")
}

#[tauri::command]
pub fn request_contacts() -> Res<()> {
    call("requestContacts", &[], false, false).map(|_| ())
}

/// [{ id, name, phones: [], emails: [] }] (read on the phone, never uploaded in clear).
#[tauri::command]
pub fn read_contacts() -> Res<Value> {
    let text = call("readContacts", &[], true, false)?.unwrap_or_else(|| "[]".into());
    serde_json::from_str(&text).map_err(|e| e.to_string())
}

/// The Android share sheet with a text.
#[tauri::command]
pub fn share_text(text: String) -> Res<()> {
    call("shareText", &[&text], false, false).map(|_| ())
}

/// Opens the SMS app with the number (may be empty) and the text.
#[tauri::command]
pub fn send_sms(number: String, body: String) -> Res<()> {
    call("sendSms", &[&number, &body], false, false).map(|_| ())
}

/// Updates the home screen widget: { title, subtitle, caption, status, image (base64 JPEG) }.
#[tauri::command]
pub fn update_widget(data: Value) -> Res<()> {
    let text = json!(data).to_string();
    call("updateWidget", &[&text], false, false).map(|_| ())
}

// ───── Voice messages ─────

#[tauri::command]
pub fn mic_status() -> bool {
    matches!(call("hasMic", &[], false, true), Ok(Some(v)) if v == "1")
}

#[tauri::command]
pub fn request_mic() -> Res<()> {
    call("requestMic", &[], false, false).map(|_| ())
}

#[tauri::command]
pub fn start_voice() -> bool {
    matches!(call("startRecording", &[], false, true), Ok(Some(v)) if v == "1")
}

/// { level 0–9, ms, recording }
#[tauri::command]
pub fn voice_level() -> Value {
    call("recordingLevel", &[], true, false)
        .ok()
        .flatten()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or(Value::Null)
}

/// { data (base64 m4a), durationMs, waveform } or null when it was too short.
#[tauri::command]
pub fn stop_voice() -> Value {
    call("stopRecording", &[], true, false)
        .ok()
        .flatten()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or(Value::Null)
}

#[tauri::command]
pub fn cancel_voice() {
    let _ = call("cancelRecording", &[], false, false);
}

/// Deletes one of my messages for everyone, with its photo or voice file.
#[tauri::command]
pub async fn delete_chat_message(state: State<'_, AppData>, id: String, path: Option<String>) -> Res<()> {
    let session = state.token().await?;
    state
        .rest(
            Method::DELETE,
            "/rest/v1/chat_messages",
            &[("id", format!("eq.{id}")), ("sender_id", format!("eq.{}", session.user_id))],
            None,
            None,
        )
        .await?;
    if let Some(path) = path.filter(|p| !p.is_empty() && !p.contains("..")) {
        let request = state.authed(Method::DELETE, &format!("/storage/v1/object/chat/{path}"), &session);
        let _ = finish(request).await;
    }
    Ok(())
}
