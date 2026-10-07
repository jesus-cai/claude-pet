// La vida de la mascota: lee las sesiones, piensa, dibuja, escucha al ratón y avisa.
'use strict';
const { ipcRenderer } = require('electron');
const fs = require('fs');
const path = require('path');
const { Probe } = require('./lib/probe');
const { Brain } = require('./lib/brain');
const { loadSheet, pickFrame } = require('./lib/sprites');
const { DesktopGuess } = require('./lib/desktop');
const pets = require('./lib/pets');
const { Flock, scanScenes, PALETTE } = require('./lib/flock');

const canvas = document.getElementById('pet');
const ctx = canvas.getContext('2d');
const bubbleEl = document.getElementById('bubble');
const paths = ipcRenderer.sendSync('paths');

// ---------- ajustes ----------
const settingsFile = path.join(pets.home(), 'windows.json');
const defaults = { petId: 'mochi', petHeight: 150, wanders: true, followsCursor: true, reactsToClaude: true,
                   announces: true, sound: true, banners: false, x: null, feetY: null,
                   // una mascota por sesión (apagado: el Bober de siempre)
                   multi: false, by: 'mix', layout: 'stage', scene: 'oficina', stageSize: 2,
                   rotation: [], pins: {}, stageX: null, stageY: null, homeX: null, hideEmptyStage: false,
                   hidden: {} };
let settings = { ...defaults };
try { settings = { ...defaults, ...JSON.parse(fs.readFileSync(settingsFile, 'utf8')) }; } catch { /* primera vez */ }
let saveTimer = null;
function save() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    try { fs.mkdirSync(pets.home(), { recursive: true }); fs.writeFileSync(settingsFile, JSON.stringify(settings, null, 2)); }
    catch { /* no pasa nada */ }
  }, 400);
}

// ---------- cerebro ----------
const probe = new Probe(path.join(pets.home(), 'sessions'));
// las sesiones quitadas a mano siguen quitadas al volver a abrir la app
for (const [k, v] of Object.entries(settings.hidden || {})) {
  if (k !== 'desktop' && v && typeof v.at === 'number') probe.hidden.set(k, { open: !!v.open, at: v.at });
}
probe.onHidden = () => { settings.hidden = Object.fromEntries(probe.hidden); save(); };
const desktopGuess = new DesktopGuess();
let desktopSeq = -1, desktopRect = null;
/** Una muestra nueva del vigilante de Claude Desktop. Mientras una sesión de Claude
 *  Code habla no se adivina nada, y la siguiente muestra vuelve a ser solo la base. */
function feedDesktop(d) {
  if (!d || d.seq === desktopSeq) return;
  desktopSeq = d.seq;
  // con varias mascotas, la de Claude Desktop sigue adivinando aunque hable Claude Code
  if (!d.running || (probe.isSignalled && !settings.multi) || probe.desktopCodeBusy) {
    desktopGuess.reset();
    probe.desktop = { busy: false, running: !!d.running, front: !!d.front };
  } else {
    const r = desktopGuess.sample(performance.now() / 1000, Number(d.cpu) || 0, !!d.front, Number(d.input) || 99);
    probe.desktop = { busy: r.busy, running: true, front: !!d.front };
  }
  desktopRect = d.front && Array.isArray(d.rect) ? d.rect : null;
}
const env0 = ipcRenderer.sendSync('env', 0, 0);
const brain = new Brain(probe, settings.x ?? env0.work.x + env0.work.width / 2);
let feetY = settings.feetY ?? env0.work.y + env0.work.height - 2;
function syncSwitches() {
  for (const k of ['wanders', 'followsCursor', 'reactsToClaude', 'announces']) brain[k] = settings[k];
}
syncSwitches();

// ---------- la mascota ----------
let catalog = [], pet = null, sheet = null, zoom = 1, petW = 0, petH = 0, winW = 340, winH = 360;
let current = null;           // cuadro que se ve ahora (para el clic-a-través)
let iconBase = null;

async function choosePet(id) {
  catalog = pets.scan(paths.bundledPets);
  const order = [...catalog.filter((p) => p.id === id), ...catalog.filter((p) => p.id === 'mochi' && p.id !== id),
                 ...catalog.filter((p) => p.id !== id && p.id !== 'mochi')];
  for (const p of order) {
    try {
      const s = await loadSheet(p);
      pet = p; sheet = s; settings.petId = p.id; save();
      layout();
      brain.setPersonality(p.reactions, p.lines);
      brain.hasLook = s.look.length === 16;
      brain.hasTalk = !!s.rows.talking;
      makeIconBase();
      badge = undefined;
      pushMenu(true);
      return true;
    } catch (e) { console.warn('no carga', p.id, e); }
  }
  return false;
}

