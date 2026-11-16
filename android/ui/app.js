// PinDrop Android UI. Every network call goes through the Rust commands (src-tauri/src).
"use strict";

const SUPABASE_URL = "https://tqtpkdxeedcjmlhabimg.supabase.co";
const MAP_STYLE = "https://tiles.openfreemap.org/styles/positron";
const REACTIONS = ["🔥", "😍", "😂", "👀", "🫶"];
const TOGETHER_M = 35;
const SYNC_M = 50;
const CAPSULE_M = 20;

const tauri = window.__TAURI__;
const invoke = (cmd, args) => tauri.core.invoke(cmd, args || {});
const $ = (id) => document.getElementById(id);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const vibrate = (p) => { try { navigator.vibrate && navigator.vibrate(p); } catch (_) {} };

const ICON = {
  lock: '<svg viewBox="0 0 24 24"><path d="M7 10V8a5 5 0 0 1 10 0v2h1a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1v-9a1 1 0 0 1 1-1zm2 0h6V8a3 3 0 0 0-6 0z"/></svg>',
  bolt: '<svg viewBox="0 0 24 24"><path d="M13 2L4 14h7l-1 8 9-12h-7z"/></svg>',
  x: '<svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" fill="none"/></svg>',
  gemSmall: '<svg viewBox="0 0 24 24"><path d="M12 2l7 6-7 14L5 8z"/></svg>',
  gem(opened) {
    const a = opened ? "#7c3aed" : "#f59e0b";
    const b = opened ? "#c084fc" : "#fde68a";
    const c = opened ? "#4c1d95" : "#b45309";
    return `<svg viewBox="0 0 34 40"><defs><linearGradient id="g${opened ? 1 : 0}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${b}"/><stop offset=".55" stop-color="${a}"/><stop offset="1" stop-color="${c}"/></linearGradient></defs>
      <path d="M17 1l12 11-12 27L5 12z" fill="url(#g${opened ? 1 : 0})" stroke="white" stroke-width="1.6" stroke-linejoin="round"/>
      <path d="M5 12h24M17 1l-5 11 5 27 5-27z" fill="none" stroke="rgba(255,255,255,.55)" stroke-width="1"/></svg>`;
  },
};

const state = {
  me: null,
  pins: [],
  friends: [],
  requests: [],
  sent: [],
  locations: [],
  online: new Set(),
  myPos: null,
  urls: {},
  cross: [],
  crossPins: new Set(),
  capsules: [],
  opens: [],
  opening: new Set(),
  route: { key: "", coords: [] },
  sync: null,
  invite: null,
  dismissedInvites: new Set(),
  dismissedCross: new Set(JSON.parse(localStorage.getItem("dismissedCross") || "[]")),
  cameraMode: "pin",
  facing: "environment",
  layoutKey: "",
};

let map;
let markers = [];
let stream = null;

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
  if (lower.includes("not friends")) return "Potete farlo solo tra amici.";
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
  el.style.animation = "none";
  void el.offsetWidth;
  el.style.animation = "";
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.add("hidden"), 2800);
}

function show(screen) {
  for (const id of ["auth", "setup", "main"]) $(id).classList.toggle("hidden", id !== screen);
}

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
  return `<div class="avatar${online} ${extra}" style="background-color:${color}">${esc(initials(p))}</div>`;
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
function distanceText(m) {
  return m < 1000 ? `${Math.round(m)} m` : `${(m / 1000).toFixed(1)} km`;
}
const pinPos = (p) => ({ lat: p.latitude, lon: p.longitude });
const isMine = (p) => p?.author?.id === state.me?.id;
const profileOf = (id) => (id === state.me?.id ? state.me : state.friends.find((f) => f.id === id));

// ───────────── Layers (sheet / camera) & back button ─────────────

let layerOpen = false;
let ignorePop = 0;

function pushLayer() {
  if (layerOpen) history.replaceState({ layer: 1 }, "");
  else history.pushState({ layer: 1 }, "");
  layerOpen = true;
}
function popLayer() {
  if (!layerOpen) return;
  layerOpen = false;
  ignorePop++;
  history.back();
}
window.addEventListener("popstate", () => {
  if (ignorePop > 0) { ignorePop--; return; }
  layerOpen = false;
  hideSheet();
  closeCamera(true);
});

function openSheet(html, mount) {
  $("sheetBody").innerHTML = html;
  $("sheet").classList.remove("hidden");
  $("sheet").querySelector(".sheet-card").scrollTop = 0;
  pushLayer();
  $("sheetBody").querySelectorAll("[data-close]").forEach((b) => b.addEventListener("click", closeSheet));
  if (mount) mount($("sheetBody"));
}
function hideSheet() {
  $("sheet").classList.add("hidden");
  $("sheetBody").innerHTML = "";
}
function closeSheet() {
  hideSheet();
  popLayer();
}
$("sheet").addEventListener("click", (e) => { if (e.target === $("sheet")) closeSheet(); });
const head = (title) => `<div class="sheet-head"><h2>${title}</h2><button class="close-x" data-close>${ICON.x}</button></div>`;

// ───────────── Auth ─────────────

