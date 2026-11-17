// PinDrop for Android: chats (1-to-1, groups, 24 h cluster chats) and 24 h Stories
// with an Instagram-style editor (effects, texts, stickers). Same backend as the iPhone app.

const CHAT_REACTIONS = ["❤️", "😂", "🔥", "😮", "👍"];
Object.assign(state, {
  threads: [],
  stories: [],
  seenStories: new Set(JSON.parse(localStorage.getItem("seenStories") || "[]")),
});

let socialStarted = false;
function startSocial() {
  if (socialStarted) return;
  socialStarted = true;
  loadThreads();
  loadStories();
  setInterval(loadThreads, 20000);
  setInterval(loadStories, 60000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) { loadThreads(); loadStories(); } });
}

/** Closes the full-screen chat / story screens (back button). */
function closeSocialOverlays() {
  closeRoom();
  closeStoryViewer();
  closeStoryEditor();
}

function openOverlay(id) {
  hideSheet();
  $(id).classList.remove("hidden");
  pushLayer();
}
function leaveOverlay() {
  closeSocialOverlays();
  popLayer();
}

function clockText(iso) {
  const d = new Date(iso);
  const today = new Date();
  const time = d.toLocaleTimeString("it-IT", { hour: "2-digit", minute: "2-digit" });
  if (d.toDateString() === today.toDateString()) return time;
  return `${d.toLocaleDateString("it-IT", { day: "numeric", month: "short" })} ${time}`;
}

// ───────────── Chats: list ─────────────

async function loadThreads() {
  if (!state.me) return;
  try {
    state.threads = (await invoke("chat_threads")) || [];
  } catch (_) { return; }
  const unread = state.threads.reduce((n, t) => n + (t.unread_count || 0), 0);
  $("chatBadge").textContent = unread > 99 ? "99+" : unread;
  $("chatBadge").classList.toggle("hidden", unread === 0);
  if ($("chatList")) renderThreadList();
}

function otherMembers(t) {
  return (t.participants || []).filter((p) => p.id !== state.me.id);
}
function threadTitle(t) {
  if (t.kind === "direct") return otherMembers(t)[0]?.display_name || "Chat";
  return `${t.emoji ? t.emoji + " " : ""}${t.title || "Gruppo"}`;
}
function threadAvatar(t) {
  if (t.kind === "direct") return avatarHTML(otherMembers(t)[0]);
  return `<div class="avatar group-av">${esc(t.emoji || "👥")}</div>`;
}
function messagePreview(m) {
  if (!m) return "Nessun messaggio";
  const who = m.sender_id === state.me.id ? "Tu: " : "";
  const body = m.body ? m.body : "";
  switch (m.kind) {
    case "photo": return `${who}📷 Foto${body ? " · " + body : ""}`;
    case "pin_reply": return `${who}↩︎ Pin: ${body}`;
    case "story_reply": return `${who}↩︎ Storia: ${body}`;
    case "location": return `${who}📍 ${m.eta_minutes != null ? `Arrivo tra ${m.eta_minutes} min` : "Posizione"}`;
    default: return who + body;
  }
}

$("chatBtn").addEventListener("click", openChatList);

function openChatList() {
  openSheet(`${head("Chat")}
    <div class="row"><button class="ghost grow" data-act="dm">✏️ Nuovo messaggio</button><button class="ghost grow" data-act="group">👥 Nuovo gruppo</button></div>
    <div id="chatList"></div>`, (root) => {
    renderThreadList();
    root.querySelector('[data-act="dm"]').addEventListener("click", openFriendPicker);
    root.querySelector('[data-act="group"]').addEventListener("click", openCreateGroup);
  });
  loadThreads();
}

function renderThreadList() {
  const list = $("chatList");
  if (!list) return;
  list.innerHTML = state.threads.map((t) => {
    const last = t.last_message;
    const ephemeral = t.expires_at ? `<span class="eph">⏳ ${esc(until(t.expires_at))}</span>` : "";
    return `<div class="person thread${t.unread_count ? " unread" : ""}" data-thread="${t.id}">${threadAvatar(t)}<div class="info"><b>${esc(threadTitle(t))} ${ephemeral}</b><span class="preview">${esc(messagePreview(last))}</span></div>
      <div class="meta"><small>${last ? esc(clockText(last.created_at)) : ""}</small>${t.unread_count ? `<span class="dot-count">${t.unread_count}</span>` : ""}</div></div>`;
  }).join("") || `<p class="muted small center">Ancora nessuna chat. Scrivi a un amico o crea un gruppo!</p>`;
  list.onclick = (e) => {
    const row = e.target.closest("[data-thread]");
    if (row) openRoom(row.dataset.thread);
  };
}

function openFriendPicker() {
  openSheet(`${head("Nuovo messaggio")}${state.friends.map((f) => `<div class="person" data-friend="${f.id}">${avatarHTML(f)}<div class="info"><b>${esc(f.display_name)}</b><span>@${esc(f.username)}</span></div></div>`).join("") || `<p class="muted small">Aggiungi prima qualche amico.</p>`}`, (root) => {
    root.addEventListener("click", (e) => {
      const row = e.target.closest("[data-friend]");
      if (row) openDirectChat(profileOf(row.dataset.friend));
    });
  });
}

const GROUP_EMOJIS = ["👥", "⚡", "🎉", "🍕", "⚽️", "🎵", "🏖️", "📚", "🍻", "❤️", "🔥", "🌙"];
function openCreateGroup() {
  let emoji = GROUP_EMOJIS[0];
  openSheet(`${head("Nuovo gruppo")}
    <input id="groupTitle" type="text" maxlength="60" placeholder="Nome del gruppo">
    <div class="emoji-grid">${GROUP_EMOJIS.map((e) => `<button class="emoji-opt${e === emoji ? " on" : ""}" data-emoji="${e}">${e}</button>`).join("")}</div>
    <h3>Chi c'è</h3>
    <div id="groupMembers">${state.friends.map((f) => `<label class="person pick">${avatarHTML(f)}<div class="info"><b>${esc(f.display_name)}</b><span>@${esc(f.username)}</span></div><input type="checkbox" value="${f.id}"></label>`).join("") || `<p class="muted small">Aggiungi prima qualche amico.</p>`}</div>
    <label class="toggle-row"><input id="groupEphemeral" type="checkbox"> ⏳ Sparisce dopo 24 ore</label>
    <button id="groupCreate" class="primary">Crea il gruppo</button>`, (root) => {
    root.querySelector(".emoji-grid").addEventListener("click", (e) => {
      const b = e.target.closest("[data-emoji]");
      if (!b) return;
      emoji = b.dataset.emoji;
      root.querySelectorAll(".emoji-opt").forEach((x) => x.classList.toggle("on", x === b));
    });
    root.querySelector("#groupCreate").addEventListener("click", async (e) => {
      const title = root.querySelector("#groupTitle").value.trim();
      const members = [...root.querySelectorAll("#groupMembers input:checked")].map((i) => i.value);
      if (!title) return toast("Dai un nome al gruppo.");
      if (!members.length) return toast("Scegli almeno un amico.");
      const btn = e.currentTarget;
      btn.disabled = true;
      try {
        const id = await invoke("create_group_chat", { title, emoji, members, ephemeralHours: root.querySelector("#groupEphemeral").checked ? 24 : 0 });
        await loadThreads();
        openRoom(id);
      } catch (err) {
        btn.disabled = false;
        toast(errorText(err));
      }
    });
  });
}

