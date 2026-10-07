> **Nota:** estas son las notas técnicas originales de la versión "Chihiro". Siguen siendo válidas para el rig por capas, la detección de Claude Desktop por CPU y el pixel art, pero los nombres cambiaron: `~/.chihiro` → `~/.compa`, `CHIHIRO_*` → `COMPA_*`, `chihiro-hook.sh` → `compa-hook.sh`, y las capas viven ahora en `pets/chihiro/`. El README principal describe el comportamiento actual de los avisos.

# Chihiro — pet de escritorio para Claude Desktop

Un muñequito 3D de Chihiro que vive en tu escritorio de macOS, camina, te sigue con
la mirada y reacciona a lo que hace la app de Claude.

Es la idea de la skill `hatch-pet` de Codex, pero para Claude. Se ve como pixel art
igual que aquella, sólo que **no es un atlas de poses**: la figurita está riggeada por
capas y la app la anima en vivo con Core Animation, así que las poses no son 16 sino
las que salgan — incluida la mirada, que sigue al cursor. El arte pixel se genera desde
la foto (`work/build_pixels.py`), no se dibuja a mano ni se pide a un modelo.

Viene en dos versiones del mismo rig, intercambiables desde el menú (**Modo píxel**):
la foto recortada y el pixel art de 30x45 celdas. Mismo espacio canónico, mismos
pivotes, mismas animaciones.

## Correr

```bash
./build.sh          # compila build/Chihiro.app
open build/Chihiro.app
```

No aparece en el Dock: vive en la barra de menú (el ícono es su cara).

**En otra Mac**, `./install.sh` hace todo: compila (o usa la app armada si no hay
Xcode CLT), la copia a `~/Applications`, instala el hook y lo registra en
`~/.claude/settings.json` sin pisar los hooks que ya estén (deja un `.bak`).

## Qué hace

| | |
|---|---|
| **Idle** | respira un píxel, parpadea cada 2-4,5 s (a veces dos veces seguidas) |
| **Mirada** | sigue el cursor con cabeza, iris y un leve squash de perfil |
| **Camina** | se va sola a un punto al azar del borde inferior y se da vuelta al volver |
| **Saluda** | click sobre ella |
| **Arrastrar** | click y arrastrar; al soltar aterriza con squash **y se queda donde la dejaste**, a la altura que sea y en el monitor que sea. Camina a esa altura. |
| **Trabajando** | mientras Claude escribe: rebote lento de un píxel y un globito (`thinking…`) que **se sostiene toda la respuesta** |
| **Festeja** | cuando la respuesta llega: dos saltos con los brazos arriba y un `done!` |
| **Atenta** | si Claude está al frente y no tocás el mouse por 3 s, mira su ventana |
| **Duerme** | tras 4 min sin actividad; se despierta sola |

El globito es una ventana aparte, click-through: la ventana de la pet está recortada
a su cuerpo y el hit-testing de `MouseCatcher` asume que todo punto adentro es ella,
así que agrandarla para que entre un globo rompía las dos cosas. Si ella está tan
arriba que el globo no entra en la pantalla, cuelga debajo de sus pies con la cola
para arriba.

Cómo se ve: cuerpo y cola son **un solo contorno** (borde fino, sombra suave), con
tipografía redondeada del sistema. El verbo va atenuado y el detalle destacado
(*reading* **Brain.swift**), así lo que importa se lee de un vistazo. Los "…" de una
línea que espera algo (*thinking…*) son tres puntos vivos; los "…" con que el hook
recorta un detalle largo se quedan como texto. Máximo dos líneas. Y el tono lo pone el
estado (`BubbleTone`): trabajando es neutro, **esperándote es naranja** y **listo es
verde**, en el borde y en el fondo, para que un permiso pendiente se vea desde lejos.
Al aparecer hace un pequeño rebote desde la punta de la cola; cambiar de línea con el
globo ya arriba sólo cambia el texto.

**Dónde está parada.** La x vive en el `Brain` (caminar la mueve); la y (`feetY`) la
tiene el `AppDelegate`, porque sólo cambia al soltarla. Las dos se guardan en
`UserDefaults` (`petX`, `petY`). Antes estaba clavada al piso y "su pantalla" se
buscaba sólo por la x: con un monitor arriba de otro los dos comparten el rango de x,
así que siempre contestaba el primero, no había forma de llevarla al otro, y el globito
se recortaba contra una pantalla en la que ella no estaba. Ahora la pantalla es la que
contiene el punto de sus pies (mientras la arrastrás, el punto de la ventana, no el que
el Brain recuerda), y si no la contiene ninguna — la soltaste en el hueco entre dos, o
desenchufaste ese monitor — la más cercana, y en el tick siguiente se la recorta adentro.

