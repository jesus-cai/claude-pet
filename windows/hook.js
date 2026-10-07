#!/usr/bin/env node
// Le cuenta a la mascota (Compa para Windows) qué está haciendo Claude Code.
//
// Port de hooks/compa-hook.sh a Node, sin dependencias. Claude Code lo llama en cada
// evento con el JSON del evento por stdin; escribe una línea por sesión en
// %USERPROFILE%\.compa\sessions\<session_id>:
//
//     <estado>\t<detalle>\t<pid>\t<evento>\t<proyecto>
//
// Se puede ejecutar con `node hook.js <Evento>` o como `Compa.exe --hook <Evento>`
// (la app lleva Node dentro), para quien no tenga Node instalado.
//
// Nunca escribe en stdout ni en stderr: lo que imprime un UserPromptSubmit entra en
// el prompt, y una mascota no tiene derecho a interrumpir la sesión.
'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');

const HOME = process.env.COMPA_HOME || path.join(os.homedir(), '.compa');

function clip(v) {
  const s = String(v ?? '').replace(/[\n\r\t]+/g, ' ');
  return s.length > 34 ? s.slice(0, 33) + '…' : s;
}
const lastPart = (p) => String(p ?? '').split(/[\\/]/).filter(Boolean).pop() || '';

/** Traduce un evento de Claude Code a [estado, detalle]. Estado '' = no es un estado. */
function classify(e, d) {
  const t = String(d.tool_name ?? '');
  const n = String(d.notification_type ?? '');
  const msg = String(d.message ?? '').toLowerCase();
  const inp = d.tool_input || {};
  const fname = lastPart(inp.file_path ?? inp.notebook_path ?? '');
  const host = String(inp.url ?? '').replace(/^[a-z]+:\/\//, '').split('/')[0];
  const mcp = t.startsWith('mcp__') ? t.split('__').pop() : '';
  const re = (r) => r.test(t);

  let state = 'thinking';
  if (e === 'Stop') state = 'done';
  else if (e === 'PostToolUseFailure') state = d.is_interrupt === true ? 'stopped' : 'thinking';
  else if (e === 'PermissionDenied') state = 'thinking';
  else if (e === 'PermissionRequest') state = 'waiting';
  else if (e === 'Notification') {
    // "Claude is waiting for your input" llega sola al minuto de acabar un turno y
    // nada la cierra: no es un estado
    if (['permission_prompt', 'worker_permission_prompt', 'elicitation_dialog',
         'elicitation_url_dialog', 'agent_needs_input'].includes(n)) state = 'waiting';
    else if (n !== '') state = '';
    else if (/waiting for your input/.test(msg)) state = '';
    else if (/permission|approv|permiso|needs your input/.test(msg)) state = 'waiting';
    else state = '';
  } else if (e === 'PreCompact') state = 'thinking';
  else if (e === 'PreToolUse') {
    if (re(/^(AskUserQuestion|ExitPlanMode)$/)) state = 'waiting';
    else if (re(/^(Edit|Write|MultiEdit|NotebookEdit)$/)) state = 'writing';
    else if (re(/^(Read|NotebookRead|Grep|Glob|ToolSearch)$/)) state = 'reading';
    else if (re(/^(Bash|BashOutput|KillShell|Monitor|PowerShell)$/)) state = 'running';
    else if (re(/^(WebSearch|WebFetch)$/)) state = 'searching';
    else if (re(/^(Task|Agent|Workflow|Skill)$/)) state = 'delegating';
    else if (mcp) state = 'running';
  }

  let detail = '';
  if (e === 'PreToolUse') {
    if (re(/^(Edit|Write|MultiEdit|NotebookEdit|Read|NotebookRead)$/)) detail = clip(fname);
    else if (t === 'AskUserQuestion') detail = 'question';
    else if (t === 'ExitPlanMode') detail = 'plan';
    else if (t === 'Bash' || t === 'PowerShell') detail = clip(inp.description ?? inp.command ?? '');
    else if (re(/^(Grep|Glob)$/)) detail = clip(inp.pattern ?? '');
    else if (t === 'WebSearch') detail = clip(inp.query ?? '');
    else if (t === 'WebFetch') detail = clip(inp.url ?? '');
    else if (re(/^(Task|Agent)$/)) detail = clip(inp.description ?? '');
    else if (t === 'Skill') detail = clip(inp.skill ?? '');
    else if (t === 'Workflow') detail = clip(inp.name ?? 'workflow');
    else if (mcp) detail = clip(mcp);
  } else if (e === 'PermissionRequest') {
    if (t === 'AskUserQuestion') detail = 'question';
    else if (t === 'ExitPlanMode') detail = 'plan';
    else if (t === 'EnterPlanMode') detail = 'plan first';
    else if (t === 'Bash' || t === 'PowerShell') detail = clip('run ' + (inp.description ?? inp.command ?? ''));
    else if (re(/^(Edit|Write|MultiEdit|NotebookEdit)$/)) detail = clip('edit ' + fname);
    else if (t === 'Read') detail = clip('read ' + fname);
    else if (t === 'WebFetch') detail = clip('fetch ' + host);
    else if (t === 'WebSearch') detail = clip('search ' + (inp.query ?? ''));
    else if (re(/^(Task|Agent)$/)) detail = 'send a helper';
    else if (t === 'Skill') detail = clip('run /' + (inp.skill ?? ''));
    else if (t === 'Workflow') detail = 'run a workflow';
    else if (mcp) detail = clip('use ' + mcp);
    else detail = clip('use ' + t);
  } else if (e === 'Notification') {
    detail = /permission/.test(n) || /permission|permiso|approv/.test(msg) ? 'permission' : 'input';
  } else if (e === 'PreCompact') detail = 'tidying up…';
  if (e === 'StopFailure') {
    // el turno terminó por un error de la API; el tipo dice cuál
    state = 'error';
    const kind = String(d.error_type ?? d.error ?? d.reason ?? '');
    detail = ERRORS[kind] || (kind ? clip(kind.replace(/_/g, ' ')) : 'api');
  }
  if (e === 'Stop' && d.last_assistant_message) {
    // el principio de la respuesta, para la notificación del sistema
    detail = clip((String(d.last_assistant_message).split('\n').find((l) => l.trim()) || '').trim());
  }
  return [state, detail];
}

const ERRORS = { rate_limit: 'usage limit reached', overloaded: 'API overloaded', authentication_failed: 'login expired',
                 oauth_org_not_allowed: 'login not allowed', account_on_hold: 'account on hold', billing_error: 'billing problem',
                 invalid_request: 'invalid request', model_not_found: 'model not found', server_error: 'server error',
                 max_output_tokens: 'answer too long', cloud_credential_error: 'cloud credentials', unknown: 'api' };
const AGENT_TTL = 30 * 60;
const WORKING = new Set(['thinking', 'reading', 'writing', 'running', 'searching', 'delegating']);   // un ayudante sin SubagentStop en media hora ya no cuenta

/** Cómo terminó el turno, mirando el final del transcript: 'cut', 'error' u 'ok'. */
function ending(transcript) {
  try {
    const fd = fs.openSync(transcript, 'r');
    const size = fs.fstatSync(fd).size;
    const len = Math.min(size, 256 * 1024);
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, size - len);
    fs.closeSync(fd);
    let last = 'ok';
    for (const line of buf.toString('utf8').split('\n')) {
      let j;
      try { j = JSON.parse(line); } catch { continue; }
      if (j.type === 'assistant') last = j.isApiErrorMessage === true ? 'error' : 'ok';
      else if (j.type === 'user') {
        const c = j.message?.content;
        const text = typeof c === 'string' ? c : Array.isArray(c) ? c.map((x) => x?.text ?? '').join(' ') : '';
        last = text.startsWith('[Request interrupted by user') ? 'cut' : 'ok';
      }
    }
    return last;
  } catch { return 'ok'; }
}