async function openDirectChat(friend) {
  if (!friend) return;
  try {
    const id = await invoke("open_direct_chat", { friend: friend.id });
    await loadThreads();
    openRoom(id);
  } catch (err) { toast(errorText(err)); }
}

/** A 24 h chat with the people at the same spot (reuses one that is still open). */
async function openHubChat(people, placeName, button) {
  const ids = people.map((p) => p.id).sort();
  const existing = state.threads.find((t) => t.kind === "cluster" && t.expires_at && new Date(t.expires_at) > new Date()
    && otherMembers(t).map((p) => p.id).sort().join() === ids.join());
  if (existing) return openRoom(existing.id);
  if (button) button.disabled = true;
  try {
    const id = await invoke("create_group_chat", { title: placeName || "Qui insieme", emoji: "📍", members: ids, ephemeralHours: 24 });
    await loadThreads();
    openRoom(id);
  } catch (err) {
    toast(errorText(err));
  } finally {
    if (button) button.disabled = false;
  }
}

async function replyToPin(pin, text) {
  const thread = await invoke("open_direct_chat", { friend: pin.author.id });
  await invoke("send_message", {
    threadId: thread, kind: "pin_reply", body: text, photo: null,
    attachmentBucket: "pins", attachmentPath: pin.thumb_path, refId: pin.id,
    placeName: pin.place_name || null, lat: null, lon: null, etaMinutes: null,
  });
  loadThreads();
}

// ───────────── Chats: room ─────────────

let room = null;

async function openRoom(threadId) {
  closeRoom();
  let thread = state.threads.find((t) => t.id === threadId);
  if (!thread) { await loadThreads(); thread = state.threads.find((t) => t.id === threadId); }
  if (!thread) return toast("Chat non disponibile.");
  room = { id: threadId, thread, messages: [], key: "", timer: 0 };
  const members = otherMembers(thread);
  const sub = thread.kind === "direct"
    ? (state.online.has(members[0]?.id) ? "● online" : `@${members[0]?.username || ""}`)
    : `${members.length + 1} persone${thread.expires_at ? ` · ⏳ sparisce tra ${until(thread.expires_at)}` : ""}`;
  const el = $("chatRoom");
  el.innerHTML = `<header class="room-head glass">
      <button class="fab plain" data-act="back" aria-label="Indietro">${ICON.back}</button>
      ${threadAvatar(thread)}
      <div class="grow"><b>${esc(threadTitle(thread))}</b><small>${esc(sub)}</small></div>
      ${thread.kind !== "direct" ? `<button class="mini-btn" data-act="leave">Esci</button>` : ""}
    </header>
    <div id="roomList" class="room-list"><p class="muted small center">Carico…</p></div>
    <div id="reactPicker" class="react-picker glass hidden">${CHAT_REACTIONS.map((e) => `<button data-react="${e}">${e}</button>`).join("")}</div>
    <footer class="room-input glass">
      <button class="fab plain" data-act="photo" aria-label="Foto">📷</button>
      <button class="fab plain" data-act="where" aria-label="Posizione">📍</button>
      <input id="roomText" type="text" maxlength="2000" placeholder="Messaggio…" autocomplete="off">
      <button class="send" data-act="send" aria-label="Invia">${ICON.send}</button>
    </footer>`;
  openOverlay("chatRoom");
  el.querySelector('[data-act="back"]').addEventListener("click", leaveOverlay);
  el.querySelector('[data-act="leave"]')?.addEventListener("click", async () => {
    if (!confirm("Uscire da questo gruppo?")) return;
    try { await invoke("leave_chat", { thread: threadId }); leaveOverlay(); loadThreads(); } catch (err) { toast(errorText(err)); }
  });
  el.querySelector('[data-act="send"]').addEventListener("click", sendText);
  $("roomText").addEventListener("keydown", (e) => { if (e.key === "Enter") sendText(); });
  el.querySelector('[data-act="photo"]').addEventListener("click", () => $("chatPhotoInput").click());
  el.querySelector('[data-act="where"]').addEventListener("click", sendLocation);
  setupReactions(el);
  await loadRoom(true);
  room && (room.timer = setInterval(() => loadRoom(false), 3000));
}

function closeRoom() {
  if (!room) return;
  clearInterval(room.timer);
  room = null;
  $("chatRoom").classList.add("hidden");
  $("chatRoom").innerHTML = "";
  loadThreads();
}

async function loadRoom(first) {
  const r = room;
  if (!r) return;
  let rows;
  try { rows = await invoke("chat_messages", { threadId: r.id }); } catch (_) { return; }
  if (room !== r) return;
  const key = rows.map((m) => `${m.id}:${(m.reactions || []).length}`).join("|");
  if (key === r.key && !first) return;
  const hadNew = rows.length && rows[rows.length - 1]?.id !== r.messages[r.messages.length - 1]?.id;
  r.messages = rows;
  r.key = key;
  await renderRoom(hadNew || first);
  if (hadNew || first) invoke("mark_chat_read", { thread: r.id }).catch(() => {});
}

function bubbleMedia(m) {
  if (!m.attachment_path) return "";
  const bucket = m.attachment_bucket || "chat";
  if (m.kind === "photo") return `<img class="msg-photo" data-bucket="${bucket}" data-path="${esc(m.attachment_path)}">`;
  if (m.kind === "pin_reply" || m.kind === "story_reply") {
    const label = m.kind === "pin_reply" ? `↩︎ Risposta al pin${m.place_name ? " · " + esc(m.place_name) : ""}` : "↩︎ Risposta alla storia";
    return `<div class="msg-ref"><img data-bucket="${bucket}" data-path="${esc(m.attachment_path)}"><span>${label}</span></div>`;
  }
  return "";
}