function layout() {
  const dpr = window.devicePixelRatio || 1;
  let z = settings.petHeight / Math.max(1, sheet.content.h);
  if (sheet.pixelated) {   // cada píxel del dibujo, un número entero de píxeles de pantalla
    const b = sheet.block * dpr;
    z = Math.max(1, Math.round(z * b)) / b;
  }
  zoom = z;
  petW = Math.round(sheet.cw * z); petH = Math.round(sheet.ch * z);
  canvas.width = Math.round(petW * dpr); canvas.height = Math.round(petH * dpr);
  canvas.style.width = petW + 'px'; canvas.style.height = petH + 'px';
  winW = Math.max(petW, 340); winH = petH + 90;
  ipcRenderer.send('size', winW, winH);
  brain.walkSpeed = settings.petHeight * 0.55;
}
const footInset = () => (sheet.ch - (sheet.content.y + sheet.content.h)) * zoom;
const contentH = () => sheet.content.h * zoom;

// ---------- globito ----------
const LEADS = new Set(['reading', 'writing', 'running', 'searching', 'helper:']);
function speak(text, tone, tag) {
  let lead = '', body = text, dots = false;
  const sp = text.indexOf(' ');
  if (sp > 0 && LEADS.has(text.slice(0, sp))) { lead = text.slice(0, sp + 1); body = text.slice(sp + 1); }
  if (!lead && body.endsWith('…')) { dots = true; body = body.slice(0, -1); }
  const esc = (s) => s.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
  bubbleEl.className = tone;
  bubbleEl.innerHTML = '<span class="dot"></span>' + (tag ? `<span class="tag">${esc(tag)} · </span>` : '')
    + (lead ? `<span class="lead">${esc(lead)}</span>` : '') + esc(body)
    + (dots ? '<span class="dots"><span>.</span><span>.</span><span>.</span></span>' : '');
  void bubbleEl.offsetWidth;            // reinicia la animación de aparecer
  bubbleEl.classList.add('show');
}
function hush() { bubbleEl.classList.remove('show'); }
brain.speak = speak;
brain.hush = hush;

// ---------- sonido y notificaciones ----------
let audio = null, lastSound = 0;
function chime(kind) {
  const now = performance.now();
  if (!settings.sound || now - lastSound < 3000) return;
  lastSound = now;
  audio = audio || new AudioContext();
  const notes = { finished: [660, 990], needsYou: [880, 880], failed: [330, 247] }[kind];
  if (!notes) return;
  notes.forEach((f, i) => {
    const o = audio.createOscillator(), g = audio.createGain();
    const t0 = audio.currentTime + i * 0.13;
    o.type = 'sine'; o.frequency.value = f;
    g.gain.setValueAtTime(0, t0); g.gain.linearRampToValueAtTime(0.18, t0 + 0.01);
    g.gain.exponentialRampToValueAtTime(0.001, t0 + 0.35);
    o.connect(g).connect(audio.destination); o.start(t0); o.stop(t0 + 0.4);
  });
}
const alert = (e) => {
  chime(e.kind);
  if (!settings.banners) return;
  const where = e.project || 'Claude';
  const text = { finished: [`${where}: listo`, e.detail || 'Claude terminó de responder.'],
                 failed: [`${where}: error`, e.detail && e.detail !== 'api' ? e.detail : 'El turno terminó con un error.'],
                 needsYou: [`${where}: te necesita`, e.detail && !['permission', 'input'].includes(e.detail)
                   ? `¿Le dejas ${e.detail}?` : 'Está esperando tu respuesta.'] }[e.kind];
  if (text) new Notification(text[0], { body: text[1], silent: true, tag: 'compa-' + e.session });
};
brain.alert = alert;

// ---------- una mascota por sesión ----------
const flock = new Flock({
  probe, settings, save, catalog: () => catalog, alert,
  bundledScenes: paths.bundledScenes, userScenes: path.join(pets.home(), 'scenes'),
  feedDesktop: (d) => feedDesktop(d),
});
const noticesNow = () => (settings.multi ? flock.notices() : brain.notices);
async function applyMode() {
  if (settings.multi) {
    hush(); canvas.style.visibility = 'hidden'; setSolid(false);
    ipcRenderer.send('size', 1, 1);
    await flock.start();
  } else {
    flock.stop();
    canvas.style.visibility = 'visible';
    if (sheet) layout();
  }
  pushMenu(true);
}

