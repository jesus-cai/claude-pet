#!/bin/bash
# Instala Compa: compila la app, la copia a ~/Applications, instala el hook y lo
# registra en ~/.claude/settings.json. Se puede correr de nuevo sin miedo: no
# duplica hooks, respeta los tuyos y deja una copia .bak antes de tocar nada.
# Si tenías la versión anterior (Chihiro), la retira y migra sus hooks.
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Hace falta el compilador de Swift. Instálalo con:"
  echo "    xcode-select --install"
  echo "y vuelve a correr ./install.sh"
  exit 1
fi
jq_bin="$(command -v jq 2>/dev/null || true)"
[ -z "$jq_bin" ] && [ -x /usr/bin/jq ] && jq_bin=/usr/bin/jq
if [ -z "$jq_bin" ]; then
  echo "Falta jq para registrar los hooks (brew install jq). Vuelve a correr ./install.sh"
  exit 1
fi

./build.sh

# --- la versión anterior ---
pkill -x Chihiro 2>/dev/null || true
if [ -d "$HOME/Applications/Chihiro.app" ]; then
  echo "retiro la versión anterior (Chihiro.app)"
  rm -rf "$HOME/Applications/Chihiro.app"
fi

# --- la app ---
mkdir -p "$HOME/Applications"
pkill -x Compa 2>/dev/null || true
rm -rf "$HOME/Applications/Compa.app"
cp -R build/Compa.app "$HOME/Applications/"
xattr -dr com.apple.quarantine "$HOME/Applications/Compa.app" 2>/dev/null || true

# --- los hooks de Claude Code ---
settings="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[ -s "$settings" ] || echo '{}' > "$settings"
cp "$settings" "$settings.bak"

"$jq_bin" '
  def ours: any(.hooks[]?; (.command // "") | test("\\.(chihiro|compa)/hook\\.sh"));
  def entry($ev; $matcher):
    ({ hooks: [{ type: "command",
                 command: ("\"$HOME/.compa/hook.sh\" " + $ev),
                 timeout: 5 }] })
    + (if $matcher then { matcher: "*" } else {} end);
  .hooks = (.hooks // {}) |
  reduce (
    ["UserPromptSubmit", false], ["PreToolUse", true], ["PostToolUse", true],
    ["PostToolUseFailure", true], ["PermissionRequest", true],
    ["PermissionDenied", true], ["Notification", false], ["Stop", false],
    ["StopFailure", false], ["SubagentStart", false], ["SubagentStop", false], ["PostCompact", false],
    ["PreCompact", false], ["SessionEnd", false]
  ) as [$ev, $m] (.;
    .hooks[$ev] = (((.hooks[$ev] // []) | map(select(ours | not))) + [entry($ev; $m)])
  )
' "$settings.bak" > "$settings.new" && mv "$settings.new" "$settings"

open "$HOME/Applications/Compa.app"

cat <<'MSG'

Listo. Compa está en la barra de menú.
- Las sesiones de Claude Code que abras a partir de ahora le avisan; las que ya
  estaban abiertas, reinícialas.
- Mascotas: menú > Mascota. Añade las tuyas en ~/.compa/pets/<nombre>/
  (pet.json + spritesheet.webp); las de ~/.codex/pets también aparecen.
- Para que arranque sola: menú > Abrir al iniciar sesión.
- Si tenías Chihiro como ítem de inicio de sesión, quítalo en
  Ajustes del Sistema > General > Ítems de inicio.
MSG
