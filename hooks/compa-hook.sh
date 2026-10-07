#!/bin/bash
# Le cuenta a la mascota (Compa) qué está haciendo Claude Code.
#
# Se engancha a los hooks de Claude Code y escribe una línea en
# ~/.compa/sessions/<session_id>:
#
#     <estado>\t<detalle>\t<pid>\t<evento>\t<proyecto>
#
# estado   ∈ thinking | reading | writing | running | searching | delegating
#            | waiting | done | stopped | error
# pid      = el proceso `claude` de esa sesión, para descartar al instante una
#            terminal cerrada de golpe (sin SessionEnd).
# evento   = el hook que escribió la línea (un `waiting` de PermissionRequest sabe
#            qué herramienta espera; la app vigila sus hijos para notar la respuesta).
# proyecto = nombre de la carpeta de trabajo, para que con varias sesiones el aviso
#            diga CUÁL terminó o cuál te necesita.
#
# Un archivo por sesión: dos Claude Code abiertos a la vez se pisarían el estado.
#
# Nada de esto puede escribir en stdout: lo que imprime un UserPromptSubmit entra
# en el prompt, y lo que imprime un PermissionRequest se lee como una decisión.
# Y nada por stderr: una mascota no tiene derecho a interrumpir tu sesión.
exec 1>/dev/null 2>/dev/null

event="${1:-}"
payload="$(cat)"

root="${COMPA_HOME:-$HOME/.compa}"
dir="$root/sessions"
mkdir -p "$dir"

jq_bin="$(command -v jq 2>/dev/null || true)"
[ -z "$jq_bin" ] && [ -x /usr/bin/jq ] && jq_bin=/usr/bin/jq

session="solo"; state="thinking"; detail=""; transcript=""; kind=""; project=""
agent=""; agent_type=""; errkind=""; snippet=""; trigger=""

