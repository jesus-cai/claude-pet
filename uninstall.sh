#!/bin/bash
# Quita Compa: la app, sus hooks de ~/.claude/settings.json (deja .bak) y, si
# pasas --all, también ~/.compa (tus mascotas incluidas).
set -euo pipefail
pkill -x Compa 2>/dev/null || true
rm -rf "$HOME/Applications/Compa.app"
settings="$HOME/.claude/settings.json"
jq_bin="$(command -v jq 2>/dev/null || echo /usr/bin/jq)"
if [ -s "$settings" ] && [ -x "$jq_bin" ]; then
  cp "$settings" "$settings.bak"
  "$jq_bin" '
    def ours: any(.hooks[]?; (.command // "") | test("\\.(chihiro|compa)/hook\\.sh"));
    if .hooks then
      .hooks |= (with_entries(.value |= map(select(ours | not))) | with_entries(select(.value | length > 0)))
    else . end
  ' "$settings.bak" > "$settings.new" && mv "$settings.new" "$settings"
fi
if [ "${1:-}" = "--all" ]; then rm -rf "$HOME/.compa"; else rm -f "$HOME/.compa/hook.sh"; fi
echo "Compa desinstalada."
