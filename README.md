# Compa — mascota de escritorio para Claude

Una mascota que vive en tu escritorio de macOS y te cuenta qué está haciendo Claude:
qué archivo lee, qué comando ejecuta, cuándo **necesita tu permiso** y cuándo **ha
terminado**. Es la idea de las *pets* de Codex, pero para Claude Code y Claude Desktop,
y **usa el mismo formato de sprites**, así que sirve cualquier mascota hecha para Codex.

Es la evolución de "Chihiro": el mismo motor, generalizado para cualquier sprite, y con
los avisos rehechos para que no se pierdan.

> **¿Windows?** Hay una versión aparte en `windows/` (ver `windows/README.md`), con
> las mismas mascotas y avisos.

## Instalar

```bash
./install.sh
```

Necesita las Command Line Tools de Xcode (`xcode-select --install`) y `jq`
(`brew install jq`). El script compila la app, la copia a `~/Applications`, instala el
hook y lo registra en `~/.claude/settings.json` sin tocar tus otros hooks (deja un
`.bak`). Si tenías la versión anterior, la retira y migra sus hooks. Reinicia las
sesiones de Claude Code que ya estuvieran abiertas.

Para quitarla: `./uninstall.sh` (o `./uninstall.sh --all` para borrar también
`~/.compa` con tus mascotas).

## Avisos

| Situación | Globito | Mascota | Barra de menú | Sonido |
|---|---|---|---|---|
| Claude trabajando | *reading Brain.swift*, *running the tests*… | animación de trabajo / revisión | — | — |
| **Te necesita** (permiso, pregunta, plan) | naranja: *mi-app · ok to run the tests?* | saluda y se queda en pose de espera | punto naranja | Ping |
| **Terminó** | verde: *mi-app · done!* | da saltos | punto verde | Glass |
| **Error** (API sobrecargada, límite…) | rojo: *mi-app · something went wrong* | se desinfla | punto rojo | Basso |
| Cortado con Esc | se quita | — | — | — |

Lo importante es que **los avisos se quedan hasta que los ves**:

- **"Terminó" y "error"** siguen en pantalla hasta que haces clic en la mascota, esa
  sesión vuelve a trabajar, o llevas ~45 s **delante del ordenador** con el aviso
  puesto. El tiempo que estás fuera no cuenta: vuelves de comer y sigue ahí.
- **Un permiso** se mantiene mientras siga pendiente, aunque pase una hora. Saluda
  cada 5 s los primeros 20 s; después solo cada 40 s y solo si estás usando el
  ordenador. Hacer clic la calla 90 s (el globito sigue).
- **Al volver al ordenador** con algo pendiente, te saluda.
- La etiqueta gris delante del texto es el **proyecto**: con varias sesiones de
  Claude Code abiertas sabes cuál te habla.

### Varias sesiones a la vez

Cada sesión de Claude Code (terminal o VS Code) tiene su propio archivo, así que no se
pisan. La mascota solo puede hacer una cosa a la vez, y elige así: un permiso
pendiente, luego el trabajo (de la sesión que se movió más recientemente), y solo
cuando no queda ninguna trabajando, la reacción de "terminado".

- **Sigue trabajando mientras quede alguna sesión trabajando.** Si está en reposo, es
  que no queda nada en marcha.
- **Las que van acabando avisan sin interrumpirla**: el globito dice unos segundos
  *"api · finally."* (rojo si falló), suena, y vuelve a la frase de trabajo. Cuando
  acaba la última, reacciona y el globito junta todas las que terminaron.

- **Con más de una sesión activa, todo lleva el proyecto delante**, también el
  trabajo: *"api · reading routes.ts"*. Con una sola, solo los avisos.
- **Los avisos se acumulan, uno por sesión.** Si terminan dos mientras no miras, el
  globito dice *"mi-app, api · finally."* (con más de tres: *"mi-app, api +2"*). Si
  alguna falló, sale en rojo. Un clic en la mascota los da todos por vistos; cada uno
  también se va solo cuando esa sesión vuelve a trabajar.