Menú (barra de menú o click derecho sobre ella): saludar, traerla al centro (de la
pantalla donde está, y al piso: es el botón de rescate), modo píxel, activar/desactivar caminata, mirada, reacción a Claude y globito, tamaño,
abrir al iniciar sesión. La primera línea del menú dice qué está viendo de Claude
(`cerrado` / `abierto` / `al frente` / `pensando…`).

## Que no se entrecorte

Tres cosas la hacían tironear, y las tres estaban fuera de la animación:

- **El reloj.** Era un `Timer` a 60 Hz, que no está alineado con el refresco de la
  pantalla: cada frame cae en una fase distinta y se ve como un temblor aunque no se
  pierda ni un cuadro. Ahora la maneja un `CADisplayLink` (`AppDelegate.startClock`),
  que además se apaga solo cuando la pantalla duerme.
- **El sondeo de Claude.** `CGWindowListCopyWindowInfo` tarda **25 ms** en esta
  máquina — más que un frame entero — y corría en el hilo principal cada 1,5 s. Es
  decir: uno o dos frames perdidos, cada segundo y medio, para siempre. Ahora la parte
  cara corre en una cola aparte y publica un snapshot bajo lock; en el hilo principal
  queda sólo `NSWorkspace` (1,4 ms).
- **La ventana.** `setFrameOrigin` es un viaje de ida y vuelta al window server, y se
  llamaba en cada frame incluso cuando ella estaba parada. Ahora sólo se llama si la
  posición cambió, y redondeada a la grilla de píxeles del backing.

**Si tocás `rebuildView`, volvé a llamar a `startClock`.** El display link está atado a
la *vista de contenido*, y reconstruirla lo deja huérfano: la animación se para en seco
y sólo vuelve reiniciando la app. Pasaba con "Tamaño" y con "Modo píxel" — dos cosas
que se tocan desde el menú, así que la pet se congelaba justo después de configurarla.

**La pantalla dormida la congela, y está bien**: el display link se pausa solo cuando
nadie mira. Ojo al medir desde un script — parece que la app se colgó y en realidad
está durmiendo. Para esos casos, `CHIHIRO_CLOCK=timer` la hace correr igual.

Medirlo: `CHIHIRO_DEBUG=1` imprime `fps=` y `worstFrame=` cada 0,5 s. Sano es 60 fps
con el peor frame en 16,7 ms; si aparecen picos de 30 ms hay algo bloqueando el hilo
principal.

Lo que queda por hacer si alguna vez se ve escalonada **caminando**: mientras camina
la ventana se mueve una vez por frame y eso no está sincronizado con el vsync. La
solución de fondo es una ventana del ancho de la pantalla y moverla a ella por dentro
con `rootDX`, que es puro Core Animation.

## Qué Claude mira (y cuál no)

| | |
|---|---|
| **Claude Desktop** (chats en la app) | por CPU, automático |
| **Claude Cowork** | idem, corre adentro de Claude Desktop |
| **Claude Code** en cualquier terminal | por señal explícita (abajo) |
| El AI propio de Cursor, claude.ai en el navegador | no |

Para Claude Code el heurístico de CPU **no serviría aunque mirara el proceso**: cuando
el modelo genera, la CPU se gasta en el servidor, no en tu máquina. Local no pasa casi
nada. Por eso ahí no se adivina, se avisa:

```
~/.chihiro/sessions/<session_id>      →  "<estado>\t<detalle>\t<pid>\t<evento>"
```

Una línea por sesión de Claude Code, con **qué** está haciendo y **sobre qué**:

| estado | globito | de dónde sale |
|---|---|---|
| `thinking` | *thinking… / on it… / here we go…* al arrancar el turno; después de la primera herramienta, *thinking…* a secas, y sólo si la pausa dura más de 2 s (entre dos herramientas seguidas se sostiene la línea anterior) | `UserPromptSubmit`, y cada `PostToolUse` |
| `reading` | *reading Brain.swift* | `PreToolUse` de Read, Grep, Glob |
| `writing` | *writing Brain.swift* | `PreToolUse` de Edit, Write, NotebookEdit |
| `running` | *running Build the app* | `PreToolUse` de Bash y de los MCP |
| `searching` | *searching swift displaylink* | `PreToolUse` de WebSearch, WebFetch |
| `delegating` | *helper: find flaky tests* | `PreToolUse` de Task, Skill, Workflow |
| `waiting` | *ok to run the tests? / has a question! / plan needs your ok!* — y **saluda** hasta que le contestes | `PermissionRequest` (sabe qué herramienta pide), `PreToolUse` de AskUserQuestion y ExitPlanMode, `Notification` como respaldo |
| `done` | festeja: *done! / all yours ✨* | `Stop` |
| `stopped` | nada: baja el globito y se queda quieta | `Stop` cuando el transcript termina en *[Request interrupted by user]*, y `PostToolUseFailure` con `is_interrupt` |