let signUpMode = false;
$("authToggle").addEventListener("click", () => {
  signUpMode = !signUpMode;
  $("authSubmit").textContent = signUpMode ? "Crea account" : "Accedi";
  $("authToggle").innerHTML = signUpMode ? "Hai già un account? <b>Accedi</b>" : "Non hai un account? <b>Registrati</b>";
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
  if (!email.includes("@")) { msg.className = "msg"; return (msg.textContent = "Scrivi la tua email qui sopra."); }
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
  const username = $("username").value.trim().toLowerCase().replace(/^@/, "");
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

/// Light map, always: OpenFreeMap Positron with a slightly warmer, more colorful touch.
function brightenStyle() {
  for (const layer of map.getStyle().layers) {
    const id = layer.id;
    try {
      if (layer.type === "background") map.setPaintProperty(id, "background-color", "#f4f4f8");
      else if (layer.type === "fill" && /water/.test(id)) map.setPaintProperty(id, "fill-color", "#cfe3fb");
      else if (layer.type === "fill" && /park|wood|grass|forest|landcover|green|garden|cemetery/.test(id)) map.setPaintProperty(id, "fill-color", "#dcf2e3");
      else if (layer.type === "line" && /water|river|stream|canal/.test(id)) map.setPaintProperty(id, "line-color", "#b9d6f7");
      else if (layer.type === "symbol") {
        map.setPaintProperty(id, "text-color", /water|ocean|sea|lake/.test(id) ? "#4f7cc4" : "#4a4a5e");
        map.setPaintProperty(id, "text-halo-color", "#ffffff");
      }
    } catch (_) {}
  }
}

function darkenStyle() {
  for (const layer of map.getStyle().layers) {
    const id = layer.id;
    try {
      if (layer.type === "background") {
        map.setPaintProperty(id, "background-color", "#0d0e1c");
      } else if (layer.type === "fill") {
        let c = "#14152a";
        if (/water/.test(id)) c = "#0c1730";
        else if (/park|wood|grass|forest|landcover|green|garden|cemetery/.test(id)) c = "#0f2420";
        else if (/building/.test(id)) c = "#1b1d38";
        map.setPaintProperty(id, "fill-color", c);
        if (/building/.test(id)) map.setPaintProperty(id, "fill-outline-color", "#25284a");
      } else if (layer.type === "line") {
        let c = "#272a4a";
        if (/water|river|stream|canal|ditch/.test(id)) c = "#10254a";
        else if (/motorway|trunk/.test(id)) c = "#5a4fa0";
        else if (/primary/.test(id)) c = "#4a4a88";
        else if (/secondary|tertiary/.test(id)) c = "#383b6c";
        else if (/boundary|admin/.test(id)) c = "#40336a";
        else if (/rail|transit/.test(id)) c = "#2b2d48";
        map.setPaintProperty(id, "line-color", c);
      } else if (layer.type === "symbol") {
        map.setPaintProperty(id, "text-color", /water|ocean|sea|lake/.test(id) ? "#5f7fbf" : "#b8bae3");
        map.setPaintProperty(id, "text-halo-color", "#0d0e1c");
        map.setPaintProperty(id, "text-halo-width", 1.3);
      }
    } catch (_) { /* layer without that property */ }
  }
}

function emptyCollection() {
  return { type: "FeatureCollection", features: [] };
}

function addOverlayLayers() {
  const style = map.getStyle();
  const vector = Object.entries(style.sources).find(([, s]) => s.type === "vector");
  const firstSymbol = style.layers.find((l) => l.type === "symbol")?.id;
  if (vector) {
    try {
      map.addLayer({
        id: "pd-buildings-3d",
        type: "fill-extrusion",
        source: vector[0],
        "source-layer": "building",
        minzoom: 15,
        paint: {
          "fill-extrusion-color": "#e4e4ee",
          "fill-extrusion-height": ["coalesce", ["get", "render_height"], 8],
          "fill-extrusion-base": ["coalesce", ["get", "render_min_height"], 0],
          "fill-extrusion-opacity": 0.9,
        },
      }, firstSymbol);
    } catch (_) {}
  }
  map.addSource("pd-zones", { type: "geojson", data: emptyCollection() });
  map.addLayer({ id: "pd-zones-fill", type: "fill", source: "pd-zones", minzoom: FAR_ZOOM, paint: { "fill-color": "#f59e0b", "fill-opacity": 0.14 } });
  map.addLayer({ id: "pd-zones-line", type: "line", source: "pd-zones", minzoom: FAR_ZOOM, paint: { "line-color": "#f59e0b", "line-width": 1.6, "line-opacity": 0.85 } });
  map.addSource("pd-trail", { type: "geojson", data: emptyCollection() });
  map.addLayer({
    id: "pd-trail-glow", type: "line", source: "pd-trail", minzoom: FAR_ZOOM,
    layout: { "line-cap": "round", "line-join": "round" },
    paint: { "line-color": "#a855f7", "line-width": 12, "line-opacity": 0.3, "line-blur": 5 },
  });
  map.addLayer({
    id: "pd-trail", type: "line", source: "pd-trail", minzoom: FAR_ZOOM,
    layout: { "line-cap": "round", "line-join": "round" },
    paint: { "line-color": "#7c3aed", "line-width": 4, "line-dasharray": [2, 1.6] },
  });
}

let mapReady = false;
function initMap() {
  if (map) return;
  map = new maplibregl.Map({
    container: "map",
    style: MAP_STYLE,
    center: [12.5, 41.9],
    zoom: 4.5,
    attributionControl: { compact: true },
    maxPitch: 60,
  });
  map.on("load", () => {
    brightenStyle();
    addOverlayLayers();
    mapReady = true;
    updateTrail();
    updateZones();
    renderMarkers(true);
  });
  let lastZoom = -1;
  map.on("zoom", () => {
    const q = Math.round(map.getZoom() * 4) / 4;
    if (q !== lastZoom) {
      lastZoom = q;
      scheduleLayout();
    }
  });
  map.on("moveend", () => scheduleLayout());
}

let layoutFrame = 0;
function scheduleLayout(force = false) {
  if (force) state.layoutKey = "";
  cancelAnimationFrame(layoutFrame);
  layoutFrame = requestAnimationFrame(() => renderMarkers(false));
}

function geojsonCircle(lat, lon, radius) {
  const points = [];
  const dLat = radius / 111320;
  const dLon = radius / (111320 * Math.cos((lat * Math.PI) / 180));
  for (let i = 0; i <= 48; i++) {
    const a = (i / 48) * Math.PI * 2;
    points.push([lon + dLon * Math.cos(a), lat + dLat * Math.sin(a)]);
  }
  return { type: "Feature", geometry: { type: "Polygon", coordinates: [points] }, properties: {} };
}

// ───────────── Pins & lock rules ─────────────

function myActivePins() {
  return state.pins.filter((p) => isMine(p) && new Date(p.expires_at) > new Date());
}
function isUnlocked() {
  return myActivePins().length > 0;
}
function isLocked(pin) {
  return !isMine(pin) && !isUnlocked() && !state.crossPins.has(pin.id);
}
function syncPartnerPin(pin) {
  if (!pin.sync_session_id) return null;
  return state.pins.find((p) => p.sync_session_id === pin.sync_session_id && p.id !== pin.id) || null;
}
/// Pins drawn on the map: a Sync Shot pair is drawn once.
function mapPins() {
  const seen = new Set();
  const out = [];
  for (const pin of state.pins) {
    if (pin.sync_session_id) {
      if (seen.has(pin.sync_session_id)) continue;
      seen.add(pin.sync_session_id);
      const partner = syncPartnerPin(pin);
      out.push(partner && isMine(partner) ? partner : pin);
    } else {
      out.push(pin);
    }
  }
  return out;
}

async function signed(bucket, paths) {
  const now = Date.now();
  const missing = [...new Set(paths)].filter((p) => p && !(state.urls[bucket + p]?.until > now));
  if (missing.length) {
    try {
      const result = await invoke("sign_urls", { paths: missing, bucket });
      for (const [path, url] of Object.entries(result)) state.urls[bucket + path] = { url, until: now + 50 * 60 * 1000 };
    } catch (_) {}
  }
  const out = {};
  for (const p of paths) out[p] = state.urls[bucket + p]?.url;
  return out;
}
const pinThumbURL = (pin) => state.urls["pins" + (isLocked(pin) ? pin.blur_path : pin.thumb_path)]?.url;

// ───────────── Friends on the map ─────────────

function freshLocations() {
  const friendIDs = new Set(state.friends.map((f) => f.id));
  const cutoff = Date.now() - 12 * 3600 * 1000;
  return state.locations
    .filter((l) => l.user_id !== state.me.id && friendIDs.has(l.user_id) && new Date(l.updated_at).getTime() > cutoff)
    .map((l) => ({ ...l, profile: profileOf(l.user_id), lat: l.latitude, lon: l.longitude }));
}

function syncCandidates() {
  if (!state.myPos) return [];
  return freshLocations()
    .filter((l) => Date.now() - new Date(l.updated_at).getTime() < 5 * 60 * 1000 && distance(state.myPos, l) <= SYNC_M)
    .map((l) => l.profile);
}

// ───────────── Layout: true positions, merge what would overlap ─────────────

/** Zoomed out further than this, only your own dot is drawn (like Apple Maps). */
const FAR_ZOOM = 7;
const isFarZoom = () => map.getZoom() < FAR_ZOOM;

function computeLayout() {
  const P = (o) => map.project([o.lon, o.lat]);
  const gap = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);
  const me = state.myPos;
  const meP = me ? P(me) : null;
  const ME_R = 36;
  const nearMe = (p, r) => meP && gap(meP, p) < ME_R + r;
  const occupied = meP ? [{ p: meP, r: ME_R }] : [];
  const fits = (p, r) => occupied.every((o) => gap(o.p, p) >= o.r + r);
  const L = { far: isFarZoom(), companions: [], groups: [], clusters: [], underMe: [], capsules: [], capsulesUnderMe: [] };
  if (L.far) return L;

  for (const f of freshLocations()) {
    f.p = P(f);
    const recent = Date.now() - new Date(f.updated_at).getTime() < 10 * 60 * 1000;
    if (me && ((recent && distance(me, f) <= TOGETHER_M) || nearMe(f.p, 14))) {
      L.companions.push(f.profile);
      continue;
    }
    const group = L.groups.find((g) => g.some((m) => distance(m, f) <= TOGETHER_M || gap(m.p, f.p) < 44));
    group ? group.push(f) : L.groups.push([f]);
  }
  for (const g of L.groups) occupied.push({ p: g[0].p, r: 22 + Math.min(g.length - 1, 4) * 9 });

  for (const pin of mapPins()) {
    const p = P(pinPos(pin));
    if (nearMe(p, 20)) { L.underMe.push(pin); continue; }
    const cluster = L.clusters.find((c) => gap(c.p, p) < 48);
    cluster ? cluster.pins.push(pin) : L.clusters.push({ p, pins: [pin] });
  }
  for (const c of L.clusters) occupied.push({ p: c.p, r: 26 });

  for (const cap of state.capsules) {
    const p = P(pinPos(cap));
    if (nearMe(p, 14)) L.capsulesUnderMe.push(cap);
    else if (fits(p, 18)) { L.capsules.push(cap); occupied.push({ p, r: 18 }); }
  }
  return L;
}

function layoutKey(L) {
  return JSON.stringify([
    L.far,
    state.myPos && [state.myPos.lat.toFixed(5), state.myPos.lon.toFixed(5)],
    L.companions.map((p) => p.id),
    L.groups.map((g) => g.map((m) => m.user_id + m.updated_at)),
    L.clusters.map((c) => c.pins.map((p) => p.id + (pinThumbURL(p) ? 1 : 0) + (isLocked(p) ? "l" : ""))),
    L.underMe.map((p) => p.id + (pinThumbURL(p) ? 1 : 0)),
    L.capsules.map((c) => c.id + (isCapsuleOpen(c) ? 1 : 0)),
    L.capsulesUnderMe.map((c) => c.id),
    [...state.online],
    activeCrossEvents().map((e) => e.id),
  ]);
}

function addMarker(el, lngLat, anchor = "bottom") {
  const marker = new maplibregl.Marker({ element: el, anchor }).setLngLat(lngLat).addTo(map);
  markers.push(marker);
  return marker;
}

function element(html, onClick) {
  const el = document.createElement("div");
  el.innerHTML = html;
  const node = el.firstElementChild;
  if (onClick) node.addEventListener("click", (e) => { e.stopPropagation(); onClick(e); });
  return node;
}

function renderMarkers(force) {
  if (!map || !mapReady || !state.me) return;
  const L = computeLayout();
  const key = layoutKey(L);
  if (!force && key === state.layoutKey) return;
  state.layoutKey = key;
  markers.forEach((m) => m.remove());
  markers = [];

  if (L.far) {
    if (state.myPos) {
      const dot = addMarker(element('<div class="m-dot"><div class="halo"></div><div class="core"></div></div>'), [state.myPos.lon, state.myPos.lat], "center");
      dot.getElement().style.zIndex = 5;
    }
    updateStatus();
    return;
  }

  for (const ev of activeCrossEvents()) {
    addMarker(element(`<div class="m-cross"><div class="wave"></div><div class="wave"></div><div class="wave"></div><div class="center">💫</div></div>`), [ev.lon, ev.lat], "center");
  }

  for (const cap of L.capsules) {
    const opened = isCapsuleOpen(cap);
    const label = isMine(cap) ? "La tua" : state.myPos ? distanceText(distance(state.myPos, pinPos(cap))) : firstName(cap.author);
    addMarker(element(`<div class="m-capsule${opened ? " opened" : ""}"><div class="gem">${ICON.gem(opened)}</div><div class="tag">${esc(label)}</div></div>`, () => openCapsule(cap)), [cap.longitude, cap.latitude]);
  }

  for (const c of L.clusters) {
    const pins = [...c.pins].sort((a, b) => (isMine(b) - isMine(a)) || (new Date(b.created_at) - new Date(a.created_at)));
    const top = pins[0];
    const url = pinThumbURL(top);
    const cls = `m-pin${isMine(top) ? " mine" : ""}${top.sync_session_id ? " sync" : ""}`;
    const html = `<div class="${cls}"><div class="frame">${url ? `<img src="${esc(url)}">` : '<div class="ph"></div>'}${isLocked(top) ? `<div class="lock">${ICON.lock}</div>` : ""}${pins.length > 1 ? `<div class="count">${pins.length}</div>` : ""}</div><div class="tail"></div></div>`;
    addMarker(element(html, () => openPins(pins)), [top.longitude, top.latitude]);
  }

  for (const g of L.groups) {
    const profiles = g.map((m) => m.profile);
    const newest = g.reduce((a, b) => (new Date(a.updated_at) > new Date(b.updated_at) ? a : b));
    const anyOnline = profiles.some((p) => state.online.has(p.id));
    const label = profiles.length > 2 ? `${firstName(profiles[0])} +${profiles.length - 1}` : profiles.map(firstName).join(" & ");
    const avatars = profiles.slice(0, 4).map((p) => avatarHTML(p)).join("") + (profiles.length > 4 ? `<div class="avatar" style="background:var(--grad)">+${profiles.length - 4}</div>` : "");
    const html = `<div class="m-group"><div class="stack${profiles.length > 1 ? " many" : ""}">${avatars}</div><div class="tag">${anyOnline ? '<span class="dot"></span>' : ""}${esc(label)}${anyOnline ? "" : ` · ${esc(ago(newest.updated_at))}`}</div></div>`;
    addMarker(element(html, () => (g.length === 1 ? openFriend(g[0].profile) : openGroup(g))), [newest.lon, newest.lat]);
  }

  if (state.myPos) {
    const own = L.underMe.filter(isMine);
    const others = L.underMe.filter((p) => !isMine(p));
    const ownURL = own[0] && pinThumbURL(own[0]);
    const otherURL = others[0] && pinThumbURL(others[0]);
    const comp = L.companions.slice(0, 4).map((p) => avatarHTML(p)).join("") + (L.companions.length > 4 ? `<div class="avatar" style="background:var(--grad)">+${L.companions.length - 4}</div>` : "");
    const html = `<div class="m-me"><div class="core"><div class="pulse"></div>${isUnlocked() ? '<div class="ring"></div>' : ""}${avatarHTML(state.me)}
      ${comp ? `<div class="stack companions">${comp}</div>` : ""}
      ${own.length ? `<div class="badge-tr" data-act="own"><img class="mini-thumb mine" src="${esc(ownURL || "")}">${own.length > 1 ? `<span class="mini-count">${own.length}</span>` : ""}</div>` : ""}
      ${others.length ? `<div class="badge-tl" data-act="others"><img class="mini-thumb" src="${esc(otherURL || "")}">${others.length > 1 ? `<span class="mini-count">${others.length}</span>` : ""}</div>` : ""}
      ${L.capsulesUnderMe.length ? `<div class="badge-bl" data-act="capsule"><div class="crystal-badge">${ICON.gemSmall}</div></div>` : ""}
      </div><div class="tag"><span class="dot"></span>Tu${L.companions.length ? ` + ${esc(L.companions.map(firstName).join(", "))}` : ""}</div></div>`;
    const el = element(html);
    el.querySelector('[data-act="own"]')?.addEventListener("click", (e) => { e.stopPropagation(); openPins(own); });
    el.querySelector('[data-act="others"]')?.addEventListener("click", (e) => { e.stopPropagation(); openPins(others); });
    el.querySelector('[data-act="capsule"]')?.addEventListener("click", (e) => { e.stopPropagation(); openCapsule(L.capsulesUnderMe[0]); });
    const marker = addMarker(el, [state.myPos.lon, state.myPos.lat], "center");
    marker.getElement().style.zIndex = 5;
  }
  updateStatus();
}

// ───────────── Trail (yours only, along the streets) ─────────────

async function updateTrail() {
  if (!mapReady) return;
  const mine = myActivePins().filter((p) => !p.sync_session_id || true).sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
  const key = mine.map((p) => p.id).join(",");
  const setLine = (coords) => {
    map.getSource("pd-trail")?.setData(coords.length >= 2
      ? { type: "Feature", geometry: { type: "LineString", coordinates: coords }, properties: {} }
      : emptyCollection());
  };
  if (key === state.route.key) return setLine(state.route.coords);
  const straight = mine.map((p) => [p.longitude, p.latitude]);
  state.route = { key, coords: straight };
  setLine(straight);
  if (straight.length < 2) return;
  try {
    const coords = await invoke("route", { points: straight });
    if (state.route.key === key && Array.isArray(coords) && coords.length >= 2) {
      state.route.coords = [straight[0], ...coords, straight[straight.length - 1]];
      setLine(state.route.coords);
    }
  } catch (_) { /* keep the straight line */ }
}

function updateZones() {
  if (!mapReady) return;
  const features = state.capsules
    .filter((c) => !isMine(c) && !isCapsuleOpen(c) && (!state.myPos || distance(state.myPos, pinPos(c)) <= 600))
    .map((c) => geojsonCircle(c.latitude, c.longitude, CAPSULE_M));
  map.getSource("pd-zones")?.setData({ type: "FeatureCollection", features });
}

// ───────────── Status pill ─────────────

function updateStatus() {
  const pill = $("statusPill");
  const candidates = syncCandidates();
  $("syncBtn").classList.toggle("hot", candidates.length > 0);
  if (candidates.length) {
    pill.innerHTML = `⚡ <span><b>${esc(candidates.map(firstName).join(", "))}</b> è qui: Sync Shot!</span>`;
  } else if (isUnlocked()) {
    const last = myActivePins().sort((a, b) => new Date(b.expires_at) - new Date(a.expires_at))[0];
    pill.innerHTML = `🔓 <span>Il tuo pin scade tra <span class="accent">${until(last.expires_at)}</span></span>`;
  } else {
    const hidden = state.pins.filter((p) => isLocked(p)).length;
    pill.innerHTML = hidden ? `🔒 <span>${hidden} foto di amici: scatta per sbloccarle</span>` : "📸 <span>Scatta e lascia il tuo pin</span>";
  }
}

// ───────────── Location ─────────────

async function ensurePermission(request) {
  try {
    let perm = await invoke("plugin:geolocation|check_permissions");
    const ok = (p) => p && (p.location === "granted" || p.coarseLocation === "granted");
    if (!ok(perm) && request) perm = await invoke("plugin:geolocation|request_permissions", { permissions: ["location", "coarseLocation"] });
    return ok(perm);
  } catch (_) {
    return "geolocation" in navigator;
  }
}

async function currentPosition() {
  try {
    const pos = await invoke("plugin:geolocation|get_current_position", { options: { enableHighAccuracy: true, timeout: 15000, maximumAge: 5000 } });
    return { lat: pos.coords.latitude, lon: pos.coords.longitude };
  } catch (_) {
    return new Promise((resolve) => {
      if (!navigator.geolocation) return resolve(null);
      navigator.geolocation.getCurrentPosition((p) => resolve({ lat: p.coords.latitude, lon: p.coords.longitude }), () => resolve(null), { enableHighAccuracy: true, timeout: 15000, maximumAge: 5000 });
    });
  }
}

let centered = false;
async function updateLocation(request = false) {
  const granted = await ensurePermission(request);
  if (!granted) {
    invoke("report_location", { lat: null, lon: null, granted: false }).catch(() => {});
    return;
  }
  const pos = await currentPosition();
  if (!pos) return;
  state.myPos = pos;
  if (!centered && map) {
    centered = true;
    map.jumpTo({ center: [pos.lon, pos.lat], zoom: 16 });
  }
  scheduleLayout(true);
  updateZones();
  checkCapsuleProximity();
  invoke("report_location", { lat: pos.lat, lon: pos.lon, granted: true }).catch(() => {});
}

$("locateBtn").addEventListener("click", async () => {
  await updateLocation(true);
  if (state.myPos) map.flyTo({ center: [state.myPos.lon, state.myPos.lat], zoom: 16.5, pitch: 0, bearing: 0, duration: 900 });
  else toast("Attiva la posizione per vederti sulla mappa.");
});

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
  $("reqBadge").textContent = state.requests.length;
  $("reqBadge").classList.toggle("hidden", state.requests.length === 0);
}

