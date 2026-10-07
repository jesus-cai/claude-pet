# Compa para Windows

La misma mascota que en Mac, para Claude Code en Windows (en la terminal y en la
extensión de VS Code) y para **Claude Desktop**. Usa las mismas mascotas, con hablar, entradas y
personalidad.

## Instalar (para quien solo quiere usarla)

1. Descomprime `Compa-Windows.zip` en una carpeta fija, por ejemplo
   `Documentos\Compa`. No la dejes en Descargas si vas a borrarla luego: Claude Code
   puede llamar a esa carpeta.
2. Abre **Compa.exe**. Windows SmartScreen puede avisar de que la app no está
   firmada: *Más información → Ejecutar de todas formas*.
3. Aparece la mascota encima de la barra de tareas y su icono en la bandeja del sistema
   (junto al reloj; si no se ve, está en la flechita ^).
4. **Reinicia Claude Code**: cierra la terminal o recarga VS Code (*Ctrl+Shift+P →
   Developer: Reload Window*) para que cargue los hooks.
5. Para que arranque sola: icono de la bandeja → **Abrir al iniciar sesión**.

Al abrirse, Compa registra sola sus hooks en `%USERPROFILE%\.claude\settings.json`
(guarda una copia `.bak` y respeta los hooks que ya hubiera). Si se mueve la carpeta
de Compa, ábrela otra vez o usa **Reinstalar hooks de Claude Code** del menú.

**Con o sin Node.** Si el ordenador tiene Node.js, los hooks lo usan (`node hook.js`):
es lo más rápido. Si no, los ejecuta el propio `Compa.exe --hook`, que funciona igual
pero tarda un poco más en cada herramienta (unas décimas de segundo). Si notas Claude
algo más lento, instala Node desde nodejs.org y pulsa *Reinstalar hooks*.

## Uso

Igual que en Mac: arrastrarla, hacer clic (da los avisos por vistos), clic derecho o
el icono de la bandeja para el menú. Avisos que se quedan hasta que los ves, el
proyecto delante con varias sesiones, sigue trabajando mientras quede alguna, y un
punto de color en el icono de la bandeja: naranja te espera, verde terminó, rojo error.
Cada sesión del menú tiene **Quitar esta sesión**: fuera de la lista y sin mascota
hasta que vuelva a trabajar (cuando le escribas otra vez).

En **Avisos** se activan el sonido y las notificaciones de Windows.

**Mascotas**: menú → Mascota. Las tuyas van en `%USERPROFILE%\.compa\pets\<nombre>\`
(`pet.json` + `spritesheet.webp`), y también aparecen las de `%USERPROFILE%\.codex\pets`.
Formato: el README principal.

## Diferencias con la versión de Mac

- Solo mascotas de tipo atlas: el rig por capas (Chihiro) no existe aquí.
- Al aprobar un permiso, el globito naranja se quita cuando el comando termina, no al
  instante (en Mac se detecta mirando los procesos).

## Claude Desktop

La app de escritorio no tiene hooks, así que se adivina, igual que en Mac, por su uso
de CPU: un pequeño PowerShell en segundo plano lo mide una vez por segundo. Ignora los
picos sueltos que la app hace sola en segundo plano y no confunde tu tecleo con una
respuesta. Lo que da de sí:

- Sabe que **está respondiendo** y cuándo **termina** (con aviso, sonido y punto
  verde, como "Claude Desktop" en el menú). Una respuesta normal avisa unos 12 s
  después de acabar. Una **tarea con herramientas** (comandos, búsquedas) se reconoce
  porque la CPU vuelve tras una pausa: desde entonces espera hasta 30 s de calma antes
  de avisar, para no dar por terminada la tarea al primer comando. Límite: si el
  *primer* comando es largo y la app se queda del todo quieta, todavía puede avisar
  antes de tiempo.
- **No sabe qué hace** (leer, ejecutar…) ni cuándo pide permiso: el globito dice solo
  *thinking…*.
- Si a la vez hay una sesión de Claude Code trabajando o esperándote, manda la de
  Claude Code: lo suyo es un hecho, lo de Desktop una suposición.
- Con Claude Desktop delante y tú quieta, la mascota mira hacia su ventana.

## Una mascota por sesión

Igual que en Mac (ver el README principal): menú de la bandeja → **Una mascota por
sesión**, con escenario, paseos cortos o libres, y colores, etiquetas y mascotas fijadas
por proyecto. Aquí también tiene su mascota **Claude Desktop** cuando está abierto.

## Subagentes

Igual que en Mac: lo que hacen los subagentes se pliega en su sesión y no cuenta como
"terminado"; con ayudantes en segundo plano, el aviso llega una sola vez, cuando la
sesión acaba de verdad. Detalles en el README principal.

## Si no avisa

Si con Claude Desktop no reacciona: menú de la bandeja; la primera línea dice
"Claude Desktop abierto" si lo está viendo. Si no lo ve, puede que una política de la
empresa bloquee PowerShell.

`%USERPROFILE%\.compa\events.log` tiene una línea por cada evento que llega de Claude
Code. Si está vacío, los hooks no se ejecutan: *Reinstalar hooks* y reiniciar Claude
Code. Para ver errores de la app, ábrela desde una terminal con `set COMPA_DEBUG=1`
y luego `Compa.exe`. Con `COMPA_FAKEDESKTOP=1` simula a Claude Desktop respondiendo
14 s de cada 30 (para probar su mascota sin abrirlo).

## Compilar (desarrollo)

```bash
cd windows
npm install
npm start          # la ejecuta
npm test           # simula sesiones y comprueba el comportamiento
npm run dist       # genera dist/Compa-<versión>-win.zip
```

Se puede compilar desde Linux o Mac también (sin firmar). `lib/` tiene la lógica
(sesiones, cerebro, atlas, hooks), `hook.js` es el hook, y `renderer.js` / `main.js`
la parte de Electron.
