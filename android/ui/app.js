// PinDrop Android UI. Every network call goes through the Rust commands (src-tauri/src/lib.rs).
"use strict";

const SUPABASE_URL = "https://tqtpkdxeedcjmlhabimg.supabase.co";
const REACTIONS = ["🔥", "😍", "😂", "👀", "🫶"];
const TOGETHER_M = 35;

const tauri = window.__TAURI__;
const invoke = (cmd, args) => tauri.core.invoke(cmd, args || {});

const $ = (id) => document.getElementById(id);
const state = {
  me: null,            // my profile
  pins: [],
  friends: [],         // accepted friend profiles
  requests: [],        // incoming pending { id, profile }
  sent: [],            // outgoing pending profiles
  locations: [],
  online: new Set(),
  myPos: null,         // { lat, lon }
  locationGranted: false,
  urls: {},            // path -> { url, until }
  photo: null,         // processed image waiting to be published
  centered: false,
};

let map, meLayer, pinLayer, friendLayer;

// ───────────── Helpers ─────────────

function esc(text) {
  return String(text ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function errorText(error) {
  const msg = String(error?.message || error || "");
  const lower = msg.toLowerCase();
  if (lower.includes("invalid login")) return "Email o password errati.";
  if (lower.includes("not confirmed")) return "Conferma prima l'email che ti abbiamo inviato.";
  if (lower.includes("already registered")) return "Questa email è già registrata.";
  if (lower.includes("password should be") || lower.includes("at least 6")) return "La password deve avere almeno 6 caratteri.";
  if (lower.includes("duplicate") && lower.includes("username")) return "Username già preso.";
  if (lower.includes("username")) return "Username non valido: 3–24 caratteri, lettere minuscole, numeri, punto e _.";
  if (lower === "offline") return "Nessuna connessione a internet.";
  if (lower === "not_signed_in") return "Sessione scaduta, accedi di nuovo.";
  if (lower.includes("rate limit")) return "Troppi tentativi, riprova tra poco.";
  return msg || "Qualcosa è andato storto.";
}

let toastTimer;
function toast(text) {
  const el = $("toast");
  el.textContent = text;
  el.classList.remove("hidden");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.add("hidden"), 2600);
}

function show(screen) {
  for (const id of ["auth", "setup", "main"]) $(id).classList.toggle("hidden", id !== screen);
}

function openSheet(id) {
  $(id).classList.remove("hidden");
  history.pushState({ sheet: id }, "");
}

function closeSheets() {
  document.querySelectorAll(".sheet").forEach((el) => el.classList.add("hidden"));
}

window.addEventListener("popstate", closeSheets);
document.querySelectorAll("[data-close]").forEach((btn) =>
  btn.addEventListener("click", () => (history.state?.sheet ? history.back() : closeSheets()))
);
document.querySelectorAll(".sheet").forEach((sheet) =>
  sheet.addEventListener("click", (e) => {
    if (e.target === sheet) history.state?.sheet ? history.back() : closeSheets();
  })
);

function initials(p) {
  const name = (p?.display_name || p?.username || "?").trim();
  return name.split(/\s+/).slice(0, 2).map((w) => w[0]?.toUpperCase() || "").join("") || "?";
}

function firstName(p) {
  return (p?.display_name || p?.username || "").trim().split(/\s+/)[0] || "?";
}

function avatarHTML(p, extra = "") {
  const online = p && state.online.has(p.id) ? " online" : "";
  if (p?.avatar_path) {
    const url = `${SUPABASE_URL}/storage/v1/object/public/avatars/${p.avatar_path}`;
    return `<div class="avatar${online} ${extra}" style="background-image:url('${esc(url)}')"></div>`;
  }
  const color = esc(p?.avatar_color || "#7C3AED");
  return `<div class="avatar${online} ${extra}" style="background:${color}">${esc(initials(p))}</div>`;
}

function ago(iso) {
  const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return "adesso";
  if (s < 3600) return `${Math.floor(s / 60)} min fa`;
  if (s < 86400) return `${Math.floor(s / 3600)} h fa`;
  return `${Math.floor(s / 86400)} g fa`;
}

function until(iso) {
  const s = Math.max(0, (new Date(iso).getTime() - Date.now()) / 1000);
  if (s < 3600) return `${Math.max(1, Math.floor(s / 60))} min`;
  return `${Math.floor(s / 3600)} h ${Math.floor((s % 3600) / 60)} min`;
}

function distance(a, b) {
  const R = 6371000, rad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * rad, dLon = (b.lon - a.lon) * rad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

// ───────────── Auth ─────────────

let signUpMode = false;

$("authToggle").addEventListener("click", () => {
  signUpMode = !signUpMode;
  $("authSubmit").textContent = signUpMode ? "Crea account" : "Accedi";
  $("authToggle").textContent = signUpMode ? "Hai già un account? Accedi" : "Non hai un account? Registrati";
  $("authMsg").textContent = "";
});

$("authSubmit").addEventListener("click", async () => {
  const email = $("email").value.trim();
  const password = $("password").value;
  const msg = $("authMsg");
  msg.className = "msg";
  if (!email.includes("@")) return (msg.textContent = "Inserisci un'email valida.");
  if (password.length < 6) return (msg.textContent = "La password deve avere almeno 6 caratteri.");
  $("authSubmit").disabled = true;
  try {
    if (signUpMode) {
      const signedIn = await invoke("sign_up", { email, password });
      if (!signedIn) {
        msg.className = "msg ok";
        msg.textContent = "Ti abbiamo inviato un'email: conferma l'account e poi accedi.";
        return;
      }
    } else {
      await invoke("sign_in", { email, password });
    }
    await enter();
  } catch (e) {
    msg.textContent = errorText(e);
  } finally {
    $("authSubmit").disabled = false;
  }
});

$("authReset").addEventListener("click", async () => {
  const email = $("email").value.trim();
  const msg = $("authMsg");
  if (!email.includes("@")) {
    msg.className = "msg";
    return (msg.textContent = "Scrivi la tua email qui sopra.");
  }
  try {
    await invoke("reset_password", { email });
    msg.className = "msg ok";
    msg.textContent = "Email per reimpostare la password inviata.";
  } catch (e) {
    msg.className = "msg";
    msg.textContent = errorText(e);
  }
});

$("setupSubmit").addEventListener("click", async () => {
  const displayName = $("displayName").value.trim();
  const username = $("username").value.trim().toLowerCase();
  const msg = $("setupMsg");
  if (!displayName) return (msg.textContent = "Scrivi il tuo nome.");
  if (!/^[a-z0-9._]{3,24}$/.test(username)) return (msg.textContent = errorText("username"));
  $("setupSubmit").disabled = true;
  try {
    state.me = await invoke("update_profile", { displayName, username });
    startMain();
  } catch (e) {
    msg.textContent = errorText(e);
  } finally {
    $("setupSubmit").disabled = false;
  }
});

$("logoutBtn").addEventListener("click", async () => {
  if (!confirm("Vuoi uscire da PinDrop?")) return;
  await invoke("sign_out").catch(() => {});
  location.reload();
});

async function enter() {
  try {
    state.me = await invoke("my_profile");
  } catch (e) {
    show("auth");
    $("authMsg").textContent = errorText(e);
    return;
  }
  if (!state.me || !state.me.is_setup) {
    $("displayName").value = state.me?.display_name || "";
    $("username").value = state.me?.username || "";
    show("setup");
  } else {
    startMain();
  }
}

// ───────────── Map ─────────────

function initMap() {
  if (map) return;
  map = L.map("map", { zoomControl: false, attributionControl: true }).setView([41.9, 12.5], 5);
  L.tileLayer("https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png", {
    maxZoom: 20,
    subdomains: "abcd",
    attribution: "© OpenStreetMap © CARTO",
  }).addTo(map);
  pinLayer = L.layerGroup().addTo(map);
  friendLayer = L.layerGroup().addTo(map);
  meLayer = L.layerGroup().addTo(map);
}

function myActivePin() {
  return state.pins.find((p) => p.author?.id === state.me.id && new Date(p.expires_at) > new Date());
}

function isUnlocked() {
  return !!myActivePin();
}

function isLocked(pin) {
  return pin.author?.id !== state.me.id && !isUnlocked();
}

async function signedURLs(paths) {
  const now = Date.now();
  const missing = [...new Set(paths)].filter((p) => p && !(state.urls[p] && state.urls[p].until > now));
  if (missing.length) {
    try {
      const result = await invoke("sign_urls", { paths: missing });
      for (const [path, url] of Object.entries(result)) state.urls[path] = { url, until: now + 50 * 60 * 1000 };
    } catch (_) { /* images retry on next refresh */ }
  }
  const out = {};
  for (const p of paths) out[p] = state.urls[p]?.url;
  return out;
}

async function renderPins() {
  const pins = state.pins;
  const paths = pins.map((p) => (isLocked(p) ? p.blur_path : p.thumb_path));
  const urls = await signedURLs(paths);
  pinLayer.clearLayers();
  for (const pin of [...pins].reverse()) {
    const locked = isLocked(pin);
    const mine = pin.author?.id === state.me.id;
    const url = urls[locked ? pin.blur_path : pin.thumb_path];
    const img = url ? `<img src="${esc(url)}">` : `<div class="ph"></div>`;
    const icon = L.divIcon({
      className: "",
      html: `<div class="pin-marker${locked ? " locked" : ""}${mine ? " mine" : ""}">${img}<div class="tip"></div></div>`,
      iconSize: [52, 58],
      iconAnchor: [26, 56],
    });
    L.marker([pin.latitude, pin.longitude], { icon, zIndexOffset: mine ? 500 : 0 })
      .on("click", () => openPin(pin))
      .addTo(pinLayer);
  }
  const pill = $("lockPill");
  if (isUnlocked()) {
    pill.textContent = `🔓 Il tuo pin scade tra ${until(myActivePin().expires_at)}`;
  } else {
    const hidden = pins.filter((p) => isLocked(p)).length;
    pill.textContent = hidden
      ? `🔒 ${hidden} pin di amici: scatta per sbloccarli`
      : "📸 Scatta una foto e lascia il tuo pin";
  }
}

function freshLocations() {
  const friendIDs = new Set(state.friends.map((f) => f.id));
  const cutoff = Date.now() - 12 * 3600 * 1000;
  return state.locations
    .filter((l) => l.user_id !== state.me.id && friendIDs.has(l.user_id) && new Date(l.updated_at).getTime() > cutoff)
    .map((l) => ({ ...l, profile: state.friends.find((f) => f.id === l.user_id), lat: l.latitude, lon: l.longitude }));
}

function renderPeople() {
  friendLayer.clearLayers();
  meLayer.clearLayers();
  const locations = freshLocations();

  // Friends with me (within 35 m, updated in the last 10 min) sit next to my avatar.
  const companions = [];
  const others = [];
  for (const l of locations) {
    const recent = Date.now() - new Date(l.updated_at).getTime() < 10 * 60 * 1000;
    if (state.myPos && recent && distance(state.myPos, l) <= TOGETHER_M) companions.push(l);
    else others.push(l);
  }

  if (state.myPos) {
    const extra = companions.map((c) => avatarHTML(c.profile)).join("");
    const width = 56 + companions.length * 23;
    const icon = L.divIcon({
      className: "",
      html: `<div style="display:flex;align-items:center"><div class="me-marker"><div class="pulse"></div>${avatarHTML(state.me)}</div>${
        extra ? `<div class="avatars" style="margin-left:-12px">${extra}</div>` : ""
      }</div>`,
      iconSize: [width, 56],
      iconAnchor: [28, 28],
    });
    L.marker([state.myPos.lat, state.myPos.lon], { icon, zIndexOffset: 1000, interactive: false }).addTo(meLayer);
  }

  // Other friends: grouped Bump-style when standing together.
  const groups = [];
  for (const l of others) {
    const group = groups.find((g) => g.some((m) => distance(m, l) <= TOGETHER_M));
    group ? group.push(l) : groups.push([l]);
  }
  for (const group of groups) {
    const newest = group.reduce((a, b) => (new Date(a.updated_at) > new Date(b.updated_at) ? a : b));
    const profiles = group.map((g) => g.profile);
    const anyOnline = profiles.some((p) => state.online.has(p.id));
    const label = profiles.length > 2
      ? `${firstName(profiles[0])} +${profiles.length - 1}`
      : profiles.map(firstName).join(" & ");
    const time = anyOnline ? "" : ` · ${ago(newest.updated_at)}`;
    const avatars = profiles.slice(0, 5).map((p) => avatarHTML(p)).join("");
    const more = profiles.length > 5 ? `<div class="avatar" style="background:var(--grad)">+${profiles.length - 5}</div>` : "";
    const width = 34 + (Math.min(profiles.length, 6) - 1) * 23 + 10;
    const icon = L.divIcon({
      className: "",
      html: `<div class="group-marker"><div class="avatars${profiles.length > 1 ? " many" : ""}">${avatars}${more}</div><div class="name-tag">${
        anyOnline ? '<span class="dot"></span>' : ""
      }${esc(label)}${esc(time)}</div></div>`,
      iconSize: [Math.max(width, 80), 58],
      iconAnchor: [Math.max(width, 80) / 2, 58],
    });
    L.marker([newest.lat, newest.lon], { icon, zIndexOffset: 800 })
      .on("click", () => {
        const names = profiles.map((p) => p.display_name || p.username).join(", ");
        toast(`${names} · ${ago(newest.updated_at)}`);
      })
      .addTo(friendLayer);
  }
}

$("centerBtn").addEventListener("click", async () => {
  await updateLocation(true);
  if (state.myPos) map.flyTo([state.myPos.lat, state.myPos.lon], 16, { duration: 0.8 });
  else toast("Attiva la posizione per vederti sulla mappa.");
});

// ───────────── Location ─────────────

async function ensurePermission(request) {
  try {
    let perm = await invoke("plugin:geolocation|check_permissions");
    const ok = (p) => p && (p.location === "granted" || p.coarseLocation === "granted");
    if (!ok(perm) && request) {
      perm = await invoke("plugin:geolocation|request_permissions", { permissions: ["location", "coarseLocation"] });
    }
    return ok(perm);
  } catch (_) {
    return "geolocation" in navigator;
  }
}

async function currentPosition() {
  try {
    const pos = await invoke("plugin:geolocation|get_current_position", {
      options: { enableHighAccuracy: true, timeout: 15000, maximumAge: 10000 },
    });
    return { lat: pos.coords.latitude, lon: pos.coords.longitude };
  } catch (_) {
    return new Promise((resolve) => {
      if (!navigator.geolocation) return resolve(null);
      navigator.geolocation.getCurrentPosition(
        (p) => resolve({ lat: p.coords.latitude, lon: p.coords.longitude }),
        () => resolve(null),
        { enableHighAccuracy: true, timeout: 15000, maximumAge: 10000 }
      );
    });
  }
}

async function updateLocation(request = false) {
  state.locationGranted = await ensurePermission(request);
  if (!state.locationGranted) {
    invoke("report_location", { lat: null, lon: null, granted: false }).catch(() => {});
    return;
  }
  const pos = await currentPosition();
  if (!pos) return;
  state.myPos = pos;
  if (!state.centered) {
    state.centered = true;
    map.setView([pos.lat, pos.lon], 16);
  }
  renderPeople();
  invoke("report_location", { lat: pos.lat, lon: pos.lon, granted: true }).catch(() => {});
}

// ───────────── Data refresh ─────────────

async function loadFriends() {
  const rows = await invoke("fetch_friends");
  const me = state.me.id;
  state.friends = [];
  state.requests = [];
  state.sent = [];
  for (const r of rows) {
    const other = r.requester_id === me ? r.addressee : r.requester;
    if (!other) continue;
    if (r.status === "accepted") state.friends.push({ ...other, friendship_id: r.id });
    else if (r.addressee_id === me) state.requests.push({ id: r.id, profile: other });
    else state.sent.push(other);
  }
  state.friends.sort((a, b) => (a.display_name || "").localeCompare(b.display_name || ""));
  const badge = $("reqBadge");
  badge.textContent = state.requests.length;
  badge.classList.toggle("hidden", state.requests.length === 0);
  renderFriendsSheet();
}

async function refresh() {
  try {
    const [pins, locations, online] = await Promise.all([
      invoke("fetch_pins"),
      invoke("friend_locations"),
      invoke("online_friends").catch(() => []),
    ]);
    state.pins = pins || [];
    state.locations = locations || [];
    state.online = new Set((online || []).map((o) => (typeof o === "string" ? o : o.id || o.user_id)));
    await renderPins();
    renderPeople();
  } catch (e) {
    if (String(e) === "not_signed_in") location.reload();
  }
}

let started = false;
async function startMain() {
  show("main");
  initMap();
  if (started) return;
  started = true;
  $("myCode").textContent = state.me.invite_code
    ? `Il tuo username: @${state.me.username} · codice invito: ${state.me.invite_code}`
    : `Il tuo username: @${state.me.username}`;
  await loadFriends().catch(() => {});
  await refresh();
  updateLocation(true);
  setInterval(refresh, 20000);
  setInterval(() => updateLocation(false), 30000);
  setInterval(() => loadFriends().catch(() => {}), 60000);
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) {
      refresh();
      updateLocation(false);
    }
  });
}