async function refresh() {
  try {
    const [pins, locations, online, caps] = await Promise.all([
      invoke("fetch_pins"),
      invoke("friend_locations"),
      invoke("online_friends").catch(() => []),
      invoke("fetch_capsules").catch(() => null),
    ]);
    state.pins = pins || [];
    state.locations = locations || [];
    state.online = new Set((online || []).map((o) => (typeof o === "string" ? o : o.id || o.user_id)));
    if (caps) {
      state.capsules = caps.capsules || [];
      state.opens = caps.opens || [];
    }
    await signed("pins", state.pins.map((p) => (isLocked(p) ? p.blur_path : p.thumb_path)));
    scheduleLayout(true);
    updateTrail();
    updateZones();
    checkCapsuleProximity();
  } catch (e) {
    if (String(e) === "not_signed_in") location.reload();
  }
}

async function refreshCross() {
  try {
    const rows = await invoke("fetch_cross_paths");
    const me = state.me.id;
    state.cross = (rows || [])
      .filter((r) => r.user_a === me || r.user_b === me)
      .map((r) => {
        const mineA = r.user_a === me;
        return {
          id: r.id,
          friendId: mineA ? r.user_b : r.user_a,
          myPin: mineA ? r.pin_a : r.pin_b,
          friendPin: mineA ? r.pin_b : r.pin_a,
          lat: r.latitude,
          lon: r.longitude,
          meters: r.distance_m,
          created_at: r.created_at,
        };
      });
    state.crossPins = new Set(state.cross.flatMap((e) => [e.myPin, e.friendPin]));
    showCrossBanner();
    scheduleLayout(true);
  } catch (_) {}
}

