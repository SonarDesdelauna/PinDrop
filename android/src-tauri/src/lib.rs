//! PinDrop for Android: all networking (Supabase auth, database, storage) lives in Rust.
//! The web UI only renders and calls these commands.

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use reqwest::{Client, Method, RequestBuilder};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::{
    fs,
    path::PathBuf,
    sync::Mutex,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tauri::{Manager, State};

mod always;
mod extra;
mod features;
mod relays;
mod social;

const SUPABASE_URL: &str = "https://tqtpkdxeedcjmlhabimg.supabase.co";
/// Public (publishable) client key, same as the iOS app. Row Level Security protects the data.
const SUPABASE_KEY: &str = "sb_publishable_jfZKfM7CgDgII_FZCmv5Tw_XLxNpTco";
const PIN_SELECT: &str = "id,latitude,longitude,place_name,caption,image_path,thumb_path,blur_path,video_path,created_at,expires_at,sync_session_id,author:profiles!pins_author_id_fkey(*),reactions(user_id,emoji,created_at)";
const CAPSULE_SELECT: &str = "id,latitude,longitude,hint,image_path,thumb_path,video_path,created_at,expires_at,recipient_id,author:profiles!geo_capsules_author_id_fkey(*)";
const FRIEND_SELECT: &str = "id,requester_id,addressee_id,status,created_at,requester:profiles!friendships_requester_id_fkey(*),addressee:profiles!friendships_addressee_id_fkey(*)";

type Res<T> = Result<T, String>;

#[derive(Clone, Serialize, Deserialize)]
struct Session {
    access_token: String,
    refresh_token: String,
    user_id: String,
    expires_at: u64,
}

struct AppData {
    http: Client,
    session: Mutex<Option<Session>>,
    file: Mutex<Option<PathBuf>>,
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn now_iso() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

fn net(error: reqwest::Error) -> String {
    if error.is_timeout() || error.is_connect() {
        "offline".to_string()
    } else {
        error.to_string()
    }
}

/// Extracts a readable message from a Supabase error body.
fn error_message(body: &str) -> String {
    if let Ok(value) = serde_json::from_str::<Value>(body) {
        for key in ["error_description", "msg", "message", "error"] {
            if let Some(text) = value.get(key).and_then(Value::as_str) {
                return text.to_string();
            }
        }
    }
    if body.trim().is_empty() {
        "error".to_string()
    } else {
        body.to_string()
    }
}

async fn finish(request: RequestBuilder) -> Res<Value> {
    let response = request.send().await.map_err(net)?;
    let status = response.status();
    let body = response.text().await.map_err(net)?;
    if !status.is_success() {
        return Err(error_message(&body));
    }
    if body.trim().is_empty() {
        return Ok(Value::Null);
    }
    serde_json::from_str(&body).map_err(|e| e.to_string())
}

impl AppData {
    fn save(&self) {
        let Some(path) = self.file.lock().unwrap().clone() else { return };
        match self.session.lock().unwrap().as_ref() {
            Some(session) => {
                if let Ok(text) = serde_json::to_string(session) {
                    let _ = fs::write(path, text);
                }
            }
            None => {
                let _ = fs::remove_file(path);
            }
        }
    }

    fn clear(&self) {
        *self.session.lock().unwrap() = None;
        self.save();
    }

    /// Stores the session from an auth response.
    fn store(&self, value: &Value) -> Res<Session> {
        let access_token = value["access_token"].as_str().ok_or("missing token")?.to_string();
        let refresh_token = value["refresh_token"].as_str().ok_or("missing token")?.to_string();
        let user_id = value["user"]["id"].as_str().ok_or("missing user")?.to_string();
        let expires_at = value["expires_at"]
            .as_u64()
            .unwrap_or_else(|| now_secs() + value["expires_in"].as_u64().unwrap_or(3600));
        let session = Session { access_token, refresh_token, user_id, expires_at };
        *self.session.lock().unwrap() = Some(session.clone());
        self.save();
        Ok(session)
    }

    async fn refresh(&self, refresh_token: &str) -> Res<Session> {
        let response = self
            .http
            .post(format!("{SUPABASE_URL}/auth/v1/token?grant_type=refresh_token"))
            .header("apikey", SUPABASE_KEY)
            .json(&json!({ "refresh_token": refresh_token }))
            .send()
            .await
            .map_err(net)?;
        let status = response.status();
        let body = response.text().await.map_err(net)?;
        if !status.is_success() {
            if status.is_client_error() {
                self.clear();
                return Err("not_signed_in".to_string());
            }
            return Err(error_message(&body));
        }
        let value: Value = serde_json::from_str(&body).map_err(|e| e.to_string())?;
        self.store(&value)
    }

    /// A valid session, refreshed when close to expiry.
    async fn token(&self) -> Res<Session> {
        let session = self.session.lock().unwrap().clone().ok_or("not_signed_in")?;
        if session.expires_at > now_secs() + 60 {
            return Ok(session);
        }
        self.refresh(&session.refresh_token).await
    }

    fn authed(&self, method: Method, path: &str, session: &Session) -> RequestBuilder {
        self.http
            .request(method, format!("{SUPABASE_URL}{path}"))
            .header("apikey", SUPABASE_KEY)
            .bearer_auth(&session.access_token)
    }

    async fn rest(
        &self,
        method: Method,
        path: &str,
        query: &[(&str, String)],
        body: Option<Value>,
        prefer: Option<&str>,
    ) -> Res<Value> {
        let session = self.token().await?;
        let mut request = self.authed(method, path, &session).query(query);
        if let Some(prefer) = prefer {
            request = request.header("Prefer", prefer);
        }
        if let Some(body) = body {
            request = request.json(&body);
        }
        finish(request).await
    }

    async fn rpc(&self, name: &str, args: Value) -> Res<Value> {
        self.rest(Method::POST, &format!("/rest/v1/rpc/{name}"), &[], Some(args), None).await
    }

    async fn upload(&self, session: &Session, bucket: &str, path: &str, bytes: Vec<u8>) -> Res<()> {
        self.upload_as(session, bucket, path, bytes, "image/jpeg").await
    }

    /// Uploads a file with its type (image/jpeg or video/mp4).
    async fn upload_as(&self, session: &Session, bucket: &str, path: &str, bytes: Vec<u8>, content_type: &str) -> Res<()> {
        let request = self
            .authed(Method::POST, &format!("/storage/v1/object/{bucket}/{path}"), session)
            .header("Content-Type", content_type)
            .header("cache-control", "max-age=21600")
            .header("x-upsert", "false")
            .body(bytes);
        finish(request).await.map(|_| ())
    }
}

fn first(value: Value) -> Value {
    match value {
        Value::Array(mut items) if !items.is_empty() => items.swap_remove(0),
        other => other,
    }
}

// ───────────── Auth ─────────────

#[tauri::command]
async fn restore_session(state: State<'_, AppData>) -> Res<Option<String>> {
    let Some(session) = state.session.lock().unwrap().clone() else { return Ok(None) };
    match state.token().await {
        Ok(fresh) => Ok(Some(fresh.user_id)),
        Err(error) if error == "not_signed_in" => Ok(None),
        // Offline: keep the stored session, it will refresh later.
        Err(_) => Ok(Some(session.user_id)),
    }
}

#[tauri::command]
async fn sign_in(state: State<'_, AppData>, email: String, password: String) -> Res<String> {
    let request = state
        .http
        .post(format!("{SUPABASE_URL}/auth/v1/token?grant_type=password"))
        .header("apikey", SUPABASE_KEY)
        .json(&json!({ "email": email.trim(), "password": password }));
    let value = finish(request).await?;
    Ok(state.store(&value)?.user_id)
}

/// Returns true when signed in right away, false when the email must be confirmed first.
#[tauri::command]
async fn sign_up(state: State<'_, AppData>, email: String, password: String) -> Res<bool> {
    let request = state
        .http
        .post(format!("{SUPABASE_URL}/auth/v1/signup"))
        .header("apikey", SUPABASE_KEY)
        .json(&json!({ "email": email.trim(), "password": password }));
    let value = finish(request).await?;
    if value.get("access_token").and_then(Value::as_str).is_some() {
        state.store(&value)?;
        Ok(true)
    } else {
        Ok(false)
    }
}

#[tauri::command]
async fn reset_password(state: State<'_, AppData>, email: String) -> Res<()> {
    let request = state
        .http
        .post(format!("{SUPABASE_URL}/auth/v1/recover"))
        .header("apikey", SUPABASE_KEY)
        .json(&json!({ "email": email.trim() }));
    finish(request).await.map(|_| ())
}

#[tauri::command]
async fn sign_out(state: State<'_, AppData>) -> Res<()> {
    if let Ok(session) = state.token().await {
        let _ = state.rpc("go_offline", json!({})).await;
        let _ = finish(state.authed(Method::POST, "/auth/v1/logout", &session)).await;
    }
    state.clear();
    Ok(())
}

// ───────────── Profile & friends ─────────────

#[tauri::command]
async fn my_profile(state: State<'_, AppData>) -> Res<Value> {
    let uid = state.token().await?.user_id;
    let rows = state
        .rest(Method::GET, "/rest/v1/profiles", &[("select", "*".into()), ("id", format!("eq.{uid}"))], None, None)
        .await?;
    Ok(first(rows))
}

#[tauri::command]
async fn update_profile(state: State<'_, AppData>, display_name: String, username: String) -> Res<Value> {
    let uid = state.token().await?.user_id;
    let body = json!({
        "display_name": display_name.trim(),
        "username": username.trim().to_lowercase(),
        "is_setup": true
    });
    let rows = state
        .rest(
            Method::PATCH,
            "/rest/v1/profiles",
            &[("select", "*".into()), ("id", format!("eq.{uid}"))],
            Some(body),
            Some("return=representation"),
        )
        .await?;
    Ok(first(rows))
}

#[tauri::command]
async fn fetch_friends(state: State<'_, AppData>) -> Res<Value> {
    state
        .rest(Method::GET, "/rest/v1/friendships", &[("select", FRIEND_SELECT.into())], None, None)
        .await
}

#[tauri::command]
async fn send_friend_request(state: State<'_, AppData>, target: String) -> Res<Value> {
    state.rpc("send_friend_request", json!({ "target": target.trim() })).await
}

#[tauri::command]
async fn respond_friend_request(state: State<'_, AppData>, request_id: String, accept: bool) -> Res<()> {
    state
        .rpc("respond_friend_request", json!({ "request_id": request_id, "accept": accept }))
        .await
        .map(|_| ())
}

#[tauri::command]
async fn online_friends(state: State<'_, AppData>) -> Res<Value> {
    state.rpc("friends_online", json!({})).await
}

// ───────────── Live location ─────────────

#[tauri::command]
async fn friend_locations(state: State<'_, AppData>) -> Res<Value> {
    state
        .rest(
            Method::GET,
            "/rest/v1/live_locations",
            &[("select", "user_id,latitude,longitude,updated_at,permission".into())],
            None,
            None,
        )
        .await
}

#[tauri::command]
async fn report_location(state: State<'_, AppData>, lat: Option<f64>, lon: Option<f64>, granted: bool, always: Option<bool>) -> Res<()> {
    let perm = if !granted { "denied" } else if always.unwrap_or(false) { "always" } else { "when_in_use" };
    state
        .rpc("report_location", json!({ "lat": lat, "lon": lon, "perm": perm }))
        .await?;
    let _ = state.rpc("touch_presence", json!({})).await;
    Ok(())
}

// ───────────── Pins ─────────────

#[tauri::command]
async fn fetch_pins(state: State<'_, AppData>) -> Res<Value> {
    state
        .rest(
            Method::GET,
            "/rest/v1/pins",
            &[
                ("select", PIN_SELECT.into()),
                ("expires_at", format!("gt.{}", now_iso())),
                ("order", "created_at.desc".into()),
            ],
            None,
            None,
        )
        .await
}

/// Signed URLs (1 hour) for images in the private `pins` bucket: { path: url }.
#[tauri::command]
async fn sign_urls(state: State<'_, AppData>, paths: Vec<String>, bucket: Option<String>) -> Res<Value> {
    let bucket = match bucket.as_deref() {
        Some("capsules") => "capsules",
        Some("chat") => "chat",
        Some("stories") => "stories",
        Some("relays") => "relays",
        _ => "pins",
    };
    let mut out = Map::new();
    if paths.is_empty() {
        return Ok(Value::Object(out));
    }
    let rows = state
        .rest(
            Method::POST,
            &format!("/storage/v1/object/sign/{bucket}"),
            &[],
            Some(json!({ "expiresIn": 3600, "paths": paths })),
            None,
        )
        .await?;
    if let Value::Array(items) = rows {
        for item in items {
            let path = item["path"].as_str().unwrap_or_default().to_string();
            let signed = item["signedURL"].as_str().or_else(|| item["signedUrl"].as_str());
            if let (false, Some(signed)) = (path.is_empty(), signed) {
                out.insert(path, Value::String(format!("{SUPABASE_URL}/storage/v1{signed}")));
            }
        }
    }
    Ok(Value::Object(out))
}

/// Uploads the three image variants, then inserts the pin (expires after 6 hours server-side).
#[tauri::command]
async fn publish_pin(
    state: State<'_, AppData>,
    lat: f64,
    lon: f64,
    caption: String,
    full: String,
    thumb: String,
    blur: String,
    sync_session_id: Option<String>,
    video: Option<String>,
) -> Res<Value> {
    let session = state.token().await?;
    let uid = session.user_id.to_lowercase();
    let pin_id = uuid::Uuid::new_v4().to_string();
    let folder = format!("{uid}/{pin_id}");
    let paths = [format!("{folder}/full.jpg"), format!("{folder}/thumb.jpg"), format!("{folder}/blur.jpg")];
    let images = [full, thumb, blur];

    let mut result: Res<Value> = Ok(Value::Null);
    for (path, data) in paths.iter().zip(images.iter()) {
        let bytes = B64.decode(data).map_err(|e| e.to_string())?;
        if let Err(error) = state.upload(&session, "pins", path, bytes).await {
            result = Err(error);
            break;
        }
    }
    let video_path = format!("{folder}/video.mp4");
    let has_video = video.as_deref().is_some_and(|v| !v.is_empty());
    if result.is_ok() && has_video {
        let bytes = B64.decode(video.unwrap_or_default()).map_err(|e| e.to_string())?;
        result = state.upload_as(&session, "pins", &video_path, bytes, "video/mp4").await.map(|_| Value::Null);
    }
    if result.is_ok() {
        let caption: String = caption.trim().chars().take(40).collect();
        let row = json!({
            "id": pin_id,
            "latitude": lat,
            "longitude": lon,
            "caption": caption,
            "image_path": paths[0],
            "thumb_path": paths[1],
            "blur_path": paths[2],
            "video_path": if has_video { Some(video_path.clone()) } else { None },
            "sync_session_id": sync_session_id
        });
        result = state
            .rest(
                Method::POST,
                "/rest/v1/pins",
                &[("select", PIN_SELECT.into())],
                Some(row),
                Some("return=representation"),
            )
            .await
            .map(first);
    }
    if result.is_err() {
        let _ = finish(
            state
                .authed(Method::DELETE, "/storage/v1/object/pins", &session)
                .json(&json!({ "prefixes": [&paths[0], &paths[1], &paths[2], &video_path] })),
        )
        .await;
    }
    result
}

#[tauri::command]
async fn delete_pin(state: State<'_, AppData>, id: String) -> Res<()> {
    state
        .rest(Method::DELETE, "/rest/v1/pins", &[("id", format!("eq.{id}"))], None, None)
        .await
        .map(|_| ())
}

#[tauri::command]
async fn toggle_reaction(state: State<'_, AppData>, pin_id: String, emoji: String, add: bool) -> Res<()> {
    let uid = state.token().await?.user_id;
    if add {
        state
            .rest(
                Method::POST,
                "/rest/v1/reactions",
                &[],
                Some(json!({ "pin_id": pin_id, "user_id": uid, "emoji": emoji })),
                None,
            )
            .await
            .map(|_| ())
    } else {
        state
            .rest(
                Method::DELETE,
                "/rest/v1/reactions",
                &[
                    ("pin_id", format!("eq.{pin_id}")),
                    ("user_id", format!("eq.{uid}")),
                    ("emoji", format!("eq.{emoji}")),
                ],
                None,
                None,
            )
            .await
            .map(|_| ())
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let http = Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .expect("http client");

    #[allow(unused_mut)]
    let mut builder = tauri::Builder::default();
    #[cfg(any(target_os = "android", target_os = "ios"))]
    {
        builder = builder.plugin(tauri_plugin_geolocation::init());
    }

    builder
        .manage(AppData { http, session: Mutex::new(None), file: Mutex::new(None) })
        .setup(|app| {
            always::remember(app.handle());
            always::start_push(app.handle());
            if let Ok(dir) = app.path().app_data_dir() {
                let _ = fs::create_dir_all(&dir);
                let path = dir.join("session.json");
                let data = app.state::<AppData>();
                if let Ok(text) = fs::read_to_string(&path) {
                    if let Ok(session) = serde_json::from_str::<Session>(&text) {
                        *data.session.lock().unwrap() = Some(session);
                    }
                }
                *data.file.lock().unwrap() = Some(path);
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            restore_session,
            sign_in,
            sign_up,
            reset_password,
            sign_out,
            my_profile,
            update_profile,
            fetch_friends,
            send_friend_request,
            respond_friend_request,
            online_friends,
            friend_locations,
            report_location,
            fetch_pins,
            sign_urls,
            publish_pin,
            delete_pin,
            toggle_reaction,
            features::route,
            features::fetch_cross_paths,
            features::fetch_capsules,
            features::capsule_secret,
            features::create_capsule,
            features::open_capsule,
            features::delete_capsule,
            features::sync_invite,
            features::sync_respond,
            features::sync_arm,
            features::sync_cancel,
            features::sync_poll,
            features::pending_sync_invites,
            features::fetch_image_b64,
            features::save_image,
            features::fetch_now_playing,
            features::music_status,
            features::link_lastfm,
            features::unlink_music,
            features::my_places,
            features::add_place,
            features::delete_place,
            features::record_presence,
            features::fetch_notifications,
            features::mark_notifications_read,
            social::chat_threads,
            social::chat_messages,
            social::open_direct_chat,
            social::create_group_chat,
            social::mark_chat_read,
            social::leave_chat,
            social::send_message,
            social::chat_reaction,
            social::fetch_stories,
            social::publish_story,
            social::mark_story_viewed,
            social::delete_story,
            always::always_location_status,
            always::request_always_location,
            always::open_app_settings,
            always::set_always_location,
            always::enable_notifications,
            relays::fetch_relays,
            relays::start_relay,
            relays::run_relay_leg,
            extra::api,
            extra::upload_avatar,
            extra::delete_avatar,
            extra::contacts_status,
            extra::request_contacts,
            extra::read_contacts,
            extra::share_text,
            extra::send_sms,
            extra::update_widget,
            extra::mic_status,
            extra::request_mic,
            extra::start_voice,
            extra::voice_level,
            extra::stop_voice,
            extra::cancel_voice,
            extra::delete_chat_message
        ])
        .run(tauri::generate_context!())
        .expect("error while running PinDrop");
}