// ───────────── Friends ─────────────

$("friendsBtn").addEventListener("click", () => {
  openSheet("friendsSheet");
  loadFriends().catch(() => {});
});

$("addFriendBtn").addEventListener("click", async () => {
  const target = $("addFriend").value.trim().replace(/^@/, "").toLowerCase();
  const msg = $("friendMsg");
  if (!target) return;
  try {
    const result = await invoke("send_friend_request", { target });
    const texts = {
      requested: ["Richiesta inviata! ✨", true],
      accepted: ["Siete amici adesso! 🎉", true],
      already_friends: ["Siete già amici.", true],
      already_requested: ["Richiesta già inviata.", true],
      not_found: ["Nessun utente con questo username o codice.", false],
      self: ["Non puoi aggiungere te stesso 😄", false],
    };
    const [text, ok] = texts[result] || ["Fatto.", true];
    msg.className = ok ? "msg ok" : "msg";
    msg.textContent = text;
    if (ok) $("addFriend").value = "";
    loadFriends().catch(() => {});
  } catch (e) {
    msg.className = "msg";
    msg.textContent = errorText(e);
  }
});

function renderFriendsSheet() {
  $("reqTitle").classList.toggle("hidden", state.requests.length === 0);
  $("requests").innerHTML = state.requests
    .map(
      (r) => `<div class="person">${avatarHTML(r.profile)}<div class="info"><b>${esc(r.profile.display_name)}</b><span>@${esc(r.profile.username)}</span></div>
      <button class="accept" data-req="${r.id}" data-ok="1">Accetta</button><button class="decline" data-req="${r.id}" data-ok="0">✕</button></div>`
    )
    .join("");
  const located = new Map(freshLocations().map((l) => [l.user_id, l]));
  const friends = state.friends
    .map((f) => {
      const loc = located.get(f.id);
      const status = state.online.has(f.id) ? "🟢 online" : loc ? `📍 ${ago(loc.updated_at)}` : `@${esc(f.username)}`;
      return `<div class="person" data-friend="${f.id}">${avatarHTML(f)}<div class="info"><b>${esc(f.display_name)} ${esc(f.status_emoji || "")}</b><span>${status}</span></div></div>`;
    })
    .join("");
  const sent = state.sent
    .map((p) => `<div class="person">${avatarHTML(p)}<div class="info"><b>${esc(p.display_name)}</b><span>Richiesta in attesa</span></div></div>`)
    .join("");
  $("friendsList").innerHTML = friends + sent || `<p class="muted small">Ancora nessun amico: aggiungili con il loro username.</p>`;
}

