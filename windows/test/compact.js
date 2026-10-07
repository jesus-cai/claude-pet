// /compact manual, compactación automática a mitad de turno y Claude Code sin PostCompact.
'use strict';
const fs = require('fs'), os = require('os'), path = require('path');
const { execFileSync } = require('child_process');
const hook = require('../hook.js');
const { Probe } = require('../lib/probe.js');
const { Brain } = require('../lib/brain.js');
const HOME = path.join(os.tmpdir(), 'compa-compact'), BASH = path.join(os.tmpdir(), 'compa-compact-bash');
for (const h of [HOME, BASH]) fs.rmSync(h, { recursive: true, force: true });
const S = path.join(HOME, 'sessions');
const probe = new Probe(S, null), b = new Brain(probe, 500); b.wanders = false;
const said = []; b.speak = (t) => said.push(t); b.hush = () => said.push('(calla)');
let alerts = []; b.alert = (e) => alerts.push(e.kind);
const bashHook = path.join(__dirname, '..', '..', 'hooks', 'compa-hook.sh');
let parity = true;
const send = (ev, extra = {}) => {
  const p = JSON.stringify({ session_id: 's', cwd: '/u/app', ...extra });
  hook.run(ev, p, { home: HOME, noPid: true });
  if (fs.existsSync(bashHook)) {   // el hook de Mac tiene que hacer exactamente lo mismo
    execFileSync('bash', [bashHook, ev], { input: p, env: { ...process.env, COMPA_HOME: BASH } });
    const r = (h) => { try { return fs.readFileSync(path.join(h, 'sessions', 's'), 'utf8').split('\t').filter((_, i) => i !== 2).join('|'); } catch { return '-'; } };
    if (r(HOME) !== r(BASH)) { parity = false; console.log('   ≠ bash:', r(BASH).trim(), ' js:', r(HOME).trim()); }
  }
};
const run = (sec) => { for (let i = 0; i < sec * 60; i++) b.step(1 / 60, { x: 0, y: 0 }, { x: 500, y: 900 }, 0); };
const state = () => fs.readFileSync(path.join(S, 's'), 'utf8').split('\t')[0];
const checks = [];
const expect = (label, cond) => { checks.push(!!cond); console.log(cond ? '✓' : '✗', label.padEnd(56), '| archivo:', state(), '| mascota:', b.activity, '| avisos:', alerts.join(',') || '-'); };
run(0.3);

send('UserPromptSubmit'); send('Stop', { last_assistant_message: 'listo' }); run(0.4); alerts = []; b.acknowledge(); run(3);
console.log('— /compact manual con la sesión parada —');
send('PreCompact', { trigger: 'manual' }); run(0.5);
expect('compactando: trabaja (tidying up)', b.activity === 'working' && /tidying/.test(said.at(-1)));
send('PostCompact', { trigger: 'manual' }); run(2);
expect('acaba: vuelve a reposo, sin avisar de nada', b.activity !== 'working' && alerts.length === 0 && state() === 'idle');

console.log('— compactación automática a mitad de un turno —');
send('UserPromptSubmit'); send('PreToolUse', { tool_name: 'Read', tool_input: { file_path: '/x/big.ts' } });
send('PreCompact', { trigger: 'auto' }); run(0.3); send('PostCompact', { trigger: 'auto' }); run(0.5);
expect('acaba la compactación: sigue trabajando', b.activity === 'working' && state() === 'thinking' && alerts.length === 0);
send('Stop', { last_assistant_message: 'hecho' }); run(0.4);
expect('el turno acaba: un aviso', alerts.join() === 'finished');

console.log('— PostCompact sin trigger —');
alerts = []; b.acknowledge(); run(3);
send('PreCompact', {}); send('PostCompact', {}); run(2);
expect('sesión parada: vuelve a reposo', state() === 'idle' && b.activity !== 'working' && alerts.length === 0);

console.log('— Claude Code antiguo, sin PostCompact —');
send('PreCompact', { trigger: 'manual' }); run(0.5);
const f = path.join(S, 's'), t = Date.now() / 1000 - 700; fs.utimesSync(f, t, t); run(2);
expect('10 min sin noticias: deja de compactar', b.activity !== 'working' && alerts.length === 0);

expect('los hooks de Mac y Windows escriben lo mismo', parity);
if (checks.includes(false)) { console.log('FALLAN', checks.filter((c) => !c).length); process.exit(1); }
console.log('todo bien');