if [ -n "$jq_bin" ]; then
  out="$(printf '%s' "$payload" | "$jq_bin" -r --arg ev "$event" '
    def clip: tostring | gsub("[\\n\\r\\t]+"; " ") | if (length > 34) then (.[0:33] + "…") else . end;
    def base: (.tool_input // {});
    def fname: ((base.file_path // base.notebook_path // "") | tostring | split("/") | last);
    def host: ((base.url // "") | tostring | sub("^[a-z]+://"; "") | split("/") | first);
    def msg: ((.message // "") | tostring | ascii_downcase);
    (if $ev == "" then ((.hook_event_name // "") | tostring) else $ev end) as $e |
    ((.tool_name // "") | tostring) as $t |
    ((.notification_type // "") | tostring) as $n |
    [ ((.session_id // "solo") | tostring | gsub("[^A-Za-z0-9._-]"; "_")),

      # ---- estado ----
      ( if   $e == "Stop"         then "done"
        elif $e == "PostToolUseFailure" then
          # la herramienta no terminó: o falló (el modelo sigue) o la cortaste vos.
          # Un corte no es una respuesta que llegó, y no se festeja.
          ( if (.is_interrupt // false) == true then "stopped" else "thinking" end )
        elif $e == "PermissionDenied" then "thinking"     # el modelo sigue sin esa herramienta
        elif $e == "PermissionRequest" then "waiting"
        elif $e == "Notification" then
          # El tipo dice qué es la notificación; el texto sólo sirve para versiones
          # viejas que no lo mandaban. La de "Claude is waiting for your input" llega
          # sola al minuto de terminar un turno y no tiene ningún evento que la cierre
          # - la escribíamos igual y la pet se quedaba en "your turn!" para siempre.
          ( if   $n == "permission_prompt" or $n == "worker_permission_prompt" then "waiting"
            elif $n == "elicitation_dialog" or $n == "elicitation_url_dialog"
              or $n == "agent_needs_input"                                   then "waiting"
            elif $n != ""                                                    then ""
            elif (msg | test("waiting for your input"))                      then ""
            elif (msg | test("permission|approv|permiso|needs your input"))  then "waiting"
            else "" end )
        elif $e == "PreCompact"   then "thinking"
        elif $e == "PreToolUse"   then
          ( if   ($t | test("^(AskUserQuestion|ExitPlanMode)$"))              then "waiting"
            elif ($t | test("^(Edit|Write|MultiEdit|NotebookEdit)$"))        then "writing"
            elif ($t | test("^(Read|NotebookRead|Grep|Glob|ToolSearch)$"))   then "reading"
            elif ($t | test("^(Bash|BashOutput|KillShell|Monitor)$"))        then "running"
            elif ($t | test("^(WebSearch|WebFetch)$"))                      then "searching"
            elif ($t | test("^(Task|Agent|Workflow|Skill)$"))               then "delegating"
            elif ($t | startswith("mcp__"))                                 then "running"
            else "thinking" end )
        else "thinking" end ),

      # ---- detalle ----
      ( if $e == "PreToolUse" then
          ( if   ($t | test("^(Edit|Write|MultiEdit|NotebookEdit|Read|NotebookRead)$")) then (fname | clip)
            elif ($t == "AskUserQuestion")         then "question"
            elif ($t == "ExitPlanMode")            then "plan"
            elif ($t == "Bash")                    then ((base.description // base.command // "") | clip)
            elif ($t | test("^(Grep|Glob)$"))      then ((base.pattern // "") | clip)
            elif ($t == "WebSearch")               then ((base.query // "") | clip)
            elif ($t == "WebFetch")                then ((base.url // "") | clip)
            elif ($t | test("^(Task|Agent)$"))     then ((base.description // "") | clip)
            elif ($t == "Skill")                   then ((base.skill // "") | clip)
            elif ($t == "Workflow")                then ((base.name // "workflow") | clip)
            elif ($t | startswith("mcp__"))        then (($t | split("__") | last) | clip)
            else "" end )
        elif $e == "PermissionRequest" then
          # Lo que está pidiendo, como frase para "ok to …?". Las dos herramientas
          # que no piden permiso sino respuesta van con su propia palabra.
          ( if   ($t == "AskUserQuestion")         then "question"
            elif ($t == "ExitPlanMode")            then "plan"
            elif ($t == "EnterPlanMode")           then "plan first"
            elif ($t == "Bash")                    then (("run " + (base.description // base.command // "")) | clip)
            elif ($t | test("^(Edit|Write|MultiEdit|NotebookEdit)$")) then (("edit " + fname) | clip)
            elif ($t == "Read")                    then (("read " + fname) | clip)
            elif ($t == "WebFetch")                then (("fetch " + host) | clip)
            elif ($t == "WebSearch")               then (("search " + (base.query // "")) | clip)
            elif ($t | test("^(Task|Agent)$"))     then "send a helper"
            elif ($t == "Skill")                   then (("run /" + (base.skill // "")) | clip)
            elif ($t == "Workflow")                then "run a workflow"
            elif ($t | startswith("mcp__"))        then (("use " + ($t | split("__") | last)) | clip)
            else (("use " + $t) | clip) end )
        elif $e == "Notification" then
          ( if ($n | test("permission")) or (msg | test("permission|permiso|approv")) then "permission"
            else "input" end )
        elif $e == "PreCompact" then "tidying up…"
        else "" end ),

      ((.transcript_path // "") | tostring),
      ( $t + (if $n != "" then " " + $n else "" end)
        + (if $e == "Notification" then " «" + ((.message // "") | tostring | clip) + "»" else "" end) ),
      ((.cwd // "") | tostring | split("/") | map(select(. != "")) | last // "" | gsub("[\\t\\n\\r]"; " ") | clip),
      ((.agent_id // "") | tostring | gsub("[^A-Za-z0-9._-]"; "_")),
      ((.agent_type // "") | tostring | clip),
      ((.error_type // .error // .reason // "") | tostring | gsub("[\\t\\n\\r]"; " ")),
      ((.last_assistant_message // "") | tostring | split("\n") | map(select(test("\\S"))) | (first // "") | gsub("^\\s+"; "") | clip),
      ((.trigger // "") | tostring)
    ] | join("")' 2>/dev/null)" || out=""

  # jq no pudo con el payload: mejor callarse que inventar. Escribir el default
  # ("solo", "thinking") creaba una sesión fantasma en estado working que tapaba
  # los avisos de las sesiones de verdad.
  [ -z "$out" ] && exit 0
  # separador US (0x1f) y no tab: `read` colapsa los tabs seguidos, y un detalle
  # vacío corría todos los campos un lugar
  IFS=$'\x1f' read -r session state detail transcript kind project agent agent_type errkind snippet trigger <<< "$out"
else
  # sin jq no hay detalle, pero el estado grueso todavía sirve
  case "$event" in
    Stop) state="done" ;;
    PermissionRequest) state="waiting" ;;
    Notification|PostToolUseFailure|PermissionDenied) exit 0 ;;   # sin jq no se sabe qué son
    *) state="thinking" ;;
  esac
fi

[ -z "$session" ] && session="solo"
f="$dir/$session"

# ---- bitácora ----
# Una línea por evento, siempre. Es lo que permite contestar "se equivocó con
# esto" mirando qué llegó de verdad en vez de adivinando; se recorta en cada
# Stop para que nunca pase de unos cientos de KB.
log="$root/events.log"
note() {
  printf '%s  %-18s %-8s %-9s %s\t%s\n' "$(date '+%m-%d %H:%M:%S')" "$event" "${session:0:8}" \
         "${1:-·}" "$detail" "$kind" >> "$log"
}

if [ "$event" = "SessionEnd" ]; then
  note "(bye)"
  rm -f "$f" "$dir/.$session.pid" "$dir/.$session.agents" "$dir/.$session.parked" "$dir/.$session.compact"
  exit 0
fi

current() { cut -f1 "$f" 2>/dev/null; }

# ---- compactar ----
# Un /compact manual no es un turno: no llega ningún Stop detrás, y la mascota se
# quedaba "tidying up…" para siempre. PreCompact guarda qué hacía la sesión, y
# PostCompact vuelve a eso: a trabajar si fue una compactación automática en mitad
# de un turno, y a reposo (sin aviso) si fue manual o la sesión estaba parada.
compact_f="$dir/.$session.compact"
if [ "$event" = "PreCompact" ]; then
  current > "$compact_f" 2>/dev/null
elif [ "$event" = "PostCompact" ]; then
  prev="$(cat "$compact_f" 2>/dev/null)"; rm -f "$compact_f"
  detail=""
  case "$prev" in
    thinking|reading|writing|running|searching|delegating) state="thinking" ;;
    *) state="idle" ;;
  esac
  [ "$trigger" = "manual" ] && state="idle"
fi

# ---- errores de la API: StopFailure dice cuál ----
if [ "$event" = "StopFailure" ]; then
  state="error"
  case "$errkind" in
    rate_limit) detail="usage limit reached" ;;       overloaded) detail="API overloaded" ;;
    authentication_failed) detail="login expired" ;;  oauth_org_not_allowed) detail="login not allowed" ;;
    account_on_hold) detail="account on hold" ;;      billing_error) detail="billing problem" ;;
    invalid_request) detail="invalid request" ;;      model_not_found) detail="model not found" ;;
    server_error) detail="server error" ;;            max_output_tokens) detail="answer too long" ;;
    cloud_credential_error) detail="cloud credentials" ;;
    ""|unknown) detail="api" ;;
    *) detail="$(printf '%s' "$errkind" | tr '_' ' ' | cut -c1-34)" ;;
  esac
fi
# el principio de la respuesta, para la notificación del sistema
[ "$event" = "Stop" ] && [ -n "$snippet" ] && detail="$snippet"

# ---- ayudantes (subagentes) ----
# Lo que pasa dentro de un subagente trae agent_id. Un ayudante nunca termina la
# sesión ni tapa un permiso pendiente del hilo principal. Si el hilo principal acaba
# su turno con ayudantes en marcha (en segundo plano), la sesión queda "aparcada"
# trabajando, y el aviso de "terminado" llega cuando acaba de verdad.
agents_f="$dir/.$session.agents"; parked_f="$dir/.$session.parked"
now_s=$(date +%s)
prune_agents() {   # quita los que llevan media hora sin SubagentStop
  [ -f "$agents_f" ] || return 0
  awk -v now="$now_s" -v drop="${1:-}" 'NF == 2 && now - $2 < 1800 && $1 != drop' "$agents_f" > "$agents_f.tmp" 2>/dev/null
  if [ -s "$agents_f.tmp" ]; then mv -f "$agents_f.tmp" "$agents_f"; else rm -f "$agents_f" "$agents_f.tmp"; fi
}
n_agents() { [ -f "$agents_f" ] && grep -c . "$agents_f" 2>/dev/null || echo 0; }
prune_agents
if [ "$event" = "SubagentStart" ]; then
  printf '%s %s\n' "${agent:-anon-$now_s}" "$now_s" >> "$agents_f"
  [ "$(current)" = "waiting" ] && { note "(helper+)"; exit 0; }
  state="delegating"
  if [ -f "$parked_f" ]; then detail="$(n_agents) in background"; else detail="${agent_type:-helper}"; fi
elif [ "$event" = "SubagentStop" ]; then
  prune_agents "$agent"
  [ -f "$parked_f" ] || { note "(helper-)"; exit 0; }     # el hilo principal sigue: él dirá
  if [ "$(n_agents)" -gt 0 ]; then
    state="delegating"; detail="$(n_agents) in background"
  else
    # el último acabó: Claude Code despierta al hilo principal; si no lo hace en un
    # rato, la app lo da por terminado
    rm -f "$parked_f"; state="thinking"; detail=""
  fi
elif [ -n "$agent" ]; then
  if [ "$(current)" = "waiting" ] && [ "$state" != "waiting" ]; then note "(helper)"; exit 0; fi
elif [ "$event" != "Notification" ] && [ "$event" != "Stop" ] && [ "$event" != "StopFailure" ]; then
  rm -f "$parked_f"   # el hilo principal vuelve a estar activo
fi

# una notificación que no es un estado no pisa lo que la pet ya tenía
[ -z "$state" ] && { note "(ignored)"; exit 0; }

# La notificación de permiso llega 6 s después del diálogo (y sólo si no tocaste
# el teclado): para entonces PermissionRequest ya lo contó, y con más detalle. No
# se pisa "ok to run tests?" con un "needs your ok!" genérico.
if [ "$event" = "Notification" ] && [ -f "$f" ] && [ "$(cut -f1 "$f" 2>/dev/null)" = "waiting" ]; then
  note "(already)"; exit 0
fi

# mtime / tamaño en segundos/bytes, igual en macOS (BSD) y en Linux (GNU)
# (GNU primero: en Linux `stat -f` existe pero significa otra cosa y no falla)
num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
mtime() { num "$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)"; }
fsize() { num "$(stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null)"; }

if [ "$event" = "Stop" ] && [ -z "$agent" ] && [ "$(n_agents)" -gt 0 ]; then
  state="delegating"; detail="$(n_agents) in background"; : > "$parked_f"
elif [ "$state" = "done" ]; then
  # Stop también corre cuando cortás con Esc a mitad de una herramienta. Eso no es
  # una respuesta que llegó: el transcript termina en "[Request interrupted by
  # user]", y el PostToolUseFailure de justo antes ya dejó un `stopped` fresco.
  # Y si el turno terminó por un error de la API (sobrecarga, límite de uso...), el
  # último mensaje del asistente viene marcado `isApiErrorMessage`: eso tampoco es
  # un "¡listo!", es un `error` - que la mascota avisa en rojo.
  age=$(( $(date +%s) - $(mtime "$f") ))
  if [ -f "$f" ] && [ "$(cut -f1 "$f" 2>/dev/null)" = "stopped" ] && [ "$age" -lt 30 ]; then
    state="stopped"
  elif [ -n "$jq_bin" ] && [ -n "$transcript" ] && [ -r "$transcript" ]; then
    ending="$(tail -n 60 "$transcript" 2>/dev/null | "$jq_bin" -Rr '
      fromjson? | select(.type == "user" or .type == "assistant")
      | if .type == "assistant" and (.isApiErrorMessage // false) == true then "error"
        elif .type == "user" then
          ( .message.content
            | if type == "string" then . else (map(.text? // "") | join(" ")) end
            | if startswith("[Request interrupted by user") then "cut" else "ok" end )
        else "ok" end' 2>/dev/null | tail -n 1)"
    case "$ending" in
      cut)   state="stopped" ;;
      error) state="error"; detail="${detail:-api}" ;;
    esac
  fi
fi

# ---- el proceso de la sesión ----
# El hook es hijo (o nieto, según el shell) del `claude` de esta sesión. Su pid va
# en el archivo para que la pet compruebe que sigue vivo. Se cachea por sesión:
# tres `ps` por evento es poco, pero cero es menos.
pidf="$dir/.$session.pid"
pid="$(cat "$pidf" 2>/dev/null)"
if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
  pid=""; p=$PPID
  for _ in 1 2 3 4 5 6; do
    [ -z "$p" ] || [ "$p" -le 1 ] && break
    cmd="$(ps -o command= -p "$p" 2>/dev/null)"
    case "$cmd" in
      claude|claude\ *|*/claude|*/claude\ *|*/claude/versions/*|*node*claude*|*bun*claude*) pid="$p"; break ;;
    esac
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  done
  [ -n "$pid" ] && printf '%s' "$pid" > "$pidf"
fi

note "$state"
tmp="$f.$$.tmp"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$state" "$detail" "$pid" "$event" "$project" "$transcript" > "$tmp" && mv -f "$tmp" "$f"

if { [ "$state" = "done" ] || [ "$state" = "stopped" ] || [ "$state" = "error" ]; } && [ -z "$agent" ]; then
  # Sesiones que se murieron sin llegar a SessionEnd. Antes se borraba TODO lo que
  # llevara media hora sin tocarse, y eso incluía un permiso esperándote mientras
  # comías: volvías y la mascota ya no sabía que había algo pendiente. Ahora sólo
  # se borra lo que tiene el pid de un proceso muerto, o lo que no tiene pid y es
  # viejo (hooks antiguos).
  for g in "$dir"/*; do
    [ -f "$g" ] || continue
    case "$g" in *.tmp) [ $(( $(date +%s) - $(mtime "$g") )) -gt 60 ] && rm -f "$g"; continue ;; esac
    gp="$(cut -f3 "$g" 2>/dev/null)"
    if [ -n "$gp" ]; then
      gn="$(basename "$g")"
      kill -0 "$gp" 2>/dev/null || ps -p "$gp" >/dev/null 2>&1 || rm -f "$g" "$dir/.$gn.pid" "$dir/.$gn.agents" "$dir/.$gn.parked" "$dir/.$gn.compact"
    elif [ $(( $(date +%s) - $(mtime "$g") )) -gt 1800 ]; then
      rm -f "$g" "$dir/.$(basename "$g").agents" "$dir/.$(basename "$g").parked"
    fi
  done
  if [ "$(fsize "$log")" -gt 400000 ]; then
    tail -n 3000 "$log" > "$log.tmp" 2>/dev/null && mv -f "$log.tmp" "$log"
  fi
fi
exit 0