Los hooks no distinguen "pensando" de "tipeando la respuesta" — no hay evento para el
primer token —, así que *escribiendo* quiere decir escribiendo **archivos**, que es lo
que sí se puede saber y además es lo que te importa mirar.

Tres cosas de Claude Code (2.1.274) que costaron encontrar y explican la mitad de los
"se equivocó con el aviso":

- **La `Notification` de permiso llega tarde y a veces nunca.** Claude Code la manda
  recién a los **6 segundos** de abierto el diálogo, y sólo si en ese lapso no tocaste
  el teclado; si contestás antes, no llega. Por eso el aviso sale ahora de
  `PermissionRequest`, que corre en el instante en que aparece el diálogo y además
  trae la herramienta: *ok to run the tests?* en vez de un *needs your ok!* genérico.
  Por el mismo camino pasan `AskUserQuestion` y la aprobación del plan, que son
  diálogos de permiso por dentro (*has a question!*, *plan needs your ok!*).
- **`Stop` también corre cuando cortás con Esc** a mitad de una herramienta (el turno
  "termina por resultado de herramienta"). Sin distinguirlo, cada corte era un *done!*
  con saltitos. El hook mira la cola del transcript: si el último mensaje es el
  *[Request interrupted by user]*, escribe `stopped`. Y `PostToolUseFailure` con
  `is_interrupt` deja un `stopped` fresco que el `Stop` siguiente respeta.
- **No hay hook para el permiso *contestado*.** Aprobás un comando y lo próximo que
  se sabe es `PostToolUse`, cuando terminó — un build de un minuto era un minuto de
  *ok to run the build?* a alguien que ya dijo que sí. Lo que sí cambia al instante es
  el árbol de procesos: el comando nace como hijo del `claude` de esa sesión. Mientras
  hay un permiso en pie la pet mira los hijos de ese pid (por eso el hook lo escribe),
  y un hijo nuevo que sobrevive dos lecturas es el permiso contestado: reescribe el
  archivo como *running the tests* y los hooks retoman de ahí. Sus propios hooks son
  hijos también, pero viven milisegundos y dicen "chihiro" en la línea de comando.

Un archivo por sesión y no uno solo compartido: con dos Claude Code abiertos, el `Stop`
del que no estás mirando le bajaba el globito al que sí. Entre sesiones, **el aviso
fresco gana**: un `done` o `stopped` recién llegado (menos de 6 s) primero, un
`waiting` en pie después, y recién entonces la sesión trabajando más reciente. Era al
revés — la que trabajaba pisaba todo — y una terminal matada a mitad de respuesta (sin
`SessionEnd`, con el archivo congelado en `running`) silenciaba el festejo y los
permisos de las sesiones vivas durante los 15 minutos que tarda el cadáver en vencerse.
Los avisos son la razón de ser de la pet; no pueden perder contra un fantasma.

Hoy el fantasma directamente no existe: el archivo lleva el **pid** de la sesión, y si
ese proceso ya no está, la pet borra el archivo en la lectura siguiente. Los 15 minutos
quedan de respaldo para hooks viejos sin pid. Y el `waiting` ya **no vence solo** a los
45 s como antes — eso era lo que la dejaba muda con un permiso todavía en pantalla si
volvías dos minutos después. Todo lo que resuelve un permiso dispara un hook (aprobar
→ `PostToolUse`, negar → `PermissionDenied` o la herramienta siguiente, Esc → `Stop`,
cerrar la terminal → el pid muere), así que el estado se sostiene hasta que pasa algo
de verdad; lo que se apaga a los 20 s es el saludo, no la línea.

Lo escribe todo `hooks/chihiro-hook.sh`, que `build.sh` copia a `~/.chihiro/hook.sh`:

```jsonc
// ~/.claude/settings.json
"hooks": {
  "UserPromptSubmit":   [{ "hooks": [{ "type": "command", "command": "\"$HOME/.chihiro/hook.sh\" UserPromptSubmit" }] }],
  "PreToolUse":         [{ "matcher": "*", "hooks": [{ "type": "command", "command": "\"$HOME/.chihiro/hook.sh\" PreToolUse" }] }],
  "PostToolUse":        [{ "matcher": "*", "hooks": [{ "type": "command", "command": "\"$HOME/.chihiro/hook.sh\" PostToolUse" }] }],
  "PostToolUseFailure": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "\"$HOME/.chihiro/hook.sh\" PostToolUseFailure" }] }],
  "PermissionRequest":  [{ "matcher": "*", "hooks": [{ "type": "command", "command": "\"$HOME/.chihiro/hook.sh\" PermissionRequest" }] }],
  "PermissionDenied":   [{ "matcher": "*", "hooks": [{ "type": "command", "command": "\"$HOME/.chihiro/hook.sh\" PermissionDenied" }] }],
  "Notification":       [{ "hooks": [{ "type": "command", "command": "\"$HOME/.chihiro/hook.sh\" Notification" }] }],
  "Stop":               [{ "hooks": [{ "type": "command", "command": "\"$HOME/.chihiro/hook.sh\" Stop" }] }],
  "PreCompact":         [{ "hooks": [{ "type": "command", "command": "\"$HOME/.chihiro/hook.sh\" PreCompact" }] }],
  "SessionEnd":         [{ "hooks": [{ "type": "command", "command": "\"$HOME/.chihiro/hook.sh\" SessionEnd" }] }]
}
```