$("requests").addEventListener("click", async (e) => {
  const btn = e.target.closest("[data-req]");
  if (!btn) return;
  btn.disabled = true;
  try {
    await invoke("respond_friend_request", { requestId: btn.dataset.req, accept: btn.dataset.ok === "1" });
    await loadFriends();
    refresh();
  } catch (err) {
    toast(errorText(err));
  }
});

$("friendsList").addEventListener("click", (e) => {
  const row = e.target.closest("[data-friend]");
  if (!row) return;
  const loc = freshLocations().find((l) => l.user_id === row.dataset.friend);
  const pin = state.pins.find((p) => p.author?.id === row.dataset.friend);
  const target = loc ? [loc.lat, loc.lon] : pin ? [pin.latitude, pin.longitude] : null;
  if (!target) return toast("Questo amico non sta condividendo la posizione.");
  history.state?.sheet ? history.back() : closeSheets();
  map.flyTo(target, 17, { duration: 0.8 });
});

// ───────────── Camera & publishing ─────────────

function canvasJPEG(source, maxSide, quality, blur = 0) {
  const scale = Math.min(1, maxSide / Math.max(source.width, source.height));
  const w = Math.max(1, Math.round(source.width * scale));
  const h = Math.max(1, Math.round(source.height * scale));
  const canvas = document.createElement("canvas");
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext("2d");
  if (blur) ctx.filter = `blur(${blur}px)`;
  ctx.drawImage(source, 0, 0, w, h);
  return canvas.toDataURL("image/jpeg", quality);
}

