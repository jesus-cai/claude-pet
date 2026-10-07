// Quién es quién en el modo "una mascota por sesión": qué mascota y qué color le toca
// a cada sesión. Estable: el mismo proyecto recibe siempre lo mismo (salvo que lo fijes
// a mano), y dos sesiones activas no se repiten mientras quede donde elegir.
'use strict';

const PALETTE = [
  { id: 'coral', name: 'Coral', hex: '#ff6b5e' }, { id: 'ambar', name: 'Ámbar', hex: '#ffb02e' },
  { id: 'verde', name: 'Verde', hex: '#4cc764' }, { id: 'turquesa', name: 'Turquesa', hex: '#2ec4b6' },
  { id: 'azul', name: 'Azul', hex: '#4a8cff' }, { id: 'violeta', name: 'Violeta', hex: '#9b6bff' },
  { id: 'rosa', name: 'Rosa', hex: '#ff6fb5' }, { id: 'oliva', name: 'Oliva', hex: '#9aa63a' },
];

function hash(s) {   // FNV-1a: estable entre ejecuciones y entre Mac y Windows
  let h = 0x811c9dc5;
  for (const ch of String(s)) { h ^= ch.codePointAt(0); h = Math.imul(h, 0x01000193) >>> 0; }
  return h >>> 0;
}

/** El primero libre empezando por el preferido; si están todos cogidos, el preferido. */
function probe(n, start, taken) {
  for (let i = 0; i < n; i++) { const k = (start + i) % n; if (!taken.has(k)) return k; }
  return start % n;
}

/**
 * sessions: [{key, project}] en orden de llegada.
 * opts: { by: 'pet'|'color'|'mix', rotation: [petId], mainPet, pins: {project: {pet, color}} }
 * keep: asignaciones vigentes (Map key → {pet, color}) para no cambiar a nadie que ya está.
 * Devuelve Map key → { pet, color (índice de PALETTE), tint (bool), label }.
 */
function assign(sessions, opts, keep = new Map()) {
  const rotation = opts.rotation && opts.rotation.length ? opts.rotation : [opts.mainPet];
  const by = opts.by || 'mix';
  const out = new Map(), petsTaken = new Set(), colorsTaken = new Set();
  const usedPet = new Map();      // mascota → cuántas veces (para teñir las repetidas en 'pet')
  for (const s of sessions) {
    const pin = (opts.pins || {})[s.project] || {};
    const prev = keep.get(s.key);
    let pet, color;
    if (prev && prev.pet && rotation.concat([opts.mainPet]).includes(prev.pet) && !pin.pet) pet = prev.pet;
    else if (pin.pet) pet = pin.pet;
    else if (by === 'color') pet = opts.mainPet;
    else pet = rotation[probe(rotation.length, hash(s.project || s.key), petsTaken)];
    petsTaken.add(rotation.indexOf(pet));
    if (prev && prev.color !== undefined && pin.color === undefined) color = prev.color;
    else if (pin.color !== undefined) color = pin.color;
    else color = probe(PALETTE.length, hash('c:' + (s.project || s.key)), colorsTaken);
    colorsTaken.add(color);
    usedPet.set(pet, (usedPet.get(pet) || 0) + 1);
    // el sprite se tiñe en 'color' y 'mix'; en 'pet' solo si la mascota se repite
    const tint = by !== 'pet' || usedPet.get(pet) > 1 || pin.color !== undefined;
    out.set(s.key, { pet, color, tint, label: s.project || 'Claude' });
  }
  // dos sesiones del mismo proyecto: "mi-app · 2"
  const seen = new Map();
  for (const s of sessions) {
    const a = out.get(s.key), n = (seen.get(a.label) || 0) + 1;
    seen.set(a.label, n);
    if (n > 1) a.label = `${a.label} · ${n}`;
  }
  return out;
}

module.exports = { assign, PALETTE, hash };