// ---------- icono de la bandeja ----------
function makeIconBase() {
  const f = sheet.rows.idle.frames[0].bmp, c = sheet.content;
  const side = Math.max(c.w, c.h);
  const cv = new OffscreenCanvas(32, 32), g = cv.getContext('2d');
  g.imageSmoothingEnabled = !sheet.pixelated;
  g.drawImage(f, c.x + c.w / 2 - side / 2, c.y + c.h / 2 - side / 2, side, side, 0, 0, 32, 32);
  iconBase = cv;
}
let badge;
async function updateTray() {
  let color = null;
  if (settings.reactsToClaude) {
    const ns = noticesNow();
    if (probe.state === 'waiting' || (settings.multi && probe.sessions.some((s) => s.state === 'waiting'))) color = '#ff9f0a';
    else if ([...ns.values()].some((n) => n.kind === 'error')) color = '#ff453a';
    else if (ns.size) color = '#30d158';
  }
  if (color === badge || !iconBase) return;
  badge = color;
  const cv = document.createElement('canvas'); cv.width = cv.height = 32;
  const g = cv.getContext('2d');
  g.drawImage(iconBase, 0, 0);
  if (color) {
    g.fillStyle = '#ffffff'; g.beginPath(); g.arc(25, 7, 7, 0, Math.PI * 2); g.fill();
    g.fillStyle = color; g.beginPath(); g.arc(25, 7, 5.5, 0, Math.PI * 2); g.fill();
  }
  ipcRenderer.send('tray', cv.toDataURL('image/png'), `Compa · ${pet ? pet.name : ''}`);
}

// ---------- menú ----------
const DESCR = { thinking: 'pensando…', reading: 'leyendo', writing: 'escribiendo', running: 'ejecutando',
                searching: 'buscando', delegating: 'delegando', waiting: 'te espera', done: 'terminó',
                stopped: 'interrumpido', error: 'error', idle: 'en reposo' };
let lastMenu = '', lastMenuAt = 0;
function pushMenu(force) {
  const now = performance.now();
  if (!force && now - lastMenuAt < 700) return;
  lastMenuAt = now;
  const sessions = probe.sessions.slice();
  const ns = noticesNow();
  // Claude Desktop como una "sesión" más mientras responde o tiene un aviso sin ver
  if ((probe.guessed || ns.has('desktop')) && !probe.isHidden('desktop')) {
    sessions.push({ key: 'desktop', project: 'Claude Desktop', detail: '',
                    state: probe.guessed ? 'thinking' : 'done', at: 0 });
  }
  // con una sola sesión también: es donde se quita a mano
  const showList = sessions.length > 0;
  const status = probe.guessed ? 'respondiendo…' : (DESCR[probe.state] || probe.state);
  const state = {
    title: sessions.length > 1 ? `${pet ? pet.name : 'Compa'} · ${sessions.length} sesiones`
                               : `${pet ? pet.name : 'Compa'} · ${probe.guessed ? `Claude Desktop ${status}`
                                   : `Claude ${probe.isSignalled ? status : (probe.desktop.running ? 'Desktop abierto' : 'en reposo')}`}${probe.project ? ` (${probe.project})` : ''}`,
    sessions: showList ? sessions.map((s) => {
      const n = ns.get(s.key);
      const mark = s.state === 'waiting' ? '🟠' : n ? (n.kind === 'error' ? '🔴' : '🟢') : (DESCR[s.state] && s.state !== 'done' && s.state !== 'stopped' && s.state !== 'error' && s.state !== 'idle' ? '⏳' : '  ');
      let d = DESCR[s.state] || s.state;
      if (s.detail && s.state !== 'thinking') d += (s.state === 'waiting' ? ': ' : ' ') + s.detail;
      let label = `${mark} ${s.project || s.key.slice(0, 8)} — ${d}${n ? ' (sin ver)' : ''}`;
      if (label.length > 70) label = label.slice(0, 69) + '…';
      return { key: s.key, label, pending: !!n, project: s.project || s.key.slice(0, 8) };
    }) : [],
    notices: ns.size,
    hiddenCount: probe.hidden.size,
    multi: settings.multi, by: settings.by, layout: settings.layout, scene: settings.scene, stageSize: settings.stageSize,
    rotation: settings.rotation, pins: settings.pins, palette: PALETTE, hideEmptyStage: settings.hideEmptyStage,
    scenes: scanScenes([path.join(pets.home(), 'scenes'), paths.bundledScenes]).map((s) => ({ id: s.id, name: s.name })),
    pets: catalog.map((p) => ({ id: p.id, name: p.name, origin: p.origin })),
    petId: pet ? pet.id : '',
    flags: { wanders: settings.wanders, followsCursor: settings.followsCursor, reactsToClaude: settings.reactsToClaude,
             announces: settings.announces, sound: settings.sound, banners: settings.banners },
    size: settings.petHeight,
  };
  const json = JSON.stringify(state);
  if (json !== lastMenu) { lastMenu = json; ipcRenderer.send('menu-state', state); }
}

