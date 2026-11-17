// PinDrop for Android: the features that iOS had and Android was missing.
// Profile (photo, username, bio, status, color), onboarding, friends extras (remove,
// suggestions, contacts, QR, profile views, time together, location reminders),
// "On my way" pings, public places with the visitors leaderboard, the 3D globe with
// objects in orbit, edge zoom and the home screen widget.

const INVITE_URL = "https://apps.apple.com/app/pindrop";
const AVATAR_COLORS = ["#7C3AED", "#A855F7", "#10B981", "#F97316", "#EC4899", "#06B6D4", "#EAB308", "#3B82F6", "#EF4444", "#14B8A6", "#8B5CF6", "#F43F5E"];
const STATUS_EMOJI = ["", "😎", "☕️", "🎧", "📚", "🏃", "🍕", "🎉", "🌙", "✈️", "💼", "🎮"];
const BEST_FRIEND_SECONDS = 7200;
const WALK_MPS = 1.35;

const extra = {
  friendTimes: new Map(),
  permissions: new Map(),
  suggestions: [],
  publicPlaces: [],
  contactPhones: new Map(),
  online: null,
  widgetKey: "",
  lastHeartbeat: 0,
};

// ───────────── Database helpers ─────────────

function api(method, path, query = [], body = null, prefer = null) {
  return invoke("api", { method, path: "/rest/v1/" + path, query, body, prefer });
}
const rpc = (name, args = {}) => api("POST", "rpc/" + name, [], args);
const nowISO = () => new Date().toISOString();
const avatarPublicURL = (path) => `${SUPABASE_URL}/storage/v1/object/public/avatars/${path}`;

