// Registra el hook de Compa en %USERPROFILE%\.claude\settings.json, que leen tanto
// Claude Code en la terminal como la extensión de VS Code. Idempotente: quita las
// entradas suyas de antes (incluidas las de la versión Chihiro), respeta las tuyas y
// guarda un .bak antes de escribir.
'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');

const EVENTS = [['UserPromptSubmit', false], ['PreToolUse', true], ['PostToolUse', true],
  ['PostToolUseFailure', true], ['PermissionRequest', true], ['PermissionDenied', true],
  ['Notification', false], ['Stop', false], ['StopFailure', false], ['SubagentStart', false],
  ['SubagentStop', false], ['PostCompact', false], ['PreCompact', false], ['SessionEnd', false]];

const OURS = /[\\/]\.(compa|chihiro)[\\/]hook|compa(\.exe)?"?\s+--hook/i;
const isOurs = (group) => (group.hooks || []).some((h) => OURS.test(String(h.command || '')));

/** Rutas con barras normales y sin comillas si no hay espacios: así el mismo comando
 *  funciona en cmd, en PowerShell y en Git Bash, sea cual sea el que use Claude Code. */
function quote(p) {
  const s = p.replace(/\\/g, '/');
  return /\s/.test(s) ? `"${s}"` : s;
}

/** mode: {node: true, script} → `node script Evento`; {exe} → `Compa.exe --hook Evento` */
function commandFor(ev, mode) {
  return mode.node ? `node ${quote(mode.script)} ${ev}` : `${quote(mode.exe)} --hook ${ev}`;
}

function register(mode, settingsPath = path.join(os.homedir(), '.claude', 'settings.json')) {
  let settings = {};
  let raw = '';
  try { raw = fs.readFileSync(settingsPath, 'utf8'); settings = raw.trim() ? JSON.parse(raw) : {}; }
  catch (e) { if (e.code !== 'ENOENT') return { ok: false, error: `settings.json no es JSON válido: ${e.message}` }; }
  const before = JSON.stringify(settings);
  settings.hooks = settings.hooks || {};
  for (const [ev, matcher] of EVENTS) {
    const kept = (settings.hooks[ev] || []).filter((g) => !isOurs(g));
    const mine = { hooks: [{ type: 'command', command: commandFor(ev, mode), timeout: 5 }] };
    if (matcher) mine.matcher = '*';
    settings.hooks[ev] = [...kept, mine];
  }
  if (JSON.stringify(settings) === before) return { ok: true, changed: false };
  fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
  if (raw) fs.writeFileSync(settingsPath + '.bak', raw);
  fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');
  return { ok: true, changed: true };
}

function unregister(settingsPath = path.join(os.homedir(), '.claude', 'settings.json')) {
  let raw;
  try { raw = fs.readFileSync(settingsPath, 'utf8'); } catch { return { ok: true, changed: false }; }
  const s = JSON.parse(raw);
  if (!s.hooks) return { ok: true, changed: false };
  for (const ev of Object.keys(s.hooks)) {
    s.hooks[ev] = (s.hooks[ev] || []).filter((g) => !isOurs(g));
    if (!s.hooks[ev].length) delete s.hooks[ev];
  }
  fs.writeFileSync(settingsPath + '.bak', raw);
  fs.writeFileSync(settingsPath, JSON.stringify(s, null, 2) + '\n');
  return { ok: true, changed: true };
}

module.exports = { register, unregister, commandFor, EVENTS };