Cada evento deja además una línea en `~/.chihiro/events.log` (hora, evento, sesión,
estado, detalle, herramienta o tipo de notificación con su texto). Es la primera cosa
que mirar cuando "se equivocó con el aviso": dice qué llegó de verdad y en qué orden.
Se recorta solo en cada `Stop`, nunca pasa de unos cientos de KB.

Un hook de `UserPromptSubmit` que imprima algo en stdout se lo come el prompt como
contexto, así que el script manda todo a `/dev/null` y sale por 0 pase lo que pase: si
se rompiera, tiene que romperse en silencio y no en tu conversación.

El `~/.chihiro/busy` de antes (un archivo pelado que existe mientras se escribe la
respuesta) sigue funcionando para cualquier cosa que no sea Claude Code — se lee como
un `thinking` sin detalle.

### Quién gana cuando hay dos

Una pet, un estado. Si Claude Code está trabajando, manda él y no se mira la CPU. Si
no, la mira, y ahí aparece Claude Desktop.

El detalle que importa: el archivo de sesión **no desaparece al terminar la respuesta**,
queda en `done` hasta que cerrás la sesión — que es donde una sesión de Claude Code pasa
la mayor parte del día. Tomar eso como "alguien está reportando" dejaba a Claude Desktop
mudo mientras hubiera una terminal abierta. Así que `done` sólo pisa la CPU **6
segundos**: los que hacen falta para que ella lo festeje. Después el escritorio recupera
el turno.

Para Claude Desktop no hay señal explícita, así que ahí sí se adivina — pero con un
filtro que **no es de magnitud**. Medido: quieta en el fondo, sin que nadie le escriba,
la app tira ráfagas de 25 a 66% de un núcleo cada medio minuto, y algunas duran 45
segundos. Por tamaño y por duración son idénticas a una respuesta: **ningún umbral las
separa** (probé de 0,10 a 0,30 y el ruido pasa igual). Lo que sí las separa es *cuándo*
pasan: el ruido de fondo ocurre mientras estás trabajando en otra cosa.

Y hay una tercera fuente de carga que ningún umbral separa de una respuesta: **vos**.
Con Claude al frente, tipear un mensaje, scrollear una respuesta larga o clickear entre
chats gasta CPU de la app, y la pet lo leía como *thinking…* mientras el que trabajaba
eras vos. Por eso, con Claude al frente, un tramo adivinado **no puede empezar mientras
estás tipeando** (tecla, scroll o click en los últimos 2,5 s: la carga es tuya), y la
entrada por carga modesta sólo está abierta durante los **20 s siguientes a que hiciste
algo**: una respuesta viene después de un envío; el mantenimiento de la app mientras
leés, no. Seguir ocupada no tiene ninguna de las dos condiciones, así que podés escribir
la siguiente pregunta mientras contesta. Y el globito de un tramo adivinado dice siempre
*thinking…*: los *on it… / here we go…* son para un turno que ella vio empezar.

Hay dos maneras de entrar, las dos medidas sobre 648 muestras de ese ruido:

- **Mirando Claude**: alcanza con carga sostenida modesta (dos muestras sobre 0,20).
  Reacciona enseguida, porque el ruido de fondo pasa cuando estás en otra cosa.
- **Mirando otra cosa**: hace falta carga que el ruido **nunca alcanzó dos veces
  seguidas** (dos muestras sobre 0,50; el fondo pica hasta 0,76 pero siempre en una
  sola muestra). Cubre el caso de preguntar y cambiarte de app antes de que se entere.

Para **seguir** ocupada no hace falta ninguna de las dos: te vas a otra app en medio de
una respuesta y ella igual ve cuándo termina. Verificado: 90 s de ruido de fondo con
pico de 0,76 → cero falsas alarmas.

**Cuánto dura "todavía está contestando".** Eran 2,2 s, que es lo que dura un hueco
entre tokens y no lo que dura un hueco de verdad. Medido sobre una traza de 525 s con
Claude Desktop al frente contestando: la carga llega **a ráfagas, con huecos de 4 a 5
segundos**, y dos veces se calló medio minuto en el medio de la misma conversación. Con
2,2 s se caía tres veces, o sea tres "done!" encima de una sola respuesta — festejaba,
volvía a trabajar, volvía a festejar. Con **8 s** la misma traza es un solo tramo de
trabajo y un solo festejo.

