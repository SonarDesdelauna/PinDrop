//! Street-following trail, cross-paths ("Sfiorati"), Geo-Capsules, Sync Shot and the Recap
//! story export. Same Supabase backend and rules as the iOS app.

use super::{finish, first, net, now_iso, AppData, Res, B64, CAPSULE_SELECT, SUPABASE_URL};
use base64::Engine;
use reqwest::Method;
use serde_json::{json, Value};
use std::{fs, path::PathBuf};
use tauri::{Manager, State};

fn iso_ago(seconds: i64) -> String {
    (chrono::Utc::now() - chrono::Duration::seconds(seconds)).to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

// ───────────── Street route for your trail ─────────────

/// Walking route through the given [lon, lat] stops (OpenStreetMap routing), as [lon, lat] points.
#[tauri::command]
pub async fn route(state: State<'_, AppData>, points: Vec<Vec<f64>>) -> Res<Value> {
    let stops: Vec<String> = points
        .iter()
        .filter(|p| p.len() == 2)
        .map(|p| format!("{:.6},{:.6}", p[0], p[1]))
        .collect();
    if stops.len() < 2 {
        return Ok(json!([]));
    }
    let url = format!(
        "https://routing.openstreetmap.de/routed-foot/route/v1/foot/{}?overview=full&geometries=geojson",
        stops.join(";")
    );
    let value = finish(state.http.get(url).header("User-Agent", "PinDrop-Android/1.0")).await?;
    Ok(value["routes"][0]["geometry"]["coordinates"].clone())
}

// ───────────── Cross-paths ("Sfiorati") ─────────────

#[tauri::command]
pub async fn fetch_cross_paths(state: State<'_, AppData>) -> Res<Value> {
    let _ = state.rpc("detect_cross_paths", json!({})).await;
    state
        .rest(
            Method::GET,
            "/rest/v1/cross_paths",
            &[
                ("select", "id,user_a,user_b,pin_a,pin_b,latitude,longitude,distance_m,delta_seconds,created_at".into()),
                ("created_at", format!("gt.{}", iso_ago(21_600))),
                ("order", "created_at.desc".into()),
            ],
            None,
            None,
        )
        .await
}

// ───────────── Geo-Capsules ─────────────

#[tauri::command]
pub async fn fetch_capsules(state: State<'_, AppData>) -> Res<Value> {
    let capsules = state
        .rest(
            Method::GET,
            "/rest/v1/geo_capsules",
            &[
                ("select", CAPSULE_SELECT.into()),
                ("expires_at", format!("gt.{}", now_iso())),
                ("order", "created_at.desc".into()),
            ],
            None,
            None,
        )
        .await?;
    let opens = state
        .rest(Method::GET, "/rest/v1/capsule_opens", &[("select", "capsule_id,user_id,opened_at".into())], None, None)
        .await
        .unwrap_or_else(|_| json!([]));
    Ok(json!({ "capsules": capsules, "opens": opens }))
}

#[tauri::command]
pub async fn capsule_secret(state: State<'_, AppData>, id: String) -> Res<Value> {
    let rows = state
        .rest(
            Method::GET,
            "/rest/v1/capsule_secrets",
            &[("select", "capsule_id,message".into()), ("capsule_id", format!("eq.{id}"))],
            None,
            None,
        )
        .await?;
    Ok(first(rows)["message"].clone())
}

#[tauri::command]
#[allow(clippy::too_many_arguments)]
pub async fn create_capsule(
    state: State<'_, AppData>,
    lat: f64,
    lon: f64,
    hint: String,
    message: String,
    recipient: Option<String>,
    full: String,
    thumb: String,
) -> Res<Value> {
    let session = state.token().await?;
    let uid = session.user_id.to_lowercase();
    let id = uuid::Uuid::new_v4().to_string();
    let paths = [format!("{uid}/{id}/full.jpg"), format!("{uid}/{id}/thumb.jpg")];
    let images = [full, thumb];

    let mut result: Res<Value> = Ok(Value::Null);
    for (path, data) in paths.iter().zip(images.iter()) {
        let bytes = B64.decode(data).map_err(|e| e.to_string())?;
        if let Err(error) = state.upload(&session, "capsules", path, bytes).await {
            result = Err(error);
            break;
        }
    }
    if result.is_ok() {
        let row = json!({
            "id": id,
            "latitude": lat,
            "longitude": lon,
            "hint": hint.trim().chars().take(80).collect::<String>(),
            "image_path": paths[0],
            "thumb_path": paths[1],
            "recipient_id": recipient.filter(|r| !r.is_empty())
        });
        result = state
            .rest(
                Method::POST,
                "/rest/v1/geo_capsules",
                &[("select", CAPSULE_SELECT.into())],
                Some(row),
                Some("return=representation"),
            )
            .await
            .map(first);
        if result.is_ok() {
            let secret = json!({
                "capsule_id": id,
                "message": message.trim().chars().take(140).collect::<String>()
            });
            if let Err(error) = state.rest(Method::POST, "/rest/v1/capsule_secrets", &[], Some(secret), None).await {
                let _ = state
                    .rest(Method::DELETE, "/rest/v1/geo_capsules", &[("id", format!("eq.{id}"))], None, None)
                    .await;
                result = Err(error);
            }
        }
    }
    if result.is_err() {
        let _ = finish(
            state
                .authed(Method::DELETE, "/storage/v1/object/capsules", &session)
                .json(&json!({ "prefixes": paths })),
        )
        .await;
    }
    result
}

/// The server checks that you are within 20 m. Returns true when the capsule opened.
#[tauri::command]
pub async fn open_capsule(state: State<'_, AppData>, id: String, lat: f64, lon: f64) -> Res<bool> {
    let value = state
        .rpc("open_capsule", json!({ "capsule": id, "lat": lat, "lon": lon }))
        .await?;
    Ok(value.as_bool().unwrap_or(false))
}

#[tauri::command]
pub async fn delete_capsule(state: State<'_, AppData>, id: String) -> Res<()> {
    state
        .rest(Method::DELETE, "/rest/v1/geo_capsules", &[("id", format!("eq.{id}"))], None, None)
        .await
        .map(|_| ())
}

// ───────────── Sync Shot ─────────────

#[tauri::command]
pub async fn sync_invite(state: State<'_, AppData>, partner: String) -> Res<Value> {
    state.rpc("sync_invite", json!({ "partner": partner })).await.map(first)
}

#[tauri::command]
pub async fn sync_respond(state: State<'_, AppData>, session: String, accept: bool) -> Res<()> {
    state
        .rpc("sync_respond", json!({ "session": session, "accept": accept }))
        .await
        .map(|_| ())
}

#[tauri::command]
pub async fn sync_arm(state: State<'_, AppData>, session: String) -> Res<Value> {
    state.rpc("sync_arm", json!({ "session": session })).await
}

#[tauri::command]
pub async fn sync_cancel(state: State<'_, AppData>, session: String) -> Res<()> {
    state.rpc("sync_cancel", json!({ "session": session })).await.map(|_| ())
}

/// { status, fire_at, server_now }
#[tauri::command]
pub async fn sync_poll(state: State<'_, AppData>, session: String) -> Res<Value> {
    state.rpc("sync_poll", json!({ "session": session })).await.map(first)
}

/// Sync Shot invitations addressed to you in the last 2 minutes.
#[tauri::command]
pub async fn pending_sync_invites(state: State<'_, AppData>) -> Res<Value> {
    let uid = state.token().await?.user_id;
    state
        .rest(
            Method::GET,
            "/rest/v1/sync_sessions",
            &[
                ("select", "id,initiator_id,partner_id,status,fire_at,created_at".into()),
                ("partner_id", format!("eq.{uid}")),
                ("status", "eq.pending".into()),
                ("created_at", format!("gt.{}", iso_ago(120))),
                ("order", "created_at.desc".into()),
            ],
            None,
            None,
        )
        .await
}

// ───────────── Recap story ─────────────

/// Downloads one of our storage images as base64 (to draw it on the story card).
#[tauri::command]
pub async fn fetch_image_b64(state: State<'_, AppData>, url: String) -> Res<String> {
    if !url.starts_with(SUPABASE_URL) {
        return Err("invalid url".into());
    }
    let response = state.http.get(url).send().await.map_err(net)?;
    if !response.status().is_success() {
        return Err("image".into());
    }
    let bytes = response.bytes().await.map_err(net)?;
    Ok(B64.encode(bytes))
}

/// Saves a JPEG (base64) in Pictures/PinDrop on the phone. Returns where it was saved.
#[tauri::command]
pub async fn save_image(app: tauri::AppHandle, data: String, name: String) -> Res<String> {
    let bytes = B64.decode(data).map_err(|e| e.to_string())?;
    let safe: String = name
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .collect();
    let file = format!("{}.jpg", if safe.is_empty() { "pindrop" } else { safe.as_str() });
    let mut folders = vec![
        PathBuf::from("/storage/emulated/0/Pictures/PinDrop"),
        PathBuf::from("/storage/emulated/0/Download"),
    ];
    if let Ok(dir) = app.path().picture_dir() {
        folders.push(dir.join("PinDrop"));
    }
    if let Ok(dir) = app.path().app_data_dir() {
        folders.push(dir);
    }
    for folder in folders {
        if fs::create_dir_all(&folder).is_err() {
            continue;
        }
        let path = folder.join(&file);
        if fs::write(&path, &bytes).is_ok() {
            return Ok(path.to_string_lossy().to_string());
        }
    }
    Err("save".into())
}

// ───────────── Now playing (Spotify / Last.fm, polled by the server) ─────────────

#[tauri::command]
pub async fn fetch_now_playing(state: State<'_, AppData>) -> Res<Value> {
    state
        .rest(
            Method::GET,
            "/rest/v1/now_playing",
            &[("select", "user_id,provider,track,artist,album,artwork_url,track_url,is_playing,updated_at".into())],
            None,
            None,
        )
        .await
}

#[tauri::command]
pub async fn music_status(state: State<'_, AppData>) -> Res<Value> {
    state.rpc("music_status", json!({})).await
}

#[tauri::command]
pub async fn link_lastfm(state: State<'_, AppData>, username: String) -> Res<Value> {
    state.rpc("link_lastfm", json!({ "username": username.trim() })).await
}

#[tauri::command]
pub async fn unlink_music(state: State<'_, AppData>, provider: String) -> Res<Value> {
    state.rpc("unlink_music", json!({ "provider": provider })).await
}

// ───────────── Saved places ─────────────

#[tauri::command]
pub async fn my_places(state: State<'_, AppData>) -> Res<Value> {
    state.rpc("my_places", json!({})).await
}

#[tauri::command]
pub async fn add_place(
    state: State<'_, AppData>,
    name: String,
    emoji: String,
    lat: f64,
    lon: f64,
    is_public: bool,
) -> Res<Value> {
    let name: String = name.trim().chars().take(40).collect();
    if name.is_empty() {
        return Err("Scrivi un nome per il luogo.".into());
    }
    state
        .rest(
            Method::POST,
            "/rest/v1/places",
            &[],
            Some(json!({
                "name": name,
                "emoji": emoji,
                "latitude": lat,
                "longitude": lon,
                "radius_m": 100,
                "is_public": is_public,
            })),
            Some("return=minimal"),
        )
        .await
}

#[tauri::command]
pub async fn delete_place(state: State<'_, AppData>, id: String) -> Res<Value> {
    state
        .rest(Method::DELETE, "/rest/v1/places", &[("id", format!("eq.{id}"))], None, Some("return=minimal"))
        .await
}

#[tauri::command]
pub async fn record_presence(state: State<'_, AppData>, lat: f64, lon: f64) -> Res<Value> {
    state.rpc("record_presence", json!({ "lat": lat, "lon": lon })).await
}

// ───────────── Notifications ─────────────

#[tauri::command]
pub async fn fetch_notifications(state: State<'_, AppData>) -> Res<Value> {
    state
        .rest(
            Method::GET,
            "/rest/v1/notifications",
            &[
                (
                    "select",
                    "id,kind,created_at,read_at,payload,actor:profiles!notifications_actor_id_fkey(*),place:places(id,name,emoji,latitude,longitude)".into(),
                ),
                ("order", "created_at.desc".into()),
                ("limit", "60".into()),
            ],
            None,
            None,
        )
        .await
}

#[tauri::command]
pub async fn mark_notifications_read(state: State<'_, AppData>) -> Res<Value> {
    let session = state.token().await?;
    state
        .rest(
            Method::PATCH,
            "/rest/v1/notifications",
            &[("user_id", format!("eq.{}", session.user_id)), ("read_at", "is.null".into())],
            Some(json!({ "read_at": now_iso() })),
            Some("return=minimal"),
        )
        .await
}
