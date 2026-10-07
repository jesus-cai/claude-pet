// Carga un atlas de Codex (8 columnas de 192x208; 9 filas v1, 11 filas v2 con 16
// direcciones de mirada) más las tiras opcionales de hablar y de entrada.
// Port de SpriteSheet.swift. Corre en el renderer: usa createImageBitmap y canvas.
'use strict';
const fs = require('fs');

const SCHEDULE = [
  ['idle', [280, 110, 110, 140, 140, 320]],
  ['runRight', [120, 120, 120, 120, 120, 120, 120, 220]],
  ['runLeft', [120, 120, 120, 120, 120, 120, 120, 220]],
  ['waving', [140, 140, 140, 280]],
  ['jumping', [140, 140, 140, 140, 280]],
  ['failed', [140, 140, 140, 140, 140, 140, 140, 240]],
  ['waiting', [150, 150, 150, 150, 150, 260]],
  ['working', [120, 120, 120, 120, 120, 220]],
  ['review', [150, 150, 150, 150, 150, 280]],
];
const NAMES = { idle: 'idle', 'running-right': 'runRight', 'running-left': 'runLeft', waving: 'waving',
                jumping: 'jumping', failed: 'failed', waiting: 'waiting', running: 'working', review: 'review' };

// Se lee el archivo con fs y se decodifica desde un Blob: una imagen cargada por
// file:// "contamina" el canvas y getImageData fallaría.
async function decode(file) {
  const buf = fs.readFileSync(file);
  const type = /\.webp$/i.test(file) ? 'image/webp' : 'image/png';
  return createImageBitmap(new Blob([buf], { type }));
}

function maskOf(bitmap, w, h) {
  const c = new OffscreenCanvas(w, h);
  const g = c.getContext('2d', { willReadFrequently: true });
  g.drawImage(bitmap, 0, 0, w, h);
  const px = g.getImageData(0, 0, w, h).data;
  const a = new Uint8Array(w * h);
  for (let i = 0; i < w * h; i++) a[i] = px[i * 4 + 3];
  let minX = w, minY = h, maxX = -1, maxY = -1;
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) if (a[y * w + x] > 40) {
    if (x < minX) minX = x; if (x > maxX) maxX = x; if (y < minY) minY = y; if (y > maxY) maxY = y;
  }
  return { w, h, a, box: maxX < 0 ? null : { x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1 } };
}

function frameAt(row, t) {
  const total = row.durations.reduce((s, d) => s + d, 0);
  if (total <= 0 || row.frames.length < 2) return 0;
  let rest = ((t % total) + total) % total;
  for (let i = 0; i < row.durations.length; i++) { if (rest < row.durations[i]) return i; rest -= row.durations[i]; }
  return row.frames.length - 1;
}

async function cells(bitmap, r, n, cw, ch, mw, mh, ms) {
  const row = { frames: [], durations: [] };
  for (let c = 0; c < n; c++) {
    if ((c + 1) * cw > bitmap.width) break;
    const bmp = await createImageBitmap(bitmap, c * cw, r * ch, cw, ch);
    const mask = maskOf(bmp, mw, mh);
    if (!mask.box) { bmp.close(); continue; }       // cuadro vacío: se salta
    row.frames.push({ bmp, mask });
    row.durations.push((Array.isArray(ms) ? ms[c] : ms) / 1000);
  }
  return row.frames.length ? row : null;
}