async function processImage(file) {
  let bitmap;
  try {
    bitmap = await createImageBitmap(file, { imageOrientation: "from-image" });
  } catch (_) {
    bitmap = await createImageBitmap(file);
  }
  const full = canvasJPEG(bitmap, 1600, 0.82);
  const thumb = canvasJPEG(bitmap, 360, 0.72);
  // Blur: shrink hard, then scale up blurred (what friends see while locked).
  const tiny = document.createElement("canvas");
  const s = 24 / Math.max(bitmap.width, bitmap.height);
  tiny.width = Math.max(1, Math.round(bitmap.width * s));
  tiny.height = Math.max(1, Math.round(bitmap.height * s));
  tiny.getContext("2d").drawImage(bitmap, 0, 0, tiny.width, tiny.height);
  const blur = canvasJPEG(Object.assign(tiny, {}), 240, 0.6, 6);
  bitmap.close?.();
  const strip = (d) => d.split(",")[1];
  return { preview: full, full: strip(full), thumb: strip(thumb), blur: strip(blur) };
}

$("photoInput").addEventListener("change", async (e) => {
  const file = e.target.files?.[0];
  e.target.value = "";
  if (!file) return;
  try {
    state.photo = await processImage(file);
    $("preview").src = state.photo.preview;
    $("caption").value = "";
    openSheet("composer");
  } catch (err) {
    toast("Impossibile leggere la foto.");
  }
});

