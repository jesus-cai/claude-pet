// Lee lo que los hooks escriben en ~/.compa/sessions y lo que el propio Claude Code
// publica de cada sesión en ~/.claude/sessions/<pid>.json, y lo convierte en dos cosas:
//  - el NIVEL: qué hace Claude ahora (para la animación y la frase de trabajo)
//  - los EVENTOS: qué ha pasado desde la última vez (para los avisos), detectados por
//    la fecha del archivo, así que se notan aunque lleguen tarde.
// Port de ClaudeProbe.swift (la parte de Claude Code; en Windows no se adivina
// Claude Desktop por CPU).
'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');

const WORKING = new Set(['thinking', 'reading', 'writing', 'running', 'searching', 'delegating']);
const isWorking = (s) => WORKING.has(s);
const STALE = 15 * 60;        // sin pid: un archivo de más de 15 min ya no dice nada
const DONE_QUIET = 6;         // un `done` solo manda en el nivel unos segundos
// Situaciones en las que ningún hook llega a cerrar el estado:
const WAKE_WAIT = 30;         // acabó el último ayudante y Claude no volvió a por el resultado
const ESC_WAIT = 150;         // Esc antes de la primera respuesta: no se dispara nada
const PARKED_WAIT = 30 * 60;  // ayudantes en segundo plano que nunca avisaron de que acabaron
const COMPACT_WAIT = 10 * 60; // una compactación sin PostCompact (Claude Code antiguo)

/** Lo que de verdad significa un archivo que nadie ha vuelto a tocar. */
function settle(s) {
  if (s.state === 'thinking' && s.source === 'SubagentStop' && s.age > WAKE_WAIT) return 'done';
  if (s.state === 'thinking' && s.source === 'UserPromptSubmit' && s.age > ESC_WAIT) {
    // solo si el transcript tampoco se ha movido: un razonamiento largo sí lo mueve
    let quiet = true;
    if (s.transcript) { try { quiet = (Date.now() - fs.statSync(s.transcript).mtimeMs) / 1000 > ESC_WAIT; } catch { /* */ } }
    if (quiet) return 'stopped';
  }
  if (s.state === 'thinking' && s.source === 'PreCompact' && s.age > COMPACT_WAIT) return 'idle';
  if (s.state === 'delegating' && (s.source === 'Stop' || s.source === 'SubagentStop') && s.age > PARKED_WAIT) return 'stopped';
  return s.state;
}

function alive(pid) {
  if (!pid) return false;
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
}

