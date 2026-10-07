// Modo "una mascota por sesión". Un solo proceso mueve a todas: un reloj, un lector
// de sesiones, y cada mascota con su cerebro y su canal. Tres disposiciones:
//   free   cada una en su ventanita, paseando por toda la pantalla
//   walks  cada una en su ventanita, con su sitio en una fila y paseos cortos
//   stage  todas dentro de un escenario (una ventana): mesa, sofá, puerta…
// Las ventanitas se abren con window.open desde este mismo renderer: comparten
// proceso, así que se dibuja en ellas directamente y nadie paga un Chromium entero.
'use strict';
const { ipcRenderer } = require('electron');
const fs = require('fs');
const path = require('path');
const { SessionFeed, DesktopFeed } = require('./probe');
const { Brain } = require('./brain');
const { loadSheet, pickFrame, drawFrame } = require('./sprites');
const { assign, PALETTE } = require('./assign');

const MAX = 6;
const HEADROOM = 70;     // espacio para el globito encima
const LABEL = 20;        // espacio para la etiqueta debajo
const LEADS = new Set(['reading', 'writing', 'running', 'searching', 'helper:']);

const CSS = `
html, body { margin: 0; height: 100%; background: transparent; overflow: hidden; user-select: none; }
canvas { position: absolute; left: 0; top: 0; }
.bubble { position: absolute; max-width: 260px; box-sizing: border-box; transform: translateX(-50%) scale(.6);
  opacity: 0; transform-origin: 50% 100%; transition: opacity .18s ease, transform .22s cubic-bezier(.2,1.4,.4,1);
  font: 600 12px/1.3 "Segoe UI Variable Text", "Segoe UI", system-ui, sans-serif; color: #f2f2f2;
  background: rgba(28,28,32,.92); border-radius: 11px; padding: 6px 10px 6px 20px; white-space: nowrap;
  overflow: hidden; text-overflow: ellipsis; box-shadow: 0 2px 10px rgba(0,0,0,.25); pointer-events: none; }
.bubble.show { opacity: 1; transform: translateX(-50%) scale(1); }
.bubble .dot { position: absolute; left: 9px; top: 50%; width: 6px; height: 6px; margin-top: -3px; border-radius: 50%; }
.bubble .tag, .bubble .lead { color: #a8a8b0; font-weight: 500; }
.bubble .dots span { animation: blink 1.2s infinite; } .bubble .dots span:nth-child(2) { animation-delay: .2s; }
.bubble .dots span:nth-child(3) { animation-delay: .4s; }
@keyframes blink { 0%, 60%, 100% { opacity: .25 } 30% { opacity: 1 } }
.working .dot { background: #8a8a92; } .waiting .dot { background: #ff9f0a; }
.done .dot { background: #30d158; } .error .dot { background: #ff453a; }
.waiting { color: #ffd9a8; } .error { color: #ffc4c0; }
.label { position: absolute; transform: translateX(-50%); padding: 1px 7px 1px 15px; border-radius: 9px;
  font: 600 10.5px/1.5 "Segoe UI Variable Text", "Segoe UI", system-ui, sans-serif; color: #fff;
  background: rgba(24,24,28,.78); white-space: nowrap; pointer-events: none; }
.label i { position: absolute; left: 6px; top: 50%; width: 6px; height: 6px; margin-top: -3px; border-radius: 50%; }
`;

const debug = (...a) => { if (process.env.COMPA_DEBUG || process.env.COMPA_QA) console.log('[flock]', ...a); };
const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));

function writeBubble(el, text, tone, tag) {
  let lead = '', body = text, dots = false;
  const sp = text.indexOf(' ');
  if (sp > 0 && LEADS.has(text.slice(0, sp))) { lead = text.slice(0, sp + 1); body = text.slice(sp + 1); }
  if (!lead && body.endsWith('…')) { dots = true; body = body.slice(0, -1); }
  el.className = 'bubble ' + tone;
  el.innerHTML = '<span class="dot"></span>' + (tag ? `<span class="tag">${esc(tag)} · </span>` : '')
    + (lead ? `<span class="lead">${esc(lead)}</span>` : '') + esc(body)
    + (dots ? '<span class="dots"><span>.</span><span>.</span><span>.</span></span>' : '');
  void el.offsetWidth;
  el.classList.add('show');
}