Lo que se paga: el "done!" del escritorio llega hasta 8 s tarde. Claude Code no lo
paga, porque ahí no se adivina nada. Y como el falso positivo más corto pasó de ~5 s a
~11 s, el mínimo para festejar una respuesta *adivinada* subió de 5 a **12 s**: por
debajo de eso fue una ráfaga, no una respuesta.

Una señal explícita le gana a cualquier medición: si hay archivo de sesión, no se mira
CPU. Si una sesión se muere a mitad de una respuesta y lo deja colgado, a los 15 minutos
se ignora, para que no quede "trabajando" para siempre.

De la CPU sale un solo bit, así que por ahí el globito es siempre *thinking…* y para
festejar todavía hace falta que la ráfaga haya durado más de 5 segundos. Con señal no:
el `done` de un hook es una respuesta que llegó de verdad, y festeja aunque haya durado
dos segundos — que era justo lo que se perdía antes.

## Cómo detecta a Claude

`Sources/ClaudeProbe.swift`:

- **abierto / al frente** — `NSWorkspace`, bundle id `com.anthropic.claudefordesktop`.
- **pensando** — recorre los ~11 procesos bajo `/Applications/Claude.app/` con
  `proc_listallpids` + `proc_pidpath` y suma su CPU con `proc_pid_rusage`.

  **Ojo con las unidades.** En Apple Silicon `ri_user_time` y `ri_system_time` vuelven
  en unidades de *mach absolute time*, no en nanosegundos. Dividirlas por 1e9 —que es
  lo que parece obvio y lo que funciona en Intel, donde el timebase es 1:1— deja toda
  la medición **41,7 veces más chica** (125/3). Con ese error Claude Desktop marcaba
  0,00 hiciera lo que hiciera, y la pet no reaccionó nunca a la app: el heurístico
  estaba muerto desde el día uno y no se notaba porque las pruebas usaban
  `CHIHIRO_FAKEBUSY` o el archivo de señal. La conversión correcta sale de
  `mach_timebase_info`. Si tocás esto, verificalo contra `ps -o time`: tienen que dar
  lo mismo. Si el
  consumo se despega de su propio piso reciente, está generando. Es adaptativo, no
  un umbral fijo, y sostiene el estado 2,2 s para no titilar entre tokens. Una vez
  que dijo "ocupada" el umbral para seguir ocupada baja (histéresis), y las muestras
  tomadas en pleno "ocupada" **no** entran al piso: si entran, una respuesta larga se
  fabrica su propio piso y a la mitad deja de parecer ocupada.
- **qué está haciendo** — el archivo de la sesión de Claude Code, que trae el estado y
  el detalle ya masticados. Se lee cada 0,2 s, aparte del muestreo completo (cada
  1,5 s): la parte cara es recorrer todos los pids de la máquina, leer un par de
  archivos cortos no lo es, y es la que tiene que ir al ritmo de ella. Enterarse un
  segundo y medio tarde de que empezó a leer otro archivo se ve como distracción.
- **dónde está su ventana** — `CGWindowListCopyWindowInfo`, sólo geometría, así que
  no pide permiso de grabación de pantalla.

Nada de esto necesita permisos especiales ni toca la app de Claude.

## Los assets

Todo sale de una sola foto de la figurita (`~/Downloads/Diseno-sin-titulo-...png`).

```bash
python3 work/make_matte.py      # segmenta con BiRefNet -> work/base3.png (una vez)
python3 work/build_layers.py    # corta las capas
python3 work/build_extras.py    # sombra de contacto + icono (SIEMPRE despues)
python3 work/build_pixels.py    # version pixel art (SIEMPRE al final)
./build.sh
```

**El recorte lo hace un modelo, no umbrales de color.** El primer intento usaba un
modelo de fondo por fila más reglas de color y el resultado era malo: el pelo son
mechas finas contra una pared casi del mismo tono, y ningún umbral separa eso. Con
`rembg` + BiRefNet el matte sale limpio de una, incluida la pierna trasera que está
tan sombreada que su tono coincide con la pared. La foto se agranda 3x antes de
segmentar — a 500 px el modelo no tiene con qué encontrar las mechas — y el rig
trabaja en ese 3x, así que a tamaño de pet la imagen se reduce en vez de estirarse.

Lo único que el modelo deja de más es la peana de madera, y ahí sí hace falta lógica
propia (`build_layers.py`, paso 1): ningún umbral la separa del zapato porque la
madera iluminada y la sandalia en sombra caen en los mismos colores. Se resuelve con
dos hechos: la piel se mantiene **cálida** aun en sombra (R−B ≈ 110, la madera ≈ 80),
y todo lo que esté a un par de píxeles de un píxel claramente de sandalia es sandalia.
Lo que pasa los dos filtros es un solo blob grande — el disco — así que se descarta
sólo el componente mayor, y el borde fino que queda pegado a cada suela se lee como
sombra de contacto.