async function renderRoom(scroll) {
  const r = room;
  const list = $("roomList");
  if (!r || !list) return;
  const group = r.thread.kind !== "direct";
  const nearBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 120;
  list.innerHTML = r.messages.map((m, i) => {
    const mine = m.sender_id === state.me.id;
    const prev = r.messages[i - 1];
    const sender = (r.thread.participants || []).find((p) => p.id === m.sender_id);
    const showName = group && !mine && prev?.sender_id !== m.sender_id;
    const reactions = Object.entries((m.reactions || []).reduce((acc, x) => { acc[x.emoji] = (acc[x.emoji] || 0) + 1; return acc; }, {}))
      .map(([e, n]) => `<span>${e}${n > 1 ? n : ""}</span>`).join("");
    let body;
    if (m.kind === "location") {
      body = `<div class="msg-loc" data-lat="${m.latitude}" data-lon="${m.longitude}">📍 <b>${m.eta_minutes != null ? `Arrivo tra ${m.eta_minutes} min` : esc(m.place_name || "La mia posizione")}</b><small>Tocca per vederla sulla mappa</small></div>`;
    } else {
      body = `${bubbleMedia(m)}${m.body ? `<div class="msg-text">${esc(m.body)}</div>` : ""}`;
    }
    return `<div class="msg${mine ? " mine" : ""}" data-msg="${m.id}">
      ${!mine && group ? (prev?.sender_id === m.sender_id ? '<div class="av-space"></div>' : avatarHTML(sender)) : ""}
      <div class="bubble-wrap">${showName ? `<small class="who">${esc(firstName(sender))}</small>` : ""}<div class="bubble">${body}</div>${reactions ? `<div class="msg-reacts">${reactions}</div>` : ""}<small class="when">${esc(clockText(m.created_at))}</small></div></div>`;
  }).join("") || `<p class="muted small center">Scrivi il primo messaggio 👋</p>`;
  if (scroll || nearBottom) list.scrollTop = list.scrollHeight;
  // Images from their buckets (chat photos, pin and story thumbnails).
  const imgs = [...list.querySelectorAll("img[data-path]")];
  const byBucket = {};
  imgs.forEach((img) => (byBucket[img.dataset.bucket] ||= []).push(img.dataset.path));
  for (const [bucket, paths] of Object.entries(byBucket)) {
    const urls = await signed(bucket, paths);
    imgs.filter((i) => i.dataset.bucket === bucket).forEach((img) => {
      if (urls[img.dataset.path]) img.src = urls[img.dataset.path];
      img.onload = () => { if (scroll || nearBottom) list.scrollTop = list.scrollHeight; };
    });
  }
  list.querySelectorAll(".msg-loc").forEach((el) => el.addEventListener("click", () => {
    const lat = Number(el.dataset.lat), lon = Number(el.dataset.lon);
    if (!isFinite(lat) || !isFinite(lon)) return;
    leaveOverlay();
    map.flyTo({ center: [lon, lat], zoom: 17, duration: 900 });
  }));
}

function setupReactions(el) {
  let pressTimer = 0;
  let target = null;
  const picker = el.querySelector("#reactPicker");
  const list = el.querySelector("#roomList");
  list.addEventListener("pointerdown", (e) => {
    const msg = e.target.closest("[data-msg]");
    if (!msg) return;
    clearTimeout(pressTimer);
    pressTimer = setTimeout(() => {
      target = msg.dataset.msg;
      const rect = msg.querySelector(".bubble").getBoundingClientRect();
      picker.style.top = `${Math.max(70, rect.top - 58)}px`;
      picker.classList.remove("hidden");
      vibrate(20);
    }, 450);
  });
  ["pointerup", "pointercancel", "pointermove"].forEach((t) => list.addEventListener(t, (e) => {
    if (t === "pointermove" && Math.abs(e.movementY) < 3) return;
    clearTimeout(pressTimer);
  }));
  list.addEventListener("contextmenu", (e) => e.preventDefault());
  el.addEventListener("click", async (e) => {
    const b = e.target.closest("[data-react]");
    if (!b) {
      if (!e.target.closest("#reactPicker")) picker.classList.add("hidden");
      return;
    }
    picker.classList.add("hidden");
    const m = room?.messages.find((x) => x.id === target);
    if (!m) return;
    const emoji = b.dataset.react;
    m.reactions = m.reactions || [];
    const add = !m.reactions.some((r) => r.emoji === emoji && r.user_id === state.me.id);
    if (add) m.reactions.push({ emoji, user_id: state.me.id });
    else m.reactions = m.reactions.filter((r) => !(r.emoji === emoji && r.user_id === state.me.id));
    room.key = "";
    renderRoom(false);
    try { await invoke("chat_reaction", { messageId: m.id, emoji, add }); } catch (err) { toast(errorText(err)); }
  });
}

async function sendMessage(args) {
  const r = room;
  if (!r) return;
  try {
    const row = await invoke("send_message", {
      threadId: r.id, kind: "text", body: "", photo: null, attachmentBucket: null, attachmentPath: null,
      refId: null, placeName: null, lat: null, lon: null, etaMinutes: null, ...args,
    });
    if (room === r && row?.id) {
      r.messages.push(row);
      r.key = "";
      renderRoom(true);
    }
  } catch (err) { toast(errorText(err)); }
}

function sendText() {
  const input = $("roomText");
  const body = input.value.trim();
  if (!body) return;
  input.value = "";
  vibrate(10);
  sendMessage({ kind: "text", body });
}

async function sendLocation() {
  const pos = (await currentPosition()) || state.myPos;
  if (!pos) return toast("Posizione non disponibile.");
  const place = placeInside(pos)[0];
  sendMessage({ kind: "location", lat: pos.lat, lon: pos.lon, placeName: place ? `${place.emoji} ${place.name}` : null });
}

$("chatPhotoInput").addEventListener("change", async (e) => {
  const file = e.target.files?.[0];
  e.target.value = "";
  if (!file || !room) return;
  try {
    const photo = await processImage(file);
    toast("Invio la foto…");
    await sendMessage({ kind: "photo", photo: photo.full });
  } catch (_) { toast("Impossibile leggere la foto."); }
});

// ───────────── Stories: bar ─────────────

async function loadStories() {
  if (!state.me) return;
  try { state.stories = (await invoke("fetch_stories")) || []; } catch (_) { return; }
  renderStoriesBar();
}

function isStorySeen(s) {
  return s.author?.id === state.me.id || state.seenStories.has(s.id) || (s.views || []).some((v) => v.viewer_id === state.me.id);
}

/** One ring per person: you first, then unseen, then most recent. */
function storyRings() {
  const byAuthor = new Map();
  for (const s of state.stories) {
    if (!s.author) continue;
    if (!byAuthor.has(s.author.id)) byAuthor.set(s.author.id, { author: s.author, stories: [] });
    byAuthor.get(s.author.id).stories.push(s);
  }
  const rings = [...byAuthor.values()].map((r) => ({
    ...r,
    mine: r.author.id === state.me.id,
    seen: r.stories.every(isStorySeen),
    latest: Math.max(...r.stories.map((s) => new Date(s.created_at).getTime())),
  }));
  rings.sort((a, b) => (b.mine - a.mine) || (a.seen - b.seen) || (b.latest - a.latest));
  return rings;
}