- **Permisos en cola**: *"mi-app +1 · ok to run the tests?"* significa que hay otra
  sesión esperándote detrás. Al contestar esta, aparece la siguiente.
- **El menú lista las sesiones abiertas**, cada una con su proyecto y lo que está
  haciendo (🟠 te espera, 🟢 terminó sin ver, 🔴 error sin ver, ⏳ trabajando). Cada
  una tiene su submenú: **Marcar como visto** (si tiene aviso) y **Quitar esta sesión**,
  que la saca de la lista y se lleva su mascota, sin avisos ni sonidos, hasta que esa
  sesión vuelva a trabajar: cuando le escribas otra vez (o, si la quitaste a mitad de
  un turno, cuando empiece el siguiente). Claude Desktop vuelve cuando responda de
  nuevo. Lo quitado sigue quitado al reiniciar, y **Volver a mostrar las sesiones
  quitadas** las trae todas de golpe.

Menú > **Avisos** activa el sonido (por defecto sí) y las notificaciones del sistema
(por defecto no; la primera vez macOS te pide permiso).

### Qué se arregló respecto a la versión anterior

- Un permiso pendiente **desaparecía a los 15 minutos** (la app ignoraba archivos de
  sesión "viejos" aunque la sesión siguiera viva) y el hook borraba en cada `Stop`
  los de otras sesiones con 30 min sin tocar. Ahora solo se descarta una sesión cuyo
  proceso ha muerto.
- Si un turno terminaba con la pantalla en reposo, el aviso **se perdía**: el reloj
  de animación se pausa y el `done` solo se miraba 6 s. Ahora los finales se detectan
  como **eventos** (por la fecha del archivo de sesión), se noten cuando se noten.
- El "done!" duraba 3,4 s. Ahora se queda hasta que lo ves (ver arriba).
- Un turno que acababa por **error de la API** se celebraba como un éxito. Ahora el
  hook lo detecta (`isApiErrorMessage` en el transcript) y avisa en rojo.
- Faltaba saber **qué sesión** avisaba, no había **indicador en la barra de menú** ni
  **sonido**.

## Una mascota por sesión (opcional)

Menú → **Una mascota por sesión**. Apagado (por defecto), todo sigue como siempre: una
sola mascota que resume todas las sesiones. Encendido, cada sesión de Claude Code
tiene la suya, con su propio globito y sus propios avisos. Llega cuando abres la
sesión y se despide y se va cuando la cierras. Los subagentes siguen dentro de la
mascota de su sesión, y el máximo es 6. **Claude Desktop** también tiene la suya
mientras está abierto: trabaja cuando responde y avisa al terminar, aunque a la vez
haya sesiones de Claude Code (en el modo clásico, Claude Code manda y Desktop no se
mide mientras habla).

En **Varias mascotas**:

- **Distinguir por**: *mascota distinta* (cada sesión, una de tu colección), *color
  distinto* (todas la mascota principal, cada una de un color) o *mezcla*. Las de color
  giran el tono (una Mochi azul sigue siendo Mochi); las grises, como Bober, se tiñen
  conservando las sombras. En "mascota distinta", si una se repite, se tiñe.
- Cada mascota lleva **debajo una etiqueta** con el proyecto, en su color, y una sombra
  del mismo color. Dos sesiones del mismo proyecto: *mi-app · 2*.
- **Mascotas en rotación**: cuáles entran en el reparto.
- **Fijar a mano**: en la lista de sesiones del menú, cada una tiene un submenú para
  fijar mascota y color a su proyecto. Se recuerda; sin fijar, cada proyecto recibe
  siempre lo mismo (y en Mac y Windows igual).