function spanText(seconds) {
  const s = Math.max(0, Math.round(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.round((s % 3600) / 60);
  if (h && m) return `${h} h ${m} min`;
  if (h) return `${h} h`;
  return `${Math.max(1, m)} min`;
}

async function sha256(text) {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
const normalizedPhone = (phone) => {
  const digits = String(phone || "").replace(/[^0-9]/g, "");
  return digits.length >= 6 ? digits.slice(-10) : null;
};
async function phoneHash(phone) {
  const n = normalizedPhone(phone);
  return n ? sha256(n) : null;
}
async function emailHash(email) {
  const e = String(email || "").trim().toLowerCase();
  return e.includes("@") ? sha256(e) : null;
}

function sanitizeUsername(raw) {
  return String(raw || "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z0-9._]/g, "").slice(0, 24);
}
const validUsername = (u) => /^[a-z0-9._]{3,24}$/.test(u);

async function usernameAvailable(username) {
  const rows = await api("GET", "profiles", [["select", "id"], ["username", "eq." + username], ["limit", "1"]]);
  return (rows || []).every((r) => r.id === state.me.id);
}

function inviteMessage() {
  return `Vieni su PinDrop! Aggiungimi con il mio codice ${state.me.invite_code || "@" + state.me.username} · scarica l'app: ${INVITE_URL}`;
}

// ───────────── Startup ─────────────

function startExtras() {
  loadFriendTimes();
  loadPermissions();
  loadSuggestions();
  setInterval(loadFriendTimes, 120000);
  setInterval(loadPermissions, 120000);
  setInterval(heartbeat, 60000);
  setTimeout(heartbeat, 8000);
  setInterval(checkPings, 20000);
  setTimeout(checkPings, 3000);
  setInterval(checkOnlineArrivals, 15000);
  setInterval(loadPublicPlaces, 300000);
  setTimeout(loadPublicPlaces, 2500);
  setInterval(syncWidget, 60000);
  setTimeout(syncWidget, 6000);
}

// ───────────── Onboarding ─────────────

function showOnboarding() {
  if (localStorage.getItem("pd.onboarded")) return Promise.resolve();
  return new Promise((resolve) => {
    const pages = [
      { icon: "📍", title: "Fissa il momento", body: "Scatta un POV live e fissalo sulla mappa dei tuoi amici. Niente galleria, filtri o AI: solo il momento." },
      { icon: "🔓", title: "Dai per ricevere", body: "I pin degli amici restano sfocati finché non pubblichi il tuo. Ogni pin svanisce dopo 6 ore." },
      { icon: "🛡️", title: "Privacy al primo posto", body: "La tua posizione la vedono solo i tuoi amici. Decidi tu se condividerla anche ad app chiusa, e puoi spegnerla quando vuoi." },
    ];
    let index = 0;
    const el = document.createElement("div");
    el.className = "onboarding";
    document.body.appendChild(el);
    const finish = () => {
      localStorage.setItem("pd.onboarded", "1");
      el.classList.add("leaving");
      setTimeout(() => el.remove(), 300);
      resolve();
    };
    const render = () => {
      const last = index === pages.length;
      const dots = [...pages, null].map((_, i) => `<i class="${i === index ? "on" : ""}"></i>`).join("");
      el.innerHTML = `<div class="aurora"></div>
        <button class="ob-skip" data-skip>Salta</button>
        <div class="ob-page">${last ? `
          <div class="ob-icon">✨</div><h1>Due permessi e sei dentro</h1>
          <div class="ob-perm"><div class="ob-perm-icon">📷</div><div class="grow"><b>Fotocamera</b><span>Solo foto live. Mai la galleria.</span></div><button class="mini" data-perm="camera">Consenti</button></div>
          <div class="ob-perm"><div class="ob-perm-icon">📍</div><div class="grow"><b>Posizione</b><span>Per fissare i pin dove sei e vedere gli amici vicini.</span></div><button class="mini" data-perm="location">Consenti</button></div>`
          : `<div class="ob-icon">${pages[index].icon}</div><h1>${esc(pages[index].title)}</h1><p>${esc(pages[index].body)}</p>`}
        </div>
        <div class="ob-dots">${dots}</div>
        <button class="primary ob-next" data-next>${last ? "Inizia a pubblicare" : "Continua"}</button>`;
      el.querySelector("[data-skip]").onclick = finish;
      el.querySelector("[data-next]").onclick = () => { vibrate(10); if (last) finish(); else { index++; render(); } };
      el.querySelectorAll("[data-perm]").forEach((b) => b.addEventListener("click", async () => {
        let ok = false;
        if (b.dataset.perm === "camera") {
          try {
            const s = await navigator.mediaDevices.getUserMedia({ video: true });
            s.getTracks().forEach((t) => t.stop());
            ok = true;
          } catch (_) {}
        } else {
          ok = await ensurePermission(true).catch(() => false);
        }
        b.textContent = ok ? "✓ Consentito" : "Impostazioni";
        b.classList.toggle("ok", ok);
        if (!ok) b.onclick = () => invoke("open_app_settings").catch(() => {});
      }));
    };
    render();
  });
}

// Live check of the username on the first setup screen.
(() => {
  const input = $("username");
  if (!input) return;
  let timer;
  input.addEventListener("input", () => {
    const clean = sanitizeUsername(input.value);
    if (clean !== input.value) input.value = clean;
    clearTimeout(timer);
    const msg = $("setupMsg");
    if (!clean) return (msg.textContent = "");
    if (!validUsername(clean)) { msg.className = "msg"; return (msg.textContent = "Usa 3–24 lettere, numeri, punti o trattini bassi."); }
    timer = setTimeout(async () => {
      if (!state.me) return;
      try {
        const ok = await usernameAvailable(clean);
        if (input.value !== clean) return;
        msg.className = ok ? "msg ok" : "msg";
        msg.textContent = ok ? "Disponibile!" : "Questo username è già in uso.";
      } catch (_) {}
    }, 400);
  });
})();

// ───────────── Edit profile ─────────────

function cropSquareJPEG(bitmap, size = 512, quality = 0.86) {
  const canvas = document.createElement("canvas");
  canvas.width = size;
  canvas.height = size;
  const side = Math.min(bitmap.width, bitmap.height);
  const sx = (bitmap.width - side) / 2;
  const sy = (bitmap.height - side) / 2;
  canvas.getContext("2d").drawImage(bitmap, sx, sy, side, side, 0, 0, size, size);
  return canvas.toDataURL("image/jpeg", quality);
}

function openEditProfile() {
  const me = state.me;
  const draft = {
    display_name: me.display_name || "",
    username: me.username || "",
    bio: me.bio || "",
    status_emoji: me.status_emoji || "",
    avatar_color: me.avatar_color || AVATAR_COLORS[0],
    avatar_path: me.avatar_path || null,
    photo: null, // new photo data URL
    removed: false,
  };
  let usernameOK = true;
  openSheet(`${head("Modifica profilo")}
    <div class="edit-avatar"><div id="editAvatar"></div>
      <div class="row center"><button class="ghost mini-btn" data-act="photo">📷 Scegli foto</button><button class="ghost mini-btn" data-act="nophoto">Rimuovi</button></div>
      <input id="avatarInput" type="file" accept="image/*" hidden></div>
    <label class="field-label">Nome</label>
    <div class="field"><input id="editName" type="text" maxlength="40" placeholder="Il tuo nome"></div>
    <label class="field-label">Username</label>
    <div class="field at"><input id="editUser" type="text" maxlength="24" autocapitalize="none" autocomplete="off" placeholder="username"></div>
    <p id="editUserMsg" class="muted small" style="margin:-4px 4px 0">3–24 caratteri: lettere, numeri, punto e trattino basso.</p>
    <label class="field-label">Bio <span id="bioCount" class="muted small"></span></label>
    <textarea id="editBio" maxlength="160" placeholder="Due parole su di te"></textarea>
    <label class="field-label">Stato</label>
    <div class="emoji-grid" id="editStatus">${STATUS_EMOJI.map((e) => `<button data-emoji="${e}">${e || "∅"}</button>`).join("")}</div>
    <label class="field-label">Colore</label>
    <div class="color-grid" id="editColor">${AVATAR_COLORS.map((c) => `<button data-color="${c}" style="background:${c}"></button>`).join("")}</div>
    <button id="editSave" class="primary">Salva</button>
    <p id="editMsg" class="msg"></p>`, (root) => {
    const $r = (s) => root.querySelector(s);
    const preview = () => {
      const p = { ...me, ...draft, avatar_path: draft.removed ? null : draft.avatar_path };
      if (draft.photo) $r("#editAvatar").innerHTML = `<div class="avatar big" style="background-image:url('${draft.photo}')"></div>`;
      else $r("#editAvatar").innerHTML = avatarHTML(p, "big");
      root.querySelectorAll("[data-emoji]").forEach((b) => b.classList.toggle("on", b.dataset.emoji === draft.status_emoji));
      root.querySelectorAll("[data-color]").forEach((b) => b.classList.toggle("on", b.dataset.color.toUpperCase() === String(draft.avatar_color).toUpperCase()));
      $r("#bioCount").textContent = `${draft.bio.length}/160`;
    };
    $r("#editName").value = draft.display_name;
    $r("#editUser").value = draft.username;
    $r("#editBio").value = draft.bio;
    $r("#editName").oninput = (e) => { draft.display_name = e.target.value.slice(0, 40); };
    $r("#editBio").oninput = (e) => { draft.bio = e.target.value.slice(0, 160); preview(); };
    let timer;
    $r("#editUser").oninput = (e) => {
      const clean = sanitizeUsername(e.target.value);
      if (clean !== e.target.value) e.target.value = clean;
      draft.username = clean;
      const msg = $r("#editUserMsg");
      clearTimeout(timer);
      usernameOK = false;
      if (!validUsername(clean)) { msg.className = "small danger-text"; return (msg.textContent = "Usa 3–24 lettere, numeri, punti o trattini bassi."); }
      if (clean === me.username) { usernameOK = true; msg.className = "muted small"; return (msg.textContent = "3–24 caratteri: lettere, numeri, punto e trattino basso."); }
      msg.className = "muted small";
      msg.textContent = "Controllo…";
      timer = setTimeout(async () => {
        try {
          const ok = await usernameAvailable(clean);
          if (draft.username !== clean) return;
          usernameOK = ok;
          msg.className = ok ? "small ok-text" : "small danger-text";
          msg.textContent = ok ? "Disponibile!" : "Questo username è già in uso.";
        } catch (_) { usernameOK = true; msg.textContent = ""; }
      }, 400);
    };
    $r("#editStatus").onclick = (e) => { const b = e.target.closest("[data-emoji]"); if (b) { draft.status_emoji = b.dataset.emoji; vibrate(8); preview(); } };
    $r("#editColor").onclick = (e) => { const b = e.target.closest("[data-color]"); if (b) { draft.avatar_color = b.dataset.color; vibrate(8); preview(); } };
    $r('[data-act="photo"]').onclick = () => $r("#avatarInput").click();
    $r('[data-act="nophoto"]').onclick = () => { draft.photo = null; draft.removed = true; preview(); };
    $r("#avatarInput").onchange = async (e) => {
      const file = e.target.files?.[0];
      e.target.value = "";
      if (!file) return;
      try {
        let bitmap;
        try { bitmap = await createImageBitmap(file, { imageOrientation: "from-image" }); } catch (_) { bitmap = await createImageBitmap(file); }
        draft.photo = cropSquareJPEG(bitmap);
        draft.removed = false;
        preview();
      } catch (_) { toast("Impossibile caricare la foto."); }
    };
    preview();
    $r("#editSave").onclick = async (e) => {
      const btn = e.currentTarget;
      const msg = $r("#editMsg");
      msg.className = "msg";
      if (!draft.display_name.trim()) return (msg.textContent = "Scrivi il tuo nome.");
      if (!validUsername(draft.username)) return (msg.textContent = "Usa 3–24 lettere, numeri, punti o trattini bassi.");
      if (!usernameOK) return (msg.textContent = "Questo username è già in uso.");
      btn.disabled = true;
      btn.textContent = "Salvo…";
      const oldPath = me.avatar_path;
      let newPath = draft.removed ? null : draft.avatar_path;
      try {
        if (draft.photo) newPath = await invoke("upload_avatar", { data: draft.photo.split(",")[1] });
        const photoChanged = newPath !== oldPath;
        const body = {
          display_name: draft.display_name.trim(),
          username: draft.username,
          bio: draft.bio.trim(),
          status_emoji: draft.status_emoji,
          avatar_color: draft.avatar_color,
          avatar_path: newPath,
          is_setup: true,
        };
        if (photoChanged) { body.avatar_live_photo = null; body.avatar_live_video = null; }
        const rows = await api("PATCH", "profiles", [["select", "*"], ["id", "eq." + me.id]], body, "return=representation");
        const fresh = Array.isArray(rows) ? rows[0] : rows;
        if (fresh) state.me = fresh;
        if (photoChanged && oldPath) invoke("delete_avatar", { path: oldPath }).catch(() => {});
        $("profileBtn").innerHTML = avatarHTML(state.me);
        scheduleLayout(true);
        closeSheet();
        toast("Profilo aggiornato ✨");
      } catch (err) {
        if (draft.photo && newPath && newPath !== oldPath) invoke("delete_avatar", { path: newPath }).catch(() => {});
        const text = String(err);
        msg.textContent = /23505|duplicate|unique/i.test(text) ? "Questo username è già in uso." : errorText(err);
        btn.disabled = false;
        btn.textContent = "Salva";
      }
    };
  });
}

// ───────────── QR and invite ─────────────

function openQR() {
  const me = state.me;
  const payload = `${INVITE_URL}?invite=${me.invite_code || me.username}`;
  let svg = "";
  try {
    const qr = qrcode(0, "M");
    qr.addData(payload);
    qr.make();
    svg = qr.createSvgTag({ cellSize: 6, margin: 2, scalable: true });
  } catch (_) {}
  openSheet(`${head("Il mio QR")}
    <p class="muted small center" style="margin:0">Inquadrami per aggiungermi</p>
    <div class="qr-card">${svg || "<p>QR non disponibile</p>"}<div class="qr-who">${avatarHTML(me)}<div><b>${esc(me.display_name)}</b><small>@${esc(me.username)}</small></div></div></div>
    <p class="muted small" style="margin:0">Mostralo a un amico: lo inquadra con la fotocamera, scarica PinDrop e ti aggiunge con il tuo codice.</p>
    ${me.invite_code ? `<button class="ghost" data-act="copy">📋 Copia codice invito · <b>${esc(me.invite_code)}</b></button>` : ""}
    <button class="primary" data-act="share">📤 Condividi invito</button>`, (root) => {
    root.querySelector('[data-act="copy"]')?.addEventListener("click", async () => {
      try { await navigator.clipboard.writeText(me.invite_code); toast("Codice copiato"); } catch (_) { toast(me.invite_code); }
    });
    root.querySelector('[data-act="share"]').addEventListener("click", () => invoke("share_text", { text: inviteMessage() }).catch((e) => toast(errorText(e))));
  });
}

// ───────────── Suggestions ─────────────

async function loadSuggestions() {
  try {
    const rows = (await rpc("suggested_friends", { lim: 20 })) || [];
    if (!rows.length) { extra.suggestions = []; return; }
    const ids = rows.map((r) => r.profile_id);
    const profiles = (await api("GET", "profiles", [["select", "*"], ["id", `in.(${ids.join(",")})`]])) || [];
    const byId = new Map(profiles.map((p) => [p.id, p]));
    extra.suggestions = rows.map((r) => byId.get(r.profile_id) && { profile: byId.get(r.profile_id), mutual: r.mutual_count, nearby: r.reason === "nearby" }).filter(Boolean);
  } catch (_) {}
}

function suggestionsHTML() {
  const known = new Set([...state.friends.map((f) => f.id), ...state.sent.map((p) => p.id), ...state.requests.map((r) => r.profile.id)]);
  const list = extra.suggestions.filter((s) => !known.has(s.profile.id));
  if (!list.length) return "";
  return `<h3>Persone che potresti conoscere</h3>` + list.map((s) => `<div class="person">${avatarHTML(s.profile)}<div class="info"><b>${esc(s.profile.display_name)}</b><span>${s.nearby ? "📍 Vicino a te" : s.mutual ? `${s.mutual} ${s.mutual === 1 ? "amico" : "amici"} in comune` : "@" + esc(s.profile.username)}</span></div><button class="mini accept" data-suggest="${esc(s.profile.username)}">Aggiungi</button></div>`).join("");
}

async function addByUsername(username, btn) {
  btn.disabled = true;
  try {
    const result = await invoke("send_friend_request", { target: username });
    btn.textContent = result === "accepted" ? "Amici 🎉" : "Inviata";
    vibrate(20);
    await loadFriends();
  } catch (e) {
    btn.disabled = false;
    toast(errorText(e));
  }
}

function renderFriendsExtras(box) {
  if (!box) return;
  box.innerHTML = `<div class="extra-actions">
      <button class="ghost grow" data-act="contacts">📇 Dai contatti</button>
      <button class="ghost grow" data-act="qr">🔳 Il mio QR</button>
      <button class="ghost grow" data-act="share">📤 Invita</button>
    </div>
    <div id="suggestBox">${suggestionsHTML()}</div>
    <p class="muted small" style="margin:6px 0 0">Tieni premuto su un amico per rimuoverlo.</p>`;
  box.querySelector('[data-act="contacts"]').onclick = openContacts;
  box.querySelector('[data-act="qr"]').onclick = openQR;
  box.querySelector('[data-act="share"]').onclick = () => invoke("share_text", { text: inviteMessage() }).catch((e) => toast(errorText(e)));
  box.onclick = (e) => {
    const b = e.target.closest("[data-suggest]");
    if (b) addByUsername(b.dataset.suggest, b);
  };
  loadSuggestions().then(() => { const s = box.querySelector("#suggestBox"); if (s) s.innerHTML = suggestionsHTML(); });
  // Long press on a friend → remove.
  const list = $("friendsList");
  if (list && !list.dataset.longpress) {
    list.dataset.longpress = "1";
    let timer = 0;
    list.addEventListener("pointerdown", (e) => {
      const row = e.target.closest("[data-friend]");
      if (!row) return;
      timer = setTimeout(() => { timer = 0; vibrate(30); confirmRemoveFriend(profileOf(row.dataset.friend)); }, 650);
    });
    const cancel = () => { clearTimeout(timer); };
    list.addEventListener("pointerup", cancel);
    list.addEventListener("pointercancel", cancel);
    list.addEventListener("pointermove", (e) => { if (Math.abs(e.movementY) > 4) cancel(); });
    list.addEventListener("contextmenu", (e) => e.preventDefault());
  }
}

// ───────────── Remove friend ─────────────

async function confirmRemoveFriend(friend) {
  if (!friend?.friendship_id) return;
  if (!confirm(`Rimuovere ${friend.display_name}?\nTu e ${firstName(friend)} non vedrete più i vostri drop.`)) return;
  try {
    await api("DELETE", "friendships", [["id", "eq." + friend.friendship_id]]);
    await loadFriends();
    if ($("friendsList")) renderFriendsList();
    else closeSheet();
    refresh();
    toast(`${firstName(friend)} rimosso dagli amici`);
  } catch (e) { toast(errorText(e)); }
}

// ───────────── Contacts ─────────────

async function waitForContacts() {
  if (await invoke("contacts_status").catch(() => false)) return true;
  await invoke("request_contacts").catch(() => {});
  for (let i = 0; i < 40; i++) {
    await new Promise((r) => setTimeout(r, 500));
    if (await invoke("contacts_status").catch(() => false)) return true;
  }
  return false;
}

function openContacts() {
  openSheet(`${head("Contatti")}
    <div id="phoneBox"></div>
    <div class="field"><input id="contactSearch" type="search" placeholder="Cerca contatti"></div>
    <div id="contactsBox"><p class="muted small">Caricamento…</p></div>`, async (root) => {
    renderPhoneBox(root.querySelector("#phoneBox"));
    const box = root.querySelector("#contactsBox");
    if (!(await waitForContacts())) {
      box.innerHTML = `<p class="muted small">Consenti l'accesso ai contatti per trovare gli amici che usano PinDrop.</p><button class="ghost" data-act="settings">Apri Impostazioni</button>`;
      box.querySelector('[data-act="settings"]').onclick = () => invoke("open_app_settings").catch(() => {});
      return;
    }
    let contacts = [];
    try { contacts = (await invoke("read_contacts")) || []; } catch (_) {
      box.innerHTML = `<p class="muted small">Impossibile caricare i contatti.</p>`;
      return;
    }
    if (!contacts.length) { box.innerHTML = `<p class="muted small">La rubrica è vuota.</p>`; return; }
    const hashTo = new Map();
    const phoneHashes = new Set();
    const emailHashes = new Set();
    for (const c of contacts) {
      c.hashes = [];
      for (const p of c.phones) {
        const h = await phoneHash(p);
        if (h) { phoneHashes.add(h); c.hashes.push(h); (hashTo.get(h) || hashTo.set(h, []).get(h)).push(c); }
      }
      for (const m of c.emails) {
        const h = await emailHash(m);
        if (h) { emailHashes.add(h); c.hashes.push(h); (hashTo.get(h) || hashTo.set(h, []).get(h)).push(c); }
      }
    }
    let matches = [];
    try { matches = (await rpc("match_contacts", { email_hashes: [...emailHashes].slice(0, 3000), phone_hashes: [...phoneHashes].slice(0, 3000) })) || []; } catch (_) {}
    const ids = [...new Set(matches.map((m) => m.profile_id))].filter((id) => id !== state.me.id);
    const profiles = ids.length ? (await api("GET", "profiles", [["select", "*"], ["id", `in.(${ids.join(",")})`]]).catch(() => [])) || [] : [];
    const byId = new Map(profiles.map((p) => [p.id, p]));
    const onApp = new Map(); // contact → profile
    for (const m of matches) {
      const p = byId.get(m.profile_id);
      if (!p) continue;
      for (const c of hashTo.get(m.matched_hash) || []) {
        onApp.set(c, p);
        const phone = c.phones[0];
        if (phone) extra.contactPhones.set(p.id, phone);
      }
    }
    const friends = new Set(state.friends.map((f) => f.id));
    const sent = new Set(state.sent.map((p) => p.id));
    const render = (q) => {
      const match = (c) => !q || c.name.toLowerCase().includes(q);
      const seen = new Set();
      const app = [...onApp.entries()].filter(([c, p]) => match(c) && !seen.has(p.id) && seen.add(p.id));
      const others = contacts.filter((c) => !onApp.has(c) && c.phones.length && match(c)).slice(0, 300);
      box.innerHTML = `${app.length ? `<h3>${app.length} su PinDrop</h3>` + app.map(([c, p]) => `<div class="person">${avatarHTML(p)}<div class="info"><b>${esc(p.display_name)}</b><span>${esc(c.name)} · @${esc(p.username)}</span></div>${friends.has(p.id) ? `<span class="muted small">Amici</span>` : sent.has(p.id) ? `<span class="muted small">Richiesta inviata</span>` : `<button class="mini accept" data-add="${esc(p.username)}">Aggiungi</button>`}</div>`).join("") : ""}
        <h3>Invita su PinDrop</h3>
        ${others.map((c) => `<div class="person"><div class="avatar" style="background:#a1a1aa">${esc(initials({ display_name: c.name }))}</div><div class="info"><b>${esc(c.name || c.phones[0])}</b><span>${esc(c.phones[0])}</span></div><button class="mini" data-invite="${esc(c.phones[0])}">Invita</button></div>`).join("") || `<p class="muted small">Nessun contatto da invitare.</p>`}`;
    };
    render("");
    root.querySelector("#contactSearch").oninput = (e) => render(e.target.value.trim().toLowerCase());
    box.onclick = (e) => {
      const add = e.target.closest("[data-add]");
      if (add) return addByUsername(add.dataset.add, add);
      const inv = e.target.closest("[data-invite]");
      if (inv) invoke("send_sms", { number: inv.dataset.invite, body: inviteMessage() }).catch((err) => toast(errorText(err)));
    };
  });
}

async function renderPhoneBox(box) {
  let saved = false;
  try {
    const rows = await api("GET", "contact_info", [["select", "phone_hash"]]);
    saved = !!rows?.[0]?.phone_hash;
  } catch (_) {}
  box.innerHTML = `<div class="phone-card"><b>Fatti trovare dagli amici col numero</b>
    ${saved ? `<div class="row"><span class="ok-text small grow">✓ Numero salvato</span><button class="ghost mini-btn" data-act="remove">Rimuovi</button></div>`
      : `<div class="row"><div class="field grow"><input id="myPhone" type="tel" placeholder="Il tuo numero di telefono"></div><button class="primary" style="padding:14px" data-act="save">Salva</button></div>`}
    <p class="muted small" style="margin:4px 0 0">Facoltativo. Viene salvata solo un'impronta anonima del numero, mai il numero.</p></div>`;
  const store = async (hash) => {
    await api("POST", "contact_info", [["on_conflict", "user_id"]], { user_id: state.me.id, phone_hash: hash, updated_at: nowISO() }, "resolution=merge-duplicates,return=minimal");
  };
  box.querySelector('[data-act="save"]')?.addEventListener("click", async () => {
    const hash = await phoneHash(box.querySelector("#myPhone").value);
    if (!hash) return toast("Numero non valido");
    try { await store(hash); toast("Numero salvato"); renderPhoneBox(box); } catch (e) { toast(errorText(e)); }
  });
  box.querySelector('[data-act="remove"]')?.addEventListener("click", async () => {
    try { await store(null); renderPhoneBox(box); } catch (e) { toast(errorText(e)); }
  });
}

// ───────────── Time together & profile views ─────────────

async function heartbeat() {
  if (!state.myPos || document.hidden || Date.now() - extra.lastHeartbeat < 55000) return;
  extra.lastHeartbeat = Date.now();
  try { await rpc("heartbeat", { lat: state.myPos.lat, lon: state.myPos.lon }); } catch (_) {}
}

async function loadFriendTimes() {
  try {
    const rows = (await api("GET", "friend_time", [["select", "user_a,user_b,seconds,best_since"]])) || [];
    extra.friendTimes = new Map(rows.map((r) => [r.user_a === state.me.id ? r.user_b : r.user_a, r]));
  } catch (_) {}
}
const isBest = (t) => !!t && (t.best_since || t.seconds >= BEST_FRIEND_SECONDS);

function bestFriend() {
  let best = null;
  for (const f of state.friends) {
    const t = extra.friendTimes.get(f.id);
    if (!t || (!(t.seconds > 0) && !isBest(t))) continue;
    if (!best || (isBest(t) !== isBest(best.time) ? isBest(t) : t.seconds > best.time.seconds)) best = { profile: f, time: t };
  }
  return best;
}

function friendTimeHTML(friend) {
  const t = extra.friendTimes.get(friend.id);
  const seconds = t?.seconds || 0;
  if (isBest(t)) {
    return `<div class="time-card best"><div class="big">💛 Tu e ${esc(firstName(friend))} siete migliori amici</div><div class="muted small">${esc(spanText(seconds))} insieme</div></div>`;
  }
  const pct = Math.min(100, (seconds / BEST_FRIEND_SECONDS) * 100);
  return `<div class="time-card"><div class="row"><b class="grow">Tempo passato insieme</b><span class="muted small">${seconds ? esc(spanText(seconds)) : "0 min"}</span></div>
    <div class="time-bar"><i style="width:${pct.toFixed(1)}%"></i></div>
    <div class="muted small">Passate ancora ${esc(spanText(BEST_FRIEND_SECONDS - seconds))} insieme (con PinDrop aperta) per diventare migliori amici.</div></div>`;
}

// ───────────── Location reminders ─────────────

async function loadPermissions() {
  try {
    const rows = (await api("GET", "location_permissions", [["select", "user_id,permission"], ["user_id", "neq." + state.me.id]])) || [];
    extra.permissions = new Map(rows.map((r) => [r.user_id, r.permission]));
  } catch (_) {}
}
function permissionLabel(p) {
  if (p === "when_in_use") return "Solo mentre usa l'app";
  if (p === "denied") return "Posizione disattivata";
  return "Posizione non ancora condivisa";
}
const friendsWithoutAlways = () => state.friends.filter((f) => extra.permissions.get(f.id) !== "always");
function remindFriend(friend) {
  const body = `Ehi ${firstName(friend)}! Su PinDrop metti la posizione su “Sempre” così ci vediamo sulla mappa anche ad app chiusa 📍`;
  invoke("send_sms", { number: extra.contactPhones.get(friend.id) || "", body }).catch((e) => toast(errorText(e)));
}

function remindersHTML() {
  const list = friendsWithoutAlways();
  if (!list.length) return `<p class="ok-text small" style="margin:0">✓ Tutti i tuoi amici hanno la posizione su Sempre</p>`;
  return `<p class="muted small" style="margin:0 0 6px">Questi amici non si vedono sulla mappa quando PinDrop è chiusa. Mandagli un messaggio per mettere la posizione su “Sempre”.</p>`
    + list.map((f) => `<div class="person">${avatarHTML(f)}<div class="info"><b>${esc(f.display_name)}</b><span class="danger-text">${esc(permissionLabel(extra.permissions.get(f.id)))}</span></div><button class="mini accept" data-remind="${f.id}">💬 Avvisa</button></div>`).join("");
}

// ───────────── Profile sheet extras ─────────────

function renderProfileExtras(box) {
  if (!box) return;
  const best = bestFriend();
  box.innerHTML = `${state.me.bio ? `<p class="muted" style="margin:0">${esc(state.me.bio)}</p>` : ""}
    <div class="extra-actions"><button class="primary grow" data-act="edit">✏️ Modifica profilo</button><button class="ghost" data-act="qr">🔳 QR</button></div>
    <div class="time-card${best && isBest(best.time) ? " best" : ""}"><div class="muted small">${best ? (isBest(best.time) ? "Migliore amico" : "Più tempo insieme") : "Migliore amico"}</div>
      ${best ? `<div class="row">${avatarHTML(best.profile)}<b class="grow">${esc(best.profile.display_name)}</b><span class="muted small">${esc(spanText(best.time.seconds))}</span></div>` : `<div class="small">Passa 2 ore con un amico (con PinDrop aperta) per diventare migliori amici.</div>`}</div>
    <h3>📍 Impostazioni posizione degli amici</h3>
    <div id="remindBox">${remindersHTML()}</div>`;
  box.querySelector('[data-act="edit"]').onclick = openEditProfile;
  box.querySelector('[data-act="qr"]').onclick = openQR;
  box.querySelector("#remindBox").onclick = (e) => {
    const b = e.target.closest("[data-remind]");
    if (b) remindFriend(profileOf(b.dataset.remind));
  };
}

// ───────────── Friend sheet extras ─────────────

async function renderFriendExtras(friend, box) {
  if (!box) return;
  const perm = extra.permissions.get(friend.id);
  const live = friend.avatar_live_video ? `<div class="live-avatar"><video src="${esc(avatarPublicURL(friend.avatar_live_video))}" autoplay loop muted playsinline></video><span>LIVE</span></div>` : "";
  box.innerHTML = `${live}
    <div class="row views-row"><span class="muted small" id="viewCount">👁 ${friend.view_count || 0} visite al profilo</span></div>
    ${friendTimeHTML(friend)}
    ${perm !== "always" ? `<div class="remind-row"><div class="grow"><b class="small">Non si vede ad app chiusa</b><div class="danger-text small">${esc(permissionLabel(perm))}</div></div><button class="mini accept" data-act="remind">💬 Avvisa</button></div>` : ""}
    <div id="friendPlaces"></div>
    <button class="ghost danger-text" data-act="remove">Rimuovi amico</button>`;
  box.querySelector('[data-act="remind"]')?.addEventListener("click", () => remindFriend(friend));
  box.querySelector('[data-act="remove"]').onclick = () => confirmRemoveFriend(friend);
  try {
    const count = await rpc("record_profile_view", { target: friend.id });
    const n = Math.max(Number(count) || 0, friend.view_count || 0);
    const el = box.querySelector("#viewCount");
    if (el) el.textContent = `👁 ${n} visite al profilo`;
  } catch (_) {}
  try {
    const places = (await api("GET", "places", [["select", "id,name,emoji,latitude,longitude"], ["owner_id", "eq." + friend.id], ["is_public", "eq.true"], ["order", "created_at.desc"]])) || [];
    const el = box.querySelector("#friendPlaces");
    if (el && places.length) {
      el.innerHTML = `<h3>Posti sulla mappa</h3>` + places.map((p) => `<div class="person" data-fly="${p.longitude},${p.latitude}"><div class="avatar" style="background:#fff;font-size:20px">${esc(p.emoji)}</div><div class="info"><b>${esc(p.name)}</b><span>${state.myPos ? esc(distanceText(distance(state.myPos, { lat: p.latitude, lon: p.longitude }))) : ""}</span></div></div>`).join("");
      el.onclick = (e) => {
        const row = e.target.closest("[data-fly]");
        if (!row) return;
        const [lon, lat] = row.dataset.fly.split(",").map(Number);
        closeSheet();
        map.flyTo({ center: [lon, lat], zoom: 17, duration: 900 });
      };
    }
  } catch (_) {}
}

// ───────────── "On my way" pings ─────────────

async function walkingSeconds(from, to) {
  try {
    const coords = await invoke("route", { points: [[from.lon, from.lat], [to.lon, to.lat]] });
    if (Array.isArray(coords) && coords.length >= 2) {
      let meters = distance(from, { lat: coords[0][1], lon: coords[0][0] });
      for (let i = 1; i < coords.length; i++) meters += distance({ lat: coords[i - 1][1], lon: coords[i - 1][0] }, { lat: coords[i][1], lon: coords[i][0] });
      meters += distance({ lat: coords[coords.length - 1][1], lon: coords[coords.length - 1][0] }, to);
      return meters / WALK_MPS;
    }
  } catch (_) {}
  return (distance(from, to) * 1.3) / WALK_MPS;
}

async function openOnMyWay(pin) {
  const name = firstName(pin.author);
  openSheet(`${head("Sto arrivando")}
    <p class="muted" style="margin:0">Fai sapere a ${esc(name)} che stai arrivando</p>
    <div class="omw-card"><div class="omw-walk">🚶</div><div class="grow"><b id="omwEta">Calcolo del tempo a piedi…</b><div class="muted small">a piedi</div></div></div>
    <p id="omwPreview" class="muted small center" style="margin:0"></p>
    <button class="primary" id="omwSend" disabled>🏃 Invia ping</button>`, async (root) => {
    const pos = state.myPos || (await currentPosition().catch(() => null));
    if (!pos) { root.querySelector("#omwEta").textContent = "Posizione non disponibile"; return; }
    const seconds = Math.min(86400, Math.round(await walkingSeconds(pos, pinPos(pin))));
    const text = spanText(seconds);
    root.querySelector("#omwEta").textContent = text;
    root.querySelector("#omwPreview").textContent = `«${firstName(state.me)} sta arrivando · ${text} a piedi»`;
    const send = root.querySelector("#omwSend");
    send.disabled = false;
    send.onclick = async () => {
      send.disabled = true;
      try {
        await api("POST", "pings", [], { to_id: pin.author.id, pin_id: pin.id, eta_seconds: seconds }, "return=minimal");
        closeSheet();
        vibrate([20, 40, 20]);
        toast(`Ping inviato! ${name} sa che stai arrivando.`);
      } catch (e) { send.disabled = false; toast(errorText(e)); }
    };
  });
}

async function checkPings() {
  if (!state.me || document.hidden) return;
  try {
    const rows = (await api("GET", "pings", [
      ["select", "id,from_id,pin_id,eta_seconds,created_at,sender:profiles!pings_from_id_fkey(*)"],
      ["to_id", "eq." + state.me.id], ["seen_at", "is.null"], ["order", "created_at.desc"], ["limit", "10"],
    ])) || [];
    if (!rows.length) return;
    const latest = rows[0];
    vibrate([30, 60, 30]);
    toast(`🏃 ${firstName(latest.sender)} sta arrivando! Arriva a piedi in circa ${spanText(latest.eta_seconds)}`);
    await api("PATCH", "pings", [["id", `in.(${rows.map((r) => r.id).join(",")})`]], { seen_at: nowISO() }, "return=minimal");
  } catch (_) {}
}

// ───────────── Friends coming online ─────────────

function checkOnlineArrivals() {
  const now = new Set(state.online);
  if (extra.online) {
    const arrived = state.friends.find((f) => now.has(f.id) && !extra.online.has(f.id));
    if (arrived) {
      const name = firstName(arrived);
      const phrases = [`${name} si è ricollegato al pianeta 🌍`, `${name} è appena atterrato su PinDrop 🛬`, `${name} è tornato in orbita 🛰️`, `${name} ha aperto la mappa 🗺️`, `Segnale trovato: ${name} è online ✨`];
      vibrate(20);
      toast(phrases[Math.floor(Math.random() * phrases.length)]);
    }
  }
  extra.online = now;
}

// ───────────── Public places ─────────────

async function loadPublicPlaces() {
  const pos = state.myPos;
  if (!pos) return;
  try {
    const rows = (await rpc("public_places_near", { lat: pos.lat, lon: pos.lon, radius_km: 30 })) || [];
    extra.publicPlaces = rows;
    scheduleLayout(true);
  } catch (_) {}
}

function visiblePublicPlaces() {
  return extra.publicPlaces.filter((pp) => pp.owner_id !== state.me?.id
    && !state.places.some((p) => distance({ lat: p.latitude, lon: p.longitude }, { lat: pp.latitude, lon: pp.longitude }) < 30));
}

function openPublicPlace(place) {
  const owner = { id: place.owner_id, display_name: place.owner_display_name, username: place.owner_username, avatar_color: place.owner_avatar_color, avatar_path: place.owner_avatar_path };
  const where = state.myPos ? distanceText(distance(state.myPos, { lat: place.latitude, lon: place.longitude })) : "";
  openSheet(`<div class="sheet-head"><div class="author"><div class="avatar" style="background:#fff;font-size:24px">${esc(place.emoji)}</div><div>${esc(place.name)}<small>Posto pubblico${where ? " · a " + esc(where) : ""}</small></div></div><button class="close-x" data-close>${ICON.x}</button></div>
    <div class="person">${avatarHTML(owner)}<div class="info"><span>Aggiunto da</span><b>${esc(place.owner_display_name)}</b></div></div>
    <button class="ghost" data-act="add">⭐ Aggiungi ai miei posti</button>
    <h3>Chi c'è stato</h3>
    <div class="seg" id="visitSeg"><button data-tab="friends" class="on">Amici</button><button data-tab="all">Tutti</button></div>
    <div id="visitorsBox"><p class="muted small">Caricamento…</p></div>`, async (root) => {
    root.querySelector('[data-act="add"]').onclick = async (e) => {
      e.currentTarget.disabled = true;
      try {
        await invoke("add_place", { name: place.name, emoji: place.emoji, lat: place.latitude, lon: place.longitude, isPublic: false });
        toast(`${place.emoji} ${place.name} aggiunto ai tuoi posti`);
        await loadPlaces();
      } catch (err) { e.currentTarget.disabled = false; toast(errorText(err)); }
    };
    let rows = [];
    let tab = "friends";
    const box = root.querySelector("#visitorsBox");
    const render = () => {
      root.querySelectorAll("[data-tab]").forEach((b) => b.classList.toggle("on", b.dataset.tab === tab));
      const list = (tab === "friends" ? rows.filter((r) => r.is_friend || r.is_me) : rows).slice().sort((a, b) => b.visit_count - a.visit_count);
      if (!list.length) { box.innerHTML = `<p class="muted small">${tab === "friends" ? "Nessuno dei tuoi amici è ancora stato qui" : "Ancora nessuno è stato qui"}</p>`; return; }
      const medal = ["🥇", "🥈", "🥉"];
      box.innerHTML = list.map((r, i) => {
        const p = { id: r.user_id, display_name: r.display_name, username: r.username, avatar_color: r.avatar_color, avatar_path: r.avatar_path };
        return `<div class="person visitor${r.is_me ? " me" : ""}"><span class="rank">${medal[i] || i + 1}</span>${avatarHTML(p)}<div class="info"><b>${r.is_me ? "Tu" : esc(r.display_name)}</b><span>${r.last_visit_at ? "ultima volta " + esc(ago(r.last_visit_at)) : ""}</span></div><b class="visits">${r.visit_count}×</b></div>`;
      }).join("");
    };
    root.querySelector("#visitSeg").onclick = (e) => { const b = e.target.closest("[data-tab]"); if (b) { tab = b.dataset.tab; render(); } };
    try { rows = (await rpc("public_place_visitors", { place: place.id })) || []; } catch (_) {}
    render();
  });
}

// ───────────── Globe: projection, space, objects in orbit, edge zoom ─────────────

const GLOBE_ZOOM = 3.4;

function setupGlobe() {
  try { map.setProjection({ type: "globe" }); } catch (_) {}
  try {
    map.setSky({
      "sky-color": "#0b1030",
      "horizon-color": "#4c5bd4",
      "fog-color": "#0b1030",
      "atmosphere-blend": ["interpolate", ["linear"], ["zoom"], 0, 1, 5, 1, 7, 0],
    });
  } catch (_) {}
  map.setMinZoom(0);
  startOrbits();
  setupEdgeZoom();
}

/** Disk of the globe on screen: center and radius in CSS pixels (found from the limb). */
function globeDisk() {
  const c = map.getCenter();
  const w = map.getContainer().clientWidth;
  const h = map.getContainer().clientHeight;
  const center = { x: w / 2, y: h / 2 };
  let r = 0;
  const lat = (c.lat * Math.PI) / 180;
  const lon = (c.lng * Math.PI) / 180;
  for (let deg = 50; deg <= 90; deg += 2) {
    const d = (deg * Math.PI) / 180;
    // Point at angular distance d to the east along the great circle.
    const lat2 = Math.asin(Math.sin(lat) * Math.cos(d));
    const lon2 = lon + Math.atan2(Math.sin(d) * Math.cos(lat), Math.cos(d) - Math.sin(lat) * Math.sin(lat2));
    const p = map.project([(lon2 * 180) / Math.PI, (lat2 * 180) / Math.PI]);
    if (Number.isFinite(p.x)) r = Math.max(r, Math.hypot(p.x - center.x, p.y - center.y));
  }
  return { center, r };
}

function startOrbits() {
  if (typeof THREE === "undefined") return;
  const canvas = document.createElement("canvas");
  canvas.id = "orbits";
  $("map").insertAdjacentElement("afterend", canvas);
  const renderer = new THREE.WebGLRenderer({ canvas, alpha: true, antialias: true });
  renderer.setPixelRatio(Math.min(2, window.devicePixelRatio || 1));
  const scene = new THREE.Scene();
  const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, -10000, 10000);
  camera.position.z = 5000;
  scene.add(new THREE.AmbientLight(0xffffff, 0.55));
  const sun = new THREE.DirectionalLight(0xffffff, 1.1);
  sun.position.set(-1, 1.2, 2);
  scene.add(sun);
  const rim = new THREE.DirectionalLight(0x8899ff, 0.5);
  rim.position.set(1, -0.5, -1);
  scene.add(rim);
  // Invisible globe that only writes depth: objects behind it disappear.
  const occluder = new THREE.Mesh(new THREE.SphereGeometry(1, 48, 32), new THREE.MeshBasicMaterial({ colorWrite: false }));
  occluder.renderOrder = -1;
  scene.add(occluder);

  const objects = ORBIT_MODELS.map((make, i) => {
    const obj = make();
    scene.add(obj.group);
    const tilt = new THREE.Euler(((i * 47) % 70 - 35) * Math.PI / 180, 0, ((i * 71) % 80 - 40) * Math.PI / 180);
    return { ...obj, radius: 1.18 + (i % 4) * 0.12, speed: (0.05 + (i % 3) * 0.025) * (i % 2 ? -1 : 1), phase: (i / ORBIT_MODELS.length) * Math.PI * 2, tilt: new THREE.Quaternion().setFromEuler(tilt) };
  });

  let visible = false;
  const start = performance.now();
  const frame = () => {
    requestAnimationFrame(frame);
    const zoom = map.getZoom();
    const alpha = Math.max(0, Math.min(1, (GLOBE_ZOOM - zoom) / 0.8));
    if (alpha <= 0) {
      if (visible) { canvas.style.opacity = "0"; renderer.clear(); visible = false; }
      return;
    }
    visible = true;
    canvas.style.opacity = String(alpha);
    const w = canvas.clientWidth;
    const h = canvas.clientHeight;
    if (canvas.width !== Math.round(w * renderer.getPixelRatio()) || canvas.height !== Math.round(h * renderer.getPixelRatio())) renderer.setSize(w, h, false);
    camera.left = 0; camera.right = w; camera.top = 0; camera.bottom = -h;
    camera.updateProjectionMatrix();
    const disk = globeDisk();
    const R = disk.r || Math.min(w, h) * 0.3;
    const cx = disk.center.x;
    const cy = -disk.center.y;
    occluder.position.set(cx, cy, 0);
    occluder.scale.setScalar(R * 0.995);
    const t = (performance.now() - start) / 1000;
    for (const o of objects) {
      const a = o.phase + t * o.speed * Math.PI * 2;
      const local = new THREE.Vector3(Math.cos(a), 0, Math.sin(a)).multiplyScalar(o.radius * R).applyQuaternion(o.tilt);
      const ahead = new THREE.Vector3(Math.cos(a + 0.05 * Math.sign(o.speed)), 0, Math.sin(a + 0.05 * Math.sign(o.speed))).multiplyScalar(o.radius * R).applyQuaternion(o.tilt);
      o.group.position.set(cx + local.x, cy + local.y, local.z);
      o.group.scale.setScalar(R * o.size);
      if (o.aim) o.group.lookAt(cx + ahead.x, cy + ahead.y, ahead.z);
      if (o.spin) o.spin(o.group, t);
    }
    renderer.render(scene, camera);
  };
  frame();
}

function mat(color, opts = {}) {
  return new THREE.MeshStandardMaterial({ color, roughness: 0.5, metalness: 0.2, ...opts });
}

const ORBIT_MODELS = [
  // Satellite
  () => {
    const g = new THREE.Group();
    g.add(new THREE.Mesh(new THREE.BoxGeometry(0.5, 0.5, 0.7), mat(0xd4a017, { metalness: 0.8, roughness: 0.3 })));
    const panel = new THREE.BoxGeometry(1.4, 0.04, 0.5);
    const blue = mat(0x1e3a8a, { metalness: 0.6, roughness: 0.25, emissive: 0x0a1a4a });
    const l = new THREE.Mesh(panel, blue); l.position.x = -1.0; g.add(l);
    const r = new THREE.Mesh(panel, blue); r.position.x = 1.0; g.add(r);
    const dish = new THREE.Mesh(new THREE.ConeGeometry(0.28, 0.2, 20, 1, true), mat(0xeeeeee, { side: THREE.DoubleSide }));
    dish.position.z = 0.48; dish.rotation.x = -Math.PI / 2; g.add(dish);
    return { group: g, size: 0.05, spin: (o, t) => { o.rotation.y = t * 0.6; o.rotation.x = 0.4; } };
  },
  // Rocket
  () => {
    const g = new THREE.Group();
    const body = new THREE.Mesh(new THREE.CylinderGeometry(0.22, 0.22, 1.1, 20), mat(0xf5f5f5));
    body.rotation.x = Math.PI / 2; g.add(body);
    const nose = new THREE.Mesh(new THREE.ConeGeometry(0.22, 0.45, 20), mat(0xef4444));
    nose.rotation.x = Math.PI / 2; nose.position.z = 0.77; g.add(nose);
    for (let i = 0; i < 3; i++) {
      const fin = new THREE.Mesh(new THREE.BoxGeometry(0.04, 0.35, 0.3), mat(0xef4444));
      const a = (i / 3) * Math.PI * 2;
      fin.position.set(Math.cos(a) * 0.28, Math.sin(a) * 0.28, -0.45);
      fin.rotation.z = a + Math.PI / 2;
      g.add(fin);
    }
    const flame = new THREE.Mesh(new THREE.ConeGeometry(0.16, 0.5, 16), new THREE.MeshBasicMaterial({ color: 0xffa31a, transparent: true, opacity: 0.85 }));
    flame.rotation.x = -Math.PI / 2; flame.position.z = -0.8; g.add(flame);
    return { group: g, size: 0.06, aim: true, spin: (o, t) => { flame.scale.setScalar(0.85 + Math.sin(t * 30) * 0.15); } };
  },
  // UFO
  () => {
    const g = new THREE.Group();
    const saucer = new THREE.Mesh(new THREE.SphereGeometry(0.7, 32, 16), mat(0xb8c0cc, { metalness: 0.9, roughness: 0.2 }));
    saucer.scale.y = 0.25; g.add(saucer);
    const dome = new THREE.Mesh(new THREE.SphereGeometry(0.32, 24, 16, 0, Math.PI * 2, 0, Math.PI / 2), mat(0x67e8f9, { transparent: true, opacity: 0.75, emissive: 0x0e7490 }));
    dome.position.y = 0.1; g.add(dome);
    for (let i = 0; i < 8; i++) {
      const light = new THREE.Mesh(new THREE.SphereGeometry(0.05, 8, 8), new THREE.MeshBasicMaterial({ color: i % 2 ? 0xfacc15 : 0x22d3ee }));
      const a = (i / 8) * Math.PI * 2;
      light.position.set(Math.cos(a) * 0.6, -0.04, Math.sin(a) * 0.6);
      g.add(light);
    }
    return { group: g, size: 0.06, spin: (o, t) => { o.rotation.y = t * 2; o.rotation.z = Math.sin(t * 1.5) * 0.2; } };
  },
  // Moon
  () => {
    const g = new THREE.Group();
    g.add(new THREE.Mesh(new THREE.IcosahedronGeometry(1, 2), mat(0xc9c9c9, { flatShading: true, roughness: 0.95, metalness: 0 })));
    for (let i = 0; i < 6; i++) {
      const crater = new THREE.Mesh(new THREE.SphereGeometry(0.22, 12, 8), mat(0x9a9a9a, { roughness: 1, metalness: 0 }));
      const a = i * 2.1;
      const b = i * 1.3;
      crater.position.set(Math.cos(a) * Math.cos(b) * 0.9, Math.sin(b) * 0.9, Math.sin(a) * Math.cos(b) * 0.9);
      crater.scale.set(1, 1, 0.35);
      crater.lookAt(0, 0, 0);
      g.add(crater);
    }
    return { group: g, size: 0.11, spin: (o, t) => { o.rotation.y = t * 0.15; } };
  },
  // Ringed planet
  () => {
    const g = new THREE.Group();
    g.add(new THREE.Mesh(new THREE.SphereGeometry(0.7, 32, 24), mat(0xf59e0b, { roughness: 0.7 })));
    const ring = new THREE.Mesh(new THREE.RingGeometry(0.95, 1.4, 48), mat(0xfde68a, { side: THREE.DoubleSide, transparent: true, opacity: 0.85 }));
    ring.rotation.x = Math.PI / 2.4; g.add(ring);
    return { group: g, size: 0.08, spin: (o, t) => { o.rotation.y = t * 0.3; o.rotation.z = 0.35; } };
  },
  // Airliner
  () => {
    const g = new THREE.Group();
    const body = new THREE.Mesh(new THREE.CylinderGeometry(0.13, 0.13, 1.3, 16), mat(0xffffff));
    body.rotation.x = Math.PI / 2; g.add(body);
    const nose = new THREE.Mesh(new THREE.SphereGeometry(0.13, 16, 12), mat(0xffffff));
    nose.position.z = 0.65; g.add(nose);
    const wings = new THREE.Mesh(new THREE.BoxGeometry(1.4, 0.04, 0.3), mat(0x93c5fd));
    wings.position.z = 0.05; g.add(wings);
    const tail = new THREE.Mesh(new THREE.BoxGeometry(0.04, 0.35, 0.22), mat(0x7c3aed));
    tail.position.set(0, 0.18, -0.55); g.add(tail);
    const stab = new THREE.Mesh(new THREE.BoxGeometry(0.5, 0.03, 0.15), mat(0x93c5fd));
    stab.position.z = -0.58; g.add(stab);
    return { group: g, size: 0.06, aim: true };
  },
  // Comet
  () => {
    const g = new THREE.Group();
    g.add(new THREE.Mesh(new THREE.IcosahedronGeometry(0.3, 1), mat(0xe0f2fe, { emissive: 0x38bdf8, emissiveIntensity: 0.6, flatShading: true })));
    const tail = new THREE.Mesh(new THREE.ConeGeometry(0.3, 2.2, 20, 1, true), new THREE.MeshBasicMaterial({ color: 0x7dd3fc, transparent: true, opacity: 0.35, side: THREE.DoubleSide, blending: THREE.AdditiveBlending, depthWrite: false }));
    tail.rotation.x = Math.PI / 2; tail.position.z = -1.1; g.add(tail);
    return { group: g, size: 0.06, aim: true };
  },
  // Hot air balloon
  () => {
    const g = new THREE.Group();
    const colors = [0xef4444, 0xfacc15, 0x3b82f6, 0x10b981];
    for (let i = 0; i < 8; i++) {
      const slice = new THREE.Mesh(new THREE.SphereGeometry(0.6, 6, 16, (i / 8) * Math.PI * 2, Math.PI / 4), mat(colors[i % 4], { roughness: 0.6, side: THREE.DoubleSide }));
      slice.scale.y = 1.15;
      g.add(slice);
    }
    const basket = new THREE.Mesh(new THREE.BoxGeometry(0.25, 0.2, 0.25), mat(0x92400e, { roughness: 0.9 }));
    basket.position.y = -0.95; g.add(basket);
    return { group: g, size: 0.06, spin: (o, t) => { o.rotation.y = t * 0.4; } };
  },
];

function setupEdgeZoom() {
  const main = $("main");
  const ZMIN = 0.4;
  const ZMAX = 18.5;
  for (const side of ["left", "right"]) {
    const strip = document.createElement("div");
    strip.className = `edge-zoom ${side}`;
    strip.innerHTML = `<div class="edge-knob">🔍</div>`;
    main.appendChild(strip);
    const knob = strip.firstElementChild;
    let g = null;
    strip.addEventListener("touchstart", (e) => {
      const t = e.touches[0];
      const box = strip.getBoundingClientRect();
      const z0 = map.getZoom();
      const below = Math.max(box.bottom - t.clientY - 8, 60);
      const above = Math.max(t.clientY - box.top - 8, 60);
      g = { y0: t.clientY, z0, top: box.top, rateOut: Math.max((z0 - ZMIN) / below, 1 / 110), rateIn: Math.max((ZMAX - z0) / above, 1 / 110), last: Math.round(z0) };
      strip.classList.add("active");
      knob.style.top = `${t.clientY - box.top}px`;
      vibrate(8);
      e.preventDefault();
    }, { passive: false });
    strip.addEventListener("touchmove", (e) => {
      if (!g) return;
      const t = e.touches[0];
      const dy = t.clientY - g.y0;
      const zoom = Math.max(ZMIN, Math.min(ZMAX, dy > 0 ? g.z0 - dy * g.rateOut : g.z0 - dy * g.rateIn));
      map.jumpTo({ zoom });
      knob.style.top = `${t.clientY - g.top}px`;
      if (Math.round(zoom) !== g.last) { g.last = Math.round(zoom); vibrate(4); }
      e.preventDefault();
    }, { passive: false });
    const end = () => { g = null; strip.classList.remove("active"); scheduleLayout(true); };
    strip.addEventListener("touchend", end);
    strip.addEventListener("touchcancel", end);
  }
}

// ───────────── Home screen widget ─────────────

async function syncWidget() {
  if (!state.me) return;
  try {
    const friendsPins = state.pins.filter((p) => !isMine(p) && new Date(p.expires_at) > Date.now()).sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
    const pin = friendsPins[0];
    const unlocked = isUnlocked();
    const active = new Set(friendsPins.map((p) => p.author?.id)).size;
    const status = unlocked ? `🔓 ${active} ${active === 1 ? "amico attivo" : "amici attivi"}` : "🔒 Pubblica per sbloccare";
    const key = JSON.stringify([pin?.id, unlocked, active, pin && Math.floor((Date.now() - new Date(pin.created_at)) / 600000)]);
    if (key === extra.widgetKey) return;
    if (!pin) {
      await invoke("update_widget", { data: { title: "", subtitle: "", caption: "", status, image: "" } });
      extra.widgetKey = key;
      return;
    }
    const path = isLocked(pin) ? pin.blur_path : pin.thumb_path;
    const urls = await signed("pins", [path]);
    let image = "";
    if (urls[path]) image = await invoke("fetch_image_b64", { url: urls[path] }).catch(() => "");
    const where = [pin.place_name, ago(pin.created_at)].filter(Boolean).join(" · ");
    await invoke("update_widget", { data: { title: pin.author?.display_name || "", subtitle: where, caption: isLocked(pin) ? "" : pin.caption || "", status, image } });
    extra.widgetKey = key;
  } catch (_) {}
}