function renderStoriesBar() {
  const bar = $("storiesBar");
  const rings = storyRings();
  const mine = rings.find((r) => r.mine);
  const others = rings.filter((r) => !r.mine);
  bar.innerHTML = `<button class="story-ring mine${mine ? "" : " empty"}" data-ring="me">${avatarHTML(state.me)}${mine ? "" : '<span class="plus">+</span>'}</button>`
    + others.map((r) => `<button class="story-ring${r.seen ? " seen" : ""}" data-ring="${r.author.id}">${avatarHTML(r.author)}</button>`).join("");
  bar.onclick = (e) => {
    const b = e.target.closest("[data-ring]");
    if (!b) return;
    vibrate(10);
    if (b.dataset.ring === "me") {
      if (!mine) return openCamera("story");
      return openStoryViewer(rings, 0);
    }
    openStoryViewer(rings, rings.findIndex((r) => r.author.id === b.dataset.ring));
  };
  // Long press on your ring: new story.
  const meBtn = bar.querySelector('[data-ring="me"]');
  let t = 0;
  meBtn.addEventListener("pointerdown", () => { t = setTimeout(() => { t = -1; openCamera("story"); }, 500); });
  meBtn.addEventListener("pointerup", (e) => { if (t === -1) e.preventDefault(); clearTimeout(t); });
  meBtn.addEventListener("pointerleave", () => clearTimeout(t));
}

// ───────────── Stories: viewer ─────────────

let viewer = null;
const PHOTO_STORY_MS = 5000;

function openStoryViewer(rings, ringIndex) {
  if (ringIndex < 0 || !rings[ringIndex]) return;
  closeStoryViewer();
  viewer = { rings, ring: ringIndex, index: 0, startedAt: 0, elapsed: 0, duration: PHOTO_STORY_MS, paused: false, frame: 0, token: 0 };
  const r = rings[ringIndex];
  const firstUnseen = r.stories.findIndex((s) => !isStorySeen(s));
  viewer.index = r.mine || firstUnseen < 0 ? 0 : firstUnseen;
  const el = $("storyViewer");
  el.innerHTML = `<div class="sv-stage">
      <div class="sv-media"></div>
      <div class="sv-bars"></div>
      <div class="sv-head"><div class="author"></div><button class="close-x dark" data-act="close">${ICON.x}</button></div>
      <div class="sv-heart hidden">❤️</div>
      <div class="sv-panel hidden"></div>
    </div>
    <div class="sv-foot"></div>`;
  openOverlay("storyViewer");
  el.querySelector('[data-act="close"]').addEventListener("click", leaveOverlay);
  setupViewerGestures(el);
  showStory();
  const tick = () => {
    if (!viewer) return;
    if (!viewer.paused && viewer.startedAt) {
      const now = performance.now();
      viewer.elapsed += now - viewer.startedAt;
      viewer.startedAt = now;
      const fill = el.querySelectorAll(".sv-bars i")[viewer.index];
      if (fill) fill.style.width = `${Math.min(100, (viewer.elapsed / viewer.duration) * 100)}%`;
      if (viewer.elapsed >= viewer.duration) nextStory();
    } else if (viewer.startedAt) {
      viewer.startedAt = performance.now();
    }
    viewer && (viewer.frame = requestAnimationFrame(tick));
  };
  viewer.frame = requestAnimationFrame(tick);
}

function closeStoryViewer() {
  if (!viewer) return;
  cancelAnimationFrame(viewer.frame);
  $("storyViewer").querySelectorAll("video").forEach((v) => v.pause());
  viewer = null;
  $("storyViewer").classList.add("hidden");
  $("storyViewer").innerHTML = "";
  renderStoriesBar();
}

function currentStory() {
  return viewer && viewer.rings[viewer.ring].stories[viewer.index];
}

async function showStory() {
  const v = viewer;
  const story = currentStory();
  if (!v || !story) return;
  const token = ++v.token;
  const r = v.rings[v.ring];
  const el = $("storyViewer");
  v.elapsed = 0;
  v.startedAt = 0;
  v.duration = PHOTO_STORY_MS;
  el.querySelector(".sv-panel").classList.add("hidden");
  el.querySelector(".sv-bars").innerHTML = r.stories.map((_, i) => `<span><i style="width:${i < v.index ? 100 : 0}%"></i></span>`).join("");
  el.querySelector(".sv-head .author").innerHTML = `${avatarHTML(r.author)}<div>${esc(r.mine ? "La tua storia" : r.author.display_name)}<small>${esc(ago(story.created_at))}${story.location_tag ? " · 📍 " + esc(story.location_tag) : ""}</small></div>`;
  const foot = el.querySelector(".sv-foot");
  if (r.mine) {
    const views = (story.views || []).filter((x) => x.viewer_id !== state.me.id);
    foot.innerHTML = `<button class="sv-btn" data-act="viewers">👁 ${views.length} ${views.length === 1 ? "visualizzazione" : "visualizzazioni"}</button><div class="grow"></div><button class="sv-btn" data-act="new">＋</button><button class="sv-btn" data-act="delete">🗑</button>`;
    foot.querySelector('[data-act="viewers"]').onclick = () => showViewersPanel(story);
    foot.querySelector('[data-act="new"]').onclick = () => { leaveOverlay(); setTimeout(() => openCamera("story"), 300); };
    foot.querySelector('[data-act="delete"]').onclick = () => deleteStory(story);
  } else {
    const liked = (story.views || []).some((x) => x.viewer_id === state.me.id && x.liked);
    foot.innerHTML = `<div class="reply-bar dark"><input id="storyReply" type="text" maxlength="500" placeholder="Rispondi a ${esc(firstName(r.author))}…"><button class="send" data-act="reply">${ICON.send}</button></div><button class="sv-like${liked ? " on" : ""}" data-act="like">${liked ? "❤️" : "🤍"}</button>`;
    const input = foot.querySelector("#storyReply");
    input.addEventListener("focus", () => { if (viewer) viewer.paused = true; });
    input.addEventListener("blur", () => { if (viewer) viewer.paused = false; });
    const send = async () => {
      const text = input.value.trim();
      if (!text) return;
      input.value = "";
      input.blur();
      try {
        const thread = await invoke("open_direct_chat", { friend: r.author.id });
        await invoke("send_message", {
          threadId: thread, kind: "story_reply", body: text, photo: null,
          attachmentBucket: "stories", attachmentPath: story.image_path, refId: story.id,
          placeName: null, lat: null, lon: null, etaMinutes: null,
        });
        toast(`Risposta inviata a ${firstName(r.author)} 💬`);
        loadThreads();
      } catch (err) { toast(errorText(err)); }
    };
    foot.querySelector('[data-act="reply"]').onclick = send;
    input.addEventListener("keydown", (e) => { if (e.key === "Enter") send(); });
    foot.querySelector('[data-act="like"]').onclick = (e) => likeStory(story, e.currentTarget);
    markStorySeen(story, liked);
  }
  // Media
  const media = el.querySelector(".sv-media");
  media.innerHTML = `<div class="sv-loading"></div>`;
  const urls = await signed("stories", [story.image_path, story.video_path].filter(Boolean));
  if (!viewer || viewer.token !== token) return;
  const img = urls[story.image_path];
  if (story.video_path && urls[story.video_path]) {
    media.innerHTML = `<video src="${esc(urls[story.video_path])}" poster="${esc(img || "")}" playsinline autoplay></video>`;
    const video = media.querySelector("video");
    video.addEventListener("loadedmetadata", () => {
      if (viewer?.token === token && isFinite(video.duration) && video.duration > 0) viewer.duration = Math.min(15, video.duration) * 1000;
    });
    video.addEventListener("playing", () => { if (viewer?.token === token && !viewer.startedAt) viewer.startedAt = performance.now(); });
    video.play().catch(() => { video.muted = true; video.play().catch(() => {}); });
    setTimeout(() => { if (viewer?.token === token && !viewer.startedAt) viewer.startedAt = performance.now(); }, 4000);
  } else {
    media.innerHTML = img ? `<img src="${esc(img)}">` : "";
    const image = media.querySelector("img");
    const go = () => { if (viewer?.token === token) viewer.startedAt = performance.now(); };
    if (image && !image.complete) { image.onload = go; image.onerror = go; } else go();
  }
  if (story.overlay_text) {
    media.insertAdjacentHTML("beforeend", `<div class="sv-overlay" style="top:${(story.overlay_y ?? 0.75) * 100}%">${esc(story.overlay_text)}</div>`);
  }
}