function openWin(name, w, h, x, y) {
  const win = window.open('', name, `width=${Math.round(w)},height=${Math.round(h)},left=${Math.round(x)},top=${Math.round(y)}`);
  win.document.open();
  win.document.write(`<!DOCTYPE html><html><head><meta charset="utf-8"><style>${CSS}</style></head><body><canvas></canvas></body></html>`);
  win.document.close();
  return win;
}

async function decodeImage(file) {
  return createImageBitmap(new Blob([fs.readFileSync(file)], { type: 'image/png' }));
}

/** Escenarios: los incluidos y los de ~/.compa/scenes (los tuyos ganan). */
function scanScenes(dirs) {
  const out = [], seen = new Set();
  for (const dir of dirs) {
    let names = [];
    try { names = fs.readdirSync(dir).sort(); } catch { continue; }
    for (const n of names) {
      try {
        const f = path.join(dir, n), meta = JSON.parse(fs.readFileSync(path.join(f, 'scene.json'), 'utf8'));
        const id = meta.id || n;
        if (seen.has(id) || !fs.existsSync(path.join(f, 'back.png'))) continue;
        seen.add(id); out.push({ ...meta, id, name: meta.name || id, folder: f });
      } catch { /* no es un escenario */ }
    }
  }
  return out;
}

class Flock {
  /** ctx: { probe, settings, save, catalog(), bundledScenes, userScenes, alert, feedDesktop } */
  constructor(ctx) {
    Object.assign(this, ctx);
    this.members = new Map();
    this.sheets = new Map();
    this.assigned = new Map();
    this.order = [];
    this.scene = null; this.stageWin = null;
    this.timer = null; this.last = 0; this.polled = 0; this.synced = 0;
  }

  get layout() { return this.settings.layout || 'walks'; }
  get scenes() { return scanScenes([this.userScenes, this.bundledScenes]); }

  /** Avisos sin ver de todas, por sesión (menú y punto de la bandeja). */
  notices() {
    const m = new Map();
    for (const mem of this.members.values()) for (const [k, n] of mem.brain.notices) m.set(k, n);
    return m;
  }
  acknowledge(key) { for (const mem of this.members.values()) if (!key || mem.key === key) mem.brain.acknowledge(); }
  wave() { for (const mem of this.members.values()) mem.brain.wave(); }

  /** El rescate: el escenario al centro de la pantalla; las sueltas, con su sitio en medio. */
  recenter() {
    const wa = ipcRenderer.sendSync('env', 0, 0).work;
    if (this.scene) {
      const sc = this.scene;
      sc.x = Math.round(wa.x + (wa.width - sc.W) / 2); sc.y = wa.y + wa.height - sc.H - 8;
      ipcRenderer.send('wmove', 'stage', sc.x, sc.y); ipcRenderer.send('wvis', 'stage', true);
      this.settings.stageX = sc.x; this.settings.stageY = sc.y; this.save();
      return;
    }
    const live = [...this.members.values()].filter((m) => !m.leaving);
    live.forEach((m, i) => {
      m.home = wa.x + wa.width / 2 + (i - (live.length - 1) / 2) * Math.max(90, m.pw * 0.9);
      m.floor = wa.y + wa.height - 4;
      m.brain.walkTo(m.home);
    });
  }

  async start() {
    this.stop();
    if (this.layout === 'stage') await this.openStage();
    this.last = performance.now();
    this.timer = setInterval(() => this.tick(), 16);   // ventana principal oculta: nada de rAF
  }

  stop() {
    clearInterval(this.timer); this.timer = null;
    for (const m of this.members.values()) if (m.win && !m.win.closed) m.win.close();
    this.members.clear();
    if (this.stageWin && !this.stageWin.closed) this.stageWin.close();
    this.stageWin = null; this.scene = null;
  }

  async restart() { await this.start(); }

  async sheetFor(id) {
    if (!this.sheets.has(id)) {
      const entry = this.catalog().find((p) => p.id === id) || this.catalog()[0];
      this.sheets.set(id, loadSheet(entry).then((s) => ({ entry, sheet: s })).catch(() => null));
    }
    return this.sheets.get(id);
  }