- **Disposición**:
  - **Escenario**: todas dentro de una oficina pequeña que mueves arrastrándola. Cada
    una tiene su mesa y trabaja detrás de ella; cuando te necesita se levanta y da un
    paso al frente; duerme en el sofá; pasea y se asoma a la ventana; entra y sale por
    la puerta. La oficina tiene siempre el mismo tamaño; el menú **Tamaño** cambia el de
    las mascotas dentro de ella (Mediana es la que encaja con las mesas).
  - **Paseos cortos**: cada una en su sitio en una fila, paseando un poco. Arrastra una
    y su sitio se va con ella.
  - **Libres**: cada una por toda la pantalla.
- **Ocultar el escenario si no hay sesiones**: la oficina desaparece cuando no queda
  ninguna sesión abierta y vuelve con la primera.

### Escenarios

Incluidos: **Oficina**, **Cabaña del bosque** y **Playa**. Los tuyos van en `~/.compa/scenes/<id>/`:

```
scene.json   {"id", "name", "size": [ancho, alto], "floor": y de los pies,
              "petHeight": alto de las mascotas, "pixelated": true,
              "walk": [x0, x1], "door": x, "desks": [x, …], "rest": x, "window": x}
back.png     lo que queda detrás de las mascotas
front.png    lo que queda delante (las mesas); transparente el resto
```

**Cambiar solo el fondo, a partir de una imagen** (una foto tuya, un dibujo, un fondo de
pantalla con licencia libre):

```bash
python3 tools/scene_from_image.py foto.jpg --id mi-fondo --name "Mi fondo" --pixel 3
```

Recorta la imagen al formato del escenario, la convierte en pixel art (`--pixel N`; sin
esa opción se queda como foto), le pone una franja de suelo bajo los pies y reutiliza
las mesas y los puestos de un escenario incluido (`--desks oficina|cabana|ninguna`).
Lo deja en `~/.compa/scenes/mi-fondo/`: menú → Varias mascotas → Escenario. Así está
hecha la **Playa** incluida.

Las coordenadas están en píxeles del escenario, con la y hacia abajo. El truco de las
mesas es `front.png`: tapa la mitad de abajo de la mascota, así que parece sentada
trabajando aunque el atlas no tenga una animación de sentarse. `tools/make_scenes.py`
genera los incluidos y sirve de ejemplo.

## Mascotas

Menú > **Mascota** muestra todas las que encuentra, en este orden (si dos tienen el
mismo `id`, gana la primera):

1. `~/.compa/pets/<id>/` — las tuyas
2. `~/.codex/pets/<id>/` — las que ya tengas instaladas para Codex
3. las incluidas en la app: **Mochi** (por defecto), **Bober** (castor gruñón en pixel art
   monocromo que te juzga; habla) y **Chihiro** (rig por capas)

### Formato estándar (el de Codex)

```
~/.compa/pets/mi-mascota/
├── pet.json
└── spritesheet.webp      (o .png)
```

```json
{
  "id": "mi-mascota",
  "displayName": "Mi mascota",
  "description": "Una frase.",
  "spriteVersionNumber": 2,
  "spritesheetPath": "spritesheet.webp",
  "pixelated": true
}
```

El atlas tiene 8 columnas de celdas de **192×208**, fondo transparente:

| Fila | Estado | Cuadros | Cuándo lo usa Compa |
|---|---|---|---|
| 0 | idle | 6 | reposo (y dormida, a cámara lenta) |
| 1 | running-right | 8 | caminando a la derecha |
| 2 | running-left | 8 | caminando a la izquierda |
| 3 | waving | 4 | saludo, clic, aviso de permiso |
| 4 | jumping | 5 | Claude terminó; también mientras la arrastras |
| 5 | failed | 8 | turno terminado en error |
| 6 | waiting | 6 | esperando tu permiso o respuesta |
| 7 | running | 6 | Claude pensando, escribiendo, ejecutando |
| 8 | review | 6 | Claude leyendo o buscando |
| 9–10 | *(solo v2)* 16 direcciones | 8 + 8 | mira hacia el cursor; 0 = arriba, sentido horario |

- **v1**: 1536×1872 (9 filas). **v2**: 1536×2288 (11 filas) y `"spriteVersionNumber": 2`.
  Compa detecta las filas aunque falte el número de versión; Codex no.