function activeCrossEvents() {
  return state.cross.filter((e) => Date.now() - new Date(e.created_at).getTime() < 6 * 3600 * 1000);
}

function showCrossBanner() {
  const banner = $("crossBanner");
  const ev = activeCrossEvents().find((e) => !state.dismissedCross.has(e.id));
  if (!ev) return banner.classList.add("hidden");
  const friend = profileOf(ev.friendId);
  if (!friend) return banner.classList.add("hidden");
  banner.innerHTML = `${avatarHTML(friend)}<div class="grow"><div class="title">💫 Vi siete sfiorati con ${esc(firstName(friend))}</div><div class="sub">a ${Math.round(ev.meters)} m · ${esc(ago(ev.created_at))} · foto sbloccate</div></div><button class="close-x" data-x>${ICON.x}</button>`;
  if (banner.classList.contains("hidden")) vibrate([30, 60, 30]);
  banner.classList.remove("hidden");
  banner.onclick = (e) => {
    if (e.target.closest("[data-x]")) {
      state.dismissedCross.add(ev.id);
      localStorage.setItem("dismissedCross", JSON.stringify([...state.dismissedCross]));
      return banner.classList.add("hidden");
    }
    map.flyTo({ center: [ev.lon, ev.lat], zoom: 17, duration: 900 });
    const pin = state.pins.find((p) => p.id === ev.friendPin);
    if (pin) setTimeout(() => openPins([pin]), 950);
  };
}

let started = false;
async function startMain() {
  show("main");
  $("profileBtn").innerHTML = avatarHTML(state.me);
  initMap();
  if (started) return;
  started = true;
  await loadFriends().catch(() => {});
  await refresh();
  refreshCross();
  updateLocation(true);
  setInterval(refresh, 15000);
  setInterval(refreshCross, 30000);
  setInterval(() => updateLocation(false), 12000);
  setInterval(() => loadFriends().catch(() => {}), 60000);
  setInterval(pollInvites, 4000);
  setInterval(updateStatus, 30000);
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) { refresh(); updateLocation(false); }
  });
}

// ───────────── Friends ─────────────

$("friendsBtn").addEventListener("click", () => {
  openFriendsSheet();
  loadFriends().then(() => { if (!$("sheet").classList.contains("hidden") && $("friendsList")) renderFriendsList(); }).catch(() => {});
});

function openFriendsSheet() {
  openSheet(`${head("Amici")}
    <div class="row"><div class="field at grow"><input id="addFriend" type="text" placeholder="username o codice invito" autocapitalize="none"></div><button id="addFriendBtn" class="primary" style="padding:15px">Aggiungi</button></div>
    <p id="friendMsg" class="msg"></p>
    <div id="requestsBox"></div>
    <h3>I tuoi amici</h3><div id="friendsList"></div>`, (root) => {
    renderFriendsList();
    root.querySelector("#addFriendBtn").addEventListener("click", addFriend);
  });
}

function renderFriendsList() {
  const box = $("requestsBox");
  if (!box) return;
  box.innerHTML = state.requests.length
    ? `<h3>Richieste</h3>` + state.requests.map((r) => `<div class="person">${avatarHTML(r.profile)}<div class="info"><b>${esc(r.profile.display_name)}</b><span>@${esc(r.profile.username)}</span></div>
        <button class="mini accept" data-req="${r.id}" data-ok="1">Accetta</button><button class="mini decline" data-req="${r.id}" data-ok="0">✕</button></div>`).join("")
    : "";
  box.onclick = async (e) => {
    const btn = e.target.closest("[data-req]");
    if (!btn) return;
    btn.disabled = true;
    try {
      await invoke("respond_friend_request", { requestId: btn.dataset.req, accept: btn.dataset.ok === "1" });
      await loadFriends();
      renderFriendsList();
      refresh();
    } catch (err) { toast(errorText(err)); }
  };
  const located = new Map(freshLocations().map((l) => [l.user_id, l]));
  const candidates = new Set(syncCandidates().map((p) => p.id));
  const list = $("friendsList");
  list.innerHTML = state.friends.map((f) => {
    const loc = located.get(f.id);
    const where = loc && state.myPos ? ` · ${distanceText(distance(state.myPos, loc))}` : "";
    const status = state.online.has(f.id) ? `<span style="color:var(--emerald2)">● online</span>${where}` : loc ? `📍 ${esc(ago(loc.updated_at))}${where}` : `@${esc(f.username)}`;
    return `<div class="person" data-friend="${f.id}">${avatarHTML(f)}<div class="info"><b>${esc(f.display_name)} ${esc(f.status_emoji || "")}</b><span>${status}</span></div>${candidates.has(f.id) ? `<button class="mini sync-chip" data-sync="${f.id}">⚡ Sync</button>` : ""}</div>`;
  }).join("") + state.sent.map((p) => `<div class="person">${avatarHTML(p)}<div class="info"><b>${esc(p.display_name)}</b><span>Richiesta in attesa</span></div></div>`).join("")
    || `<p class="muted small">Ancora nessun amico: aggiungili con il loro username.</p>`;
  list.onclick = (e) => {
    const sync = e.target.closest("[data-sync]");
    if (sync) { e.stopPropagation(); return startSync(profileOf(sync.dataset.sync)); }
    const row = e.target.closest("[data-friend]");
    if (row) openFriend(profileOf(row.dataset.friend));
  };
}

async function addFriend() {
  const input = $("addFriend");
  const target = input.value.trim().replace(/^@/, "").toLowerCase();
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
    if (ok) input.value = "";
    await loadFriends();
    renderFriendsList();
  } catch (e) {
    msg.className = "msg";
    msg.textContent = errorText(e);
  }
}

function openFriend(friend) {
  if (!friend) return;
  const loc = freshLocations().find((l) => l.user_id === friend.id);
  const pin = state.pins.find((p) => p.author?.id === friend.id);
  const canSync = syncCandidates().some((p) => p.id === friend.id);
  const where = loc ? `${state.online.has(friend.id) ? "online ora" : "visto " + ago(loc.updated_at)}${state.myPos ? " · a " + distanceText(distance(state.myPos, loc)) : ""}` : "posizione non condivisa";
  openSheet(`<div class="sheet-head"><div class="author">${avatarHTML(friend)}<div>${esc(friend.display_name)} ${esc(friend.status_emoji || "")}<small>@${esc(friend.username)} · ${esc(where)}</small></div></div><button class="close-x" data-close>${ICON.x}</button></div>
    ${friend.bio ? `<p class="muted" style="margin:0">${esc(friend.bio)}</p>` : ""}
    ${canSync ? `<button class="primary emerald" data-act="sync">⚡ Sync Shot con ${esc(firstName(friend))}</button>` : `<p class="muted small" style="margin:0">⚡ Il Sync Shot si attiva quando siete a meno di ${SYNC_M} m.</p>`}
    <div class="row">${loc ? `<button class="ghost grow" data-act="map">📍 Mostra sulla mappa</button>` : ""}${pin && !isLocked(pin) ? `<button class="ghost grow" data-act="pin">🖼️ La sua foto</button>` : ""}</div>`, (root) => {
    root.querySelector('[data-act="sync"]')?.addEventListener("click", () => startSync(friend));
    root.querySelector('[data-act="map"]')?.addEventListener("click", () => { closeSheet(); map.flyTo({ center: [loc.lon, loc.lat], zoom: 17, duration: 900 }); });
    root.querySelector('[data-act="pin"]')?.addEventListener("click", () => openPins([pin]));
  });
}