  // ---------- quién está ----------
  async sync() {
    const live = this.probe.sessions.map((s) => ({ key: s.key, project: s.project }));
    if (this.probe.desktop.running && !this.probe.isHidden('desktop')) live.push({ key: 'desktop', project: 'Claude Desktop' });
    for (const s of live) if (!this.order.includes(s.key)) this.order.push(s.key);
    this.order = this.order.filter((k) => live.some((s) => s.key === k) || this.members.has(k));
    const want = this.order.map((k) => live.find((s) => s.key === k)).filter(Boolean).slice(0, MAX);
    const ids = this.catalog().map((p) => p.id);
    const rotation = (this.settings.rotation && this.settings.rotation.length ? this.settings.rotation : ids).filter((id) => ids.includes(id));
    this.assigned = assign(want, { by: this.settings.by || 'mix', rotation, mainPet: this.settings.petId,
                                   pins: this.settings.pins || {} }, this.assigned);
    for (const s of want) {
      const a = this.assigned.get(s.key);
      const m = this.members.get(s.key);
      if (!m) await this.add(s.key, a);
      else if (m.petId !== a.pet || m.color !== a.color || m.tint !== a.tint || m.label !== a.label) await this.restyle(m, a);
    }
    for (const m of this.members.values()) {
      if (!m.leaving && !want.some((s) => s.key === m.key)) this.leave(m);
    }
  }

  async add(key, a) {
    const loaded = await this.sheetFor(a.pet);
    if (!loaded || this.members.has(key)) return;
    const feed = key === 'desktop' ? new DesktopFeed(this.probe) : new SessionFeed(this.probe, key);
    const brain = new Brain(feed, 0);
    for (const k of ['wanders', 'followsCursor', 'reactsToClaude', 'announces']) brain[k] = this.settings[k];
    brain.alert = (e) => this.alert(e);
    const m = { key, feed, brain, petId: a.pet, color: a.color, tint: a.tint, label: a.label, ...loaded,
                scratch: document.createElement('canvas'), leaving: false, solid: false, born: performance.now() };
    brain.setPersonality(m.entry.reactions, m.entry.lines);
    brain.hasLook = this.layout !== 'stage' && m.sheet.look.length === 16;
    brain.hasTalk = !!m.sheet.rows.talking;
    this.members.set(key, m);
    debug('llega', key, a.pet, a.color, a.label);
    if (this.layout === 'stage' && this.scene) this.placeInStage(m);
    else this.openPetWindow(m);
  }

  async restyle(m, a) {
    debug('cambia', m.key, m.petId, '→', a.pet, m.color, '→', a.color, m.label, '→', a.label);
    const loaded = await this.sheetFor(a.pet);
    if (!loaded) return;
    Object.assign(m, { petId: a.pet, color: a.color, tint: a.tint, label: a.label, ...loaded });
    m.brain.setPersonality(m.entry.reactions, m.entry.lines);
    m.brain.hasTalk = !!m.sheet.rows.talking;
    if (this.layout !== 'stage') this.sizePetWindow(m);
    else if (this.scene) this.sizeInStage(m);
    if (m.labelEl) this.writeLabel(m);
  }

  hex(m) { return PALETTE[m.color % PALETTE.length].hex; }

  writeLabel(m) {
    m.labelEl.innerHTML = `<i style="background:${this.hex(m)}"></i>${esc(m.label)}`;
  }

  // ---------- ventanitas (free, walks) ----------
  petSize(m) {
    const z = this.settings.petHeight / Math.max(1, m.sheet.content.h) * 0.85;   // un poco más pequeñas
    return { z, w: m.sheet.cw * z, h: m.sheet.ch * z };
  }

  sizePetWindow(m) {
    const { z, w, h } = this.petSize(m);
    m.z = z; m.pw = w; m.ph = h;
    m.W = Math.max(w, 240); m.H = h + HEADROOM + LABEL;
    m.canvas.width = Math.round(m.W * devicePixelRatio); m.canvas.height = Math.round(m.H * devicePixelRatio);
    m.canvas.style.width = m.W + 'px'; m.canvas.style.height = m.H + 'px';
    ipcRenderer.send('wsize', m.name, m.W, m.H);
    m.brain.walkSpeed = this.settings.petHeight * 0.5;
  }

