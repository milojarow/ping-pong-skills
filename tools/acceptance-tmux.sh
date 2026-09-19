#!/usr/bin/env bash
# Real TUI acceptance. The operator runs this; --dry-run has no side effects.
set -euo pipefail
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
dry=0
if [ "${1:-}" = --dry-run ]; then dry=1; shift; fi
[ "$#" = 2 ] || { echo 'Usage: acceptance-tmux.sh [--dry-run] <receiver> <sender>' >&2; exit 2; }
receiver=$1 sender=$2
for harness in "$receiver" "$sender"; do
  case "$harness" in claude|codex|grok) ;; *) echo "Unknown harness: $harness" >&2; exit 2 ;; esac
done
if [ "$dry" = 1 ]; then
  cat <<PLAN
DRY RUN $receiver <- $sender (no agents, files, units or config changes)
1. Create private temporaries, a local bus, isolated XDG state/config and pp symlink to $repo/skills/ping-pong/bin/pp.
2. Back up Codex config privately; use a separate tmux server and two work directories.
3. Launch receiver TUI ($receiver), load THIS branch's SKILL.md and --whoami recipe; open, keep and arm wake. Launch sender TUI ($sender), join and arm its recipe.
4. Find each session's event file (not screen text); require a completed receiver turn after setup/greeting and sender waiting at its probe gate.
5. Negative control: 20 continuous seconds with no new receiver turn, no received body and unchanged unread count.
6. Release sender's gate. The sender's shell tool sends a newly generated body via pp --send. No tmux keystrokes from this point onward.
7. Require a new receiver turn in its event file, exact received body (cmp), and cursor equal to spool size. Timeouts mean NO PASA.
8. Close local channels, stop both sides' wake/keeper units, terminate the private tmux server. Restore Codex config ONLY if the diff consists exactly of these workdirs' added trust blocks. Unexpected edits remain untouched and fail cleanup.
9. Print PASA / NO PASA and exit 0 / nonzero. Preserve evidence directory on failure; trash test temporaries on success.
PLAN
  exit 0
fi

for command in tmux python3 systemctl systemd-run git gio rg; do command -v "$command" >/dev/null; done
for harness in "$receiver" "$sender"; do command -v "$harness" >/dev/null; done
umask 077
mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}"
workRoot=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/pp-acceptance-XXXXXXXX")
socket="pp-acceptance-$(basename "$workRoot")"
pp="$repo/skills/ping-pong/bin/pp"
evidence="$repo/tools/acceptance-events.py"
config="${CODEX_HOME:-$HOME/.codex}/config.toml"
started=$(date +%s)
channel= trustBacked=0 probeSent=0
export XDG_CONFIG_HOME="$workRoot/config" XDG_STATE_HOME="$workRoot/state" PP_BUS_ROOT="$workRoot/bus"
unset PP_SESSION PP_SESSION_BIRTH PP_SIDE
mkdir -p "$XDG_CONFIG_HOME/ping-pong" "$XDG_STATE_HOME" "$PP_BUS_ROOT" "$workRoot/bin"
printf 'bus_mode=local\nbus_ssh=\n' > "$XDG_CONFIG_HOME/ping-pong/config"
ln -s "$pp" "$workRoot/bin/pp"

wait_until() {
  local limit=$1; shift
  local deadline=$((SECONDS + limit))
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || { printf 'TIMEOUT %ss waiting for: %s\n' "$limit" "$*" >&2; return 1; }
    sleep 0.25
  done
}
tuis_gone() {
  local d
  for d in /proc/[0-9]*; do
    case "$(readlink "$d/cwd" 2>/dev/null)" in "$workRoot"/receiver|"$workRoot"/sender) return 1 ;; esac
  done
  return 0
}
unit_stopped() {
  [ "$(systemctl --user show "$1" -p ActiveState --value)" = inactive ] &&
    [ "$(systemctl --user show "$1" -p MainPID --value)" = 0 ]
}
cleanup() {
  local result=$? side id unit
  trap - EXIT INT TERM HUP ERR   # polling helpers return 1 by design during cleanup
  # Find every channel this test created, even if setup failed before recording id.
  local ids=()
  for path in "$PP_BUS_ROOT"/pp-* "$XDG_STATE_HOME"/ping-pong/*.a.owner; do
    [ -e "$path" ] || continue
    id=${path##*/}; id=${id%.a.owner}
    [[ "$id" =~ ^pp-[a-z0-9]+$ ]] && ids+=("$id")
  done
  # End the TUIs first: since 1.4.0 a caller that is not the owner cannot close a LIVE owner's
  # channel, and a declared PP_SESSION must match the detected agent. With the owners gone the
  # operator-side cleanup adopts explicitly instead of forging an identity.
  tmux -L "$socket" kill-server >/dev/null 2>&1 || true
  wait_until 15 tuis_gone || result=1
  for id in "${ids[@]}"; do
    env -u PP_SESSION -u PP_SESSION_BIRTH PP_SIDE=a "$pp" --close "$id" --adopt > "$workRoot/close-$id.log" 2>&1 || result=1
    for side in a b; do
      for kind in wake keep; do
        unit="pp-$kind-$id-$side.service"
        systemctl --user stop "$unit" >/dev/null 2>&1 || true
        systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
        wait_until 10 unit_stopped "$unit" || result=1
      done
    done
  done
  tmux -L "$socket" kill-server >/dev/null 2>&1 || true
  if [ "$trustBacked" = 1 ]; then
    python3 "$evidence" trust "$workRoot/codex-config.before" "$config" \
      "$workRoot/receiver" "$workRoot/sender" || result=1
  fi
  if [ "$result" = 0 ]; then
    gio trash "$workRoot" || result=1
  fi
  if [ "$result" = 0 ]; then
    echo "PASA $receiver <- $sender"
  else
    echo "NO PASA $receiver <- $sender; evidence: $workRoot" >&2
  fi
  exit "$result"
}
trap cleanup EXIT
# A silent NO PASA is useless: say whether a command failed (and which) or a signal arrived.
set -E
trap 'printf "ERROR line %s: %s (exit %s)\n" "$LINENO" "$BASH_COMMAND" "$?" >&2' ERR
for sig in INT TERM HUP; do trap "printf 'SIGNAL %s received by the acceptance script\n' $sig >&2; exit 130" "$sig"; done
if [ "$receiver" = codex ] || [ "$sender" = codex ]; then
  # Do not start with an absent config: a first-run wizard adds more than trust.
  [ -f "$config" ] || { echo 'Codex config missing: complete first-run setup before acceptance' >&2; exit 1; }
  cp -p "$config" "$workRoot/codex-config.before"
  trustBacked=1