function openGroup(group) {
  openSheet(`${head("Sono insieme")}${group.map((m) => `<div class="person" data-friend="${m.user_id}">${avatarHTML(m.profile)}<div class="info"><b>${esc(m.profile.display_name)}</b><span>${state.online.has(m.user_id) ? "● online" : esc(ago(m.updated_at))}</span></div></div>`).join("")}`, (root) => {
    root.addEventListener("click", (e) => {
      const row = e.target.closest("[data-friend]");
      if (row) openFriend(profileOf(row.dataset.friend));
    });
  });
}

$("profileBtn").addEventListener("click", () => {
  const me = state.me;
  openSheet(`<div class="sheet-head"><div class="author">${avatarHTML(me)}<div>${esc(me.display_name)}<small>@${esc(me.username)}</small></div></div><button class="close-x" data-close>${ICON.x}</button></div>
    ${me.invite_code ? `<div class="stat"><span>CODICE INVITO</span><b style="letter-spacing:2px">${esc(me.invite_code)}</b></div>` : ""}
    <p class="muted small" style="margin:0">Gli amici possono aggiungerti con @${esc(me.username)}${me.invite_code ? " o con il codice invito" : ""}.</p>
    <button class="danger" data-act="logout">Esci da PinDrop</button>`, (root) => {
    root.querySelector('[data-act="logout"]').addEventListener("click", async () => {
      await invoke("sign_out").catch(() => {});
      location.reload();
    });
  });
});

// ───────────── Camera ─────────────

async function startStream() {
  stopStream();
  const video = $("video");
  try {
    stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: state.facing, width: { ideal: 1920 }, height: { ideal: 1440 } },
      audio: false,
    });
    video.srcObject = stream;
    video.classList.toggle("front", state.facing === "user");
    await video.play().catch(() => {});
    return true;
  } catch (_) {
    return false;
  }
}
function stopStream() {
  if (stream) stream.getTracks().forEach((t) => t.stop());
  stream = null;
}

async function openCamera(mode) {
  state.cameraMode = mode;
  const labels = { pin: "📍 Nuovo pin", capsule: "💎 Geo-Capsula", sync: "⚡ Sync Shot" };
  $("camMode").textContent = labels[mode];
  $("countdown").classList.add("hidden");
  $("syncStatus").classList.toggle("hidden", mode !== "sync");
  $("shutter").classList.toggle("hidden", mode === "sync");
  $("camGallery").classList.toggle("hidden", mode === "sync");
  $("camera").classList.remove("hidden");
  hideSheet();
  pushLayer();
  const ok = await startStream();
  if (!ok) {
    if (mode === "sync") {
      syncStatus("Fotocamera non disponibile: consenti il permesso fotocamera a PinDrop.");
    } else {
      closeCamera();
      $("photoInput").dataset.mode = mode;
      $("photoInput").click();
    }
  }
}

function closeCamera(silent = false) {
  if ($("camera").classList.contains("hidden")) return;
  if (state.sync) {
    invoke("sync_cancel", { session: state.sync.id }).catch(() => {});
    state.sync = null;
  }
  stopStream();
  $("camera").classList.add("hidden");
  if (!silent) popLayer();
}

$("camClose").addEventListener("click", () => closeCamera());
$("camFlip").addEventListener("click", () => {
  state.facing = state.facing === "user" ? "environment" : "user";
  startStream();
});
$("camGallery").addEventListener("click", () => {
  $("photoInput").dataset.mode = state.cameraMode;
  $("photoInput").click();
});

function captureFrame() {
  const video = $("video");
  if (!video.videoWidth) return null;
  const canvas = document.createElement("canvas");
  canvas.width = video.videoWidth;
  canvas.height = video.videoHeight;
  const ctx = canvas.getContext("2d");
  if (state.facing === "user") { ctx.translate(canvas.width, 0); ctx.scale(-1, 1); }
  ctx.drawImage(video, 0, 0);
  return canvas;
}

function flash() {
  const el = $("flash");
  el.classList.remove("go");
  void el.offsetWidth;
  el.classList.add("go");
}

$("shutter").addEventListener("click", async () => {
  const frame = captureFrame();
  if (!frame) return toast("La fotocamera non è pronta.");
  flash();
  vibrate(30);
  const photo = await processImage(frame);
  const mode = state.cameraMode;
  closeCamera(true);
  openComposer(photo, mode);
});

$("photoInput").addEventListener("change", async (e) => {
  const file = e.target.files?.[0];
  const mode = e.target.dataset.mode || "pin";
  e.target.value = "";
  if (!file) return;
  try {
    const photo = await processImage(file);
    closeCamera(true);
    openComposer(photo, mode);
  } catch (_) {
    toast("Impossibile leggere la foto.");
  }
});

$("cameraBtn").addEventListener("click", () => openCamera("pin"));
$("capsuleBtn").addEventListener("click", () => openCamera("capsule"));

function canvasJPEG(source, maxSide, quality, blur = 0) {
  const w0 = source.width, h0 = source.height;
  const scale = Math.min(1, maxSide / Math.max(w0, h0));
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.round(w0 * scale));
  canvas.height = Math.max(1, Math.round(h0 * scale));
  const ctx = canvas.getContext("2d");
  if (blur) ctx.filter = `blur(${blur}px)`;
  ctx.drawImage(source, 0, 0, canvas.width, canvas.height);
  return canvas.toDataURL("image/jpeg", quality);
}

async function processImage(source) {
  let bitmap = source;
  if (source instanceof Blob) {
    try { bitmap = await createImageBitmap(source, { imageOrientation: "from-image" }); }
    catch (_) { bitmap = await createImageBitmap(source); }
  }
  const full = canvasJPEG(bitmap, 1600, 0.84);
  const thumb = canvasJPEG(bitmap, 360, 0.74);
  const tiny = document.createElement("canvas");
  const s = 24 / Math.max(bitmap.width, bitmap.height);
  tiny.width = Math.max(1, Math.round(bitmap.width * s));
  tiny.height = Math.max(1, Math.round(bitmap.height * s));
  tiny.getContext("2d").drawImage(bitmap, 0, 0, tiny.width, tiny.height);
  const blur = canvasJPEG(tiny, 240, 0.6, 6);
  const strip = (d) => d.split(",")[1];
  return { preview: full, full: strip(full), thumb: strip(thumb), blur: strip(blur) };
}

// ───────────── Composer: pin or Geo-Capsule ─────────────

function openComposer(photo, mode) {
  let current = mode === "capsule" ? "capsule" : "pin";
  const friendsOptions = state.friends.map((f) => `<option value="${f.id}">Solo ${esc(f.display_name)}</option>`).join("");
  openSheet(`${head("Pubblica")}
    <div class="preview-wrap"><img class="photo" src="${photo.preview}"></div>
    <div class="seg"><button data-mode="pin">📍 Pin</button><button data-mode="capsule">💎 Geo-Capsula</button></div>
    <div data-pane="pin"><input id="caption" type="text" maxlength="40" placeholder="Didascalia (opzionale)"></div>
    <div data-pane="capsule" style="display:flex;flex-direction:column;gap:10px">
      <input id="hint" type="text" maxlength="80" placeholder="Indizio visibile a tutti (es. sotto la panchina rossa)">
      <textarea id="secret" maxlength="140" placeholder="Messaggio segreto: si legge solo a meno di 20 m"></textarea>
      <select id="recipient"><option value="">Tutti gli amici</option>${friendsOptions}</select>
    </div>
    <button id="publishBtn" class="primary">Pubblica qui</button>
    <p id="publishNote" class="muted small center" style="margin:0"></p>`, (root) => {
    const apply = () => {
      root.querySelectorAll("[data-mode]").forEach((b) => {
        b.classList.toggle("on", b.dataset.mode === current);
        b.classList.toggle("amber", b.dataset.mode === "capsule");
      });
      root.querySelector('[data-pane="pin"]').style.display = current === "pin" ? "" : "none";
      root.querySelector('[data-pane="capsule"]').style.display = current === "capsule" ? "flex" : "none";
      const btn = root.querySelector("#publishBtn");
      btn.className = current === "capsule" ? "primary amber" : "primary";
      btn.textContent = current === "capsule" ? "💎 Nascondi la capsula qui" : "📍 Pubblica qui";
      root.querySelector("#publishNote").textContent = current === "capsule"
        ? "La capsula resta qui 24 ore. Si apre solo a meno di 20 m."
        : "Il pin sparisce dopo 6 ore.";
    };
    root.querySelectorAll("[data-mode]").forEach((b) => b.addEventListener("click", () => { current = b.dataset.mode; apply(); }));
    apply();
    root.querySelector("#publishBtn").addEventListener("click", async (e) => {
      const btn = e.currentTarget;
      btn.disabled = true;
      const label = btn.textContent;
      btn.textContent = "Pubblico…";
      try {
        if (!(await ensurePermission(true))) throw new Error("Serve la posizione per pubblicare.");
        const pos = (await currentPosition()) || state.myPos;
        if (!pos) throw new Error("Posizione non disponibile, riprova all'aperto.");
        state.myPos = pos;
        if (current === "capsule") {
          const secret = root.querySelector("#secret").value.trim();
          if (!secret) throw new Error("Scrivi il messaggio segreto.");
          await invoke("create_capsule", {
            lat: pos.lat, lon: pos.lon,
            hint: root.querySelector("#hint").value,
            message: secret,
            recipient: root.querySelector("#recipient").value || null,
            full: photo.full, thumb: photo.thumb,
          });
          closeSheet();
          celebrate("💎");
          toast("Geo-Capsula nascosta qui per 24 ore");
        } else {
          const pin = await invoke("publish_pin", {
            lat: pos.lat, lon: pos.lon, caption: root.querySelector("#caption").value,
            full: photo.full, thumb: photo.thumb, blur: photo.blur, syncSessionId: null,
          });
          if (pin?.id) state.pins.unshift(pin);
          closeSheet();
          toast("Pin pubblicato! 🔓 Ora vedi le foto dei tuoi amici");
        }
        map.flyTo({ center: [pos.lon, pos.lat], zoom: 17, duration: 900 });
        await refresh();
      } catch (err) {
        toast(errorText(err));
        btn.disabled = false;
        btn.textContent = label;
      }
    });
  });
}