async function loadSheet(pet) {
  const atlas = await decode(pet.sheet);
  const W = atlas.width, H = atlas.height;
  if (W < 8 || W % 8) throw new Error('el ancho del atlas no es múltiplo de 8');
  const cw = W / 8;
  const wanted = cw * 208 / 192;
  const count = pet.version >= 2 ? 11 : (Math.abs(H / 11 - wanted) < Math.abs(H / 9 - wanted) ? 11 : 9);
  const ch = Math.floor(H / count);
  const mw = Math.max(24, cw >> 1), mh = Math.max(26, ch >> 1);
  const rows = {};
  for (let r = 0; r < SCHEDULE.length; r++) {
    const [name, ms] = SCHEDULE[r];
    const row = await cells(atlas, r, ms.length, cw, ch, mw, mh, ms);
    if (row) rows[name] = row;
  }
  if (!rows.idle) throw new Error('el atlas no tiene fila de reposo');
  let look = [];
  if (count >= 11) {
    for (let r = 9; r <= 10; r++) {
      const row = await cells(atlas, r, 8, cw, ch, mw, mh, 100);
      if (row) look.push(...row.frames);
    }
    if (look.length !== 16) look = [];
  }
  const strip = async (file, ms) => {
    try {
      const b = await decode(file);
      if (b.height !== ch) return null;
      return await cells(b, 0, Math.floor(b.width / cw), cw, ch, mw, mh, Math.max(40, ms));
    } catch { return null; }
  };
  if (pet.talk) { const t = await strip(pet.talk, pet.talkMs); if (t) rows.talking = t; }
  const intros = {};
  for (const [k, f] of Object.entries(pet.intros || {})) {
    if (!NAMES[k]) continue;
    const s = await strip(f, pet.introMs);
    if (s) intros[NAMES[k]] = s;
  }
  let pixelated = pet.pixelated;
  if (pixelated === null) {
    // el pixel art tiene bordes duros: casi ningún píxel semitransparente
    const m = maskOf(rows.idle.frames[0].bmp, cw, ch);
    let solid = 0, soft = 0;
    for (const a of m.a) if (a > 0) { if (a > 15 && a < 240) soft++; else solid++; }
    pixelated = solid > 0 && soft / (solid + soft) < 0.015;
  }
  const block = pixelBlock(rows.idle.frames[0].bmp), color = colorInfo(rows.idle.frames[0].bmp);
  // dónde está la mascota dentro de la celda (unión de los cuadros de reposo), y cada
  // animación a la misma escala que el reposo
  const fit = await evenOut({ rows, look, intros, cw, ch, mw, mh, pixelated });
  atlas.close();
  return { rows, look: fit.look, intros, cw: fit.cw, ch: fit.ch, content: fit.content, pixelated, block,
           scaled: fit.scaled, ...color };
}

/** Lo opaco de un cuadro sin las motas sueltas (una chispa, un brillo, un píxel
 *  perdido), en píxeles de la máscara: la caja de las manchas que cuentan y su masa
 *  (cuántos píxeles opacos). Una mota lejos del cuerpo agrandaba la caja y la mascota
 *  salía más pequeña de lo que es. */
function measure(mask) {
  const { w, h, a } = mask;
  const lab = new Int32Array(w * h).fill(-1);
  const comps = [], stack = [];
  let total = 0;
  for (let i = 0; i < w * h; i++) {
    if (a[i] <= 40 || lab[i] >= 0) continue;
    const c = { n: 0, x0: w, y0: h, x1: -1, y1: -1 }, id = comps.length;
    comps.push(c); lab[i] = id; stack.push(i);
    while (stack.length) {
      const j = stack.pop(), x = j % w, y = (j - x) / w;
      c.n++;
      if (x < c.x0) c.x0 = x; if (x > c.x1) c.x1 = x; if (y < c.y0) c.y0 = y; if (y > c.y1) c.y1 = y;
      for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
        const nx = x + dx, ny = y + dy;
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        const k = ny * w + nx;
        if (a[k] > 40 && lab[k] < 0) { lab[k] = id; stack.push(k); }
      }
    }
    total += c.n;
  }
  if (!total) return null;
  const min = Math.max(3, total * 0.03);
  let box = null, mass = 0;
  for (const c of comps) {
    if (c.n < min) continue;
    mass += c.n;
    const b = { x: c.x0, y: c.y0, w: c.x1 - c.x0 + 1, h: c.y1 - c.y0 + 1 };
    box = box ? unite(box, b) : b;
  }
  if (!box) return null;
  return { box, mass };
}

function unite(a, b) {
  const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
  return { x, y, w: Math.max(a.x + a.w, b.x + b.w) - x, h: Math.max(a.y + a.h, b.y + b.h) - y };
}

const median = (v) => { const s = v.slice().sort((p, q) => p - q); return s.length ? s[s.length >> 1] : 0; };

// Mascotas de la comunidad (petdex) a veces dibujan cada animación a una escala: el
// Pikachu corre a dos tercios de su tamaño de reposo y con los pies en el aire. Una fila
// claramente más pequeña que el reposo (por masa, que no cambia con la postura) se
// agranda hasta él y se apoya en el mismo suelo. Caer (failed) y saltar (jumping) se
// dejan: encogerse ahí suele ser a propósito.
const GROW_FROM = { move: 1.12, stand: 1.2 };
const GROW_MAX = 1.6;
const kindOf = (name) => (name === 'runRight' || name === 'runLeft' ? 'move'
                          : name === 'failed' || name === 'jumping' ? 'keep' : 'stand');

/** Mide el reposo (la caja que define el "tamaño") y agranda las filas pequeñas. Si
 *  alguna ya no cabe en su celda, todas las celdas crecen por igual. Cambia los cuadros
 *  en su sitio; devuelve las medidas nuevas. */