// ---- lo que publica Claude Code ----
//
// Cada sesión de Claude Code (terminal, VS Code, la pestaña Code de Claude Desktop, el
// SDK) mantiene ~/.claude/sessions/<pid>.json con su estado al momento: "busy" mientras
// responde o tiene ayudantes en marcha, "waiting" (+ waitingFor) cuando te espera,
// "idle" al acabar del todo ("shell" = acabado, con comandos en segundo plano). Es lo
// que usa la vista de sesiones del propio Claude Code. Manda en el NIVEL: un Esc, un
// permiso contestado o el final de verdad de un turno con ayudantes se notan al
// instante, sin esperas inventadas. Los hooks siguen poniendo el detalle (qué lee, qué
// ejecuta) y cómo acabó (bien, cortado, error). No está documentado: sin ese archivo
// (Claude Code antiguo), todo funciona como antes, solo con hooks.
const IDLE_SETTLE = 2;        // "idle" tiene que durar esto antes de cerrar un turno sin hook de fin
const presenceDir = () => process.env.COMPA_PRESENCE
  || path.join(process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude'), 'sessions');
// Claude Code dentro de Claude Desktop: su CPU es la de la app, no hay que adivinarla
const IN_DESKTOP = new Set(['claude-desktop', 'local-agent']);

function readPresence(dir) {
  const out = new Map();
  let names = [];
  try { names = fs.readdirSync(dir); } catch { return out; }
  for (const n of names) {
    if (!n.endsWith('.json')) continue;
    let j;
    try { j = JSON.parse(fs.readFileSync(path.join(dir, n), 'utf8')); } catch { continue; }
    if (!j || typeof j.sessionId !== 'string' || typeof j.status !== 'string') continue;
    const pid = Number(j.pid) || 0;
    if (!pid || !alive(pid)) continue;   // se borra al salir; si quedó, el proceso dirá
    out.set(j.sessionId, { pid, status: j.status, waitingFor: typeof j.waitingFor === 'string' ? j.waitingFor : '',
                           at: Number(j.statusUpdatedAt) || Number(j.updatedAt) || 0, startedAt: Number(j.startedAt) || 0,
                           cwd: String(j.cwd || ''), entrypoint: String(j.entrypoint || '') });
  }
  return out;
}

/** "dialog open" es un menú tuyo abierto en la terminal (/config…): no te está esperando. */
const realWait = (p) => p.status === 'waiting' && p.waitingFor !== 'dialog open';
const waitDetail = (w) => (/input/.test(w) ? 'input' : 'permission');

/** "¿ejecuto los tests?" era la pregunta; "ejecutando los tests" es la respuesta. */
function afterApproval(ask) {
  for (const [v, s] of [['run ', 'running'], ['use ', 'running'], ['edit ', 'writing'], ['read ', 'reading'],
                        ['fetch ', 'searching'], ['search ', 'searching'], ['send a helper', 'delegating']]) {
    if (ask.startsWith(v)) return [s, ask.slice(v.length).trim()];
  }
  return ['thinking', ''];
}

/** Lo que dice el hook, corregido por lo que dice Claude Code. */
function blend(sig, p, now) {
  const at = Math.max(sig.at, p.at);
  const set = (state, detail, when = at) => Object.assign(sig, { state, detail, at: when, age: Math.max(0, (now - when) / 1000) });
  if (realWait(p)) {
    // un hook de trabajo posterior al aviso de espera: ya contestaste, aunque el archivo no lo diga aún
    if (isWorking(sig.state) && sig.at > p.at + 1500) return sig;
    if (sig.state !== 'waiting') set('waiting', waitDetail(p.waitingFor));
    else sig.at = at;
  } else if (p.status === 'waiting') {
    // un menú tuyo abierto: si el hook decía "te espera", eso ya se contestó
    if (sig.state === 'waiting' && p.at > sig.at) { const [st, d] = afterApproval(sig.detail); set(st, d); }
  } else if (p.status === 'busy') {
    if (isWorking(sig.state)) return sig;
    if (sig.state === 'waiting') { const [st, d] = afterApproval(sig.detail); set(st, d); return sig; }
    if (sig.state === 'done' || sig.state === 'stopped' || sig.state === 'error') {
      // ocupado desde DESPUÉS del final: un turno nuevo (su hook está llegando)
      if (p.at > sig.at) { set('thinking', ''); return sig; }
      // ocupado desde ANTES: el hilo principal acabó (Stop) pero quedan ayudantes en
      // segundo plano. Nada de "terminado" todavía: el aviso llega cuando acabe todo,
      // una sola vez. Los primeros segundos, por si el "idle" está al caer, sin cambiar de cara.
      if ((now - sig.at) / 1000 < IDLE_SETTLE) set('thinking', '', sig.at);
      else set('delegating', 'helpers');
    } else set('thinking', '');
  } else if (p.status === 'idle' || p.status === 'shell') {
    if (!isWorking(sig.state) && sig.state !== 'waiting') return sig;
    if ((now - p.at) / 1000 < IDLE_SETTLE) return sig;     // el hook de fin está llegando
    // un hook más nuevo que ese "idle" (acabas de escribirle): manda él un rato
    if (sig.at > p.at && (now - sig.at) / 1000 < 10) return sig;
    // acabó sin hook que lo cierre: un Esc, un permiso cortado, ayudantes que acaban...
    if (sig.state === 'delegating' || sig.source === 'SubagentStop') set('done', sig.detail === 'helpers' ? '' : sig.detail, p.at);
    else if (sig.source === 'PreCompact' || sig.source === 'PostCompact') set('idle', '', p.at);
    else set('stopped', '', p.at);
  }
  return sig;
}

/** Una sesión que solo conoce Claude Code (sin hooks): lo que se pueda. */
function fromPresence(key, p, now) {
  let state;
  if (realWait(p)) state = 'waiting';
  else if (p.status === 'busy') state = 'thinking';
  else if (p.at - p.startedAt > 5000) state = 'done';     // ha trabajado: "idle" = terminó
  else return null;                                       // recién abierta y sin hacer nada
  return { key, state, detail: state === 'waiting' ? waitDetail(p.waitingFor) : '', pid: p.pid, source: 'presence',
           project: (p.cwd.split(/[\\/]/).filter(Boolean).pop() || '').slice(0, 34), transcript: '', at: p.at,
           age: Math.max(0, (now - p.at) / 1000) };
}

function readSignals(dir, now = Date.now(), presence = new Map()) {
  const out = [];
  const seen = new Set();
  let names = [];
  try { names = fs.readdirSync(dir); } catch { /* sin hooks todavía */ }
  for (const key of names) {
    if (key.startsWith('.') || key.endsWith('.tmp')) continue;
    const file = path.join(dir, key);
    let raw, st;
    try { st = fs.statSync(file); raw = fs.readFileSync(file, 'utf8'); } catch { continue; }
    if (!st.isFile()) continue;
    const parts = raw.replace(/[\r\n]+$/, '').split('\t');
    const pid = parseInt(parts[2], 10) || 0;
    const live = pid > 0 && alive(pid);
    if (pid > 0 && !live) {
      // el proceso de la sesión ya no existe: nadie está diciendo lo que pone
      try { fs.unlinkSync(file); fs.unlinkSync(path.join(dir, `.${key}.pid`)); } catch { /* */ }
      continue;
    }
    const age = (now - st.mtimeMs) / 1000;
    if (!live && age > STALE) continue;
    const sig = { key, state: parts[0] || 'thinking', detail: parts[1] || '', pid,
                  source: parts[3] || '', project: parts[4] || '', transcript: parts[5] || '', at: st.mtimeMs, age };
    const p = presence.get(key);
    if (p) { out.push(blend(sig, p, now)); seen.add(key); continue; }
    sig.state = settle(sig);
    // un `done` deducido llega tarde: para el nivel cuenta desde ahora, no desde el archivo
    if (sig.state === 'done' && parts[0] !== 'done') sig.age = Math.max(0, age - WAKE_WAIT);
    out.push(sig);
  }
  for (const [key, p] of presence) {
    if (seen.has(key) || key.startsWith('.') || /[\\/]/.test(key)) continue;
    const sig = fromPresence(key, p, now);
    if (sig) out.push(sig);
  }
  return out;
}

/** Un permiso pendiente, luego el trabajo, y solo si nada trabaja un `done` reciente:
 *  mientras quede algo en marcha la mascota sigue trabajando. */
function pick(all) {
  let notice = null, waiting = null, working = null;
  const newer = (a, b) => !a || b.at > a.at;
  for (const s of all) {
    if (s.state === 'done' || s.state === 'stopped' || s.state === 'error') {
      if (s.age < DONE_QUIET && newer(notice, s)) notice = s;
    } else if (s.state === 'waiting') { if (newer(waiting, s)) waiting = s; }
    else if (isWorking(s.state)) { if (newer(working, s)) working = s; }
  }
  return waiting || working || notice || null;
}

class Probe {
  constructor(dir, presence = presenceDir()) {
    this.dir = dir;
    this.presenceDir = presence;   // null: solo hooks
    this.presence = new Map();
    this.desktopCodeBusy = false;  // Claude Code de Claude Desktop trabajando: no se adivina por CPU
    this.desktopCodeLast = -Infinity;
    this.desktopCodeQuiet = 10000;
    this.state = 'idle';
    this.detail = '';
    this.project = '';
    this.isSignalled = false;
    this.sessions = [];
    this.events = [];
    this.seen = new Map();
    this.primed = false;
    // Claude Desktop, adivinado por CPU (lo rellena el renderer). Solo cuenta cuando
    // ninguna sesión de Claude Code está diciendo nada: un hook es un hecho.
    this.desktop = { busy: false, running: false, front: false };
    this.guessed = false;
    // Registro de eventos para varios oyentes (una mascota por sesión): cada canal
    // lleva su propio cursor, y nadie le quita un evento a otro. `takeEvents` sigue
    // siendo la cola del canal combinado, como siempre.
    this.log = [];
    this.seq = 0;
    // Sesiones quitadas a mano (clic derecho → Quitar): ni en la lista, ni mascota, ni
    // avisos, hasta que vuelvan a trabajar. Por clave: { open, at }. `open` = el turno
    // que corría al quitarla aún no ha acabado (lo que haga hasta acabarlo no cuenta).
    this.hidden = new Map();
    this.onHidden = null;   // () => void, para guardarlo
  }

  isHidden(key) { return this.hidden.has(key); }

  /** Quita una sesión (o 'desktop') hasta que vuelva a trabajar. */
  hide(key) {
    let open = false;
    if (key === 'desktop') open = !!this.desktop.busy;
    else {
      const s = this.sessions.find((x) => x.key === key);
      open = !!s && (isWorking(s.state) || s.state === 'waiting');
    }
    this.hidden.set(key, { open, at: Date.now() });
    if (this.onHidden) this.onHidden();
  }

  unhideAll() {
    // vuelven como estaban, no como nuevas: una que acabó hace rato no se celebra otra vez
    for (const s of readSignals(this.dir, Date.now(), this.presence)) if (this.hidden.has(s.key)) this.seen.set(s.key, { state: s.state, at: s.at });
    this.hidden.clear();
    if (this.onHidden) this.onHidden();
  }

  /** Qué sesiones quitadas vuelven: una que trabaja (o te espera) después de haber
   *  acabado el turno que tenía, o que recibe un mensaje nuevo tuyo. Las que ya no
   *  existen se olvidan. Devuelve las que se ven. */
  screen(all) {
    if (!this.hidden.size) return all;
    let changed = false;
    const out = [];
    for (const s of all) {
      const h = this.hidden.get(s.key);
      if (!h) { out.push(s); continue; }
      const active = isWorking(s.state) || s.state === 'waiting';
      if (!active) { if (h.open) { h.open = false; changed = true; } continue; }
      // (con un segundo de margen: la fecha del archivo y el reloj no van al milisegundo)
      if (!h.open || (s.source === 'UserPromptSubmit' && s.at > h.at + 1000)) {
        this.hidden.delete(s.key); changed = true; out.push(s);
      }
    }
    for (const key of [...this.hidden.keys()]) {
      if (key === 'desktop' || this.presence.has(key) || fs.existsSync(path.join(this.dir, key))) continue;
      this.hidden.delete(key); changed = true;
    }
    const d = this.hidden.get('desktop');
    if (d && !this.desktop.running) { this.hidden.delete('desktop'); changed = true; }   // cerrado: se olvida
    else if (d) {
      if (!this.desktop.busy) { if (d.open) { d.open = false; changed = true; } }
      else if (!d.open) { this.hidden.delete('desktop'); changed = true; }
    }
    if (changed && this.onHidden) this.onHidden();
    return out;
  }

  get isBusy() { return isWorking(this.state); }

  takeEvents() { const e = this.events; this.events = []; return e; }

  poll(now = Date.now()) {
    this.presence = this.presenceDir ? readPresence(this.presenceDir) : new Map();
    // y unos segundos después: su CPU tarda un poco en bajar
    const codeBusy = [...this.presence.values()].some((p) => IN_DESKTOP.has(p.entrypoint) && p.status === 'busy');
    if (codeBusy) this.desktopCodeLast = now;
    this.desktopCodeBusy = codeBusy || now - this.desktopCodeLast < this.desktopCodeQuiet;
    const all = this.screen(readSignals(this.dir, now, this.presence));
    this.track(all);
    this.sessions = all.slice().sort((a, b) => b.at - a.at);
    const sig = pick(all);
    this.isSignalled = !!sig;
    this.guessed = !sig && this.desktop.busy && !this.hidden.has('desktop');
    this.state = sig ? sig.state : (this.guessed ? 'thinking' : 'idle');
    this.detail = sig ? sig.detail : '';
    this.project = sig ? sig.project : '';
  }

  emit(e) {
    this.events.push(e);
    this.log.push({ ...e, seq: ++this.seq });
    if (this.log.length > 500) this.log.splice(0, this.log.length - 500);
  }

  track(all) {
    const now = new Map();
    for (const s of all) {
      now.set(s.key, { state: s.state, at: s.at });
      const before = this.seen.get(s.key);
      if (before && before.at === s.at && before.state === s.state) continue;
      let kind = null;
      if (s.state === 'done') kind = before?.state === 'done' ? null : 'finished';
      else if (s.state === 'error') kind = before?.state === 'error' ? null : 'failed';
      else if (s.state === 'waiting') kind = before?.state === 'waiting' ? null : 'needsYou';
      else if (s.state === 'stopped') kind = 'engaged';
      else if (isWorking(s.state)) kind = before && isWorking(before.state) ? null : 'engaged';
      if (!kind) continue;
      // una sesión sin hooks que aparece ya terminada: no la vimos trabajar, no se celebra
      if (!before && s.source === 'presence' && kind !== 'needsYou') continue;
      // al arrancar solo importa un permiso que siga en pie
      if (!this.primed && kind !== 'needsYou') continue;
      this.emit({ kind, session: s.key, project: s.project, detail: s.detail, quiet: !this.primed });
    }
    for (const key of this.seen.keys()) {
      if (!now.has(key)) this.emit({ kind: 'gone', session: key, project: '', detail: '', quiet: true });
    }
    this.seen = now;
    this.primed = true;
  }
}

/** Canal de UNA sesión de Claude Code, para su propia mascota. Misma interfaz que
 *  el lector (lo que el cerebro usa), pero solo ve esa sesión. No lee nada: el que
 *  coordina las mascotas hace `probe.poll()` una vez para todas, y cada canal se
 *  pone al día con lo leído. */
class SessionFeed {
  constructor(probe, key) {
    this.probe = probe; this.key = key;
    this.cursor = probe.seq;
    this.lastProject = '';
    this.desktop = { busy: false, running: false, front: false };
    this.refresh();
  }
  get isBusy() { return isWorking(this.state); }
  poll() { this.refresh(); }
  refresh() {
    const s = this.probe.sessions.find((x) => x.key === this.key);
    this.exists = !!s;
    this.guessed = false;
    this.isSignalled = !!s;
    this.sessions = s ? [s] : [];
    if (!s) { this.state = 'idle'; this.detail = ''; this.project = this.lastProject; return; }
    let st = s.state;
    // como en el combinado: un final solo manda en el nivel unos segundos
    if ((st === 'done' || st === 'stopped' || st === 'error') && s.age >= DONE_QUIET) st = 'idle';
    this.state = st; this.detail = s.detail; this.project = this.lastProject = s.project;
  }
  takeEvents() {
    // al día antes de entregar: un aviso tiene que llegar junto con el estado que lo explica
    this.refresh();
    const out = this.probe.log.filter((e) => e.seq > this.cursor && e.session === this.key);
    this.cursor = this.probe.seq;
    return out;
  }
}

/** Canal de Claude Desktop (adivinado por CPU), para su propia mascota. A diferencia
 *  del combinado, no cede ante Claude Code: cada uno tiene su mascota. */
class DesktopFeed {
  constructor(probe) { this.probe = probe; this.key = 'desktop'; this.sessions = []; this.refresh(); }
  get isBusy() { return isWorking(this.state); }
  get desktop() { return this.probe.desktop; }
  poll() { this.refresh(); }
  refresh() {
    const d = this.probe.desktop;
    this.exists = !!d.running;
    this.isSignalled = false;
    this.state = d.busy ? 'thinking' : 'idle';
    this.guessed = !!d.busy;
    this.detail = ''; this.project = 'Claude Desktop';
  }
  takeEvents() { return []; }   // sus avisos los deduce el cerebro al acabar la racha
}

module.exports = { Probe, SessionFeed, DesktopFeed, isWorking, readSignals, readPresence, pick };
