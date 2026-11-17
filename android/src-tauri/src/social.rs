//! Chats (1-to-1, groups, 24 h cluster chats) and 24 h Stories with photos or videos.
//! Same Supabase tables and rules as the iOS app.

use super::{finish, first, now_iso, AppData, Res, B64};
use base64::Engine;
use reqwest::Method;
use serde_json::{json, Value};
use tauri::State;

const MESSAGE_SELECT: &str = "id,thread_id,sender_id,kind,body,attachment_bucket,attachment_path,ref_id,place_name,latitude,longitude,eta_minutes,created_at,reactions:chat_reactions(user_id,emoji)";
const STORY_SELECT: &str = "id,image_path,video_path,overlay_text,overlay_y,location_tag,created_at,expires_at,author:profiles!stories_author_id_fkey(*),views:story_views(viewer_id,liked,viewed_at,viewer:profiles!story_views_viewer_id_fkey(*))";

fn clip(text: &str, max: usize) -> String {
    text.trim().chars().take(max).collect()
}

// ───────────── Chats ─────────────

#[tauri::command]
pub async fn chat_threads(state: State<'_, AppData>) -> Res<Value> {
    state.rpc("my_chat_threads", json!({})).await
}

/// The latest messages of a thread, oldest first.
#[tauri::command]
pub async fn chat_messages(state: State<'_, AppData>, thread_id: String) -> Res<Value> {
    let rows = state
        .rest(
            Method::GET,
            "/rest/v1/chat_messages",
            &[
                ("select", MESSAGE_SELECT.into()),
                ("thread_id", format!("eq.{thread_id}")),
                ("order", "created_at.desc".into()),
                ("limit", "120".into()),
            ],
            None,
            None,
        )
        .await?;
    Ok(match rows {
        Value::Array(mut items) => {
            items.reverse();
            Value::Array(items)
        }
        other => other,
    })
}

#[tauri::command]
pub async fn open_direct_chat(state: State<'_, AppData>, friend: String) -> Res<Value> {
    state.rpc("open_direct_chat", json!({ "friend": friend })).await
}

/// A group chat; with `ephemeral_hours` > 0 it is a cluster chat that disappears.
#[tauri::command]
pub async fn create_group_chat(
    state: State<'_, AppData>,
    title: String,
    emoji: String,
    members: Vec<String>,
    ephemeral_hours: i64,
) -> Res<Value> {
    state
        .rpc(
            "create_group_chat",
            json!({ "title": clip(&title, 60), "emoji": emoji, "members": members, "ephemeral_hours": ephemeral_hours }),
        )
        .await
}

#[tauri::command]
pub async fn mark_chat_read(state: State<'_, AppData>, thread: String) -> Res<()> {
    state.rpc("mark_chat_read", json!({ "thread": thread })).await.map(|_| ())
}

#[tauri::command]
pub async fn leave_chat(state: State<'_, AppData>, thread: String) -> Res<()> {
    state.rpc("leave_chat", json!({ "thread": thread })).await.map(|_| ())
}

/// Uploads the photo (if any) to the chat bucket, then inserts the message.
#[tauri::command]
#[allow(clippy::too_many_arguments)]
pub async fn send_message(
    state: State<'_, AppData>,
    thread_id: String,
    kind: String,
    body: String,
    photo: Option<String>,
    attachment_bucket: Option<String>,
    attachment_path: Option<String>,
    ref_id: Option<String>,
    place_name: Option<String>,
    lat: Option<f64>,
    lon: Option<f64>,
    eta_minutes: Option<i64>,
) -> Res<Value> {
    let session = state.token().await?;
    let id = uuid::Uuid::new_v4().to_string();
    let mut bucket = attachment_bucket;
    let mut path = attachment_path;
    if let Some(photo) = photo.filter(|p| !p.is_empty()) {
        let photo_path = format!("{}/{id}.jpg", thread_id.to_lowercase());
        let bytes = B64.decode(photo).map_err(|e| e.to_string())?;
        state.upload(&session, "chat", &photo_path, bytes).await?;
        bucket = Some("chat".into());
        path = Some(photo_path);
    }
    let row = json!({
        "id": id,
        "thread_id": thread_id,
        "kind": kind,
        "body": body.chars().take(2000).collect::<String>(),
        "attachment_bucket": bucket,
        "attachment_path": path,
        "ref_id": ref_id,
        "place_name": place_name.map(|p| clip(&p, 120)),
        "latitude": lat,
        "longitude": lon,
        "eta_minutes": eta_minutes
    });
    state
        .rest(
            Method::POST,
            "/rest/v1/chat_messages",
            &[("select", MESSAGE_SELECT.into())],
            Some(row),
            Some("return=representation"),
        )
        .await
        .map(first)
}