ipcRenderer.on('cmd', async (_e, cmd, arg) => {
  switch (cmd) {
    case 'toggle':
      settings[arg] = !settings[arg]; save(); syncSwitches();
      for (const m of flock.members.values()) m.brain[arg] = settings[arg];
      if (arg === 'banners' && settings.banners && Notification.permission !== 'granted') Notification.requestPermission();
      if (arg === 'multi') await applyMode();
      break;
    case 'set':
      settings[arg.key] = arg.value; save();
      if (arg.key === 'by') flock.assigned = new Map();
      if (settings.multi && ['layout', 'scene', 'stageSize'].includes(arg.key)) await flock.restart();
      break;
    case 'rotation': {
      const all = catalog.map((p) => p.id);
      let rot = settings.rotation && settings.rotation.length ? settings.rotation.slice() : all.slice();
      rot = rot.includes(arg) ? rot.filter((id) => id !== arg) : [...rot, arg];
      settings.rotation = rot.length && rot.length < all.length ? rot : [];   // vacío = todas
      save(); flock.assigned = new Map();
      break;
    }
    case 'pin': {
      const p = { ...(settings.pins[arg.project] || {}) };
      if ('pet' in arg) { if (arg.pet) p.pet = arg.pet; else delete p.pet; }
      if ('color' in arg) { if (arg.color === null) delete p.color; else p.color = arg.color; }
      settings.pins = { ...settings.pins, [arg.project]: p };
      if (!Object.keys(p).length) delete settings.pins[arg.project];
      save(); flock.assigned = new Map();
      break;
    }
    case 'seen': if (settings.multi) flock.acknowledge(); else brain.acknowledge(); break;
    case 'seenSession': if (settings.multi) flock.acknowledge(arg); else brain.acknowledgeSession(arg); break;
    case 'hide':
      // Claude Desktop "respondiendo" que se quita no ha terminado: nada de celebrarlo
      if (arg === 'desktop' && !settings.multi && probe.guessed) brain.land(false);
      if (settings.multi) flock.acknowledge(arg); else brain.acknowledgeSession(arg);
      probe.hide(arg);
      probe.poll();
      break;
    case 'unhideAll': probe.unhideAll(); probe.poll(); break;
    case 'wave': if (settings.multi) flock.wave(); else brain.wave(); break;
    case 'recenter': {
      if (settings.multi) { flock.recenter(); break; }
      const env = ipcRenderer.sendSync('env', brain.x, feetY);
      feetY = env.work.y + env.work.height - 2;
      brain.endDrag(env.work.x + env.work.width / 2);
      break;
    }
    case 'pet': await choosePet(arg); flock.assigned = new Map(); break;
    case 'rescan': await choosePet(settings.petId); flock.sheets.clear(); if (settings.multi) await flock.restart(); break;
    case 'size':
      // "Tamaño" es el de las mascotas, también dentro del escenario (que no cambia)
      settings.petHeight = arg;
      save(); if (settings.multi) await flock.restart(); else layout();
      break;
    case 'hooks':
      speak(arg && arg.ok ? 'hooks ready' : 'hooks failed', arg && arg.ok ? 'done' : 'error', 'Claude Code');
      // fuerza a que el globito vuelva a lo que toque (o se esconda) a los 3 s
      setTimeout(() => { brain.lastLine = '\u0000'; }, 3000);
      break;
  }
  pushMenu(true);
});