Después del corte:

- **Bordes** — el rim suave del matte todavía arrastra el beige de la foto (halo
  blanco sobre escritorio claro). Se re-extiende el color interior hacia afuera.
- **Ojos** — se pinta esclerótica bajo cada iris para que el iris pueda deslizarse.
- **Párpados cerrados** — la piel de alrededor se lleva hacia adentro con convolución
  normalizada (blur de lo conocido dividido por el blur de la cobertura), no con
  dilatación iterativa: con un agujero de este ancho la dilatación deja vetas
  diagonales. Encima va un arco de pestaña.

Los pasos con radio — inpaint, blur, dilatación — van multiplicados por `S`. Si no,
al subir la resolución el relleno no llega a cubrir su agujero: así se rompieron los
párpados la primera vez que se pasó a 3x.

## El pixel art

```bash
python3 work/build_pixels.py 26 8   # layers/ -> layers-px/: celda de 26 px, 8 colores
./build.sh
```

Lo que decide si se lee como sprite o como foto achicada **no es el tamaño de celda,
es cómo cada celda elige su color**. Promediar — que es lo que hace el filtro
"pixelar" de cualquier editor — inventa un color intermedio en cada borde: queda
redondo y blandito por más que agrandes las celdas. Acá en cambio la paleta se arma
primero, cada píxel de origen se pega a ella, y **cada celda toma el color más
frecuente**, no el promedio. Eso mantiene los bordes duros y las zonas planas.

Y encima:

1. **Una sola grilla.** Cada capa se estira hasta múltiplos de la celda *antes* de
   bajar la resolución. Si cada parte cae en su propio medio píxel, los píxeles del
   brazo no coinciden con los del cuerpo.
2. **Alfa de 1 bit.** El borde suave es lo que delata a una foto reducida.
3. **Una paleta chica para toda la figura** (8 colores), no una por capa.
4. **Contorno oscuro por parte móvil**, que es lo que hace que un brazo se lea como un
   brazo a 12 píxeles de ancho.

5. **Sin píxeles sueltos** (`despeckle`). Una celda que no comparte color con ningún
   vecino es ruido del downsample — un brillo del pelo que cayó en el rojo del
   vestido, una sombra suelta en el medio de la piel. Invisible a tamaño completo,
   cantan "hecho a máquina" a este. Un sprite dibujado a mano no tiene píxeles
   huérfanos, así que cada uno toma el color más común de alrededor.
6. **Al pelo se le prohíbe el rojo del vestido.** Los brillos cálidos del pelo caían
   en los dos rojos de la paleta y quedaban manchones que parecían daño. En la cabeza
   esas dos entradas directamente no están disponibles.

### La cara se dibuja aparte

Todo lo demás sobrevive al downsample porque es grande y plano. La cara no: un ojo
mide dos o tres celdas, y **cualquier regla que elija el color de una celda que es
mitad pupila y mitad blanco se equivoca**. El primer intento dejó un ojo hecho una
barra y el otro una cruz. Así que las facciones se ubican con la geometría del propio
rig (el centro de cada iris, la boca medida sobre la foto) y se dibujan como píxeles
explícitos, en colores mezclados desde la paleta para que sigan siendo de la familia.

Dos cosas que se probaron y no funcionan a esta escala:

- **Esclerótica.** Un ojo con blanco alrededor de la pupila necesita 4 celdas de ancho,
  y con borde son 6: los dos ojos se tocan y parecen anteojos. Peor: el blanco del lado
  de adentro queda contra la piel, que es casi igual de clara, así que no se ve — y el
  ojo parece torcido, mirando siempre para afuera.
- **La moda para el iris.** Ni con la regla del más oscuro: la pupila es tan chica que
  el resultado depende de dónde cayó la grilla.

Lo que sí funciona es lo que usan los pets de verdad: **el ojo *es* la pupila**, un
bloque de 2x3 con una celda de brillo arriba a la izquierda, sobre piel lisa. Se lee
siempre, no se toca con el otro, y como el iris es una capa aparte, sigue moviéndose
una celda para cada lado cuando ella mira. Para el parpadeo, `lidL/lidR` son una línea
de tres celdas con piel arriba y abajo.

Dos cosas más que hacían que la cara se viera torcida:

- **Los ojos van forzados a la misma fila y simétricos.** En la foto ella tiene la
  cabeza un poco girada: los centros de los dos iris difieren 3 px en vertical. Tres
  píxeles no son nada a tamaño completo y son *una celda entera* acá — le dejaban un
  ojo una fila más arriba y una fila más alto que el otro. Ahora los dos salen de un
  mismo eje (`FACE_X`, `EYE_Y`) a una cantidad entera de celdas de cada lado, y la
  boca usa ese mismo eje.
