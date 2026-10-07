// Puestos y paseos dirigidos (escenario): a la mesa a trabajar, al frente a avisar,
// por la puerta al llegar y al irse. Sin puestos, nada cambia (lo cubren las otras pruebas).
'use strict';
const fs = require('fs'), os = require('os'), path = require('path');
const hook = require('../hook.js');
const { Probe, SessionFeed } = require('../lib/probe.js');
const { Brain } = require('../lib/brain.js');
const HOME = path.join(os.tmpdir(), 'compa-spots'); fs.rmSync(HOME, { recursive: true, force: true });
const probe = new Probe(path.join(HOME, 'sessions'), null);
const send = (ev, extra = {}) => hook.run(ev, JSON.stringify({ session_id: 'A', cwd: '/u/app', ...extra }), { home: HOME, noPid: true });
send('UserPromptSubmit'); send('Stop', {}); probe.poll();
const b = new Brain(new SessionFeed(probe, 'A'), 26); b.speak = () => {}; b.hush = () => {}; b.wanders = false;
b.walkSpeed = 40; b.bounds = [14, 346];
b.spots = { work: 128, wait: 150, rest: 322, window: 174 };
const run = (sec) => { for (let i = 0; i < sec * 60; i++) { if (i % 12 === 0) probe.poll(); b.step(1 / 60, { x: 0, y: 0 }, { x: b.x, y: 100 }, 0); } };
const checks = []; const expect = (l, c) => { checks.push(!!c); console.log(c ? '✓' : '✗', l, `(x=${Math.round(b.x)} ${b.activity} ${b.clip})`); };
let arrived = false; b.x = -20; b.walkTo(60, () => { arrived = true; }); run(0.3);
expect('entra desde fuera andando', b.clip === 'runRight' && b.x > -20 && b.x < 60);
run(2); expect('llega y avisa', arrived && Math.abs(b.x - 60) < 1);
send('UserPromptSubmit'); run(0.3);
expect('Claude trabaja: va hacia su mesa andando', b.activity === 'working' && b.clip === 'runRight');
run(3); expect('en la mesa: trabaja quieta', Math.abs(b.x - 128) < 1 && b.clip === 'working');
send('PermissionRequest', { tool_name: 'Bash', tool_input: { description: 'deploy' } }); run(2.5);
expect('te espera: da un paso al frente', Math.abs(b.x - 150) < 1 && b.clip === 'waiting');
send('PostToolUse', { tool_name: 'Bash' }); run(1.5);
expect('contestado: vuelve a la mesa', Math.abs(b.x - 128) < 1 && b.activity === 'working');
let goneAt = null; b.walkTo(26, () => { goneAt = b.x; }); run(4);
expect('se va por la puerta (aunque Claude siga trabajando)', goneAt !== null && Math.abs(goneAt - 26) < 1);
if (checks.includes(false)) process.exit(1); console.log('todo bien');