- Si a una fila le faltan cuadros, se saltan; si falta una fila entera, usa la más
  parecida (review → running, waiting → waving…).
- `"pixelated"` es opcional: si no está, se deduce del borde del sprite. En pixel art
  se escala sin suavizar y se mueve de píxel en píxel.

### Hablar (opcional)

El formato de Codex no tiene animación de hablar, así que va en un archivo aparte: una
tira horizontal de celdas del mismo tamaño que las del atlas (192×208), con los
cuadros que quieras (3 o 4 bastan: boca cerrada, entreabierta, abierta…).

```json
  "talkSheet": "talk.webp",
  "talkFrameMs": 110
```

Cada vez que aparece una frase nueva en el globito, la mascota la "dice": reproduce la
tira durante el tiempo aproximado de lectura (entre 0,8 y 2,6 s) y vuelve a lo que
estaba haciendo. Solo cuando está en reposo; si está saltando o
saludando, manda esa animación. Codex ignora estos campos, así que la mascota sigue
funcionando allí.

### Personalidad (opcional)

Por defecto todas reaccionan igual: saltan al terminar, saludan contentas al clic. Con
`reactions` eliges qué fila del atlas se usa en cada momento, y con `lines` qué dice:

```json
  "reactions": { "done": "waving", "drag": "jumping", "wave": "waving", "error": "failed" },
  "lines": {
    "start": ["fine…", "if I must…"],
    "done":  ["finally.", "there. happy?"],
    "error": ["called it."]
  }
```

Momentos: `done` (Claude terminó), `drag` (la arrastras), `wave` (clic o te necesita),
`error`, `work`. Filas: `idle`, `waving`, `jumping`, `failed`, `waiting`, `running`,
`review`, `talking`. Así, Bober no salta de alegría cuando Claude termina, sino que
asiente con desgana (`done → waving`). La fila `jumping` queda para cuando lo levantas,
y la ha dibujado como un sobresalto.

### Entradas (opcional)

Una tira que se reproduce **una sola vez** al empezar una fila, antes de su bucle: sacar
algo, sentarse, ponerse unas gafas… Mismo formato que la de hablar:

```json
  "introSheets": { "running": "laptop-out.webp" },
  "introFrameMs": 160
```

Bober la usa para sacar el portátil cuando Claude se pone a trabajar; luego teclea en
bucle con la pantalla iluminándole la cara. (Mientras trabaja no mueve la boca con cada
línea del globito: si no, cortaría el tecleo en cada herramienta.)

**Comprobar una mascota** antes de usarla:

```bash
python3 tools/validate_pet.py ~/.compa/pets/mi-mascota --sheet /tmp/hoja.png
```