$("publishBtn").addEventListener("click", async () => {
  if (!state.photo) return;
  const btn = $("publishBtn");
  btn.disabled = true;
  btn.textContent = "Pubblico…";
  try {
    if (!(await ensurePermission(true))) throw new Error("Serve la posizione per lasciare il pin.");
    const pos = (await currentPosition()) || state.myPos;
    if (!pos) throw new Error("Posizione non disponibile, riprova all'aperto.");
    state.myPos = pos;
    const pin = await invoke("publish_pin", {
      lat: pos.lat,
      lon: pos.lon,
      caption: $("caption").value,
      full: state.photo.full,
      thumb: state.photo.thumb,
      blur: state.photo.blur,
    });
    state.photo = null;
    history.state?.sheet ? history.back() : closeSheets();
    if (pin && pin.id) state.pins.unshift(pin);
    await renderPins();
    renderPeople();
    map.flyTo([pos.lat, pos.lon], 17, { duration: 0.8 });
    toast("Pin pubblicato! 🔓 Ora vedi i pin dei tuoi amici");
    refresh();
  } catch (err) {
    toast(errorText(err));
  } finally {
    btn.disabled = false;
    btn.textContent = "Pubblica qui 📍";
  }
});

// ───────────── Pin viewer ─────────────

let viewing = null;