function markStorySeen(story, liked) {
  if (state.seenStories.has(story.id)) return;
  state.seenStories.add(story.id);
  localStorage.setItem("seenStories", JSON.stringify([...state.seenStories].slice(-400)));
  invoke("mark_story_viewed", { storyId: story.id, liked }).catch(() => {});
}

async function likeStory(story, btn) {
  story.views = story.views || [];
  let mine = story.views.find((x) => x.viewer_id === state.me.id);
  if (!mine) { mine = { viewer_id: state.me.id, liked: false }; story.views.push(mine); }
  mine.liked = !mine.liked;
  btn.classList.toggle("on", mine.liked);
  btn.textContent = mine.liked ? "❤️" : "🤍";
  vibrate(mine.liked ? [15, 40, 15] : 10);
  if (mine.liked) {
    const heart = $("storyViewer").querySelector(".sv-heart");
    heart.classList.remove("hidden", "pop");
    void heart.offsetWidth;
    heart.classList.add("pop");
    setTimeout(() => heart.classList.add("hidden"), 900);
  }
  try { await invoke("mark_story_viewed", { storyId: story.id, liked: mine.liked }); } catch (err) { toast(errorText(err)); }
}

function showViewersPanel(story) {
  const panel = $("storyViewer").querySelector(".sv-panel");
  const views = (story.views || []).filter((x) => x.viewer_id !== state.me.id).sort((a, b) => new Date(b.viewed_at) - new Date(a.viewed_at));
  viewer.paused = true;
  panel.innerHTML = `<div class="sheet-head"><h2>👁 ${views.length}</h2><button class="close-x" data-act="x">${ICON.x}</button></div>
    ${views.map((x) => `<div class="person">${avatarHTML(x.viewer)}<div class="info"><b>${esc(x.viewer?.display_name || "")}</b><span>${esc(ago(x.viewed_at))}</span></div>${x.liked ? "❤️" : ""}</div>`).join("") || `<p class="muted small">Ancora nessuno l'ha vista.</p>`}`;
  panel.classList.remove("hidden");
  panel.querySelector('[data-act="x"]').onclick = (e) => { e.stopPropagation(); panel.classList.add("hidden"); if (viewer) viewer.paused = false; };
}

async function deleteStory(story) {
  viewer.paused = true;
  if (!confirm("Eliminare questa storia?")) { viewer.paused = false; return; }
  try {
    await invoke("delete_story", { id: story.id, paths: [story.image_path, story.video_path].filter(Boolean) });
    state.stories = state.stories.filter((s) => s.id !== story.id);
    const r = viewer.rings[viewer.ring];
    r.stories = r.stories.filter((s) => s.id !== story.id);
    if (!r.stories.length) return leaveOverlay();
    viewer.index = Math.min(viewer.index, r.stories.length - 1);
    viewer.paused = false;
    showStory();
  } catch (err) {
    viewer.paused = false;
    toast(errorText(err));
  }
}

function nextStory() {
  const v = viewer;
  if (!v) return;
  const r = v.rings[v.ring];
  if (v.index < r.stories.length - 1) { v.index++; return showStory(); }
  if (v.ring < v.rings.length - 1) {
    v.ring++;
    const next = v.rings[v.ring];
    const firstUnseen = next.stories.findIndex((s) => !isStorySeen(s));
    v.index = firstUnseen < 0 ? 0 : firstUnseen;
    return showStory();
  }
  leaveOverlay();
}
function prevStory() {
  const v = viewer;
  if (!v) return;
  if (v.index > 0) { v.index--; return showStory(); }
  if (v.ring > 0) { v.ring--; v.index = 0; return showStory(); }
  showStory();
}

function setupViewerGestures(el) {
  const stage = el.querySelector(".sv-stage");
  let down = null;
  stage.addEventListener("pointerdown", (e) => {
    if (e.target.closest("button, .sv-panel, input")) return;
    down = { x: e.clientX, y: e.clientY, t: Date.now() };
    if (viewer) viewer.paused = true;
    el.querySelector("video")?.pause();
  });
  stage.addEventListener("pointerup", (e) => {
    if (!down || !viewer) return;
    const dx = e.clientX - down.x, dy = e.clientY - down.y, held = Date.now() - down.t;
    down = null;
    if (!el.querySelector(".sv-panel").classList.contains("hidden")) return;
    viewer.paused = false;
    el.querySelector("video")?.play().catch(() => {});
    if (dy > 90 && Math.abs(dy) > Math.abs(dx)) return leaveOverlay();
    if (held > 260 || Math.abs(dx) > 30) {
      if (dx < -60) nextStory();
      else if (dx > 60) prevStory();
      return;
    }
    if (e.clientX < stage.clientWidth * 0.3) prevStory();
    else nextStory();
  });
  stage.addEventListener("pointercancel", () => { down = null; if (viewer) viewer.paused = false; });
}

// ───────────── Stories: editor ─────────────