  openPetWindow(m) {
    const env = ipcRenderer.sendSync('env', 0, 0), wa = env.work;
    m.name = 'pet-' + m.key.replace(/[^\w-]/g, '_');
    m.floor = wa.y + wa.height - 4;
    const slot = this.slotOf(m, wa);
    const fromRight = slot > wa.x + wa.width / 2;
    const startX = fromRight ? wa.x + wa.width + 80 : wa.x - 80;
    m.brain.x = startX;
    m.win = openWin(m.name, 240, 200, startX - 120, m.floor - 200);
    const doc = m.win.document;
    m.canvas = doc.querySelector('canvas'); m.ctx = m.canvas.getContext('2d');
    m.bubbleEl = doc.createElement('div'); m.bubbleEl.className = 'bubble'; doc.body.appendChild(m.bubbleEl);
    m.labelEl = doc.createElement('div'); m.labelEl.className = 'label'; doc.body.appendChild(m.labelEl);
    this.writeLabel(m);
    m.brain.speak = (t, tone, tag) => writeBubble(m.bubbleEl, t, tone, tag);
    m.brain.hush = () => m.bubbleEl.classList.remove('show');
    this.sizePetWindow(m);
    m.home = slot;
    m.brain.walkTo(slot);
    this.wireWindowMouse(m);
  }

  slotOf(m, wa) {
    if (this.layout === 'free') return wa.x + 120 + Math.random() * (wa.width - 240);
    const i = [...this.members.keys()].indexOf(m.key);
    const { w } = this.petSize(m);
    const anchor = this.settings.homeX ?? (wa.x + wa.width - 120);
    return anchor - i * Math.max(90, w * 0.9);
  }

  wireWindowMouse(m) {
    const doc = m.win.document;
    const over = (e) => this.hitPet(m, e.clientX - (m.W - m.pw) / 2, e.clientY - HEADROOM, m.pw, m.ph);
    doc.addEventListener('mousemove', (e) => {
      if (m.drag) return;
      const s = over(e);
      if (s !== m.solid) { m.solid = s; ipcRenderer.send('wsolid', m.name, s); }
    });
    doc.addEventListener('pointerdown', (e) => {
      if (e.button !== 0 || !over(e)) return;
      m.canvas.setPointerCapture(e.pointerId);
      m.drag = { sx: e.screenX, sy: e.screenY, wx: m.win.screenX, wy: m.win.screenY, x: m.win.screenX, y: m.win.screenY, moved: false };
      m.brain.beginDrag();
    });
    doc.addEventListener('pointermove', (e) => {
      if (!m.drag) return;
      const dx = e.screenX - m.drag.sx, dy = e.screenY - m.drag.sy;
      if (Math.abs(dx) + Math.abs(dy) > 4) m.drag.moved = true;
      m.drag.x = m.drag.wx + dx; m.drag.y = m.drag.wy + dy;
      ipcRenderer.send('wmove', m.name, m.drag.x, m.drag.y);
    });
    doc.addEventListener('pointerup', () => {
      if (!m.drag) return;
      if (m.drag.moved) {
        const x = m.drag.x + m.W / 2;
        m.floor = m.drag.y + HEADROOM + m.ph - this.footInset(m);
        m.brain.endDrag(x);
        if (this.layout === 'walks') m.home = x;   // su sitio va con ella
      } else { m.brain.endDrag(m.brain.x); m.brain.acknowledge(); m.brain.wave(); }
      m.drag = null;
    });
    doc.addEventListener('contextmenu', (e) => { e.preventDefault(); ipcRenderer.send('popup'); });
  }

  footInset(m) { return (m.sheet.ch - (m.sheet.content.y + m.sheet.content.h)) * m.z; }

  hitPet(m, lx, ly, w, h) {
    const f = m.frame;
    if (!f || lx < 0 || ly < 0 || lx >= w || ly >= h) return false;
    const k = f.mask;
    return k.a[Math.floor(ly / h * k.h) * k.w + Math.floor(lx / w * k.w)] > 40;
  }