async function openPin(pin) {
  if (isLocked(pin)) {
    toast("🔒 Pubblica una tua foto per vedere i pin dei tuoi amici");
    return;
  }
  viewing = pin;
  const mine = pin.author?.id === state.me.id;
  $("viewerAuthor").innerHTML = `${avatarHTML(pin.author)}<span>${esc(mine ? "Tu" : pin.author?.display_name)}</span>`;
  $("viewerCaption").textContent = pin.caption || "";
  $("viewerCaption").classList.toggle("hidden", !pin.caption);
  $("viewerMeta").textContent = `${ago(pin.created_at)}${pin.place_name ? " · " + pin.place_name : ""} · scade tra ${until(pin.expires_at)}`;
  $("deletePinBtn").classList.toggle("hidden", !mine);
  $("viewerImg").src = state.urls[pin.thumb_path]?.url || "";
  renderReactions();
  openSheet("viewer");
  const urls = await signedURLs([pin.image_path]);
  if (viewing === pin && urls[pin.image_path]) $("viewerImg").src = urls[pin.image_path];
}

function renderReactions() {
  const pin = viewing;
  const list = pin.reactions || [];
  $("viewerReactions").innerHTML = REACTIONS.map((emoji) => {
    const count = list.filter((r) => r.emoji === emoji).length;
    const on = list.some((r) => r.emoji === emoji && r.user_id === state.me.id);
    return `<button class="${on ? "on" : ""}" data-emoji="${emoji}">${emoji}${count ? " " + count : ""}</button>`;
  }).join("");
}