async function evenOut({ rows, look, intros, cw, ch, mw, mh, pixelated }) {
  const kx = cw / mw, ky = ch / mh;
  const toCell = (b) => ({ x: b.x * kx, y: b.y * ky, w: b.w * kx, h: b.h * ky });
  const idle = rows.idle.frames.map((f) => measure(f.mask)).filter(Boolean);
  let content = null;
  for (const m of idle) content = content ? unite(content, m.box) : { ...m.box };
  content = toCell(content || { x: 0, y: 0, w: mw, h: mh });
  const idleMass = median(idle.map((m) => m.mass));
  const mid = content.x + content.w / 2, floor = content.y + content.h;

  const groups = [];
  for (const [name, r] of Object.entries(rows)) if (name !== 'idle') groups.push({ kind: kindOf(name), frames: r.frames });
  if (look.length) groups.push({ kind: 'stand', frames: look });
  for (const [name, r] of Object.entries(intros)) groups.push({ kind: kindOf(name), frames: r.frames });

  let minX = 0, maxX = cw, minY = 0, scaled = 0;
  for (const g of groups) {
    if (g.kind === 'keep') continue;
    const ms = g.frames.map((f) => measure(f.mask)).filter(Boolean);
    if (!ms.length) continue;
    const k = Math.sqrt(idleMass / Math.max(1, median(ms.map((m) => m.mass))));
    if (k < GROW_FROM[g.kind]) continue;
    let u = null;
    for (const m of ms) u = u ? unite(u, m.box) : { ...m.box };
    u = toCell(u);
    g.t = { k: Math.min(k, GROW_MAX), cx: u.x + u.w / 2, bottom: u.y + u.h };
    minX = Math.min(minX, mid + (u.x - g.t.cx) * g.t.k);
    maxX = Math.max(maxX, mid + (u.x + u.w - g.t.cx) * g.t.k);
    minY = Math.min(minY, floor + (u.y - g.t.bottom) * g.t.k);
    scaled++;
  }
  if (!scaled) return { cw, ch, content, look, scaled };
  const padX = Math.ceil(Math.max(-minX, maxX - cw, 0)), padT = Math.ceil(-minY);
  const W = cw + 2 * padX, H = ch + padT;
  const nmw = Math.max(24, W >> 1), nmh = Math.max(26, H >> 1);
  const redo = async (f, t) => {
    const c = new OffscreenCanvas(W, H), g = c.getContext('2d');
    g.imageSmoothingEnabled = !pixelated; g.imageSmoothingQuality = 'high';
    if (t) g.setTransform(t.k, 0, 0, t.k, padX + mid - t.cx * t.k, padT + floor - t.bottom * t.k);
    else g.translate(padX, padT);
    g.drawImage(f.bmp, 0, 0);
    const bmp = await createImageBitmap(c);
    f.bmp.close();
    f.bmp = bmp; f.mask = maskOf(bmp, nmw, nmh);
  };
  const all = [{ frames: rows.idle.frames }, ...groups];
  for (const g of all) {
    if (!g.t && !padX && !padT) continue;
    for (const f of g.frames) await redo(f, g.t);
  }
  return { cw: W, ch: H, content: { ...content, x: content.x + padX, y: content.y + padT }, look, scaled };
}

/** El pixel art suele dibujarse pequeño y ampliarse: un píxel del dibujo es un bloque
 *  de N×N píxeles del atlas (4 en Mochi y Bober). Al ajustar el tamaño hay que respetar
 *  esos bloques, no cada píxel del atlas: si no, quedan muy pocos tamaños posibles. */
function pixelBlock(bmp) {
  const c = new OffscreenCanvas(bmp.width, bmp.height), g = c.getContext('2d', { willReadFrequently: true });
  g.drawImage(bmp, 0, 0);
  const px = new Uint32Array(g.getImageData(0, 0, bmp.width, bmp.height).data.buffer);
  const gcd = (a, b) => (b ? gcd(b, a % b) : a);
  let k = 0;
  for (let y = 0; y < bmp.height; y++) {
    let run = 0;
    for (let x = 0; x < bmp.width; x++) {
      const p = px[y * bmp.width + x], opaque = (p >>> 24) > 0;
      if (x > 0 && opaque && p === px[y * bmp.width + x - 1]) { run++; continue; }
      if (run > 0 && (px[y * bmp.width + x - 1] >>> 24) > 0) { k = gcd(k, run); if (k === 1) return 1; }
      run = opaque ? 1 : 0;
    }
    if (run > 0) k = gcd(k, run);
  }
  return Math.max(1, Math.min(k, 16));
}

