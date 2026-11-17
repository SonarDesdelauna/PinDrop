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