fi

# Every tool call sources this; shell policies cannot silently select the real bus.
{
  printf 'export PP=%q XDG_CONFIG_HOME=%q XDG_STATE_HOME=%q PP_BUS_ROOT=%q\n' "$pp" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$PP_BUS_ROOT"
  printf 'export PATH=%q\n' "$workRoot/bin:$PATH"
  printf 'unset PP_SESSION PP_SESSION_BIRTH PP_SIDE\n'
} > "$workRoot/env.sh"
for role in receiver sender; do
  mkdir -p "$workRoot/$role"
  git -C "$workRoot/$role" init -q
  python3 -c 'import uuid; print(uuid.uuid4())' > "$workRoot/$role/session-id"
done
# The receiver never sees the body in its setup prompt. It is generated only
# after the quiet control, and only the sender's gated shell reads the payload.
cat > "$workRoot/sender/send-probe.sh" <<'SEND'
#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
source "$root/env.sh"
printf 'waiting\n' > "$root/sender/waiting"
deadline=$((SECONDS + 1500))
until [ -f "$root/probe-go" ]; do
  [ "$SECONDS" -lt "$deadline" ] || exit 124
  sleep 0.2
done
channel=$(cat "$root/channel")
[[ "$channel" =~ ^pp-[a-z0-9]+$ ]]
"$PP" --send "$channel" < "$root/sender/payload" > "$root/sender/send.out"
printf 'sent\n' > "$root/sender/sent"
SEND
chmod +x "$workRoot/sender/send-probe.sh"