// ---------- ratón ----------
// La ventana deja pasar el ratón salvo cuando está encima de la mascota de verdad
// (píxel opaco del cuadro actual): así no estorba en los bordes transparentes.
let solid = false, drag = null;
function overPet(clientX, clientY) {
  if (!current) return false;
  const r = canvas.getBoundingClientRect();
  const nx = (clientX - r.left) / r.width, ny = (clientY - r.top) / r.height;
  if (nx < 0 || ny < 0 || nx >= 1 || ny >= 1) return false;
  const m = current.mask;
  return m.a[Math.floor(ny * m.h) * m.w + Math.floor(nx * m.w)] > 40;
}
function setSolid(v) { if (v !== solid) { solid = v; ipcRenderer.send('solid', v); } }
document.addEventListener('mousemove', (e) => { if (!drag) setSolid(overPet(e.clientX, e.clientY)); });
canvas.addEventListener('pointerdown', (e) => {
  if (e.button !== 0 || !overPet(e.clientX, e.clientY)) return;
  canvas.setPointerCapture(e.pointerId);
  canvas.classList.add('dragging');
  drag = { sx: e.screenX, sy: e.screenY, wx: window.screenX, wy: window.screenY, moved: false, x: window.screenX, y: window.screenY };
  brain.beginDrag();
});
canvas.addEventListener('pointermove', (e) => {
  if (!drag) return;
  const dx = e.screenX - drag.sx, dy = e.screenY - drag.sy;
  if (Math.abs(dx) + Math.abs(dy) > 4) drag.moved = true;
  drag.x = drag.wx + dx; drag.y = drag.wy + dy;
  ipcRenderer.send('move', drag.x, drag.y);
});
canvas.addEventListener('pointerup', () => {
  if (!drag) return;
  canvas.classList.remove('dragging');
  if (drag.moved) {
    feetY = drag.y + winH - footInset();
    brain.endDrag(drag.x + winW / 2);
    settings.x = brain.x; settings.feetY = feetY; save();
  } else {
    brain.endDrag(brain.x);
    brain.acknowledge();      // lo que te estuviera enseñando, ya lo has visto
    brain.wave();
  }
  drag = null;
});
canvas.addEventListener('contextmenu', (e) => { e.preventDefault(); ipcRenderer.send('popup'); });

// ---------- bucle ----------
let last = performance.now(), lastPos = '';
function frame(now) {
  requestAnimationFrame(frame);
  if (!sheet) return;
  if (settings.multi) { last = now; updateTray(); pushMenu(false); return; }   // la bandada va por su cuenta
  const dt = Math.min(0.05, (now - last) / 1000); last = now;
  const env = ipcRenderer.sendSync('env', brain.x, feetY);
  const wa = env.work;
  const half = petW / 2;
  brain.bounds = [wa.x + half * 0.6, wa.x + wa.width - half * 0.6];
  if (!drag) feetY = Math.min(Math.max(feetY, wa.y + contentH() + 60), wa.y + wa.height - 2);
  const head = { x: brain.x, y: feetY - contentH() * 0.78 };
  feedDesktop(env.desktop);
  // con Claude Desktop delante y tú quieto, mira hacia su ventana
  let target = env.cursor;
  if (desktopRect && env.idle > 3 && brain.reactsToClaude) {
    target = { x: (desktopRect[0] + desktopRect[2]) / 2, y: (desktopRect[1] + desktopRect[3]) / 2 };
  }
  const f = brain.step(dt, target, head, env.idle);

  current = pickFrame(sheet, f);
  const dpr = window.devicePixelRatio || 1;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, petW, petH);
  ctx.imageSmoothingEnabled = !sheet.pixelated;
  ctx.drawImage(current.bmp, 0, 0, petW, petH);
  bubbleEl.style.bottom = Math.round(footInset() + contentH() + 8) + 'px';

  if (!drag) {
    const grid = sheet.pixelated ? zoom : 1;
    const wx = Math.round((brain.x - winW / 2) / grid) * grid;
    const wy = Math.round(feetY + footInset() - winH);
    const pos = `${Math.round(wx)},${wy}`;
    if (pos !== lastPos) { lastPos = pos; ipcRenderer.send('move', wx, wy); }
  }
  updateTray();
  pushMenu(false);
}

(async () => {
  if (!(await choosePet(settings.petId))) {
    speak('no pets found', 'error', '');
    return;
  }
  const h = paths.hooks;
  if (h && !h.ok) speak('hooks failed', 'error', 'Claude Code');
  requestAnimationFrame(frame);
  if (settings.multi) await applyMode();
})();