// ───────────── Pin viewer ─────────────

function openPins(pins, index = 0) {
  if (!pins.length) return;
  const pin = pins[index];
  if (isLocked(pin)) return toast("🔒 Pubblica una tua foto per vedere quelle dei tuoi amici");
  const partner = syncPartnerPin(pin);
  const mine = isMine(pin);
  const reactionsHTML = () => REACTIONS.map((emoji) => {
    const list = pin.reactions || [];
    const count = list.filter((r) => r.emoji === emoji).length;
    const on = list.some((r) => r.emoji === emoji && r.user_id === state.me.id);
    return `<button class="${on ? "on" : ""}" data-emoji="${emoji}">${emoji}${count ? " " + count : ""}</button>`;
  }).join("");
  const media = pin.sync_session_id
    ? `<div class="split"><img data-full="${esc(pin.image_path)}" src="${esc(pinThumbURL(pin) || "")}">${partner ? `<img data-full="${esc(partner.image_path)}" src="${esc(pinThumbURL(partner) || "")}">` : `<div class="wait">In attesa dell'altra metà…</div>`}<div class="seam"></div><div class="bolt">${ICON.bolt}</div><div class="sign glass">${esc(firstName(pin.author))} <span style="color:var(--emerald2)">×</span> ${esc(partner ? firstName(partner.author) : "…")}</div></div>`
    : `<img class="photo" data-full="${esc(pin.image_path)}" src="${esc(pinThumbURL(pin) || "")}">`;
  openSheet(`<div class="sheet-head"><div class="author">${avatarHTML(pin.author)}<div>${esc(mine ? "Tu" : pin.author?.display_name)}<small>${esc(ago(pin.created_at))}${pin.place_name ? " · " + esc(pin.place_name) : ""} · scade tra ${esc(until(pin.expires_at))}</small></div></div><button class="close-x" data-close>${ICON.x}</button></div>
    ${media}
    ${pin.caption ? `<p class="caption">${esc(pin.caption)}</p>` : ""}
    ${state.crossPins.has(pin.id) && !mine ? `<p class="muted small" style="margin:0">💫 Sbloccata perché vi siete sfiorati</p>` : ""}
    <div class="reactions">${reactionsHTML()}</div>
    ${pins.length > 1 ? `<div class="row"><button class="ghost grow" data-nav="-1" ${index === 0 ? "disabled" : ""}>‹ Precedente</button><span class="muted small">${index + 1}/${pins.length}</span><button class="ghost grow" data-nav="1" ${index === pins.length - 1 ? "disabled" : ""}>Successiva ›</button></div>` : ""}
    ${mine ? `<button class="danger" data-act="delete">Elimina pin</button>` : ""}`, async (root) => {
    root.querySelectorAll("[data-nav]").forEach((b) => b.addEventListener("click", () => openPins(pins, index + Number(b.dataset.nav))));
    root.querySelector(".reactions").addEventListener("click", async (e) => {
      const btn = e.target.closest("[data-emoji]");
      if (!btn) return;
      const emoji = btn.dataset.emoji;
      pin.reactions = pin.reactions || [];
      const add = !pin.reactions.some((r) => r.emoji === emoji && r.user_id === state.me.id);
      if (add) pin.reactions.push({ emoji, user_id: state.me.id });
      else pin.reactions = pin.reactions.filter((r) => !(r.emoji === emoji && r.user_id === state.me.id));
      root.querySelector(".reactions").innerHTML = reactionsHTML();
      vibrate(15);
      try { await invoke("toggle_reaction", { pinId: pin.id, emoji, add }); } catch (err) { toast(errorText(err)); }
    });
    root.querySelector('[data-act="delete"]')?.addEventListener("click", async () => {
      if (!confirm("Eliminare questo pin?")) return;
      try {
        await invoke("delete_pin", { id: pin.id });
        state.pins = state.pins.filter((p) => p.id !== pin.id);
        closeSheet();
        refresh();
      } catch (err) { toast(errorText(err)); }
    });
    const imgs = [...root.querySelectorAll("[data-full]")];
    const urls = await signed("pins", imgs.map((i) => i.dataset.full));
    imgs.forEach((img) => { if (urls[img.dataset.full]) img.src = urls[img.dataset.full]; });
  });
}

// ───────────── Geo-Capsules ─────────────

function isCapsuleOpen(cap) {
  return isMine(cap) || state.opens.some((o) => o.capsule_id === cap.id && o.user_id === state.me.id);
}

async function openCapsule(cap, justOpened = false) {
  if (!cap) return;
  const mine = isMine(cap);
  const opened = isCapsuleOpen(cap);
  const dist = state.myPos ? distance(state.myPos, pinPos(cap)) : null;
  const title = mine ? "La tua Geo-Capsula" : `Geo-Capsula di ${esc(firstName(cap.author))}`;
  const forMe = cap.recipient_id && cap.recipient_id === state.me.id;
  openSheet(`${head(title)}
    <div class="gem-hero">${ICON.gem(opened && !mine)}</div>
    ${cap.hint ? `<div class="stat"><span>INDIZIO</span><b style="font-size:17px">${esc(cap.hint)}</b></div>` : ""}
    <p class="muted small center" style="margin:0">${forMe ? "🎯 Solo per te · " : ""}${dist != null ? "a " + distanceText(dist) + " · " : ""}scade tra ${esc(until(cap.expires_at))}</p>
    <div id="capsuleContent"></div>
    ${!opened ? (dist != null && dist <= CAPSULE_M
      ? `<button class="primary amber" data-act="open">💎 Apri la capsula</button>`
      : `<p class="muted center" style="margin:0">Avvicinati a meno di ${CAPSULE_M} m per aprirla.</p><button class="ghost" data-act="go">📍 Mostra sulla mappa</button>`) : ""}
    ${mine ? `<button class="danger" data-act="delete">Elimina capsula</button>` : ""}`, async (root) => {
    root.querySelector('[data-act="go"]')?.addEventListener("click", () => { closeSheet(); map.flyTo({ center: [cap.longitude, cap.latitude], zoom: 17.5, duration: 900 }); });
    root.querySelector('[data-act="open"]')?.addEventListener("click", () => tryOpenCapsule(cap, true));
    root.querySelector('[data-act="delete"]')?.addEventListener("click", async () => {
      if (!confirm("Eliminare questa capsula?")) return;
      try { await invoke("delete_capsule", { id: cap.id }); closeSheet(); refresh(); } catch (err) { toast(errorText(err)); }
    });
    if (opened) {
      const box = root.querySelector("#capsuleContent");
      try {
        const [urls, secret] = await Promise.all([signed("capsules", [cap.image_path]), invoke("capsule_secret", { id: cap.id }).catch(() => null)]);
        if (!box.isConnected) return;
        box.innerHTML = `${urls[cap.image_path] ? `<img class="photo" src="${esc(urls[cap.image_path])}">` : ""}${secret ? `<div class="secret" style="margin-top:12px">🔐 ${esc(secret)}</div>` : ""}`;
      } catch (_) {}
      if (justOpened) celebrate("✨");
    }
  });
}

async function tryOpenCapsule(cap, manual) {
  if (state.opening.has(cap.id)) return;
  state.opening.add(cap.id);
  try {
    const pos = (await currentPosition()) || state.myPos;
    if (!pos) throw new Error("Posizione non disponibile.");
    const ok = await invoke("open_capsule", { id: cap.id, lat: pos.lat, lon: pos.lon });
    if (ok) {
      state.opens.push({ capsule_id: cap.id, user_id: state.me.id, opened_at: new Date().toISOString() });
      vibrate([40, 50, 80]);
      updateZones();
      scheduleLayout(true);
      openCapsule(cap, true);
    } else if (manual) {
      toast(`Avvicinati ancora: devi essere a meno di ${CAPSULE_M} m.`);
    }
  } catch (err) {
    if (manual) toast(errorText(err));
  } finally {
    setTimeout(() => state.opening.delete(cap.id), 20000);
  }
}