const STORY_EFFECTS = [
  { name: "Originale", filter: "none", tint: null },
  { name: "Vivido", filter: "saturate(1.6) contrast(1.1)", tint: null },
  { name: "Tramonto", filter: "sepia(.3) saturate(1.5) hue-rotate(-12deg)", tint: "rgba(255,110,60,.18)" },
  { name: "Ghiaccio", filter: "brightness(1.06) saturate(.85) contrast(1.05)", tint: "rgba(70,160,255,.2)" },
  { name: "Neon", filter: "saturate(2.1) contrast(1.25) hue-rotate(18deg)", tint: "rgba(168,85,247,.18)" },
  { name: "Sogno", filter: "brightness(1.12) saturate(1.25) blur(.6px)", tint: "rgba(255,170,225,.2)" },
  { name: "Glitch", filter: "contrast(1.45) saturate(1.9) hue-rotate(95deg)", tint: null },
  { name: "Pellicola", filter: "contrast(1.15) saturate(.8) sepia(.18)", tint: "rgba(255,228,170,.12)" },
  { name: "Vintage", filter: "sepia(.6) contrast(.95) brightness(1.06)", tint: "rgba(120,70,20,.1)" },
  { name: "Noir", filter: "grayscale(1) contrast(1.35)", tint: null },
];
const TEXT_STYLES = ["classic", "box", "neon", "type"];
const TEXT_STYLE_NAMES = { classic: "Classico", box: "Riquadro", neon: "Neon", type: "Macchina" };
const TEXT_COLORS = ["#ffffff", "#18181b", "#a855f7", "#10b981", "#f59e0b", "#ef4444", "#3b82f6", "#f472b6"];

let editor = null;

function openStoryEditor(shot) {
  closeStoryEditor();
  editor = { shot, effect: 0, layers: [], nextId: 1, url: shot.video ? URL.createObjectURL(shot.video) : null, busy: false };
  const el = $("storyEditor");
  el.innerHTML = `<div class="se-top">
      <button class="fab glass" data-act="close" aria-label="Chiudi">${ICON.x}</button>
      <div class="grow"></div>
      <button class="fab glass tool" data-act="text">Aa</button>
      <button class="fab glass tool" data-act="place">📍</button>
      <button class="fab glass tool" data-act="time">🕒</button>
    </div>
    <div class="se-wrap"><div class="se-stage">
      <div class="se-media">${shot.video ? `<video src="${editor.url}" autoplay loop playsinline></video>` : ""}</div>
      <div class="se-tint"></div>
      <div class="se-layers"></div>
      <div class="se-effect-name hidden"></div>
      <div class="se-trash hidden">🗑</div>
    </div></div>
    <div class="se-effects">${STORY_EFFECTS.map((f, i) => `<button data-effect="${i}" class="${i === 0 ? "on" : ""}">${f.name}</button>`).join("")}</div>
    <div class="se-bottom"><button class="primary" data-act="publish">✨ Pubblica la storia</button></div>
    <div class="se-text hidden"></div>`;
  if (!shot.video) {
    const c = shot.canvas;
    c.className = "";
    el.querySelector(".se-media").appendChild(c);
  }
  openOverlay("storyEditor");
  fitEditor();
  el.querySelector('[data-act="close"]').addEventListener("click", leaveOverlay);
  el.querySelector('[data-act="text"]').addEventListener("click", () => editText(null));
  el.querySelector('[data-act="place"]').addEventListener("click", addPlaceSticker);
  el.querySelector('[data-act="time"]').addEventListener("click", () => addLayer({ kind: "sticker", text: `🕒 ${new Date().toLocaleTimeString("it-IT", { hour: "2-digit", minute: "2-digit" })}`, style: "sticker", color: "#18181b" }));
  el.querySelector(".se-effects").addEventListener("click", (e) => {
    const b = e.target.closest("[data-effect]");
    if (b) setEffect(Number(b.dataset.effect));
  });
  el.querySelector('[data-act="publish"]').addEventListener("click", publishStory);
  setupEditorGestures(el);
  applyEffect();
}

function fitEditor() {
  const el = $("storyEditor");
  const wrap = el.querySelector(".se-wrap");
  const stage = el.querySelector(".se-stage");
  if (!wrap || !stage) return;
  const w = Math.min(wrap.clientWidth, wrap.clientHeight * 9 / 16);
  stage.style.width = `${Math.round(w)}px`;
  stage.style.height = `${Math.round(w * 16 / 9)}px`;
}
window.addEventListener("resize", () => { if (editor) fitEditor(); });

function closeStoryEditor() {
  if (!editor) return;
  if (editor.url) URL.revokeObjectURL(editor.url);
  editor = null;
  $("storyEditor").querySelectorAll("video").forEach((v) => v.pause());
  $("storyEditor").classList.add("hidden");
  $("storyEditor").innerHTML = "";
}

function setEffect(i) {
  if (!editor) return;
  editor.effect = (i + STORY_EFFECTS.length) % STORY_EFFECTS.length;
  vibrate(10);
  applyEffect();
  const name = $("storyEditor").querySelector(".se-effect-name");
  name.textContent = STORY_EFFECTS[editor.effect].name;
  name.classList.remove("hidden", "show");
  void name.offsetWidth;
  name.classList.add("show");
  $("storyEditor").querySelector(`[data-effect="${editor.effect}"]`)?.scrollIntoView({ inline: "center", behavior: "smooth", block: "nearest" });
}

function applyEffect() {
  const el = $("storyEditor");
  const fx = STORY_EFFECTS[editor.effect];
  el.querySelector(".se-media").style.filter = fx.filter;
  el.querySelector(".se-tint").style.background = fx.tint || "transparent";
  el.querySelectorAll("[data-effect]").forEach((b) => b.classList.toggle("on", Number(b.dataset.effect) === editor.effect));
}

function addLayer(layer) {
  if (!editor) return;
  editor.layers.push({ id: editor.nextId++, x: 0.5, y: 0.42 + 0.06 * (editor.layers.length % 4), scale: 1, rot: 0, ...layer });
  vibrate(10);
  renderLayers();
}

async function addPlaceSticker() {
  if (editor.layers.some((l) => l.kind === "place")) return toast("Hai già lo sticker del luogo.");
  const pos = state.myPos || (await currentPosition());
  let name = pos ? placeInside(pos)[0]?.name : null;
  if (!name && pos) {
    try {
      const res = await fetch(`https://nominatim.openstreetmap.org/reverse?format=jsonv2&zoom=16&accept-language=it&lat=${pos.lat}&lon=${pos.lon}`);
      const data = await res.json();
      const a = data.address || {};
      name = a.neighbourhood || a.suburb || a.road || a.village || a.town || a.city || data.name;
      const city = a.city || a.town || a.village;
      if (name && city && name !== city) name = `${name}, ${city}`;
    } catch (_) {}
  }
  if (!editor) return;
  addLayer({ kind: "place", text: `📍 ${name || "Qui"}`, style: "sticker", color: "#18181b" });
}