- **La parte de abajo de la cara se borra a piel antes de dibujar la boca.** Su boca
  real es grande y abierta, y reducida queda como una barra oscura de lado a lado.
  Dibujarle una boca chica encima sólo agregaba una boca arriba de un bigote.

El tamaño de celda y la cantidad de colores son argumentos. A 26 quedan 30x45 celdas;
a 32 se empieza a perder la expresión; a 18 vuelve a parecer una foto pixelada en vez
de un sprite. Con 12 colores en vez de 8 el vestido deja de ser plano y vuelve el
aspecto de foto.

Los patrones de la cara (`EYE`, `PUP`, `SHUT`, `MOUTHART`) son literales de texto al
final del script: se editan como se edita pixel art, mirando. Si movés la boca o
cambiás el tamaño de celda, `MOUTH_AT` está en coordenadas canónicas, no en celdas.

La sombra se **redibuja** como elipse plana: la gaussiana del rig de foto, reducida,
daba una manchita corrida a un costado (su rect estaba centrado en la foto, no en ella).

### Las extremidades vienen ya rotadas

En modo píxel los brazos y las piernas **no rotan en vivo**: el rig trae cada uno
dibujado en 9 ángulos fijos (`SPIN` en el script, `armR@-32.png` y compañía) y la app
cambia la imagen, no la transformación.

Rotar un sprite de pixel art con vecino-más-cercano lo rompe: a 16° el contorno del
brazo se desarma en manchitas sueltas y la forma pierde píxeles, y como el ángulo
cambia en cada frame, tiembla. Rotar **la foto** y recién después pixelar da una
figura sólida en cualquier ángulo — que es como se hicieron las hojas de sprites toda
la vida. Todos los ángulos comparten un mismo rect, así que la capa nunca se mueve.

Por la misma razón, en modo píxel la **cabeza y el torso no rotan**, sólo se trasladan:
la cabeza lleva la cara, y girarla unos grados vuelve a muestrear los ojos con otra
forma en cada frame. Las extremidades sí giran porque su giro está horneado.

Del lado de la app, tres reglas (`PetView`):

- `magnificationFilter = .nearest`, obvio.
- **Todo cae en la grilla**: el lienzo se redondea a múltiplos de celda y el zoom se
  redondea para que una celda mida un número entero de píxeles de pantalla. Si no, unas
  celdas salen de 5 píxeles y otras de 6, y titilan cuando se mueve. Por eso el tamaño
  real de la pet puede quedar unos puntos abajo del que pediste.
- **Ganancias antes de redondear** (`PetView.gainBody/gainHead/gainIris`). Respirar
  mueve 1,8 px canónicos: menos de un décimo de celda, que redondeado es cero, y
  quedaría congelada. Cada canal se amplifica hasta que su pico llega a una celda
  entera y recién ahí se redondea. Así el idle es un rebote de un píxel y la mirada
  mueve el iris una celda — que es como se anima el pixel art, no deslizándose.
  Ojo: la ganancia es *proporcional al tamaño de celda*. Con números fijos anda sólo
  en el tamaño para el que se eligieron; al agrandar la celda, respirar vuelve a
  redondear a cero y ella se queda dura.

Las escalas también se redondean a celdas enteras: un sprite escalado 1,014 duplica una
fila de píxeles y deja el resto igual, y esa fila titila.

## El rig

`layers/rig.json` guarda todo en un espacio canónico de 1002x1416 px (334x472 x S) con los pivotes de
cada articulación. `PetView` monta un `CALayer` por parte con su `anchorPoint` en el
pivote; `Brain` produce un `Pose` por frame y `PetView.apply` lo traduce a transforms.

Las piernas se dibujan **detrás** del short y los brazos llevan un collar de tela
debajo de la manga, así ninguna rotación abre un agujero.

**El hombro tiene un tope real: 32°** (`Brain.armLimit`, aplicado con un clamp al
final de `pose`). Los brazos van *detrás* de la cabeza, y como el pelo es ancho, a
partir de ~35° la mano desaparece atrás del pelo y el brazo queda como un muñón
flotando en el cuello. Se midió componiendo el rig fuera de la app a 0-72°: hasta 30
la mano se ve entera, a 45 ya no está. El saludo usaba 57° y el festejo 72°; los dos
se veían cortados. Si algún día hace falta más brazo, no alcanza con subir el número:
hay que agrandar el recorte del brazo o sacar la mano del plano del pelo.

Los cambios de estado **no cortan**: `enter` congela la pose y `settled` la mezcla con
la nueva por 0,24 s (`Pose.mix` + smoothstep). Sin eso, pasar de idle a festejo movía
el hombro 30° en un frame y se leía como un salto de imagen, no como un movimiento.

La velocidad de caminata sale de la zancada (`Brain.stepsPerSecond` × la excursión del
pie × `scale`), no de un número fijo: así los pies no patinan y sigue andando bien en
los tres tamaños.

