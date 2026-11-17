//! Relay (Staffetta) on Android: start a relay, run your leg, list the relays you can see.

use super::{AppData, Res, Session, B64};
use base64::Engine;
use serde_json::{json, Value};
use tauri::State;

/// Relays you or your friends are running (active first), with their legs.
#[tauri::command]
pub async fn fetch_relays(state: State<'_, AppData>) -> Res<Value> {
    state.rpc("my_relays", json!({})).await
}

/// Uploads the leg photo and its thumbnail to relays/{me}/{relay}/{leg}.jpg.
async fn upload_leg(state: &AppData, session: &Session, relay_id: &str, leg_id: &str, full: &str, thumb: &str) -> Res<(String, String)> {
    let uid = session.user_id.to_lowercase();
    let image = format!("{uid}/{relay_id}/{leg_id}.jpg");
    let small = format!("{uid}/{relay_id}/{leg_id}_thumb.jpg");
    let full = B64.decode(full).map_err(|e| e.to_string())?;
    let thumb = B64.decode(thumb).map_err(|e| e.to_string())?;
    state.upload_as(session, "relays", &image, full, "image/jpeg").await?;
    state.upload_as(session, "relays", &small, thumb, "image/jpeg").await?;
    Ok((image, small))
}

#[tauri::command]
#[allow(clippy::too_many_arguments)]
pub async fn start_relay(
    state: State<'_, AppData>,
    title: String,
    emoji: String,
    lat: f64,
    lon: f64,
    place_name: Option<String>,
    caption: String,
    full: String,
    thumb: String,
    pass_to: String,
) -> Res<Value> {
    let session = state.token().await?;
    let relay_id = uuid::Uuid::new_v4().to_string();
    let leg_id = uuid::Uuid::new_v4().to_string();
    let (image, small) = upload_leg(&state, &session, &relay_id, &leg_id, &full, &thumb).await?;
    state
        .rpc(
            "start_relay",
            json!({
                "relay_id": relay_id, "leg_id": leg_id,
                "title": title.trim().chars().take(40).collect::<String>(),
                "emoji": emoji, "lat": lat, "lon": lon,
                "place_name": place_name.map(|p| p.chars().take(120).collect::<String>()),
                "caption": caption.trim().chars().take(40).collect::<String>(),
                "image_path": image, "thumb_path": small, "pass_to": pass_to,
            }),
        )
        .await?;
    Ok(json!({ "id": relay_id }))
}

#[tauri::command]
#[allow(clippy::too_many_arguments)]
pub async fn run_relay_leg(
    state: State<'_, AppData>,
    relay_id: String,
    lat: f64,
    lon: f64,
    place_name: Option<String>,
    caption: String,
    full: String,
    thumb: String,
    pass_to: Option<String>,
) -> Res<Value> {
    let session = state.token().await?;
    let leg_id = uuid::Uuid::new_v4().to_string();
    let (image, small) = upload_leg(&state, &session, &relay_id, &leg_id, &full, &thumb).await?;
    state
        .rpc(
            "run_relay_leg",
            json!({
                "target": relay_id, "leg_id": leg_id, "lat": lat, "lon": lon,
                "place_name": place_name.map(|p| p.chars().take(120).collect::<String>()),
                "caption": caption.trim().chars().take(40).collect::<String>(),
                "image_path": image, "thumb_path": small,
                "pass_to": pass_to.filter(|p| !p.is_empty()),
            }),
        )
        .await
}
