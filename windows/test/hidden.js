// Quitar sesiones a mano (clic derecho → Quitar esta sesión): fuera de la lista, sin
// mascota y sin avisos hasta que vuelvan a trabajar.
'use strict';
const fs = require('fs'), os = require('os'), path = require('path');
const hook = require('../hook.js');
const { Probe, SessionFeed } = require('../lib/probe.js');
const { Brain } = require('../lib/brain.js');
const HOME = path.join(os.tmpdir(), 'compa-hidden'); fs.rmSync(HOME, { recursive: true, force: true });
const OK = path.join(os.tmpdir(), 'compa-ok.jsonl');
fs.writeFileSync(OK, '{"type":"assistant","message":{"content":[]}}\n');
const send = (sid, proj, ev, extra = {}) => hook.run(ev, JSON.stringify({ session_id: sid, cwd: '/u/' + proj, ...extra }), { home: HOME, noPid: true });
const pause = (ms) => { const t = Date.now() + ms; while (Date.now() < t) { /* espera */ } };
const probe = new Probe(path.join(HOME, 'sessions'), null);
let saved = 0; probe.onHidden = () => saved++;
const b = new Brain(probe, 500); b.wanders = false;
const alerts = []; b.alert = (e) => alerts.push(`${e.kind}:${e.project}`); b.speak = () => {}; b.hush = () => {};
const run = (sec) => { for (let i = 0; i < sec * 60; i++) b.step(1 / 60, { x: 0, y: 0 }, { x: 500, y: 900 }, 0); };
const checks = [];
const expect = (label, cond) => { checks.push(!!cond); console.log(cond ? '✓' : '✗', label); };
const keys = () => probe.sessions.map((s) => s.key).sort().join(',');

send('A', 'zombi', 'UserPromptSubmit'); send('B', 'api', 'UserPromptSubmit'); run(0.5);
send('A', 'zombi', 'Stop', { transcript_path: OK }); run(0.5);
expect('dos sesiones, A con aviso', keys() === 'A,B' && b.notices.has('A'));

// quitar una que ya acabó
b.acknowledgeSession('A'); probe.hide('A'); probe.poll(); run(0.3);
expect('A quitada: fuera de la lista', keys() === 'B');
expect('…y se guarda', saved >= 1 && probe.isHidden('A'));
expect('el estado lo lleva B', probe.state === 'thinking' && probe.project === 'api');
// lo que pase en A sin que le escribas no la trae (p. ej. una notificación suelta)
send('A', 'zombi', 'Notification', { message: 'Claude is waiting for your input' }); pause(5); run(0.3);
expect('una notificación de reposo no la trae', keys() === 'B');
// le escribes otra vez: vuelve
pause(5); send('A', 'zombi', 'UserPromptSubmit'); run(0.3);   // acabado: no hace falta margen
expect('le escribes: vuelve', keys() === 'A,B' && !probe.isHidden('A'));

// quitar una que está trabajando: lo que queda de ese turno no la trae
probe.hide('B'); probe.poll(); run(0.3);
expect('B quitada mientras trabaja', keys() === 'A' && probe.hidden.get('B').open === true);
send('B', 'api', 'PreToolUse', { tool_name: 'Bash', tool_input: { description: 'tests' } }); run(0.3);
expect('sigue con su turno: sigue fuera', keys() === 'A');
const before = alerts.length;
send('B', 'api', 'Stop', { transcript_path: OK }); run(0.5);
expect('acaba su turno: sin aviso ni sonido', keys() === 'A' && alerts.length === before && !b.notices.has('B'));
send('B', 'api', 'UserPromptSubmit'); run(0.3);
expect('turno nuevo: vuelve', keys() === 'A,B');

// cortada con Esc (no llega Stop) y le escribes otra vez: vuelve igual
send('C', 'web', 'UserPromptSubmit'); probe.poll(); probe.hide('C'); probe.poll();
expect('C quitada a mitad de turno', !keys().includes('C'));
pause(1100); send('C', 'web', 'UserPromptSubmit'); run(0.3);
expect('mensaje nuevo tras Esc: vuelve', keys().includes('C'));
fs.rmSync(path.join(HOME, 'sessions', 'C'));

// la sesión se cierra estando quitada: se olvida
probe.hide('A'); probe.poll();
fs.rmSync(path.join(HOME, 'sessions', 'A'));
probe.poll();
expect('cerrada: ya no cuenta como quitada', !probe.isHidden('A'));

// Claude Desktop: fuera hasta que vuelva a responder después de acabar
probe.desktop = { busy: true, running: true, front: false };
fs.rmSync(path.join(HOME, 'sessions', 'B')); run(0.3);   // sin Claude Code: manda la adivinanza
expect('Desktop respondiendo', probe.guessed);
probe.hide('desktop'); probe.poll();
expect('Desktop quitado: no se adivina', !probe.guessed && probe.isHidden('desktop'));
probe.desktop = { busy: false, running: true, front: false }; probe.poll();
expect('acaba: sigue quitado', probe.isHidden('desktop'));
probe.desktop = { busy: true, running: true, front: false }; probe.poll();
expect('vuelve a responder: vuelve', !probe.isHidden('desktop') && probe.guessed);

// Una mascota por sesión: la de una sesión quitada se queda sin sesión
probe.desktop = { busy: false, running: false, front: false };
send('B', 'api', 'UserPromptSubmit');
const feed = new SessionFeed(probe, 'B'); probe.poll(); feed.refresh();
expect('canal de B la ve', feed.exists);
probe.hide('B'); probe.poll(); feed.refresh();
expect('quitada: su mascota se va', !feed.exists);
probe.unhideAll(); probe.poll(); feed.refresh();
expect('"volver a mostrar": vuelve', feed.exists && probe.hidden.size === 0);

// "volver a mostrar" una que acabó hace rato: vuelve tal cual, sin celebrarlo otra vez
send('B', 'api', 'Stop', { transcript_path: OK }); run(0.3); b.acknowledge();
probe.hide('B'); probe.poll(); run(0.3);
const n0 = alerts.length;
probe.unhideAll(); run(0.5);
expect('vuelve sin aviso ni sonido', keys().includes('B') && alerts.length === n0 && !b.notices.has('B'));
// Claude Desktop quitado y cerrado: se olvida
probe.desktop = { busy: true, running: true, front: false }; probe.hide('desktop');
probe.desktop = { busy: false, running: false, front: false }; probe.poll();
expect('Desktop cerrado: se olvida', !probe.isHidden('desktop'));

if (checks.includes(false)) { console.log('FALLAN', checks.filter((c) => !c).length); process.exit(1); }
console.log('todo bien');
