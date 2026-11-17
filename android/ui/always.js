// "Consenti sempre" on Android: the option only exists in the system settings (Android 11+),
// so PinDrop asks for it there and then runs a small background service that keeps
// sending your position to your friends while the app is closed.

const ALWAYS_KEY = "alwaysLocation";
const alwaysState = { supported: false, foreground: false, background: false, running: false };

function alwaysOn() {
  return alwaysState.running;
}

async function syncAlways(maybeAsk = false) {
  try {
    Object.assign(alwaysState, await invoke("always_location_status"));
  } catch (_) { return; }
  if (!alwaysState.supported) return;
  const wanted = localStorage.getItem(ALWAYS_KEY) !== "0";
  const run = wanted && alwaysState.background;
  if (run !== alwaysState.running) {
    try {
      await invoke("set_always_location", { on: run });
      alwaysState.running = run;
    } catch (_) {}
  }
  const box = $("alwaysBox");
  if (box) renderAlwaysBox(box);
  // Once, after you allowed the position: explain how to pick "Consenti sempre".
  if (maybeAsk && alwaysState.foreground && !alwaysState.background && !localStorage.getItem("alwaysAsked") && $("sheet").classList.contains("hidden")) {
    localStorage.setItem("alwaysAsked", "1");
    openAlwaysSheet();
  }
}

function openAlwaysSheet() {
  openSheet(`${head("📍 Posizione sempre attiva")}
    <p style="margin:0">Così i tuoi amici vedono dove sei anche quando PinDrop è chiusa, come su iPhone.</p>
    <div class="stat"><span>COME FARE</span><b style="font-size:15px;line-height:1.5">Tocca il pulsante qui sotto → <u>Posizione</u> → scegli <u>Consenti sempre</u>.</b></div>
    <p class="muted small" style="margin:0">Android mostra "Consenti sempre" solo nelle impostazioni dell'app, non nella finestra di richiesta. Mentre è attiva vedrai una piccola notifica di PinDrop.</p>
    <button class="primary" data-act="go">Apri le impostazioni della posizione</button>
    <button class="ghost" data-close>Non ora</button>`, (root) => {
    root.querySelector('[data-act="go"]').addEventListener("click", () => { closeSheet(); askAlways(); });
  });
}

async function askAlways() {
  localStorage.setItem(ALWAYS_KEY, "1");
  if (!(await ensurePermission(true))) return toast("Prima consenti la posizione a PinDrop.");
  try {
    await invoke("request_always_location");
  } catch (_) {
    invoke("open_app_settings").catch(() => toast("Apri Impostazioni → App → PinDrop → Autorizzazioni → Posizione."));
  }
}

function renderAlwaysBox(box) {
  if (!box) return;
  if (!alwaysState.supported) {
    box.innerHTML = `<p class="muted small" style="margin:0">La posizione si aggiorna mentre l'app è aperta.</p>`;
    return;
  }
  const wanted = localStorage.getItem(ALWAYS_KEY) !== "0";
  if (alwaysState.background) {
    box.innerHTML = `<label class="toggle-row"><input type="checkbox" data-act="toggle" ${wanted ? "checked" : ""}> Condividi la posizione anche ad app chiusa</label>
      <p class="muted small" style="margin:6px 0 0">${alwaysState.running ? "✅ Attiva: «Consenti sempre» è concesso." : "Spenta: gli amici vedono l'ultima posizione di quando avevi l'app aperta."}</p>`;
    box.querySelector('[data-act="toggle"]').addEventListener("change", async (e) => {
      localStorage.setItem(ALWAYS_KEY, e.target.checked ? "1" : "0");
      await syncAlways();
    });
  } else {
    box.innerHTML = `<p class="muted small" style="margin:0 0 8px">Ora la posizione si aggiorna solo con l'app aperta. Scegli <b>Consenti sempre</b> per condividerla anche ad app chiusa.</p>
      <button class="primary" data-act="ask" style="width:100%">📍 Attiva "Consenti sempre"</button>
      <button class="link small" data-act="settings">Apri le impostazioni dell'app</button>`;
    box.querySelector('[data-act="ask"]').addEventListener("click", askAlways);
    box.querySelector('[data-act="settings"]').addEventListener("click", () => invoke("open_app_settings").catch(() => {}));
  }
}