/** ¿Sigue vivo este proceso? */
function alive(pid) {
  if (!pid) return false;
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
}

/** El proceso `claude` de la sesión, buscado una vez por sesión y guardado: en
 *  Windows preguntar por el árbol de procesos cuesta casi un segundo. */
function sessionPid(dir, session) {
  const pidf = path.join(dir, `.${session}.pid`);
  try {
    const p = parseInt(fs.readFileSync(pidf, 'utf8'), 10);
    if (alive(p)) return p;
  } catch { /* sin caché todavía */ }
  let pid = 0;
  try {
    let procs;
    if (process.platform === 'win32') {
      const out = execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
        'Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name,CommandLine | ConvertTo-Json -Compress'],
        { timeout: 3500, windowsHide: true, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
      procs = JSON.parse(out).map((p) => ({ pid: p.ProcessId, ppid: p.ParentProcessId,
                                            name: String(p.Name || ''), cmd: String(p.CommandLine || '') }));
    } else {
      const out = execFileSync('ps', ['-axo', 'pid=,ppid=,command='], { encoding: 'utf8', timeout: 2000 });
      procs = out.split('\n').map((l) => l.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/)).filter(Boolean)
        .map((m) => ({ pid: +m[1], ppid: +m[2], name: m[3].split(/[\\/ ]/).filter(Boolean).pop() || '', cmd: m[3] }));
    }
    const byPid = new Map(procs.map((p) => [p.pid, p]));
    let p = process.ppid;
    for (let i = 0; i < 12 && p > 1; i++) {
      const pr = byPid.get(p);
      if (!pr) break;
      const name = pr.name.toLowerCase(), cmd = pr.cmd.toLowerCase();
      if (/^claude(\.exe)?$/.test(name) || (/^node(\.exe)?$/.test(name) && /claude/.test(cmd))) { pid = p; break; }
      p = pr.ppid;
    }
  } catch { /* sin pid: la app usa la caducidad de siempre */ }
  if (pid) { try { fs.writeFileSync(pidf, String(pid)); } catch { /* da igual */ } }
  return pid;
}

