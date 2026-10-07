// Subagentes, ayudantes en segundo plano, errores de la API y Esc: el aviso de
// "terminado" tiene que llegar una vez y solo cuando la sesión acaba de verdad.
'use strict';
const fs = require('fs'), os = require('os'), path = require('path');
const hook = require('../hook.js');
const { Probe } = require('../lib/probe.js');
const { Brain } = require('../lib/brain.js');
const HOME = path.join(os.tmpdir(), 'compa-agents'); fs.rmSync(HOME, { recursive: true, force: true });
const S = path.join(HOME, 'sessions');
const probe = new Probe(S, null), b = new Brain(probe, 500); b.wanders = false;
const said = []; b.speak = (t, tone, tag) => said.push(`[${tone}] ${tag ? tag + ' · ' : ''}${t}`); b.hush = () => {};
let alerts = []; b.alert = (e) => alerts.push(e.kind + (e.detail ? `(${e.detail})` : ''));
const send = (ev, extra = {}) => hook.run(ev, JSON.stringify({ session_id: 's1', cwd: '/u/app', transcript_path: '/nope', ...extra }), { home: HOME, noPid: true });
const run = (sec) => { for (let i = 0; i < sec * 60; i++) b.step(1 / 60, { x: 0, y: 0 }, { x: 500, y: 900 }, 0); };
const age = (sec) => { const f = path.join(S, 's1'), t = Date.now() / 1000 - sec; fs.utimesSync(f, t, t); };
const checks = [];
const expect = (label, cond) => { checks.push(!!cond); console.log(cond ? '✓' : '✗', label.padEnd(52), '|', fs.existsSync(path.join(S, 's1')) ? fs.readFileSync(path.join(S, 's1'), 'utf8').split('\t').slice(0, 2).join(' · ') : '(sin archivo)', '| avisos:', alerts.join(',') || '-'); };
run(0.3);

console.log('— subagente normal (en primer plano) —');
send('UserPromptSubmit'); send('PreToolUse', { tool_name: 'Agent', tool_input: { description: 'explore code' } });
send('SubagentStart', { agent_id: 'a1', agent_type: 'Explore' });
send('PreToolUse', { agent_id: 'a1', agent_type: 'Explore', tool_name: 'Read', tool_input: { file_path: '/x/a.ts' } }); run(0.4);
expect('el ayudante lee y la mascota trabaja', b.activity === 'working' && probe.state === 'reading');
send('SubagentStop', { agent_id: 'a1', agent_type: 'Explore' }); run(0.4);
expect('acaba el ayudante: NO avisa', alerts.length === 0 && b.activity === 'working');
send('PostToolUse', { tool_name: 'Agent' }); send('Stop', { last_assistant_message: 'He revisado el código.\nTodo bien.' }); run(0.4);
expect('acaba la sesión: avisa una vez, con resumen', alerts.join() === 'finished(He revisado el código.)');

console.log('— ayudantes en segundo plano —');
alerts = []; b.acknowledge();
send('UserPromptSubmit'); send('PreToolUse', { tool_name: 'Agent', tool_input: { description: 'tests', run_in_background: true } });
send('SubagentStart', { agent_id: 'b1', agent_type: 'general-purpose' }); send('SubagentStart', { agent_id: 'b2', agent_type: 'general-purpose' });
send('PostToolUse', { tool_name: 'Agent' }); send('Stop', { last_assistant_message: 'Lanzados dos ayudantes.' }); run(0.4);
expect('Claude acaba su turno con 2 fuera: NO avisa', alerts.length === 0 && b.activity === 'working' && probe.state === 'delegating');
send('PreToolUse', { agent_id: 'b1', tool_name: 'Bash', tool_input: { description: 'run tests' } }); run(0.3);
expect('un ayudante trabaja: sigue trabajando', b.activity === 'working' && alerts.length === 0);
send('SubagentStop', { agent_id: 'b1' }); run(0.3);
expect('acaba uno: queda 1 en segundo plano', /1 in background/.test(fs.readFileSync(path.join(S, 's1'), 'utf8')) && alerts.length === 0);
send('SubagentStop', { agent_id: 'b2' }); run(0.3);
expect('acaba el último: espera a que Claude vuelva', alerts.length === 0 && probe.state === 'thinking');
send('UserPromptSubmit'); send('PreToolUse', { tool_name: 'Read', tool_input: { file_path: '/x/r.md' } }); send('Stop', { last_assistant_message: 'Resultados listos.' }); run(0.4);
expect('Claude usa los resultados y acaba: UN aviso', alerts.join() === 'finished(Resultados listos.)');

console.log('— ayudante mientras el hilo principal espera un permiso —');
alerts = []; b.acknowledge();
send('UserPromptSubmit'); send('SubagentStart', { agent_id: 'c1' });
send('PermissionRequest', { tool_name: 'Bash', tool_input: { description: 'deploy' } }); run(0.3);
send('PostToolUse', { agent_id: 'c1', tool_name: 'Grep' }); run(0.3);
expect('el ayudante no tapa el permiso pendiente', probe.state === 'waiting' && /\[waiting\]/.test(said.at(-1)));
send('PostToolUse', { tool_name: 'Bash' }); send('SubagentStop', { agent_id: 'c1' }); send('Stop', {}); run(0.4);

console.log('— el ayudante que acaba y Claude que nunca vuelve —');
alerts = []; b.acknowledge();
send('UserPromptSubmit'); send('SubagentStart', { agent_id: 'd1' }); send('Stop', {}); send('SubagentStop', { agent_id: 'd1' }); run(0.3);
expect('recién acabado: aún espera', alerts.length === 0);
age(40); run(0.4);
expect('30 s sin que Claude vuelva: lo da por terminado', alerts.join() === 'finished');

console.log('— error de la API —');
alerts = []; b.acknowledge();
send('UserPromptSubmit'); send('StopFailure', { error_type: 'rate_limit' }); run(0.4);
expect('StopFailure: aviso rojo con el motivo', alerts.join() === 'failed(usage limit reached)' && /\[error\].*usage limit reached/.test(said.at(-1)));

console.log('— Esc antes de la primera respuesta —');
alerts = []; b.acknowledge();
send('UserPromptSubmit'); run(0.3);
expect('pensando…', b.activity === 'working');
age(200); run(2);
expect('sin hooks ni transcript en 2,5 min: deja de pensar, sin avisar', b.activity !== 'working' && alerts.length === 0);

if (checks.includes(false)) { console.log('FALLAN', checks.filter((c) => !c).length); process.exit(1); }
console.log('todo bien');