  leave(m) {
    debug('se va', m.key);
    m.leaving = true;
    const done = () => {
      debug('fuera', m.key);
      if (m.win && !m.win.closed) m.win.close();
      if (this.layout === 'stage') { m.bubbleEl?.remove(); m.labelEl?.remove(); }
      this.members.delete(m.key);
      this.order = this.order.filter((k) => k !== m.key);
    };
    m.brain.wave();
    setTimeout(() => {
      if (!this.members.has(m.key)) return;
      if (this.layout === 'stage') m.brain.walkTo(this.scene.door, done);
      else {
        const wa = ipcRenderer.sendSync('env', m.brain.x, m.floor).work;
        m.brain.walkTo(m.brain.x > wa.x + wa.width / 2 ? wa.x + wa.width + 120 : wa.x - 120, done);
      }
    }, 1500);
  }

  // ---------- escenario ----------
  async openStage() {
    const list = this.scenes;
    const meta = list.find((s) => s.id === this.settings.scene) || list[0];
    if (!meta) return;
    const back = await decodeImage(path.join(meta.folder, 'back.png'));
    let front = null;
    try { front = await decodeImage(path.join(meta.folder, 'front.png')); } catch { /* sin primer plano */ }
    const [sw, sh] = meta.size;
    const zoom = 2;   // la oficina siempre en su tamaño pequeño; "Tamaño" es el de las mascotas
    const W = sw * zoom, H = sh * zoom + HEADROOM;
    const env = ipcRenderer.sendSync('env', 0, 0), wa = env.work;
    const x = this.settings.stageX ?? wa.x + wa.width - W - 24, y = this.settings.stageY ?? wa.y + wa.height - H - 8;
    this.scene = { ...meta, back, front, zoom, W, H, x, y };
    const win = openWin('stage', W, H, x, y);
    this.stageWin = win;
    const doc = win.document;
    this.scene.canvas = doc.querySelector('canvas'); this.scene.ctx = this.scene.canvas.getContext('2d');
    this.scene.canvas.width = W * devicePixelRatio; this.scene.canvas.height = H * devicePixelRatio;
    this.scene.canvas.style.width = W + 'px'; this.scene.canvas.style.height = H + 'px';
    ipcRenderer.send('wsize', 'stage', W, H); ipcRenderer.send('wmove', 'stage', x, y);
    this.wireStageMouse();
  }

  placeInStage(m) {
    const sc = this.scene, doc = this.stageWin.document;
    m.name = 'stage';
    this.sizeInStage(m);
    m.bubbleEl = doc.createElement('div'); m.bubbleEl.className = 'bubble'; doc.body.appendChild(m.bubbleEl);
    m.labelEl = doc.createElement('div'); m.labelEl.className = 'label'; doc.body.appendChild(m.labelEl);
    this.writeLabel(m);
    m.brain.speak = (t, tone, tag) => writeBubble(m.bubbleEl, t, tone, tag);
    m.brain.hush = () => m.bubbleEl.classList.remove('show');
    m.brain.walkSpeed = 34;
    m.brain.bounds = sc.walk;
    this.assignDesks();
    m.brain.x = sc.door;
    m.brain.walkTo(m.desk ?? sc.walk[0] + Math.random() * (sc.walk[1] - sc.walk[0]));
  }

  /** Mediana = lo que encaja en las mesas; Pequeña y Grande escalan desde ahí. */
  sizeInStage(m) {
    const sc = this.scene;
    const scale = { 100: 0.8, 150: 1, 220: 1.3 }[this.settings.petHeight] || this.settings.petHeight / 150;
    m.z = sc.petHeight * sc.zoom * scale / Math.max(1, m.sheet.content.h);
    m.pw = m.sheet.cw * m.z; m.ph = m.sheet.ch * m.z;
  }

  /** Cada una a su mesa; sin mesa libre, trabajan de pie junto a la última. */
  assignDesks() {
    const sc = this.scene, desks = sc.desks || [];
    let i = 0;
    for (const m of this.members.values()) {
      if (m.leaving) continue;
      m.desk = i < desks.length ? desks[i] : (desks.at(-1) ?? sc.window) + 22 * (i - desks.length + 1);
      m.brain.spots = { work: m.desk, wait: m.desk + 18, rest: (sc.rest ?? sc.walk[1]) - 14 * (i % 3), window: sc.window };
      i++;
    }
  }

