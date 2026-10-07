// Claude Desktop respondiendo (adivinado) de principio a fin, y una sesión de Claude
// Code que manda sobre la adivinanza.
'use strict';
const fs = require('fs'), os = require('os'), path = require('path');
const hook = require('../hook.js');
const { Probe } = require('../lib/probe.js');
const { Brain } = require('../lib/brain.js');
const { DesktopGuess } = require('../lib/desktop.js');
const HOME = path.join(os.tmpdir(), 'compa-desk'); fs.rmSync(HOME, { recursive: true, force: true });
const probe = new Probe(path.join(HOME, 'sessions'), null), b = new Brain(probe, 500), g = new DesktopGuess();
b.wanders = false;
const said = []; b.speak = (t, tone, tag) => said.push(`[${tone}] ${tag ? tag + ' · ' : ''}${t}`); b.hush = () => {};
const alerts = []; b.alert = (e) => alerts.push(`${e.kind}:${e.project}`);
let total = 0, t = 0;
// una muestra por segundo, como el vigilante de PowerShell
function second(cpu, front, input) {
  t += 1; total += cpu;
  if (probe.isSignalled) { g.reset(); probe.desktop = { busy: false, running: true, front }; }
  else probe.desktop = { busy: g.sample(t, total, front, input).busy, running: true, front };
  for (let i = 0; i < 60; i++) b.step(1 / 60, { x: 0, y: 0 }, { x: 500, y: 900 }, input);
}
const checks = [];
const expect = (label, ok) => { checks.push(ok); console.log(ok ? '✓' : '✗', label, '→', b.activity, JSON.stringify(said.at(-1) || '')); };
for (let i = 0; i < 5; i++) second(0.02, true, 1 + i);         // escribe y envía
for (let i = 0; i < 6; i++) second(0.45, true, 6 + i);         // responde
expect('Claude Desktop respondiendo → trabaja', b.activity === 'working' && probe.guessed);
for (let i = 0; i < 4; i++) second(0.03, true, 12 + i);        // pausa de 4 s entre ráfagas
expect('pausa corta: sigue trabajando', b.activity === 'working');
for (let i = 0; i < 6; i++) second(0.45, true, 16 + i);
for (let i = 0; i < 16; i++) second(0.02, true, 22 + i);       // termina
expect('termina: reacciona y avisa', /\[done\] Claude Desktop · /.test(said.at(-1) || '') && alerts.includes('finished:Claude Desktop'));
// ahora una sesión de Claude Code: manda ella, y la CPU de Desktop no cuenta
b.acknowledge();
hook.run('UserPromptSubmit', JSON.stringify({ session_id: 'k', cwd: '/u/proyecto' }), { home: HOME, noPid: true });
for (let i = 0; i < 3; i++) second(0.6, false, 50);
expect('con Claude Code activo manda el hook', b.activity === 'working' && !probe.guessed && probe.isSignalled);
if (checks.includes(false)) process.exit(1);
console.log('todo bien');