/** ¿Mascota en grises (se tiñe) o de color (se gira el tono)? Y su tono dominante,
 *  para girar hasta el color pedido. */
function colorInfo(bmp) {
  const c = new OffscreenCanvas(bmp.width, bmp.height), g = c.getContext('2d', { willReadFrequently: true });
  g.drawImage(bmp, 0, 0);
  const px = g.getImageData(0, 0, bmp.width, bmp.height).data;
  let n = 0, sat = 0, hx = 0, hy = 0;
  for (let i = 0; i < px.length; i += 4) {
    if (px[i + 3] < 128) continue;
    const r = px[i] / 255, gg = px[i + 1] / 255, b = px[i + 2] / 255;
    const max = Math.max(r, gg, b), min = Math.min(r, gg, b), d = max - min;
    const s = max === 0 ? 0 : d / max;
    n++; sat += s;
    if (d < 0.05) continue;
    let h = max === r ? ((gg - b) / d) % 6 : max === gg ? (b - r) / d + 2 : (r - gg) / d + 4;
    h *= 60;
    hx += Math.cos(h * Math.PI / 180) * s; hy += Math.sin(h * Math.PI / 180) * s;
  }
  const hue = (Math.atan2(hy, hx) * 180 / Math.PI + 360) % 360;
  return { gray: n === 0 || sat / n < 0.12, hue };
}

/** Qué fila usar si el atlas no tiene la pedida. */
function rowFor(sheet, clip) {
  const chain = { runLeft: ['runLeft', 'runRight'], review: ['review', 'working'],
                  waiting: ['waiting', 'waving'], jumping: ['jumping', 'waving'] }[clip] || [clip];
  for (const c of chain) if (sheet.rows[c]) return sheet.rows[c];
  return sheet.rows.idle;
}

/** El cuadro a dibujar para lo que dice el cerebro. */
function pickFrame(sheet, f) {
  if (f.look !== null && f.look !== undefined && sheet.look.length === 16) return sheet.look[((f.look % 16) + 16) % 16];
  const intro = sheet.intros[f.clip];
  const lead = intro ? intro.durations.reduce((s, d) => s + d, 0) : 0;
  if (intro && f.clipAge < lead) return intro.frames[frameAt(intro, f.clipAge)];
  const row = rowFor(sheet, f.clip);
  return row.frames[frameAt(row, (f.clipAge - lead) * (f.sleeping ? 0.35 : 1))];
}

/** Tono (0-360) de un color #rrggbb. */
function hueOf(hex) {
  const r = parseInt(hex.slice(1, 3), 16) / 255, g = parseInt(hex.slice(3, 5), 16) / 255, b = parseInt(hex.slice(5, 7), 16) / 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
  if (!d) return 0;
  let h = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
  return (h * 60 + 360) % 360;
}

/** Dibuja un cuadro, teñido si toca: las de color giran el tono hasta el pedido (una
 *  Mochi azul sigue siendo Mochi); las grises se colorean conservando las sombras. */
function drawFrame(ctx, frame, sheet, x, y, w, h, hex, scratch) {
  if (!hex) { ctx.drawImage(frame.bmp, x, y, w, h); return; }
  if (!sheet.gray) {
    ctx.save();
    ctx.filter = `hue-rotate(${Math.round((hueOf(hex) - sheet.hue + 360) % 360)}deg)`;
    ctx.drawImage(frame.bmp, x, y, w, h);
    ctx.restore();
    return;
  }
  const bw = frame.bmp.width, bh = frame.bmp.height;
  if (scratch.width !== bw || scratch.height !== bh) { scratch.width = bw; scratch.height = bh; }
  const g = scratch.getContext('2d');
  g.globalCompositeOperation = 'source-over'; g.globalAlpha = 1;
  g.clearRect(0, 0, bw, bh);
  g.drawImage(frame.bmp, 0, 0);
  g.globalCompositeOperation = 'color'; g.globalAlpha = 0.7;
  g.fillStyle = hex; g.fillRect(0, 0, bw, bh);
  g.globalCompositeOperation = 'destination-in'; g.globalAlpha = 1;
  g.drawImage(frame.bmp, 0, 0);
  g.globalCompositeOperation = 'source-over';
  ctx.drawImage(scratch, x, y, w, h);
}

module.exports = { loadSheet, pickFrame, frameAt, drawFrame, hueOf, measure };