function layerHTML(l) {
  const cls = l.kind === "text" ? `text ${l.style}` : "sticker";
  const style = l.kind === "text"
    ? (l.style === "box" ? `background:${l.color};color:${contrastInk(l.color)}` : l.style === "neon" ? `color:${l.color};text-shadow:0 0 6px ${l.color},0 0 18px ${l.color}` : l.style === "type" ? `color:${l.color}` : `color:${l.color}`)
    : "";
  return `<div class="layer ${cls}" data-id="${l.id}" style="left:${l.x * 100}%;top:${l.y * 100}%;transform:translate(-50%,-50%) rotate(${l.rot}rad) scale(${l.scale})"><div class="ink" style="${style}">${esc(l.text)}</div></div>`;
}

function renderLayers() {
  const box = $("storyEditor").querySelector(".se-layers");
  if (box) box.innerHTML = editor.layers.map(layerHTML).join("");
}

function contrastInk(hex) {
  const n = parseInt(hex.slice(1), 16);
  const lum = (0.299 * ((n >> 16) & 255) + 0.587 * ((n >> 8) & 255) + 0.114 * (n & 255)) / 255;
  return lum > 0.6 ? "#18181b" : "#ffffff";
}

function editText(layer) {
  const el = $("storyEditor");
  const panel = el.querySelector(".se-text");
  let style = layer?.style || "classic";
  let color = layer?.color || "#ffffff";
  panel.innerHTML = `<div class="se-text-top"><button class="mini-btn" data-act="style"></button><div class="grow"></div><button class="mini-btn strong" data-act="done">Fatto</button></div>
    <textarea id="seTextInput" maxlength="120" placeholder="Scrivi qualcosa…"></textarea>
    <div class="se-colors">${TEXT_COLORS.map((c) => `<button data-color="${c}" style="background:${c}"></button>`).join("")}</div>`;
  panel.classList.remove("hidden");
  const input = panel.querySelector("#seTextInput");
  input.value = layer?.text || "";
  const sync = () => {
    panel.querySelector('[data-act="style"]').textContent = `Aa · ${TEXT_STYLE_NAMES[style]}`;
    panel.querySelectorAll("[data-color]").forEach((b) => b.classList.toggle("on", b.dataset.color === color));
    input.className = `se-input ${style}`;
    input.style.color = style === "box" ? contrastInk(color) : color;
    input.style.background = style === "box" ? color : "transparent";
  };
  sync();
  setTimeout(() => input.focus(), 50);
  panel.querySelector('[data-act="style"]').onclick = () => { style = TEXT_STYLES[(TEXT_STYLES.indexOf(style) + 1) % TEXT_STYLES.length]; sync(); };
  panel.querySelector(".se-colors").onclick = (e) => { const b = e.target.closest("[data-color]"); if (b) { color = b.dataset.color; sync(); } };
  panel.querySelector('[data-act="done"]').onclick = () => {
    const text = input.value.trim();
    panel.classList.add("hidden");
    if (layer) {
      if (!text) editor.layers = editor.layers.filter((l) => l !== layer);
      else Object.assign(layer, { text, style, color });
      renderLayers();
    } else if (text) {
      addLayer({ kind: "text", text, style, color });
    }
  };
}

function setupEditorGestures(el) {
  const stage = el.querySelector(".se-stage");
  const trash = el.querySelector(".se-trash");
  const pointers = new Map();
  let g = null;
  const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);
  const angle = (a, b) => Math.atan2(b.y - a.y, b.x - a.x);
  stage.addEventListener("pointerdown", (e) => {
    try { stage.setPointerCapture(e.pointerId); } catch (_) {}
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pointers.size === 1) {
      const node = e.target.closest(".layer");
      const layer = node && editor.layers.find((l) => l.id === Number(node.dataset.id));
      g = { layer, start: { x: e.clientX, y: e.clientY }, base: layer ? { x: layer.x, y: layer.y } : null, moved: false };
      if (layer) { editor.layers = editor.layers.filter((l) => l !== layer).concat(layer); renderLayers(); }
    } else if (pointers.size === 2 && g?.layer) {
      const [a, b] = [...pointers.values()];
      g.pinch = { d: dist(a, b), a: angle(a, b), scale: g.layer.scale, rot: g.layer.rot };
      g.moved = true;
    }
  });
  stage.addEventListener("pointermove", (e) => {
    if (!pointers.has(e.pointerId) || !g) return;
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (!g.layer) return;
    const rect = stage.getBoundingClientRect();
    if (g.pinch && pointers.size >= 2) {
      const [a, b] = [...pointers.values()];
      g.layer.scale = Math.max(0.4, Math.min(5, g.pinch.scale * dist(a, b) / g.pinch.d));
      g.layer.rot = g.pinch.rot + angle(a, b) - g.pinch.a;
    } else if (!g.pinch) {
      const dx = e.clientX - g.start.x, dy = e.clientY - g.start.y;
      if (Math.hypot(dx, dy) > 6) g.moved = true;
      g.layer.x = Math.max(0.03, Math.min(0.97, g.base.x + dx / rect.width));
      g.layer.y = Math.max(0.03, Math.min(0.97, g.base.y + dy / rect.height));
      trash.classList.toggle("hidden", !g.moved);
      const t = trash.getBoundingClientRect();
      g.overTrash = Math.hypot(e.clientX - (t.left + t.width / 2), e.clientY - (t.top + t.height / 2)) < 60;
      trash.classList.toggle("hot", !!g.overTrash);
    }
    const node = stage.querySelector(`.layer[data-id="${g.layer.id}"]`);
    if (node) {
      node.style.left = `${g.layer.x * 100}%`;
      node.style.top = `${g.layer.y * 100}%`;
      node.style.transform = `translate(-50%,-50%) rotate(${g.layer.rot}rad) scale(${g.layer.scale})`;
      node.classList.toggle("doomed", !!g.overTrash);
    }
  });
  const end = (e) => {
    pointers.delete(e.pointerId);
    if (!g) return;
    if (pointers.size > 0) {
      // Lifting one of two fingers: keep moving with the other one.
      if (g.layer && g.pinch) {
        const [p] = [...pointers.values()];
        g.pinch = null;
        g.start = { x: p.x, y: p.y };
        g.base = { x: g.layer.x, y: g.layer.y };
      }
      return;
    }
    const dx = e.clientX - g.start.x, dy = e.clientY - g.start.y;
    if (g.layer) {
      if (g.overTrash) {
        editor.layers = editor.layers.filter((l) => l !== g.layer);
        vibrate(30);
        renderLayers();
      } else if (!g.moved && g.layer.kind === "text") {
        editText(g.layer);
      }
    } else if (Math.abs(dx) > 50 && Math.abs(dx) > Math.abs(dy)) {
      setEffect(editor.effect + (dx < 0 ? 1 : -1));
    }
    trash.classList.add("hidden");
    trash.classList.remove("hot");
    g = null;
  };
  stage.addEventListener("pointerup", end);
  stage.addEventListener("pointercancel", end);
}