function checkCapsuleProximity() {
  if (!state.myPos || state.sync) return;
  for (const cap of state.capsules) {
    if (isCapsuleOpen(cap)) continue;
    if (distance(state.myPos, pinPos(cap)) <= CAPSULE_M) {
      tryOpenCapsule(cap, false);
      break;
    }
  }
}

function celebrate(emoji) {
  const box = $("celebration");
  const colors = ["#7c3aed", "#a855f7", "#10b981", "#f59e0b", "#f472b6", "#fde68a"];
  box.innerHTML = Array.from({ length: 70 }, () => {
    const left = Math.random() * 100;
    const dur = 1.6 + Math.random() * 1.6;
    const delay = Math.random() * 0.5;
    const c = colors[Math.floor(Math.random() * colors.length)];
    return `<div class="confetti" style="left:${left}%;background:${c};animation-duration:${dur}s;animation-delay:${delay}s"></div>`;
  }).join("") + `<div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font-size:96px;animation:tick 1.4s ease-out forwards">${emoji}</div>`;
  box.classList.remove("hidden");
  setTimeout(() => { box.classList.add("hidden"); box.innerHTML = ""; }, 3400);
}

// ───────────── Sync Shot ─────────────

$("syncBtn").addEventListener("click", () => {
  const candidates = syncCandidates();
  if (!candidates.length) return toast(`⚡ Avvicinati a meno di ${SYNC_M} m da un amico per un Sync Shot`);
  if (candidates.length === 1) return startSync(candidates[0]);
  openSheet(`${head("⚡ Sync Shot con…")}${candidates.map((p) => `<div class="person" data-friend="${p.id}">${avatarHTML(p)}<div class="info"><b>${esc(p.display_name)}</b><span>vicino a te</span></div><button class="mini sync-chip">⚡</button></div>`).join("")}`, (root) => {
    root.addEventListener("click", (e) => {
      const row = e.target.closest("[data-friend]");
      if (row) startSync(profileOf(row.dataset.friend));
    });
  });
});

function syncStatus(text) {
  const el = $("syncStatus");
  el.innerHTML = text;
  el.classList.toggle("hidden", !text);
}

async function startSync(friend) {
  if (!friend || state.sync) return;
  try {
    const row = await invoke("sync_invite", { partner: friend.id });
    if (!row?.id) throw new Error("Impossibile avviare il Sync Shot.");
    await openCamera("sync");
    state.sync = { id: row.id, partner: friend, offset: 0 };
    syncStatus(`⚡ Invito inviato a <b>${esc(firstName(friend))}</b>…<br><span class="muted small">Puntate le fotocamere: lo scatto parte da solo per tutti e due.</span>`);
    runSyncLoop(state.sync);
  } catch (err) {
    toast(errorText(err));
  }
}

async function pollInvites() {
  if (state.sync || !state.me) return;
  try {
    const rows = await invoke("pending_sync_invites");
    const invite = (rows || []).find((r) => !state.dismissedInvites.has(r.id));
    const banner = $("inviteBanner");
    if (!invite) { state.invite = null; return banner.classList.add("hidden"); }
    if (state.invite?.id === invite.id) return;
    state.invite = invite;
    const from = profileOf(invite.initiator_id);
    if (!from) return;
    vibrate([60, 80, 60]);
    banner.innerHTML = `${avatarHTML(from)}<div class="grow"><div class="title">⚡ ${esc(firstName(from))} vuole un Sync Shot</div><div class="sub">Scatto sincronizzato, una foto a testa</div></div><button class="mini accept" data-ok>Vai</button><button class="close-x" data-no>${ICON.x}</button>`;
    banner.classList.remove("hidden");
    banner.onclick = async (e) => {
      if (e.target.closest("[data-no]")) {
        state.dismissedInvites.add(invite.id);
        banner.classList.add("hidden");
        invoke("sync_respond", { session: invite.id, accept: false }).catch(() => {});
        return;
      }
      if (!e.target.closest("[data-ok]")) return;
      state.dismissedInvites.add(invite.id);
      banner.classList.add("hidden");
      try {
        await invoke("sync_respond", { session: invite.id, accept: true });
        await openCamera("sync");
        state.sync = { id: invite.id, partner: from, offset: 0 };
        syncStatus(`⚡ Pronti con <b>${esc(firstName(from))}</b>…`);
        runSyncLoop(state.sync);
      } catch (err) { toast(errorText(err)); }
    };
  } catch (_) {}
}

async function runSyncLoop(s) {
  const startedAt = Date.now();
  while (state.sync === s) {
    const t0 = Date.now();
    let row = null;
    try { row = await invoke("sync_poll", { session: s.id }); } catch (_) {}
    const t1 = Date.now();
    if (state.sync !== s) return;
    if (row) {
      if (row.server_now) s.offset = new Date(row.server_now).getTime() - (t0 + t1) / 2;
      if (row.status === "ready") {
        syncStatus(`⚡ <b>${esc(firstName(s.partner))}</b> è pronto!`);
        try { await invoke("sync_arm", { session: s.id }); } catch (_) {}
      } else if (row.status === "armed" && row.fire_at) {
        return countdown(s, new Date(row.fire_at).getTime() - s.offset);
      } else if (row.status === "cancelled") {
        state.sync = null;
        closeCamera();
        return toast(`${firstName(s.partner)} ha annullato il Sync Shot`);
      }
    }
    if (Date.now() - startedAt > 90000) {
      closeCamera();
      return toast("Sync Shot scaduto");
    }
    await sleep(500);
  }
}

async function countdown(s, fireAt) {
  syncStatus("");
  const el = $("countdown");
  for (const n of [3, 2, 1]) {
    const wait = fireAt - n * 1000 - Date.now();
    if (wait > 0) await sleep(wait);
    if (state.sync !== s) return;
    el.textContent = n;
    el.classList.remove("hidden", "tick");
    void el.offsetWidth;
    el.classList.add("tick");
    vibrate(45);
  }
  const wait = fireAt - Date.now();
  if (wait > 0) await sleep(wait);
  if (state.sync !== s) return;
  el.classList.add("hidden");
  const frame = captureFrame();
  flash();
  vibrate(140);
  if (!frame) {
    state.sync = null;
    closeCamera();
    return toast("La fotocamera non era pronta, riprova.");
  }
  syncStatus("📤 Pubblico la tua metà…");
  try {
    const photo = await processImage(frame);
    const pos = state.myPos || (await currentPosition());
    if (!pos) throw new Error("Posizione non disponibile.");
    const pin = await invoke("publish_pin", {
      lat: pos.lat, lon: pos.lon, caption: "", full: photo.full, thumb: photo.thumb, blur: photo.blur, syncSessionId: s.id,
    });
    if (pin?.id) state.pins.unshift(pin);
    syncStatus(`⏳ Aspetto la foto di <b>${esc(firstName(s.partner))}</b>…`);
    let partnerPin = null;
    for (let i = 0; i < 25 && !partnerPin; i++) {
      await sleep(1500);
      const pins = await invoke("fetch_pins").catch(() => null);
      if (pins) {
        state.pins = pins;
        partnerPin = pins.find((p) => p.sync_session_id === s.id && p.author?.id === s.partner.id);
      }
    }
    state.sync = null;
    closeCamera(true);
    await signed("pins", state.pins.map((p) => (isLocked(p) ? p.blur_path : p.thumb_path)));
    celebrate("⚡");
    const mine = state.pins.find((p) => p.sync_session_id === s.id && isMine(p)) || pin;
    openPins([mine]);
    refresh();
  } catch (err) {
    state.sync = null;
    closeCamera();
    toast(errorText(err));
  }
}

// ───────────── Recap ─────────────

$("recapBtn").addEventListener("click", openRecap);

function recapSummary() {
  const mine = myActivePins().sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
  const path = state.route.coords.length >= 2 ? state.route.coords.map(([lon, lat]) => ({ lat, lon })) : mine.map(pinPos);
  let meters = 0;
  for (let i = 1; i < path.length; i++) meters += distance(path[i - 1], path[i]);
  const spots = [];
  for (const p of mine) if (!spots.some((s) => distance(s, pinPos(p)) <= 25)) spots.push(pinPos(p));
  const met = new Map();
  for (const ev of state.cross) { const f = profileOf(ev.friendId); if (f) met.set(f.id, f); }
  for (const p of mine) {
    const partner = syncPartnerPin(p);
    if (partner?.author) met.set(partner.author.id, partner.author);
    for (const o of state.pins) {
      if (!isMine(o) && o.author && distance(pinPos(o), pinPos(p)) <= 25 && Math.abs(new Date(o.created_at) - new Date(p.created_at)) <= 3600000) met.set(o.author.id, o.author);
    }
  }
  const minutes = mine.length > 1 ? (new Date(mine[mine.length - 1].created_at) - new Date(mine[0].created_at)) / 60000 : 0;
  return { pins: mine, path, meters, spots: spots.length, friends: [...met.values()], minutes };
}

function durationText(min) {
  if (min < 1) return "—";
  if (min < 60) return `${Math.round(min)} min`;
  return `${Math.floor(min / 60)} h ${Math.round(min % 60)}`;
}