/** Hace todo el trabajo. Devuelve lo que escribió (para las pruebas). */
function run(eventArg, raw, opts = {}) {
  const root = opts.home || HOME;
  const dir = path.join(root, 'sessions');
  fs.mkdirSync(dir, { recursive: true });
  let d;
  try { d = JSON.parse(raw); } catch { return null; }   // mejor callarse que inventar
  if (!d || typeof d !== 'object') return null;
  const event = eventArg || String(d.hook_event_name ?? '');
  const session = String(d.session_id ?? 'solo').replace(/[^A-Za-z0-9._-]/g, '_') || 'solo';
  const f = path.join(dir, session);
  const log = path.join(root, 'events.log');
  let [state, detail] = classify(event, d);
  const kind = String(d.tool_name ?? '') + (d.notification_type ? ' ' + d.notification_type : '');
  const project = clip(lastPart(d.cwd ?? '').replace(/[\t\n\r]/g, ' '));
  const note = (what) => {
    const stamp = new Date().toISOString().slice(5, 19).replace('T', ' ');
    try { fs.appendFileSync(log, `${stamp}  ${event.padEnd(18)} ${session.slice(0, 8).padEnd(8)} ${String(what || '·').padEnd(9)} ${detail}\t${kind}\n`); }
    catch { /* nada */ }
  };
  const current = () => { try { return fs.readFileSync(f, 'utf8').split('\t')[0]; } catch { return ''; } };

  const side = (ext) => path.join(dir, `.${session}.${ext}`);
  if (event === 'SessionEnd') {
    note('(bye)');
    for (const g of [f, side('pid'), side('agents'), side('parked'), side('compact')]) { try { fs.unlinkSync(g); } catch { /* ya no está */ } }
    return 'bye';
  }

  // ---- compactar ----
  // Un /compact manual no es un turno: no llega ningún Stop detrás. PreCompact
  // guarda qué hacía la sesión y PostCompact vuelve a eso: a trabajar si fue
  // automática en mitad de un turno, a reposo (sin aviso) si fue manual.
  if (event === 'PreCompact') {
    try { fs.writeFileSync(side('compact'), current()); } catch { /* */ }
  } else if (event === 'PostCompact') {
    let prev = '';
    try { prev = fs.readFileSync(side('compact'), 'utf8').trim(); fs.unlinkSync(side('compact')); } catch { /* */ }
    detail = '';
    state = WORKING.has(prev) && d.trigger !== 'manual' ? 'thinking' : 'idle';
  }

  // ---- ayudantes (subagentes) ----
  // Lo que pasa dentro de un subagente trae agent_id. Un ayudante nunca termina la
  // sesión, y nunca tapa un permiso que el hilo principal tiene pendiente. Si el
  // hilo principal acaba su turno con ayudantes todavía en marcha (en segundo plano),
  // la sesión queda "aparcada" trabajando: el aviso de "terminado" llega cuando
  // acaba de verdad, no antes.
  const agentId = d.agent_id ? String(d.agent_id) : '';
  const now = Date.now() / 1000;
  const agents = new Map();
  try {
    for (const l of fs.readFileSync(side('agents'), 'utf8').split('\n')) {
      const [id, ts] = l.split(' ');
      if (id && now - Number(ts) < AGENT_TTL) agents.set(id, Number(ts));
    }
  } catch { /* ninguno */ }
  const saveAgents = () => {
    try {
      if (agents.size) fs.writeFileSync(side('agents'), [...agents].map(([id, ts]) => `${id} ${ts}`).join('\n') + '\n');
      else fs.unlinkSync(side('agents'));
    } catch { /* */ }
  };
  const parked = fs.existsSync(side('parked'));
  const park = (on) => { try { if (on) fs.writeFileSync(side('parked'), '1'); else fs.unlinkSync(side('parked')); } catch { /* */ } };
  const background = () => `${agents.size} in background`;

  if (event === 'SubagentStart') {
    agents.set(agentId || `anon-${now}`, now); saveAgents();
    if (current() === 'waiting') { note('(helper+)'); return 'helper'; }
    state = 'delegating'; detail = parked ? background() : clip(d.agent_type || 'helper');
  } else if (event === 'SubagentStop') {
    agents.delete(agentId); saveAgents();
    if (!parked) { note('(helper-)'); return 'helper'; }   // el hilo principal sigue: él dirá
    if (agents.size) { state = 'delegating'; detail = background(); }
    else {
      // el último ayudante acabó: Claude Code despierta al hilo principal para que
      // use el resultado. Si no lo hace en un rato, la app lo da por terminado.
      park(false); state = 'thinking'; detail = '';
    }
  } else if (agentId) {
    if (current() === 'waiting' && state !== 'waiting') { note('(helper)'); return 'helper'; }
    if (!state) { note('(ignored)'); return 'ignored'; }
  } else if (event !== 'Notification' && event !== 'Stop' && event !== 'StopFailure' && parked) {
    park(false);   // el hilo principal vuelve a estar activo
  }

  if (!state) { note('(ignored)'); return 'ignored'; }
  if (event === 'Notification' && current() === 'waiting') { note('(already)'); return 'already'; }

  if (event === 'Stop' && !agentId && agents.size) {
    state = 'delegating'; detail = background(); park(true);
  } else if (state === 'done') {
    let age = Infinity;
    try { age = (Date.now() - fs.statSync(f).mtimeMs) / 1000; } catch { /* nuevo */ }
    if (current() === 'stopped' && age < 30) state = 'stopped';
    else if (d.transcript_path) {
      const how = ending(String(d.transcript_path));
      if (how === 'cut') state = 'stopped';
      else if (how === 'error') { state = 'error'; detail = detail || 'api'; }
    }
  }

  const pid = opts.noPid ? 0 : sessionPid(dir, session);
  note(state);
  const transcript = String(d.transcript_path ?? '').replace(/[\t\n]/g, ' ');
  const line = `${state}\t${detail}\t${pid || ''}\t${event}\t${project}\t${transcript}\n`;
  const tmp = `${f}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, line);
  fs.renameSync(tmp, f);

  if ((state === 'done' || state === 'stopped' || state === 'error') && !agentId) {
    // sesiones muertas sin SessionEnd: sólo las de un proceso muerto, o sin pid y viejas
    for (const name of fs.readdirSync(dir)) {
      const g = path.join(dir, name);
      try {
        const st = fs.statSync(g);
        const age = (Date.now() - st.mtimeMs) / 1000;
        if (name.endsWith('.tmp')) { if (age > 60) fs.unlinkSync(g); continue; }
        if (name.startsWith('.')) continue;
        const gp = parseInt(fs.readFileSync(g, 'utf8').split('\t')[2], 10);
        const drop = () => {
          fs.unlinkSync(g);
          for (const x of ['pid', 'agents', 'parked', 'compact']) { try { fs.unlinkSync(path.join(dir, `.${name}.${x}`)); } catch { /* */ } }
        };
        if (gp) { if (!alive(gp)) drop(); }
        else if (age > 1800) drop();
      } catch { /* otro hook lo tocó a la vez */ }
    }
    try {
      if (fs.statSync(log).size > 400000) {
        const lines = fs.readFileSync(log, 'utf8').split('\n');
        fs.writeFileSync(log, lines.slice(-3000).join('\n'));
      }
    } catch { /* nada */ }
  }
  return line;
}

/** Lee stdin entero y corre. Nunca falla hacia fuera: un hook roto no puede romper Claude. */
function main(eventArg) {
  let raw = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (c) => { raw += c; });
  process.stdin.on('end', () => {
    try { run(eventArg, raw); } catch { /* silencio */ }
    process.exit(0);
  });
  process.stdin.on('error', () => process.exit(0));
}

module.exports = { run, classify, ending, main };
if (require.main === module) main(process.argv[2] || '');
