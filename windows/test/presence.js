// Lo que publica Claude Code en ~/.claude/sessions/<pid>.json manda en el nivel; los
// hooks ponen el detalle. Sobre todo: con ayudantes, un solo aviso al final de todo.
'use strict';
const fs = require('fs'), os = require('os'), path = require('path');
const hook = require('../hook.js');
const { Probe } = require('../lib/probe.js');
const { Brain } = require('../lib/brain.js');
const HOME = path.join(os.tmpdir(), 'compa-presence'); fs.rmSync(HOME, { recursive: true, force: true });
const S = path.join(HOME, 'sessions'), P = path.join(HOME, 'claude-sessions');
fs.mkdirSync(P, { recursive: true });
const OK = path.join(os.tmpdir(), 'compa-ok.jsonl');
fs.writeFileSync(OK, '{"type":"assistant","message":{"content":[]}}\n');
const send = (sid, ev, extra = {}) => hook.run(ev, JSON.stringify({ session_id: sid, cwd: '/u/proj-' + sid, ...extra }), { home: HOME, noPid: true });
/** Lo que escribiría Claude Code. `ago`: hace cuántos ms cambió de estado. */
let fakePid = 0;
const cc = (sid, status, { ago = 0, waitingFor, entrypoint = 'cli', pid = process.pid, started = Date.now() - 60000 } = {}) => {
  const now = Date.now() - ago;
  fs.writeFileSync(path.join(P, `${sid}-${pid}.json`), JSON.stringify({ pid, sessionId: sid, cwd: '/u/proj-' + sid,
    startedAt: started, kind: 'interactive', entrypoint, status, updatedAt: now, statusUpdatedAt: now, ...(waitingFor && { waitingFor }) }));
};
const backdate = (sid, ms) => { const t = (Date.now() - ms) / 1000; fs.utimesSync(path.join(S, sid), t, t); };
const probe = new Probe(S, P);
probe.desktopCodeQuiet = 0;   // sin los 10 s de margen, para no esperar
const b = new Brain(probe, 500); b.wanders = false; b.speak = () => {}; b.hush = () => {};
const alerts = []; b.alert = (e) => alerts.push(`${e.kind}:${e.project}`);
const run = (sec) => { for (let i = 0; i < sec * 60; i++) b.step(1 / 60, { x: 0, y: 0 }, { x: 500, y: 900 }, 0); };
const st = (sid) => probe.sessions.find((s) => s.key === sid) || {};
const checks = [];
const expect = (label, cond) => { checks.push(!!cond); console.log(cond ? '✓' : '✗', label); };
const fresh = (n) => alerts.slice(n);
run(0.3);

console.log('— ayudantes: un aviso, al final —');
send('A', 'UserPromptSubmit'); cc('A', 'busy'); run(0.3);
expect('trabajando', st('A').state === 'thinking');
let n = alerts.length;
// el hook no se enteró de los ayudantes (sin SubagentStart): su Stop dice "done"
send('A', 'Stop', { transcript_path: OK }); backdate('A', 3000); cc('A', 'busy', { ago: 8000 }); run(0.3);
expect('Stop del hilo principal con ayudantes vivos: sigue trabajando', st('A').state === 'delegating');
expect('…y sin aviso', fresh(n).length === 0);
// el ayudante acaba, Claude despierta, otro Stop, todavía queda otro ayudante
send('A', 'UserPromptSubmit'); send('A', 'Stop', { transcript_path: OK }); backdate('A', 3000); run(0.3);
expect('segundo Stop con otro ayudante vivo: sin aviso', fresh(n).length === 0 && st('A').state === 'delegating');
cc('A', 'idle', { ago: 2500 }); run(0.3);
expect('acaba todo: un aviso', fresh(n).join() === 'finished:proj-A' && st('A').state === 'done');
run(1);
expect('…y solo uno', fresh(n).length === 1);

console.log('— el final llega antes que el "idle" —');
send('A', 'UserPromptSubmit'); cc('A', 'busy'); run(0.3); n = alerts.length;
send('A', 'Stop', { transcript_path: OK }); run(0.3);          // hook de fin recién llegado, Claude Code aún "busy"
expect('ni aviso ni "ayudantes" durante el desfase', fresh(n).length === 0 && st('A').state === 'thinking');
cc('A', 'idle'); run(0.3);
expect('al llegar el idle: aviso', fresh(n).join() === 'finished:proj-A');

console.log('— turno nuevo con el hook aún por llegar —');
backdate('A', 10000); cc('A', 'busy'); run(0.3);
expect('ocupado después del final = turno nuevo, no ayudantes', st('A').state === 'thinking');

console.log('— Esc antes de responder —');
send('A', 'UserPromptSubmit'); backdate('A', 4000); cc('A', 'idle', { ago: 3000 }); n = alerts.length; run(0.3);
expect('cortado al momento (no a los 150 s)', st('A').state === 'stopped' && fresh(n).length === 0);
send('A', 'UserPromptSubmit'); cc('A', 'idle', { ago: 5000 }); run(0.3);
expect('mensaje nuevo antes de que Claude Code se entere: manda el hook', st('A').state === 'thinking');

console.log('— permisos —');
cc('A', 'busy'); send('A', 'PreToolUse', { tool_name: 'Bash', tool_input: { description: 'the tests' } }); backdate('A', 3000);
n = alerts.length; cc('A', 'waiting', { waitingFor: 'permission prompt' }); run(0.3);
expect('te espera aunque el hook no lo dijera', st('A').state === 'waiting' && fresh(n).join() === 'needsYou:proj-A');
send('A', 'PermissionRequest', { tool_name: 'Bash', tool_input: { description: 'the tests' } }); backdate('A', 2000); run(0.2);
cc('A', 'busy'); run(0.3);
expect('contestado: ejecutando al momento', st('A').state === 'running' && st('A').detail === 'the tests');
send('A', 'PermissionRequest', { tool_name: 'Bash', tool_input: { description: 'the tests' } }); backdate('A', 2000);
cc('A', 'waiting', { waitingFor: 'dialog open' }); run(0.3);
expect('un menú tuyo abierto no es "te espera"', st('A').state === 'running');

console.log('— sesión sin hooks —');
n = alerts.length;
cc('B', 'idle', { started: Date.now() - 500 }); run(0.3);
expect('recién abierta y quieta: no sale', !st('B').key);
cc('B', 'idle', { started: Date.now() - 600000, ago: 60000 }); run(0.3);
expect('ya terminada al verla: sale, sin aviso', st('B').state === 'done' && fresh(n).length === 0);
cc('B', 'busy'); run(0.3);
expect('trabajando', st('B').state === 'thinking');
cc('B', 'idle'); run(0.3);
expect('acaba: aviso', fresh(n).join() === 'finished:proj-B');
fs.unlinkSync(path.join(P, `B-${process.pid}.json`));

console.log('— Claude Desktop —');
cc('C', 'busy', { entrypoint: 'claude-desktop' }); run(0.3);
expect('Claude Code dentro de Claude Desktop: no se adivina por CPU', probe.desktopCodeBusy);
cc('C', 'idle', { entrypoint: 'claude-desktop' }); run(0.3);
expect('…y al acabar, vuelve la CPU', !probe.desktopCodeBusy);

console.log('— procesos muertos —');
cc('D', 'busy', { pid: 999999 }); run(0.3);
expect('un archivo de un proceso muerto no cuenta', !st('D').key);

if (checks.includes(false)) { console.log('FALLAN', checks.filter((c) => !c).length); process.exit(1); }
console.log('todo bien');