async function openRecap() {
  const sum = recapSummary();
  if (!sum.pins.length) {
    return openSheet(`${head("Recap della serata")}<p class="muted">Scatta almeno una foto stasera: il Recap disegna il tuo percorso tra i pin e crea una storia da condividere.</p><button class="primary" data-act="cam">📸 Scatta ora</button>`, (root) => {
      root.querySelector('[data-act="cam"]').addEventListener("click", () => openCamera("pin"));
    });
  }
  openSheet(`${head("La tua serata ✨")}
    <div class="stats">
      <div class="stat"><b>${distanceText(sum.meters)}</b><span>PERCORSI</span></div>
      <div class="stat"><b>${sum.spots}</b><span>SPOT</span></div>
      <div class="stat"><b>${sum.friends.length}</b><span>AMICI INCONTRATI</span></div>
      <div class="stat"><b>${durationText(sum.minutes)}</b><span>DURATA</span></div>
    </div>
    <img id="storyImg" class="story" alt="">
    <p id="storyNote" class="muted small center" style="margin:0">Creo la tua storia 9:16…</p>
    <button id="saveStory" class="primary" disabled>⬇️ Salva nella galleria</button>`, async (root) => {
    try {
      const dataURL = await renderStory(sum);
      if (!root.isConnected) return;
      root.querySelector("#storyImg").src = dataURL;
      root.querySelector("#storyNote").textContent = "Pronta da condividere nelle storie.";
      const btn = root.querySelector("#saveStory");
      btn.disabled = false;
      btn.addEventListener("click", async () => {
        try {
          const path = await invoke("save_image", { data: dataURL.split(",")[1], name: `pindrop-recap-${Date.now()}` });
          toast(`Salvata: ${path.replace("/storage/emulated/0/", "")}`);
        } catch (err) { toast("Non riesco a salvare l'immagine."); }
      });
    } catch (_) {
      root.querySelector("#storyNote").textContent = "Non riesco a creare la storia.";
    }
  });
}

async function loadImage(b64) {
  const img = new Image();
  img.src = "data:image/jpeg;base64," + b64;
  await img.decode();
  return img;
}

async function renderStory(sum) {
  const W = 1080, H = 1920;
  const c = document.createElement("canvas");
  c.width = W; c.height = H;
  const g = c.getContext("2d");
  const bg = g.createLinearGradient(0, 0, 0, H);
  bg.addColorStop(0, "#1a0b3a"); bg.addColorStop(0.55, "#0e0d22"); bg.addColorStop(1, "#06070f");
  g.fillStyle = bg; g.fillRect(0, 0, W, H);
  const glow = (x, y, r, color) => { const rg = g.createRadialGradient(x, y, 0, x, y, r); rg.addColorStop(0, color); rg.addColorStop(1, "transparent"); g.fillStyle = rg; g.fillRect(0, 0, W, H); };
  glow(200, 300, 600, "rgba(124,58,237,.45)");
  glow(950, 1500, 600, "rgba(16,185,129,.28)");

  g.textAlign = "left";
  g.fillStyle = "rgba(255,255,255,.6)";
  g.font = "800 34px sans-serif";
  g.fillText("LA MIA SERATA", 90, 170);
  g.fillStyle = "white";
  g.font = "900 78px sans-serif";
  const date = new Date(sum.pins[0].created_at).toLocaleDateString("it-IT", { weekday: "long", day: "numeric", month: "long" });
  g.fillText(date.charAt(0).toUpperCase() + date.slice(1), 90, 260);

  // Map card
  const box = { x: 70, y: 330, w: 940, h: 940 };
  g.save();
  g.beginPath(); g.roundRect(box.x, box.y, box.w, box.h, 56); g.clip();
  g.fillStyle = "rgba(255,255,255,.045)"; g.fillRect(box.x, box.y, box.w, box.h);
  g.strokeStyle = "rgba(255,255,255,.04)"; g.lineWidth = 2;
  for (let i = 1; i < 10; i++) {
    g.beginPath(); g.moveTo(box.x + (box.w / 10) * i, box.y); g.lineTo(box.x + (box.w / 10) * i, box.y + box.h); g.stroke();
    g.beginPath(); g.moveTo(box.x, box.y + (box.h / 10) * i); g.lineTo(box.x + box.w, box.y + (box.h / 10) * i); g.stroke();
  }
  const pts = sum.path.length ? sum.path : sum.pins.map(pinPos);
  const lat0 = pts.reduce((a, p) => a + p.lat, 0) / pts.length;
  const k = Math.cos((lat0 * Math.PI) / 180);
  const xs = pts.map((p) => p.lon * k), ys = pts.map((p) => p.lat);
  const minX = Math.min(...xs), maxX = Math.max(...xs), minY = Math.min(...ys), maxY = Math.max(...ys);
  const span = Math.max(maxX - minX, maxY - minY, 0.0015);
  const pad = 130;
  const scale = (box.w - pad * 2) / span;
  const cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
  const proj = (p) => [box.x + box.w / 2 + (p.lon * k - cx) * scale, box.y + box.h / 2 - (p.lat - cy) * scale];
  if (pts.length >= 2) {
    g.lineCap = "round"; g.lineJoin = "round";
    g.beginPath(); pts.forEach((p, i) => { const [x, y] = proj(p); i ? g.lineTo(x, y) : g.moveTo(x, y); });
    g.strokeStyle = "rgba(168,85,247,.35)"; g.lineWidth = 34; g.shadowColor = "#a855f7"; g.shadowBlur = 40; g.stroke();
    g.shadowBlur = 0;
    const lg = g.createLinearGradient(box.x, box.y, box.x + box.w, box.y + box.h);
    lg.addColorStop(0, "#c084fc"); lg.addColorStop(1, "#34d399");
    g.strokeStyle = lg; g.lineWidth = 12; g.setLineDash([30, 22]); g.stroke(); g.setLineDash([]);
  }
  const urls = await signed("pins", sum.pins.map((p) => p.thumb_path));
  for (let i = 0; i < sum.pins.length; i++) {
    const p = sum.pins[i];
    const [x, y] = proj(pinPos(p));
    const r = 54;
    g.save();
    g.shadowColor = "rgba(0,0,0,.6)"; g.shadowBlur = 24;
    g.fillStyle = "white"; g.beginPath(); g.arc(x, y, r + 7, 0, Math.PI * 2); g.fill();
    g.restore();
    try {
      const img = await loadImage(await invoke("fetch_image_b64", { url: urls[p.thumb_path] }));
      g.save(); g.beginPath(); g.arc(x, y, r, 0, Math.PI * 2); g.clip();
      const s = Math.max((r * 2) / img.width, (r * 2) / img.height);
      g.drawImage(img, x - (img.width * s) / 2, y - (img.height * s) / 2, img.width * s, img.height * s);
      g.restore();
    } catch (_) {
      g.fillStyle = "#7c3aed"; g.beginPath(); g.arc(x, y, r, 0, Math.PI * 2); g.fill();
    }
    g.fillStyle = "#7c3aed"; g.beginPath(); g.arc(x + r * 0.75, y - r * 0.75, 24, 0, Math.PI * 2); g.fill();
    g.fillStyle = "white"; g.font = "900 26px sans-serif"; g.textAlign = "center"; g.textBaseline = "middle";
    g.fillText(String(i + 1), x + r * 0.75, y - r * 0.75 + 1);
    g.textBaseline = "alphabetic";
  }
  g.restore();

  // Stats
  const stats = [[distanceText(sum.meters), "percorsi"], [String(sum.spots), "spot"], [String(sum.friends.length), "amici"]];
  stats.forEach(([v, l], i) => {
    const x = 90 + i * 320;
    g.textAlign = "left";
    g.fillStyle = "white"; g.font = "900 84px sans-serif"; g.fillText(v, x, 1430);
    g.fillStyle = "rgba(255,255,255,.55)"; g.font = "800 32px sans-serif"; g.fillText(l.toUpperCase(), x, 1480);
  });
  if (sum.friends.length) {
    g.fillStyle = "rgba(255,255,255,.75)"; g.font = "700 40px sans-serif"; g.textAlign = "left";
    const names = sum.friends.slice(0, 4).map(firstName).join(", ") + (sum.friends.length > 4 ? ` +${sum.friends.length - 4}` : "");
    g.fillText(`Con ${names} 💜`, 90, 1600);
  }
  // Footer
  const fg = g.createLinearGradient(330, 0, 750, 0);
  fg.addColorStop(0, "#7c3aed"); fg.addColorStop(1, "#10b981");
  g.fillStyle = fg; g.beginPath(); g.roundRect(330, 1730, 420, 96, 48); g.fill();
  g.fillStyle = "white"; g.font = "900 46px sans-serif"; g.textAlign = "center"; g.fillText("📍 PinDrop", 540, 1793);
  return c.toDataURL("image/jpeg", 0.9);
}

// ───────────── Boot ─────────────

(async function boot() {
  try {
    const userID = await invoke("restore_session");
    if (userID) return await enter();
  } catch (_) {}
  show("auth");
})();