$("viewerReactions").addEventListener("click", async (e) => {
  const btn = e.target.closest("[data-emoji]");
  if (!btn || !viewing) return;
  const emoji = btn.dataset.emoji;
  const pin = viewing;
  pin.reactions = pin.reactions || [];
  const add = !pin.reactions.some((r) => r.emoji === emoji && r.user_id === state.me.id);
  if (add) pin.reactions.push({ emoji, user_id: state.me.id, created_at: new Date().toISOString() });
  else pin.reactions = pin.reactions.filter((r) => !(r.emoji === emoji && r.user_id === state.me.id));
  renderReactions();
  try {
    await invoke("toggle_reaction", { pinId: pin.id, emoji, add });
  } catch (err) {
    toast(errorText(err));
  }
});

$("deletePinBtn").addEventListener("click", async () => {
  if (!viewing || !confirm("Eliminare questo pin?")) return;
  try {
    await invoke("delete_pin", { id: viewing.id });
    state.pins = state.pins.filter((p) => p.id !== viewing.id);
    history.state?.sheet ? history.back() : closeSheets();
    await renderPins();
  } catch (err) {
    toast(errorText(err));
  }
});

// ───────────── Boot ─────────────

(async function boot() {
  try {
    const userID = await invoke("restore_session");
    if (userID) return await enter();
  } catch (_) { /* fall through to login */ }
  show("auth");
})();