/** Draws the texts and stickers on a W×H canvas, matching what the editor shows. */
function drawLayers(ctx, W, H) {
  const stage = $("storyEditor").querySelector(".se-stage");
  const k = W / (stage?.clientWidth || 360);
  for (const l of editor.layers) {
    ctx.save();
    ctx.translate(l.x * W, l.y * H);
    ctx.rotate(l.rot);
    ctx.scale(l.scale * k, l.scale * k);
    const sticker = l.kind !== "text";
    const style = sticker ? "sticker" : l.style;
    const size = style === "neon" ? 32 : style === "type" ? 24 : style === "sticker" ? 20 : 30;
    const family = style === "type" ? "'Courier New', monospace" : "'Google Sans', Roboto, system-ui, sans-serif";
    ctx.font = `${style === "type" ? 700 : 800} ${size}px ${family}`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    const lines = l.text.split("\n");
    const lh = size * 1.22;
    const width = Math.max(...lines.map((t) => ctx.measureText(t).width));
    const height = lines.length * lh;
    if (style === "box" || style === "sticker" || style === "type") {
      const padX = style === "sticker" ? 14 : 14, padY = style === "sticker" ? 9 : 8;
      ctx.fillStyle = style === "box" ? l.color : style === "type" ? "rgba(0,0,0,.55)" : "rgba(255,255,255,.95)";
      roundRect(ctx, -width / 2 - padX, -height / 2 - padY, width + padX * 2, height + padY * 2, style === "sticker" ? (height + padY * 2) / 2 : 12);
      ctx.fill();
    }
    ctx.fillStyle = style === "box" ? contrastInk(l.color) : style === "sticker" ? "#18181b" : l.color;
    if (style === "classic") { ctx.shadowColor = "rgba(0,0,0,.45)"; ctx.shadowBlur = 8; ctx.shadowOffsetY = 2; }
    if (style === "neon") { ctx.shadowColor = l.color; ctx.shadowBlur = 18; }
    lines.forEach((t, i) => {
      const y = -height / 2 + lh * (i + 0.5);
      ctx.fillText(t, 0, y);
      if (style === "neon") ctx.fillText(t, 0, y);
    });
    ctx.restore();
  }
}

function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

/** One finished frame: the source cropped to 9:16, the effect, then texts and stickers. */
function composeFrame(ctx, source, sw, sh, W, H, overlay) {
  const fx = STORY_EFFECTS[editor.effect];
  const scale = Math.max(W / sw, H / sh);
  const cw = W / scale, ch = H / scale;
  ctx.filter = fx.filter;
  ctx.drawImage(source, (sw - cw) / 2, (sh - ch) / 2, cw, ch, 0, 0, W, H);
  ctx.filter = "none";
  if (fx.tint) { ctx.fillStyle = fx.tint; ctx.fillRect(0, 0, W, H); }
  if (overlay) ctx.drawImage(overlay, 0, 0, W, H);
}

function overlayCanvas(W, H) {
  if (!editor.layers.length) return null;
  const c = document.createElement("canvas");
  c.width = W;
  c.height = H;
  drawLayers(c.getContext("2d"), W, H);
  return c;
}

async function publishStory(e) {
  if (!editor || editor.busy) return;
  const btn = e.currentTarget;
  editor.busy = true;
  btn.disabled = true;
  btn.textContent = editor.shot.video ? "Preparo il video…" : "Pubblico…";
  const ed = editor;
  try {
    const W = 1080, H = 1920;
    const poster = document.createElement("canvas");
    poster.width = W;
    poster.height = H;
    const src = ed.shot.canvas;
    composeFrame(poster.getContext("2d"), src, src.width, src.height, W, H, overlayCanvas(W, H));
    const photo = poster.toDataURL("image/jpeg", 0.86).split(",")[1];
    let video = null;
    if (ed.shot.video) {
      const plain = ed.effect === 0 && !ed.layers.length;
      const blob = plain ? ed.shot.video : await renderStoryVideo(ed, (p) => { btn.textContent = `Preparo il video… ${Math.round(p * 100)}%`; });
      btn.textContent = "Pubblico…";
      video = await blobB64(blob);
    }
    const place = ed.layers.find((l) => l.kind === "place");
    const story = await invoke("publish_story", {
      photo, video, overlayText: "", overlayY: 0.75,
      locationTag: place ? place.text.replace(/^📍\s*/, "") : null,
    });
    if (story?.id) state.stories.push(story);
    leaveOverlay();
    renderStoriesBar();
    celebrate("✨");
    toast("Storia pubblicata per 24 ore ✨");
    loadStories();
  } catch (err) {
    if (editor === ed) {
      ed.busy = false;
      btn.disabled = false;
      btn.textContent = "✨ Pubblica la storia";
    }
    toast(errorText(err));
  }
}

/** Plays the clip once into a canvas with the effect and the layers, recording it again as MP4 (with its sound). */
function renderStoryVideo(ed, progress) {
  return new Promise((resolve, reject) => {
    const W = 720, H = 1280;
    const canvas = document.createElement("canvas");
    canvas.width = W;
    canvas.height = H;
    const ctx = canvas.getContext("2d");
    const overlay = overlayCanvas(W, H);
    const video = document.createElement("video");
    video.src = ed.url;
    video.playsInline = true;
    video.preload = "auto";
    let audioCtx = null;
    const out = canvas.captureStream(30);
    try {
      audioCtx = new AudioContext();
      const source = audioCtx.createMediaElementSource(video);
      const dest = audioCtx.createMediaStreamDestination();
      source.connect(dest);
      dest.stream.getAudioTracks().forEach((t) => out.addTrack(t));
    } catch (_) {}
    let recorder;
    try {
      recorder = new MediaRecorder(out, { mimeType: videoMime(), videoBitsPerSecond: 3000000, audioBitsPerSecond: 96000 });
    } catch (err) { return reject(err); }
    const chunks = [];
    recorder.ondataavailable = (e) => { if (e.data && e.data.size) chunks.push(e.data); };
    recorder.onstop = () => {
      audioCtx?.close().catch(() => {});
      resolve(new Blob(chunks, { type: "video/mp4" }));
    };
    let frame = 0;
    const draw = () => {
      if (video.videoWidth) composeFrame(ctx, video, video.videoWidth, video.videoHeight, W, H, overlay);
      if (isFinite(video.duration) && video.duration > 0) progress(Math.min(1, video.currentTime / video.duration));
      frame = requestAnimationFrame(draw);
    };
    video.onended = () => { cancelAnimationFrame(frame); setTimeout(() => recorder.state !== "inactive" && recorder.stop(), 120); };
    video.onerror = () => { cancelAnimationFrame(frame); reject(new Error("Impossibile preparare il video.")); };
    video.oncanplay = () => {
      video.oncanplay = null;
      draw();
      recorder.start(250);
      video.play().catch((err) => { cancelAnimationFrame(frame); reject(err); });
    };
    video.load();
  });
}