Ojo con una: AppKit fija el `anchorPoint` de la capa de respaldo de una vista en
`(0,0)`, así que el espejado (`facing = -1`) tiene que ir entre traslaciones o la
figura se va fuera del canvas. Está comentado en `PetView.swift`.

## Debug

```bash
CHIHIRO_DEBUG=1 ./build/Chihiro.app/Contents/MacOS/Chihiro   # estado por stderr
CHIHIRO_DEMO=1  ...                                          # ciclo de 18 s con todos los estados
CHIHIRO_QA=/ruta ...                                         # vuelca un PNG cada 0,55 s
CHIHIRO_FAKEBUSY=1 ...                                       # finge que Claude responde 9 s de cada 22
CHIHIRO_CLOCK=timer ...                                      # reloj viejo: corre con la pantalla dormida
CHIHIRO_QA_EVERY=0.08 CHIHIRO_QA_FRAMES=180 ...              # volcados rapidos, para eventos breves
```

La línea de debug empieza con la hora (`18:30:38`), que es lo que permite cruzar una
traza con algo que pasó afuera de la app — "¿vio la respuesta que acabo de mandar en
Claude Desktop?" no se contesta sin eso.

El volcado por defecto (cada 0,55 s) **se pierde los eventos cortos**: un parpadeo dura
0,28 s y no aparecía en 41 frames seguidos, lo que parecía demostrar que no parpadeaba.
No lo demostraba. Para eso está `CHIHIRO_QA_EVERY`, y `lid=` en la línea de debug.

`CHIHIRO_FAKEBUSY` es la forma de mirar "trabajando → festeja → globito" sin depender
de mandarle algo a Claude y esperar. `CHIHIRO_DEMO` recorre los ocho estados en 21 s.

Para los estados de Claude Code no hace falta ni eso: se escriben a mano, y la línea de
debug trae `say="…"` con lo que tiene puesto en el globito, así que la reacción entera
se verifica desde un script.

```bash
S=~/.chihiro/sessions; mkdir -p $S
printf 'reading\tBrain.swift\n' > $S/qa       # lee un archivo
printf 'writing\tBrain.swift\n' > $S/qa       # lo escribe
printf 'waiting\trun the tests\n' > $S/qa     # "ok to run the tests?" y saluda
printf 'waiting\tquestion\n' > $S/qa          # "has a question!"
printf 'done\t\n'                 > $S/qa     # festeja
printf 'stopped\t\n'              > $S/qa     # baja el globito sin festejar
rm $S/qa
```

Los campos tres y cuatro (pid y evento) son opcionales; con un pid la pet borra el
archivo cuando ese proceso muere, y con `PermissionRequest` de evento mira los hijos
del pid para adivinar el permiso contestado (`sleep 1000 & echo $!` sirve de sesión
de mentira).

Ojo con probar esto **desde** Claude Code: sus propios hooks están escribiendo su
archivo de sesión al mismo tiempo, y la sesión que trabaja le gana a la de mentira.
`CHIHIRO_SESSIONS=/tmp/qa-sessions` la hace mirar otro directorio, y ahí las sesiones
vivas no se meten.

Para revisar si una pose se sale del lienzo, los volcados de `CHIHIRO_QA` sirven aunque
tengan las líneas grises: si el alpha del PNG toca un borde, esa pose se está cortando
contra la ventana. `screencapture -l` falla con la pantalla dormida, los volcados no.

`CHIHIRO_QA` usa `CALayer.render(in:)`, que dibuja unas líneas grises finas en los
bordes de las capas que **no** aparecen en pantalla. Para revisar el render real usá
`screencapture -o -l <window id>` (el id sale con `CHIHIRO_DEBUG=1`).

## Ajustes

- Velocidad y amplitud de cada estado: `Brain.pose(...)`. El salto del festejo usa
  `rootDY`, y el aire que tiene arriba sale del `0.130` de `PetView.init`: si lo subís,
  subí también el alto del `box` o se le corta la cabeza contra el borde de la ventana.
- Qué dice (en inglés): `Brain.startLines` / `Brain.doneLines`. La línea de "está
  trabajando" **no tiene duración**: se sostiene hasta que llega la respuesta. Un globo
  que aparece y se va mientras mirás para otro lado es igual que ningún globo.
- Posición de reposo de los brazos: `Brain.armRest`. En la foto los tiene extendidos
  hacia los costados, así que un sprite sin rotar se lee como "brazos en alto todo el
  tiempo". Todo lo que no sea saludar o festejar cuelga desde ahí.
- Parpadeo: en modo píxel es **duro, sin transición**. Un sprite de 1 bit dibujado a
  media opacidad es una mancha sobre los ojos, no un parpadeo — por eso no se leía.
- Sensibilidad de "Claude pensando": `ClaudeProbe.refresh`, línea `let hot = ...`.
- Nivel de ventana: `.statusBar` para que flote sobre apps en pantalla completa.
