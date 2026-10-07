// Fase 1 del modo "una mascota por sesión": un lector, varios canales. Cada mascota
// de sesión ve solo lo suyo; la combinada (la de siempre) sigue igual.
'use strict';
const fs = require('fs'), os = require('os'), path = require('path');
const hook = require('../hook.js');
const { Probe, SessionFeed, DesktopFeed } = require('../lib/probe.js');
const { Brain } = require('../lib/brain.js');
const HOME = path.join(os.tmpdir(), 'compa-feeds'); fs.rmSync(HOME, { recursive: true, force: true });
const probe = new Probe(path.join(HOME, 'sessions'), null);
const send = (sid, proj, ev, extra = {}) => hook.run(ev, JSON.stringify({ session_id: sid, cwd: '/u/' + proj, ...extra }), { home: HOME, noPid: true });
send('A', 'mi-app', 'UserPromptSubmit'); send('B', 'api', 'UserPromptSubmit');
probe.poll();
function pet(feed, name) {
  const b = new Brain(feed, 500); b.wanders = false;
  b.said = []; b.alerts = [];
  b.speak = (t, tone, tag) => b.said.push(`[${tone}] ${tag ? tag + ' · ' : ''}${t}`); b.hush = () => {};
  b.alert = (e) => b.alerts.push(e.kind); b.name = name;
  return b;
}
const all = pet(probe, 'combinada');
const pa = pet(new SessionFeed(probe, 'A'), 'mi-app'), pb = pet(new SessionFeed(probe, 'B'), 'api');
const pets = [all, pa, pb];
// el coordinador lee una vez por "fotograma de lectura" y luego mueve a todas
const run = (sec) => { for (let i = 0; i < sec * 60; i++) { if (i % 12 === 0) probe.poll(); for (const p of pets) p.step(1 / 60, { x: 0, y: 0 }, { x: 500, y: 900 }, 0); } };
const checks = [];
const expect = (label, cond) => { checks.push(!!cond); console.log(cond ? '✓' : '✗', label); };
const line = (p) => `${p.name}: ${p.activity} ${JSON.stringify(p.said.at(-1) || '')}`;
run(0.5);
send('A', 'mi-app', 'PreToolUse', { tool_name: 'Read', tool_input: { file_path: '/x/a.ts' } });
send('B', 'api', 'PreToolUse', { tool_name: 'Bash', tool_input: { description: 'run tests' } }); run(0.5);
console.log('  ', pets.map(line).join('\n   '));
expect('cada una dice lo suyo, sin etiqueta de proyecto', /\[working\] reading a\.ts$/.test(pa.said.at(-1)) && /\[working\] running run tests$/.test(pb.said.at(-1)));
send('A', 'mi-app', 'Stop', { last_assistant_message: 'listo' }); run(0.4);
console.log('  ', pets.map(line).join('\n   '));
expect('acaba mi-app: SU mascota reacciona y avisa', pa.activity === 'celebrating' && pa.alerts.join() === 'finished');
expect('la de api ni se entera y sigue trabajando', pb.activity === 'working' && pb.alerts.length === 0);
expect('la combinada, como siempre: sigue trabajando y lo dice de pasada', all.activity === 'working' && /\[done\] mi-app · /.test(all.said.at(-1)));
send('B', 'api', 'PermissionRequest', { tool_name: 'Bash', tool_input: { description: 'deploy' } }); run(0.4);
expect('api pide permiso: solo su mascota saluda', pb.activity === 'waving' && /\[waiting\] ok to run deploy\?/.test(pb.said.at(-1)) && pa.activity !== 'waving');
pa.acknowledge(); run(0.3);
expect('clic en la de mi-app: solo quita SU aviso', pa.notices.size === 0 && all.notices.has('A'));
send('B', 'api', 'SessionEnd'); run(0.4);
expect('se cierra api: su canal lo sabe (para despedirse)', pa.claude.exists === true && pb.claude.exists === false);
// Claude Desktop con su propio canal: no cede ante Claude Code
const desk = pet(new DesktopFeed(probe), 'desktop'); pets.push(desk);
probe.desktop = { busy: true, running: true, front: true }; run(13);
expect('Claude Desktop trabajando en su mascota', desk.activity === 'working' && desk.claude.guessed);
probe.desktop = { busy: false, running: true, front: true }; run(0.5);
expect('Claude Desktop termina: su mascota avisa', desk.alerts.join() === 'finished' && desk.notice?.project === 'Claude Desktop' && /^\[done\] /.test(desk.said.at(-1)));
if (checks.includes(false)) { console.log('FALLAN', checks.filter((c) => !c).length); process.exit(1); }
console.log('todo bien');
