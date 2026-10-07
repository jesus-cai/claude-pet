// Busca mascotas (formato atlas de Codex). Mismo orden que en Mac: las tuyas, las de
// Codex, las incluidas; si dos tienen el mismo id gana la primera.
'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');

const home = () => process.env.COMPA_HOME || path.join(os.homedir(), '.compa');
const userPets = () => path.join(home(), 'pets');
const codexPets = () => path.join(process.env.CODEX_HOME || path.join(os.homedir(), '.codex'), 'pets');

function entry(folder, origin) {
  let meta = {};
  try { meta = JSON.parse(fs.readFileSync(path.join(folder, 'pet.json'), 'utf8')) || {}; } catch { /* sin manifiesto */ }
  if (meta.kind === 'rig') return null;   // el rig por capas solo existe en Mac
  const id = (typeof meta.id === 'string' && meta.id) || path.basename(folder);
  const name = (typeof meta.displayName === 'string' && meta.displayName) || id;
  const exists = (rel) => { if (!rel) return null; const p = path.join(folder, rel); return fs.existsSync(p) ? p : null; };
  const sheet = exists(meta.spritesheetPath) || exists('spritesheet.webp') || exists('spritesheet.png');
  if (!sheet) return null;
  const intros = {};
  for (const [k, v] of Object.entries(meta.introSheets || {})) { const p = exists(v); if (p) intros[k] = p; }
  return {
    id, name, folder, origin, sheet,
    version: Number(meta.spriteVersionNumber) || 1,
    pixelated: typeof meta.pixelated === 'boolean' ? meta.pixelated : null,
    talk: exists(meta.talkSheet), talkMs: Number(meta.talkFrameMs) || 110,
    intros, introMs: Number(meta.introFrameMs) || 140,
    reactions: meta.reactions || {}, lines: meta.lines || {},
  };
}

function scan(bundled) {
  const roots = [[userPets(), 'tuya'], [codexPets(), 'Codex']];
  if (bundled) roots.push([bundled, 'incluida']);
  const seen = new Set(), out = [];
  for (const [dir, origin] of roots) {
    let names = [];
    try { names = fs.readdirSync(dir).sort(); } catch { continue; }
    for (const n of names) {
      if (n.startsWith('.')) continue;
      const f = path.join(dir, n);
      try { if (!fs.statSync(f).isDirectory()) continue; } catch { continue; }
      const e = entry(f, origin);
      if (e && !seen.has(e.id)) { seen.add(e.id); out.push(e); }
    }
  }
  return out;
}

module.exports = { scan, entry, home, userPets, codexPets };
