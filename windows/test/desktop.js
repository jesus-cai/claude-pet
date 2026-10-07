// Trazas simuladas de Claude Desktop: el algoritmo debe ver la respuesta y solo ella.
'use strict';
const { DesktopGuess } = require('../lib/desktop.js');
function play(name, trace, expectBusyAny, expectEndIdle) {
  const g = new DesktopGuess(); let total = 0, t = 0, any = false, last;
  for (const [cpu, front, input] of trace) {
    t += 1; total += cpu; last = g.sample(t, total, front, input);
    if (last.busy) any = true;
  }
  const ok = any === expectBusyAny && (expectEndIdle === undefined || !last.busy === expectEndIdle);
  console.log(ok ? '✓' : '✗', name, `(ocupado en algún momento: ${any}, al final: ${last.busy})`);
  return ok;
}
const rep = (n, x) => Array.from({ length: n }, () => x);
const idle = (n, front = false, input = 99) => rep(n, [0.02, front, input]);
const idleFor = (n, front) => idle(n, front, 99);
const results = [
  // 10 min en segundo plano con picos sueltos de 25-70 % cada ~30 s
  play('ruido de fondo: picos sueltos', [].concat(...rep(20, [...idle(29), [0.6, false, 99]])), false),
  // escribes un mensaje largo con Claude delante: la CPU sube, pero eres tú
  play('tecleando en Claude', [...idle(5, true, 0.5), ...rep(15, [0.35, true, 0.3]), ...idle(5, true, 3)], false),
  // envías y responde 40 s con pausas de 4-5 s entre ráfagas; luego silencio
  play('respuesta real con pausas', [...idle(3, true, 1), ...idle(3, true, 3),
    ...[].concat(...rep(5, [...rep(4, [0.4, true, 8]), ...idle(4, true, 8)])), ...idleFor(90, true)], true, true),
  // pides algo largo y cambias de ventana: carga fuerte sostenida
  play('tarea larga en segundo plano', [...idle(3), ...rep(10, [0.8, false, 1]), ...idle(20)], true, true),
  // una respuesta corta y normal: termina pronto (no espera el margen de herramientas)
  play('respuesta normal: avisa pronto', [...idle(3, true, 1), ...rep(8, [0.45, true, 5]), ...idle(14, true, 30)], true, true),
];
// Una tarea como las de este chat, con las cifras medidas en un Mac real: escribe, un
// comando de 60 s (la app gasta un 1-5 % por su animación), escribe más, otro comando con
// 20 s seguidos casi a cero (el peor tramo medido fueron 16 s), y termina. Antes avisaba de
// "terminado" a los 8 s del primer comando.
{
  const g = new (require('../lib/desktop.js').DesktopGuess)();
  let total = 0, t = 0, endedEarly = false, phase = '';
  const step = (cpu, front, input) => { t++; total += cpu; return g.sample(t, total, front, input).busy; };
  const seg = (name, n, cpu, blip = 0) => {
    phase = name;
    for (let i = 0; i < n; i++) {
      // en los registros reales siempre había un pico (la app actualizando) cada ≤20 s
      const c = blip && i % blip === blip - 1 ? 0.12 : cpu;
      if (!step(c, false, 99) && !endedEarly) endedEarly = phase;
    }
  };
  for (let i = 0; i < 3; i++) step(0.005, true, 1);
  for (let i = 0; i < 6; i++) step(0.6, true, 6);         // empieza a escribir (con la app delante)
  seg('comando 1 (60 s)', 60, 0.04, 15);                    // herramienta: animación 1-5 % y algún pico
  seg('escribe', 8, 0.5);
  seg('comando 2 (silencio de 20 s)', 20, 0.01);            // el tramo más quieto medido fue de 16 s
  seg('escribe y acaba', 6, 0.5);
  let endAt = null;
  for (let i = 0; i < 120; i++) if (!step(0.01, false, 99) && endAt === null) endAt = i;
  const ok = !endedEarly && endAt !== null;
  console.log(ok ? '✓' : '✗', 'tarea con comandos largos: no avisa antes de tiempo',
              endedEarly ? `(avisó durante: ${endedEarly})` : `(avisa ${endAt} s después de acabar)`);
  results.push(ok);
}
// El caso que este método no puede salvar: el PRIMER comando, largo y sin ninguna
// animación (la app del todo quieta). Hasta ese momento nada indica que haya
// herramientas, y avisa a los 12 s. Se deja escrito para que se vea el límite.
{
  const g = new (require('../lib/desktop.js').DesktopGuess)();
  let total = 0, t = 0, endedAt = null;
  const step = (cpu, front, input) => { t++; total += cpu; return g.sample(t, total, front, input).busy; };
  for (let i = 0; i < 3; i++) step(0.02, true, 1);
  for (let i = 0; i < 6; i++) step(0.6, true, 6);
  for (let i = 0; i < 30; i++) if (!step(0.01, false, 99) && endedAt === null) endedAt = i;
  console.log('· límite conocido: primer comando sin animación →', endedAt === null ? 'aguanta' : `avisa a los ${endedAt} s`);
}
// Lo que la dejaba "pensando" para siempre: después de acabar, la app con una conversación
// larga sigue gastando un 2-4 % en reposo, y tú lees y haces scroll con ella delante.
{
  const g = new (require('../lib/desktop.js').DesktopGuess)();
  let total = 0, t = 0;
  const step = (cpu, front, input) => { t++; total += cpu; return g.sample(t, total, front, input).busy; };
  for (let i = 0; i < 3; i++) step(0.005, true, 1);
  for (let i = 0; i < 6; i++) step(0.6, true, 6);           // responde
  for (let i = 0; i < 15; i++) step(0.04, false, 99);       // un comando (animación)
  for (let i = 0; i < 6; i++) step(0.55, false, 99);        // responde más y acaba
  let endAt = null;
  for (let i = 0; i < 180; i++) {
    // reposo: un 2-4 % de fondo, y a ratos tú leyendo con scroll (picos del 15-30 %)
    const reading = i % 20 < 6;
    const busy = step(reading ? 0.15 + (i % 3) * 0.07 : 0.02 + (i % 3) * 0.01, reading, reading ? 0.5 : 30);
    if (!busy && endAt === null) endAt = i;
  }
  const ok = endAt !== null && endAt >= 10 && endAt <= 60;
  console.log(ok ? '✓' : '✗', 'tras acabar, el reposo de la app y tu lectura no la dejan pensando',
              endAt === null ? '(no acabó en 3 min)' : `(acaba ${endAt} s después)`);
  results.push(ok);
}
if (results.includes(false)) process.exit(1);
console.log('todo bien');