  wireStageMouse() {
    const sc = this.scene, doc = this.stageWin.document;
    const toScene = (e) => ({ x: e.clientX / sc.zoom, y: (e.clientY - HEADROOM) / sc.zoom });
    const petAt = (e) => {
      for (const m of [...this.members.values()].reverse()) {
        const lx = e.clientX - (m.brain.x * sc.zoom - m.pw / 2), ly = e.clientY - (HEADROOM + sc.floor * sc.zoom + this.footInset(m) - m.ph);
        if (this.hitPet(m, lx, ly, m.pw, m.ph)) return m;
      }
      return null;
    };
    const inScene = (e) => e.clientY >= HEADROOM;
    let solid = false;
    doc.addEventListener('mousemove', (e) => {
      if (this.stageDrag) return;
      const s = inScene(e) || !!petAt(e);
      if (s !== solid) { solid = s; ipcRenderer.send('wsolid', 'stage', s); }
      doc.body.style.cursor = petAt(e) ? 'grab' : inScene(e) ? 'move' : 'default';
    });
    doc.addEventListener('pointerdown', (e) => {
      if (e.button !== 0) return;
      sc.canvas.setPointerCapture(e.pointerId);
      const m = petAt(e);
      if (m) { m.brain.beginDrag(); this.stageDrag = { pet: m, moved: false, sx: e.screenX }; }
      else if (inScene(e)) this.stageDrag = { sx: e.screenX, sy: e.screenY, x0: sc.x, y0: sc.y, moved: false };
    });
    doc.addEventListener('pointermove', (e) => {
      const d = this.stageDrag;
      if (!d) return;
      if (Math.abs(e.screenX - d.sx) > 3) d.moved = true;
      if (d.pet) d.pet.brain.x = Math.min(Math.max(toScene(e).x, sc.walk[0]), sc.walk[1]);
      else {
        d.moved = true;
        sc.x = d.x0 + e.screenX - d.sx; sc.y = d.y0 + e.screenY - d.sy;
        ipcRenderer.send('wmove', 'stage', sc.x, sc.y);
      }
    });
    doc.addEventListener('pointerup', () => {
      const d = this.stageDrag; this.stageDrag = null;
      if (!d) return;
      if (d.pet) {
        d.pet.brain.endDrag(d.pet.brain.x);
        if (!d.moved) { d.pet.brain.acknowledge(); d.pet.brain.wave(); }
      } else { this.settings.stageX = sc.x; this.settings.stageY = sc.y; this.save(); }
    });
    doc.addEventListener('contextmenu', (e) => { e.preventDefault(); ipcRenderer.send('popup'); });
  }

  // ---------- reloj ----------
  tick() {
    const now = performance.now();
    const dt = Math.min(0.05, (now - this.last) / 1000); this.last = now;
    const env = ipcRenderer.sendSync('env', 0, 0);
    this.feedDesktop(env.desktop);
    if (now - this.polled > 200) { this.probe.poll(); this.polled = now; }
    if (now - this.synced > 500) { this.synced = now; this.sync(); }
    if (this.layout === 'stage') this.tickStage(dt, env);
    else for (const m of this.members.values()) this.tickWindow(m, dt, env);
  }