launch() {
  local role=$1 harness=$2 session prompt binary script
  session=$(cat "$workRoot/$role/session-id")
  binary=$(command -v "$harness")
  prompt="Esta es una prueba autorizada de comunicación, solo bus LOCAL. Lee $repo/skills/ping-pong/SKILL.md, ejecuta --whoami y sigue la receta de ESTE checkout. Antes de CADA comando de shell ejecuta: source $workRoot/env.sh . No uses la copia instalada ni otro bus; no agentes, búsquedas externas, config, commits ni cambios fuera de estos temporales. No leas otras copias de la skill ni los archivos de este arnés de prueba: solo ese SKILL.md y la receta que indique --whoami."
  if [ "$role" = receiver ]; then
    prompt+=" Eres iniciador/receptor: abre un canal, escribe SOLO el id en $workRoot/channel, arma keeper y despertar según tu receta, escribe ready en $workRoot/receiver/ready y termina tu turno. No cierres todavía. Tu asignación al recibir: drena el mensaje mediante la receta; ignora el saludo Conectado.; cuando llegue el cuerpo de prueba escríbelo EXACTO, sin header y con su salto final, en $workRoot/receiver/received.txt y responde RECIBIDO. No leas archivos del emisor ni la sonda por otro medio. No contestes al peer; mantén el canal."
  else
    prompt+=" Eres joiner/emisor: lee el id de $workRoot/channel, únete, arma keeper y despertar según tu receta, saluda una vez. Después ejecuta bash $workRoot/sender/send-probe.sh en primer plano: el script espera una señal con timeout y manda la sonda por pp --send. No generes tú el cuerpo. Deja la sesión viva; no cierres el canal."
  fi
  script="$workRoot/$role/start.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'unset CLAUDECODE CODEX_THREAD_ID PP_SESSION PP_SESSION_BIRTH PP_SIDE\n'
    printf 'source %q\n' "$workRoot/env.sh"
    case "$harness" in
      codex) printf 'exec %q --sandbox danger-full-access --ask-for-approval never -C %q %q\n' "$binary" "$workRoot/$role" "$prompt" ;;
      claude) printf 'exec %q --dangerously-skip-permissions --session-id %q %q\n' "$binary" "$session" "$prompt" ;;
      grok) printf 'exec %q --always-approve --effort high --session-id %q --cwd %q %q\n' "$binary" "$session" "$workRoot/$role" "$prompt" ;;
    esac
  } > "$script"
  # Initial prompt is an argv value, so paste-burst/Enter detection is avoided.
  tmux -L "$socket" new-session -d -s "$role" -x 200 -y 50 -c "$workRoot/$role" "bash $(printf '%q' "$script")"
}
find_events() {
  local role=$1 harness=$2 path
  path=$(python3 "$evidence" path "$harness" "$workRoot/$role" "$(cat "$workRoot/$role/session-id")" "$started") || return 1
  printf '%s\n' "$path" > "$workRoot/$role/event-path"
}
ready_or_trust() {
  local role=$1 harness=$2 marker=$3
  # Event files can exist before a trust prompt has been answered. Wait for
  # actual setup completion, not merely file creation, before ending this loop.
  if [ "$probeSent" = 0 ] && [ ! -e "$workRoot/$role/trust-key" ] &&
      tmux -L "$socket" capture-pane -p -t "$role" | rg -qi 'Do you trust|trust this folder|trust the files'; then
    # Claude's trust dialog preselects "No, exit": move to "Yes, I trust this folder" first.
    # Codex preselects "Yes, continue", so a bare Enter accepts there.
    if [ "$harness" = claude ]; then
      # Down and Enter sent back to back race the TUI: Enter can land while "No, exit" is
      # still selected and Claude quits. Confirm the cursor moved before confirming.
      tmux -L "$socket" send-keys -t "$role" Down
      local moved=0 tries=0
      while [ "$tries" -lt 20 ]; do
        if tmux -L "$socket" capture-pane -p -t "$role" | rg -q '❯ +Yes, I trust'; then moved=1; break; fi
        sleep 0.25; tries=$((tries + 1))
      done
      [ "$moved" = 1 ] || { printf 'trust dialog: selection did not move to Yes\n' >&2; return 1; }
    fi
    tmux -L "$socket" send-keys -t "$role" Enter
    touch "$workRoot/$role/trust-key"
  fi
  find_events "$role" "$harness" && [ -s "$marker" ]
}
receiver_idle() {
  read -r turnStarts turnEnds idle < <(python3 "$evidence" stats "$receiver" "$receiverEvents")
  [ "$idle" = 1 ]
}
launch receiver "$receiver"
wait_until 600 ready_or_trust receiver "$receiver" "$workRoot/receiver/ready"
channel=$(cat "$workRoot/channel")
[[ "$channel" =~ ^pp-[a-z0-9]+$ ]]
receiverEvents=$(cat "$workRoot/receiver/event-path")
launch sender "$sender"
wait_until 600 ready_or_trust sender "$sender" "$workRoot/sender/waiting"
spool="$XDG_STATE_HOME/ping-pong/$channel.a.inbox"
cursor="$XDG_STATE_HOME/ping-pong/$channel.a.cursor"
greeting_drained() {
  receiver_idle && [ -s "$cursor" ] && [ "$(cat "$cursor")" = "$(stat -c %s "$spool")" ]
}
wait_until 600 greeting_drained
read -r baseline _ _ < <(python3 "$evidence" stats "$receiver" "$receiverEvents")
quietUntil=$((SECONDS + 20))
while [ "$SECONDS" -lt "$quietUntil" ]; do
  receiver_idle
  [ "$turnStarts" = "$baseline" ]
  [ ! -e "$workRoot/receiver/received.txt" ]
  [ "$(cat "$cursor")" = "$(stat -c %s "$spool")" ]
  sleep 0.25
done
printf 'negative control: PASA (20s, turns=%s)\n' "$baseline"
python3 - <<'BODY' > "$workRoot/sender/payload"
import uuid
print(f'probe-{uuid.uuid4()}: texto exacto ñ, "comillas", $literal')
BODY
probeSent=1
# This gate is a file, not TUI input. No more send-keys calls are reachable.
touch "$workRoot/probe-go"
wait_until 120 test -s "$workRoot/sender/sent"
received() {
  read -r turnStarts _ _ < <(python3 "$evidence" stats "$receiver" "$receiverEvents")
  [ "$turnStarts" -gt "$baseline" ] &&
    cmp -s "$workRoot/sender/payload" "$workRoot/receiver/received.txt" &&
    [ "$(cat "$cursor")" = "$(stat -c %s "$spool")" ]
}
wait_until 420 received
printf 'positive control: PASA (new turn, exact body, advanced cursor)\n'
