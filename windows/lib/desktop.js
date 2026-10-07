// Adivina si Claude Desktop está respondiendo, por su uso de CPU: la app de
// escritorio no tiene hooks. Port del algoritmo de ClaudeProbe.swift, con sus mismos
// umbrales medidos (ver las notas técnicas): en segundo plano la app hace picos
// sueltos de 25-70 % cada medio minuto, que nunca se sostienen dos muestras seguidas;
// una respuesta sí. Y con Claude delante, casi todo lo que gasta CPU eres tú
// escribiendo, así que mientras tecleas ahí no puede empezar una racha.
'use strict';

const BUSY_HOLD = 12;       // una pausa de hasta 12 s entre ráfagas sigue siendo la misma respuesta
// Una tarea con herramientas (comandos, búsquedas) se ejecuta en el servidor: mientras
// tanto la app apenas gasta CPU, y con 8 s de margen avisaba de "terminado" al primer
// comando. Cuando la CPU vuelve tras una pausa, es que hay herramientas de por medio, y
// desde ese momento se espera mucho más antes de darla por acabada.
const TOOL_GAP = 8;         // 8 s de calma y luego vuelta al trabajo = una herramienta entre medias (escribir pausa menos)
// Medido en un Mac real con una tarea de 5 min y comandos de hasta 1,5 min: mientras
// corre una herramienta la app gasta 1-5 % (su animación) frente al 0 % parada, pero
// hubo un tramo de 16 s seguidos casi a cero. 30 s es casi el doble de eso.
const TOOL_HOLD = 30;       // margen una vez se sabe que hay herramientas
const WARM = 0.015;         // la animación de "trabajando" mientras corre una herramienta
// ...pero una conversación larga abierta gasta eso mismo en reposo: sin límite, la mascota
// se quedaba "pensando" para siempre. El consumo pequeño solo cuenta durante este rato
// desde la última actividad fuerte (en un Mac real, con comandos de 1,5 min, nunca pasaron
// más de 20 s sin una).
const WARM_LIMIT = 25;
const TYPING_GATE = 2.5;    // tecleando en Claude: la carga es tuya
const ASKED_WINDOW = 20;    // una respuesta llega poco después de enviar algo

class DesktopGuess {
  constructor() { this.reset(); this.busySince = -100; this.hold = BUSY_HOLD; this.lastHot = -100; }

  /** Tras un rato sin medir (una sesión de Claude Code mandaba), la próxima muestra
   *  es solo la base: el primer delta repartido sobre todo el hueco no significa nada. */
  reset() { this.lastTotal = 0; this.lastAt = 0; this.floor = []; this.hotStreak = 0; this.loudStreak = 0; }

  /** total: segundos de CPU acumulados por todos los procesos de Claude Desktop.
   *  inFront: Claude Desktop en primer plano. inputAge: segundos desde tu última
   *  entrada. Devuelve {busy, cpu}. */
  sample(now, total, inFront, inputAge) {
    const busyNow = () => now - this.busySince < this.hold;
    if (!(this.lastAt > 0 && now > this.lastAt && total >= this.lastTotal)) {
      this.lastTotal = total; this.lastAt = now;
      return { busy: busyNow(), cpu: 0 };
    }
    const cpu = (total - this.lastTotal) / (now - this.lastAt);
    this.lastTotal = total; this.lastAt = now;
    const floor = this.floor.length ? Math.min(...this.floor) : 0;
    const busy = busyNow();
    if (!busy) this.hold = BUSY_HOLD;
    const hot = cpu > floor + (busy ? 0.06 : 0.18) && cpu > (busy ? 0.05 : 0.20);
    // ya en una respuesta, una carga mínima pero sostenida es la animación de la app
    // esperando a una herramienta: no es trabajo nuevo, pero tampoco el final
    // lo que gastas tú usando la app (leer, hacer scroll) no alarga la tarea
    const yours = inFront && inputAge < TYPING_GATE;
    const warm = busy && !hot && !yours && cpu > floor + WARM && now - this.lastHot < WARM_LIMIT;
    if (hot && !yours) {
      if (busy && now - this.lastHot >= TOOL_GAP) this.hold = TOOL_HOLD;
      this.lastHot = now;
    }
    this.hotStreak = hot ? this.hotStreak + 1 : 0;
    // el suelo representa a Claude quieto: lo que se mide en mitad de una respuesta no
    // lo alimenta, o una respuesta larga subiría su propio suelo hasta dejar de verse
    if (!hot) { this.floor.push(cpu); if (this.floor.length > 60) this.floor.shift(); }
    this.loudStreak = cpu > 0.5 ? this.loudStreak + 1 : 0;
    const typing = inFront && inputAge < TYPING_GATE;
    const asked = inFront && inputAge < ASKED_WINDOW;
    const starts = this.hotStreak >= 2 && !typing && (asked || this.loudStreak >= 2);
    if (busy ? (hot && !yours) || warm : starts) this.busySince = now;
    return { busy: busyNow(), cpu };
  }
}

/** El vigilante de PowerShell: una vez por segundo, una línea JSON con
 *  {running, cpu, front, input, rect}. Se lanza codificado (-EncodedCommand) para que
 *  la política de ejecución de scripts no lo bloquee. */
const WATCH_PS = String.raw`
$ErrorActionPreference = 'SilentlyContinue'
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class CompaW {
  [StructLayout(LayoutKind.Sequential)] public struct LII { public uint cbSize; public uint dwTime; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LII p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  public static double InputAge() { var i = new LII(); i.cbSize = (uint)Marshal.SizeOf(i); GetLastInputInfo(ref i); return unchecked((uint)Environment.TickCount - i.dwTime) / 1000.0; }
}
"@
$desk = $null
while ($true) {
  $all = @(Get-Process -Name claude)
  # Claude Code también es claude.exe, pero corre dentro de una terminal y no tiene
  # ventana propia: la app de escritorio es la que la tiene. Se recuerda su ruta para
  # cuando está minimizada en la bandeja.
  $w = $all | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if ($w -and $w.Path) { $desk = $w.Path }
  $mine = @($all | Where-Object {
    $p = $_.Path
    if ($desk) { $p -eq $desk -or -not $p } else { $p -and $p -notmatch '\\\.local\\|\\node' -or -not $p }
  })
  $cpu = 0.0; foreach ($x in $mine) { if ($x.CPU) { $cpu += [double]$x.CPU } }
  $fg = [CompaW]::GetForegroundWindow(); $fp = [uint32]0
  [void][CompaW]::GetWindowThreadProcessId($fg, [ref]$fp)
  $front = [bool]($mine | Where-Object { $_.Id -eq $fp })
  $rect = $null
  if ($front) { $r = New-Object CompaW+RECT; if ([CompaW]::GetWindowRect($fg, [ref]$r)) { $rect = @($r.L, $r.T, $r.R, $r.B) } }
  $o = @{ running = ($mine.Count -gt 0); cpu = $cpu; front = $front; input = [CompaW]::InputAge(); rect = $rect }
  [Console]::Out.WriteLine(($o | ConvertTo-Json -Compress))
  [Console]::Out.Flush()
  Start-Sleep -Milliseconds 1000
}
`;

const encoded = () => Buffer.from(WATCH_PS, 'utf16le').toString('base64');

module.exports = { DesktopGuess, WATCH_PS, encoded, BUSY_HOLD, TOOL_HOLD };