  tickWindow(m, dt, env) {
    if (!m.win || m.win.closed) return;
    const wa = env.work, b = m.brain;
    b.bounds = this.layout === 'free' ? [wa.x + m.pw * 0.4, wa.x + wa.width - m.pw * 0.4]
                                      : [m.home - 110, m.home + 110];
    const fi = this.footInset(m), contentH = m.sheet.content.h * m.z;
    const head = { x: b.x, y: m.floor - contentH * 0.78 };
    const f = b.step(dt, env.cursor, head, env.idle);
    m.frame = pickFrame(m.sheet, f);
    const dpr = devicePixelRatio, ctx = m.ctx;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, m.W, m.H);
    ctx.imageSmoothingEnabled = !m.sheet.pixelated;
    const px = (m.W - m.pw) / 2, py = HEADROOM;
    this.shadow(ctx, m, m.W / 2, py + m.ph - fi, m.pw);
    drawFrame(ctx, m.frame, m.sheet, px, py, m.pw, m.ph, m.tint ? this.hex(m) : null, m.scratch);
    m.bubbleEl.style.left = m.W / 2 + 'px';
    m.bubbleEl.style.bottom = Math.round(LABEL + fi + contentH + 6) + 'px';
    m.labelEl.style.left = m.W / 2 + 'px';
    m.labelEl.style.top = Math.round(py + m.ph - fi + 3) + 'px';
    const wx = Math.round(b.x - m.W / 2), wy = Math.round(m.floor + fi - (HEADROOM + m.ph));
    if (!m.drag && (wx !== m.wx || wy !== m.wy)) { m.wx = wx; m.wy = wy; ipcRenderer.send('wmove', m.name, wx, wy); }
  }

  shadow(ctx, m, cx, y, w) {
    ctx.save();
    ctx.fillStyle = this.hex(m); ctx.globalAlpha = 0.35;
    ctx.beginPath(); ctx.ellipse(cx, y, w * 0.22, Math.max(2, w * 0.04), 0, 0, Math.PI * 2); ctx.fill();
    ctx.restore();
  }

  tickStage(dt, env) {
    const sc = this.scene;
    if (!sc || !this.stageWin || this.stageWin.closed) return;
    // una oficina vacía puede esconderse hasta que alguien abra una sesión
    const hidden = !!this.settings.hideEmptyStage && this.members.size === 0;
    if (hidden !== !!this.stageHidden) { this.stageHidden = hidden; ipcRenderer.send('wvis', 'stage', !hidden); }
    const dpr = devicePixelRatio, ctx = sc.ctx, z = sc.zoom;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, sc.W, sc.H);
    ctx.imageSmoothingEnabled = !sc.pixelated;
    ctx.drawImage(sc.back, 0, HEADROOM, sc.W, sc.H - HEADROOM);
    const cursor = { x: (env.cursor.x - sc.x) / z, y: (env.cursor.y - sc.y - HEADROOM) / z };
    const ms = [...this.members.values()].sort((a, b) => a.brain.x - b.brain.x);
    if (process.env.COMPA_DEBUG && performance.now() - (this.dbg || 0) > 2000) {
      this.dbg = performance.now();
      debug(ms.map((m) => `${m.key}:x=${typeof m.brain.x === 'number' ? m.brain.x.toFixed(1) : m.brain.x} ${m.brain.activity}/${m.brain.clip} f=${m.brain.forced} t=${m.brain.walkTarget} desk=${m.desk} st=${m.feed.state}`).join(' | '));
    }
    const bubbles = [];
    for (const m of ms) {
      const b = m.brain, fi = this.footInset(m);
      const f = b.step(dt, cursor, { x: b.x, y: sc.floor - sc.petHeight * 0.78 }, env.idle);
      m.frame = pickFrame(m.sheet, f);
      const cx = b.x * z, feet = HEADROOM + sc.floor * z;
      ctx.imageSmoothingEnabled = !m.sheet.pixelated;
      this.shadow(ctx, m, cx, feet, m.pw);
      drawFrame(ctx, m.frame, m.sheet, cx - m.pw / 2, feet + fi - m.ph, m.pw, m.ph, m.tint ? this.hex(m) : null, m.scratch);
      m.labelEl.style.left = cx + 'px'; m.labelEl.style.top = Math.round(feet + 2) + 'px';
      m.bubbleEl.style.left = cx + 'px';
      bubbles.push({ m, cx, top: feet - m.sheet.content.h * m.z - 6 });
    }
    ctx.imageSmoothingEnabled = !sc.pixelated;
    if (sc.front) ctx.drawImage(sc.front, 0, HEADROOM, sc.W, sc.H - HEADROOM);
    // globitos que se pisarían: el siguiente sube un escalón
    let prev = null;
    for (const bb of bubbles) {
      let lift = 0;
      const w = bb.m.bubbleEl.offsetWidth || 120;
      if (prev && bb.m.bubbleEl.classList.contains('show') && Math.abs(bb.cx - prev.cx) < (w + prev.w) / 2 + 4) lift = prev.lift + 24;
      bb.m.bubbleEl.style.bottom = Math.round(sc.H - bb.top + lift) + 'px';
      if (bb.m.bubbleEl.classList.contains('show')) prev = { cx: bb.cx, w, lift };
    }
  }
}

module.exports = { Flock, scanScenes, PALETTE };