**De dónde sacar más**: [petdex](https://petdex.crafter.run) tiene cientos
(`npx petdex install <nombre>` las deja en `~/.codex/pets`, que Compa ya lee). La skill
`hatch-pet` de Codex genera una desde una imagen. O dibújala tú: `tools/make_demo_pet.py`
es el generador de Mochi y `tools/make_beaver_pet.py` el de Bober (con tira de hablar);
sirven de plantilla de qué va en cada fila.

**Tamaño igualado**: el tamaño de una mascota es la altura de su reposo (sin chispas ni
motas sueltas). Algunas de petdex dibujan cada animación a una escala distinta (el
Pikachu corre a dos tercios de su tamaño y con los pies en el aire): una fila
claramente más pequeña que el reposo, por masa de píxeles, se agranda hasta él (como
mucho ×1,6) y se apoya en el mismo suelo. Caer y saltar no se tocan, porque encogerse
ahí suele ser a propósito. Mochi y Bober no cambian.

Después de añadir una carpeta: menú > Mascota > **Volver a buscar mascotas**.

### Rig por capas (formato de Chihiro)

El formato antiguo sigue funcionando: piezas recortadas con pivotes que la app anima en
vivo. Se declara con `"kind": "rig"` y las carpetas de capas:

```json
{ "id": "chihiro", "displayName": "Chihiro", "kind": "rig",
  "layers": "layers", "pixelLayers": "layers-px" }
```

Si tiene las dos variantes, el menú muestra **Modo píxel**. Los detalles del rig y de
cómo se generaron sus capas están en `docs/NOTAS-TECNICAS-chihiro.md`.

## Cómo se entera de lo que hace Claude

Funciona igual con Claude Code en la terminal y con la **extensión de VS Code**: las dos
leen los hooks de `~/.claude/settings.json`. Una salvedad conocida: en la extensión el
hook `Notification` no se dispara. Compa no depende de él para los permisos, pero si
alguna vez no reacciona a uno, `~/.compa/events.log` dice qué llegó.

**Claude Code** — por hooks. `hooks/compa-hook.sh` (instalado en `~/.compa/hook.sh`)
escribe una línea por sesión:

```
~/.compa/sessions/<session_id>  →  estado \t detalle \t pid \t evento \t proyecto
```

| estado | de qué hook sale |
|---|---|
| `thinking` | `UserPromptSubmit`, `PostToolUse`, `PreCompact` |
| `reading` / `writing` / `running` / `searching` / `delegating` | `PreToolUse` según la herramienta |
| `waiting` | `PermissionRequest`, `PreToolUse` de AskUserQuestion/ExitPlanMode, `Notification` de permiso |
| `done` / `stopped` / `error` | `Stop` (mirando el final del transcript), `StopFailure`, `PostToolUseFailure` con interrupción |
| (ayudantes) | `SubagentStart`, `SubagentStop`, y cualquier evento con `agent_id` |

**Subagentes y ayudantes en segundo plano.** Lo que pasa dentro de un subagente llega
con `agent_id`. Compa lo pliega en su sesión: el ayudante puede mostrar lo que hace
(*reading…*), pero nunca cuenta como que la sesión ha terminado, y nunca tapa un
permiso que el hilo principal tenga pendiente. Si Claude acaba su turno con ayudantes
todavía en marcha, la sesión sigue trabajando (*helper: 2 in background*) y el aviso de
"terminado" llega una sola vez, cuando Claude vuelve con sus resultados y acaba de
verdad. Lleva la cuenta con `SubagentStart`/`SubagentStop` en
`~/.compa/sessions/.<sesión>.agents`.

**Lo que publica el propio Claude Code.** Cada sesión de Claude Code (terminal, VS
Code, la pestaña Code de Claude Desktop, el SDK) mantiene `~/.claude/sessions/<pid>.json`
con su estado al momento: `busy` mientras responde **o tiene ayudantes en marcha**,
`waiting` (con `waitingFor`) cuando te espera, `idle` cuando ha acabado del todo
(`shell`: acabado, con comandos en segundo plano). Es lo que usa la vista de sesiones de
Claude Code, y no depende de la CPU ni de los hooks. Compa lo usa para el **nivel**, y
los hooks para el **detalle** (qué lee, qué ejecuta, cómo acabó):

- Con ayudantes, el aviso de "terminado" llega **una vez, cuando acaba todo**: aunque el
  hilo principal haga `Stop` varias veces mientras los ayudantes siguen, Claude Code
  sigue en `busy` y no se avisa.
- Un Esc antes de responder se nota al momento (antes, a los 2,5 min).
- Un permiso contestado vuelve a trabajo al instante, sin el truco de los procesos.
- Sesiones sin hooks (o sin instalar) también se ven: trabajando, esperándote y
  terminadas, sin el detalle.
- Mientras Claude Code trabaja **dentro** de Claude Desktop (pestaña Code), no se
  adivina la app por CPU.

No está documentado por Anthropic: si el archivo no está (Claude Code antiguo), todo
sigue como antes, con solo hooks y las reglas de abajo.

**Lo que ningún hook cierra**, y la app resuelve sola cuando no tiene el archivo de
Claude Code:

| Situación | Qué hace |
|---|---|
| Acabó el último ayudante y Claude no vuelve en 30 s | lo da por terminado (con aviso) |
| Esc antes de la primera respuesta (no se dispara nada) | tras 2,5 min sin hooks ni cambios en el transcript, deja de pensar, sin aviso |
| Ayudantes en segundo plano que nunca avisan de que acabaron | a la media hora deja de esperarlos |
| `/compact` manual (no es un turno: no llega `Stop`) | `PostCompact` la devuelve a reposo sin aviso; si fue automática a mitad de turno, sigue trabajando. Sin `PostCompact` (Claude Code antiguo), a los 10 min |

**Errores de la API**: `StopFailure` trae el motivo, y el globito rojo lo dice
(*usage limit reached*, *API overloaded*, *login expired*…). **Notificaciones**: la del
sistema lleva el principio de la última respuesta de Claude (`last_assistant_message`).

Cada evento deja una línea en `~/.compa/events.log`: es lo primero que mirar cuando
"se equivocó con el aviso". Con el `pid` de la sesión, la app descarta al momento una
terminal cerrada de golpe, y nota cuándo aprobaste un permiso (aparece un proceso hijo)
sin esperar a que termine el comando.

**Claude Desktop (el chat) / Cowork** — no tienen hooks ni ese archivo, así que se adivina por el uso de CPU de
la app, con filtros para no confundir tu propio tecleo ni el ruido de fondo. Las
tareas con herramientas (la app quieta mientras corre un comando en el servidor) se
reconocen cuando la CPU vuelve tras una pausa, y entonces espera hasta 30 s de calma
antes de avisar de que ha terminado. Avisa de
"terminó", pero no de permisos ni del detalle. Las cifras y mediciones están en las
notas técnicas.

Cualquier otra herramienta puede manejarla escribiendo en ese directorio
(`printf 'waiting\tquestion\t\t\tmi-script\n' > ~/.compa/sessions/prueba`).

## Depurar

```bash
COMPA_DEBUG=1 ~/Applications/Compa.app/Contents/MacOS/Compa   # estado por stderr cada 0,5 s
COMPA_DEMO=1 …            # ciclo de 24 s por todos los estados
COMPA_FAKEBUSY=1 …        # finge que Claude Desktop responde 9 s de cada 22
COMPA_SESSIONS=/tmp/s …   # mira otro directorio de sesiones (para pruebas)
COMPA_QA=/ruta …          # vuelca un PNG cada 0,55 s (COMPA_QA_EVERY, COMPA_QA_FRAMES)
COMPA_CLOCK=timer …       # reloj por Timer: sigue corriendo con la pantalla dormida
```

Probar los avisos sin Claude, a mano (en otro directorio para que tus sesiones reales
no interfieran):

```bash
S=/tmp/s; mkdir -p $S     # y lanza la app con COMPA_SESSIONS=$S
printf 'reading\tBrain.swift\t\t\tmi-app\n'          > $S/qa
printf 'waiting\trun the tests\t\t\tmi-app\n'        > $S/qa   # naranja, saluda, suena
printf 'done\t\t\t\tmi-app\n'                        > $S/qa   # verde, salta, se queda
printf 'error\tapi\t\t\tmi-app\n'                    > $S/qa   # rojo
rm $S/qa
```

## Estructura

```
Sources/
  AppDelegate.swift   ventana, reloj, menú, punto de la barra de menú
  Brain.swift         qué hace la mascota y qué dice el globito
  ClaudeProbe.swift   lee las sesiones de Claude Code y la CPU de Claude Desktop
  PetLibrary.swift    busca mascotas y elige el visor
  SpriteSheet.swift   formato estándar: lector del atlas + SpriteView
  Rig.swift, PetView.swift, Pose.swift   formato de capas (Chihiro)
  Bubble.swift        el globito
  Notifier.swift      sonido y notificaciones del sistema
hooks/compa-hook.sh   el hook de Claude Code
pets/                 mascotas incluidas
tools/                validador de atlas y generador de Mochi
```