#[tauri::command]
pub async fn chat_reaction(state: State<'_, AppData>, message_id: String, emoji: String, add: bool) -> Res<()> {
    let uid = state.token().await?.user_id;
    if add {
        state
            .rest(
                Method::POST,
                "/rest/v1/chat_reactions",
                &[],
                Some(json!({ "message_id": message_id, "emoji": emoji })),
                None,
            )
            .await
            .map(|_| ())
    } else {
        state
            .rest(
                Method::DELETE,
                "/rest/v1/chat_reactions",
                &[
                    ("message_id", format!("eq.{message_id}")),
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

// ───────────── Stories ─────────────

#[tauri::command]
pub async fn fetch_stories(state: State<'_, AppData>) -> Res<Value> {
    state
        .rest(
            Method::GET,
            "/rest/v1/stories",
            &[
                ("select", STORY_SELECT.into()),
                ("expires_at", format!("gt.{}", now_iso())),
                ("order", "created_at.asc".into()),
            ],
            None,
            None,
        )
        .await
}

/// Uploads the photo (and the video, if any) and creates a story that lasts 24 hours.
#[tauri::command]
pub async fn publish_story(
    state: State<'_, AppData>,
    photo: String,
    video: Option<String>,
    overlay_text: String,
    overlay_y: f64,
    location_tag: Option<String>,
) -> Res<Value> {
    let session = state.token().await?;
    let uid = session.user_id.to_lowercase();
    let id = uuid::Uuid::new_v4().to_string();
    let path = format!("{uid}/{id}.jpg");
    let video_path = format!("{uid}/{id}.mp4");
    let has_video = video.as_deref().is_some_and(|v| !v.is_empty());

    let bytes = B64.decode(photo).map_err(|e| e.to_string())?;
    state.upload(&session, "stories", &path, bytes).await?;
    let mut result: Res<Value> = Ok(Value::Null);
    if has_video {
        let bytes = B64.decode(video.unwrap_or_default()).map_err(|e| e.to_string())?;
        result = state.upload_as(&session, "stories", &video_path, bytes, "video/mp4").await.map(|_| Value::Null);
    }
    if result.is_ok() {
        let row = json!({
            "id": id,
            "image_path": path,
            "video_path": if has_video { Some(video_path.clone()) } else { None },
            "overlay_text": overlay_text.chars().take(80).collect::<String>(),
            "overlay_y": overlay_y.clamp(0.0, 1.0),
            "location_tag": location_tag.filter(|t| !t.trim().is_empty()).map(|t| clip(&t, 120))
        });
        result = state
            .rest(
                Method::POST,
                "/rest/v1/stories",
                &[("select", STORY_SELECT.into())],
                Some(row),
                Some("return=representation"),
            )
            .await
            .map(first);
    }
    if result.is_err() {
        let _ = finish(
            state
                .authed(Method::DELETE, "/storage/v1/object/stories", &session)
                .json(&json!({ "prefixes": [&path, &video_path] })),
        )
        .await;
    }
    result
}

#[tauri::command]
pub async fn mark_story_viewed(state: State<'_, AppData>, story_id: String, liked: bool) -> Res<()> {
    let uid = state.token().await?.user_id;
    state
        .rest(
            Method::POST,
            "/rest/v1/story_views",
            &[("on_conflict", "story_id,viewer_id".into())],
            Some(json!({ "story_id": story_id, "viewer_id": uid, "liked": liked })),
            Some("resolution=merge-duplicates,return=minimal"),
        )
        .await
        .map(|_| ())
}

#[tauri::command]
pub async fn delete_story(state: State<'_, AppData>, id: String, paths: Vec<String>) -> Res<()> {
    let session = state.token().await?;
    state
        .rest(Method::DELETE, "/rest/v1/stories", &[("id", format!("eq.{id}"))], None, None)
        .await?;
    let _ = finish(
        state
            .authed(Method::DELETE, "/storage/v1/object/stories", &session)
            .json(&json!({ "prefixes": paths })),
    )
    .await;
    Ok(())
}
