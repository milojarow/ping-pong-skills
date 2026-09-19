#!/usr/bin/env bash
# Exercise the real CLI and user-systemd keepers on an isolated local bus.
set -euo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
if [ "${PP_SELFTEST_ISOLATED:-0}" != 1 ]; then
  exec systemd-run --user --quiet --wait --pipe --collect \
    --unit="pp-selftest-$(date +%s)-$$" \
    --setenv=PP_SELFTEST_ISOLATED=1 \
    --setenv=PP_SELFTEST_LOG_DIR="${PP_SELFTEST_LOG_DIR:-}" \
    -- "$repo/tools/selftest.sh"
fi

unset PP_SESSION PP_SIDE PP_SESSION_BIRTH
export PP_LEASH_POLL=1 PP_AWAIT_POLL=1 PP_SEND_GRACE=3 PP_SEND_TIMEOUT=5
pp="$repo/skills/ping-pong/bin/pp"
if [ "${1:-}" = --case ]; then
  testRoot=$3
else
  testRoot=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/pp-selftest-XXXXXXXX")
  trap 'gio trash "$testRoot"' EXIT
  mkdir -p "$testRoot/bin"
  cat > "$testRoot/bin/actor" <<'ACTOR'
#!/bin/bash
set -uo pipefail
actorDir=$1
exec 3<>"$actorDir/requests"
printf '%s\n' "$$" > "$actorDir/pid"
while IFS= read -r request <&3; do
  bash "$request" > "$request.out" 2>&1
  printf '%s\n' "$?" > "$request.rc"
done
ACTOR
for harness in claude codex grok; do
  cp "$testRoot/bin/actor" "$testRoot/bin/$harness"
  chmod +x "$testRoot/bin/$harness"
done
fi

wait_until() {
  local deadline=$((SECONDS + 15))
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

start_actor() {
  local harness=$1 tag=$2
  mkdir -p "$caseRoot/$tag"
  mkfifo "$caseRoot/$tag/requests"
  "$testRoot/bin/$harness" "$caseRoot/$tag" &
  actorPids+=("$!")
  wait_until test -s "$caseRoot/$tag/pid"
  [ "$(cat "/proc/$(cat "$caseRoot/$tag/pid")/comm")" = "$harness" ]
}

request() {
  local tag=$1
  shift
  requestCount=$((requestCount + 1))
  lastRequest="$caseRoot/$tag/request-$requestCount"
  printf '%q ' "$@" > "$lastRequest"
  printf '\n' >> "$lastRequest"
  printf '%s\n' "$lastRequest" > "$caseRoot/$tag/requests"
  wait_until test -f "$lastRequest.rc"
  if [ "$(cat "$lastRequest.rc")" != 0 ]; then
    cat "$lastRequest.out"
    return 1
  fi
}

open_actor() {
  request "$1" "$pp" --open --topic selftest --as "$1"
  channel=$(sed -n 's/^Channel open: //p' "$lastRequest.out")
  [[ "$channel" =~ ^pp-[a-z0-9]+$ ]]
}

active() { systemctl --user is-active --quiet "pp-keep-$channel-$1.service"; }
inactive() {
  local unit="pp-keep-$channel-$1.service" state pid
  state=$(systemctl --user show "$unit" -p ActiveState --value)
  pid=$(systemctl --user show "$unit" -p MainPID --value)
  [ "$state" = inactive ] && [ "$pid" = 0 ]
}
has_mail() { rg -l --fixed-strings "$1" "$XDG_STATE_HOME/ping-pong" >/dev/null; }
assert_absent() {
  if rg -q "$1" "$2"; then return 1; else [ "$?" = 1 ]; fi
}

setup_receiver() {
  start_actor claude receiver
  open_actor receiver
  request receiver "$pp" --keep "$channel"
  mkdir -p "$caseRoot/sender"
  env XDG_STATE_HOME="$caseRoot/sender" PP_SESSION=nosession \
    "$pp" --join "$channel" --as sender
}

send_mail() {
  env XDG_STATE_HOME="$caseRoot/sender" PP_SESSION=nosession \
    "$pp" --send "$channel" --as sender -m "$1"
  wait_until has_mail "$1"
}

identity() {
  local harness=$1
  start_actor "$harness" owner
  open_actor owner
  rg -q --fixed-strings "session $harness:$(cat "$caseRoot/owner/pid")" "$lastRequest.out"
}
identity_claude() { identity claude; }
identity_codex() { identity codex; }
identity_grok() { identity grok; }
identity_human() {
  "$pp" --open --topic human > "$caseRoot/human.out"
  rg -q 'session nosession' "$caseRoot/human.out"
}

keeper() {
  local harness=$1 pid deadline
  start_actor "$harness" owner
  open_actor owner
  request owner "$pp" --keep "$channel"
  deadline=$((SECONDS + 3))
  while [ "$SECONDS" -lt "$deadline" ]; do
    active a
    sleep 0.1
  done
  pid=$(cat "$caseRoot/owner/pid")
  kill -TERM "$pid"
  wait_until inactive a
  wait_until test ! -d "$PP_BUS_ROOT/$channel"
}
keeper_codex() { keeper codex; }
keeper_grok() { keeper grok; }

same_machine() {
  start_actor claude first
  start_actor claude second
  open_actor first
  # Legacy files must neither select a side nor override a current owner.
  printf 'b\n' > "$XDG_STATE_HOME/ping-pong/$channel.side"
  printf 'session=claude:1\n' > "$XDG_STATE_HOME/ping-pong/$channel.owner"
  request second "$pp" --join "$channel" --as second
  request first "$pp" --keep "$channel"
  request second "$pp" --keep "$channel"
  test -f "$XDG_STATE_HOME/ping-pong/$channel.a.inbox"
  test -f "$XDG_STATE_HOME/ping-pong/$channel.b.inbox"
  request first "$pp" --send "$channel" -m only-to-b
  request second "$pp" --await "$channel" --wait 3
  rg -q '^only-to-b$' "$lastRequest.out"
  assert_absent '^only-to-b$' "$XDG_STATE_HOME/ping-pong/$channel.a.inbox"
  request second "$pp" --send "$channel" -m only-to-a
  request first "$pp" --await "$channel" --wait 3
  rg -q '^only-to-a$' "$lastRequest.out"
  assert_absent '^only-to-a$' "$XDG_STATE_HOME/ping-pong/$channel.b.inbox"
  request first "$pp" --close "$channel"
  wait_until inactive a
  wait_until inactive b
}

mail_restart() {
  setup_receiver
  send_mail survives-restart
  request receiver "$pp" --unkeep "$channel"
  request receiver "$pp" --keep "$channel"
  request receiver "$pp" --await "$channel" --wait 3
  rg -q '^survives-restart$' "$lastRequest.out"
}

mail_concurrent() {
  setup_receiver
  local owner="claude:$(cat "$caseRoot/receiver/pid")" first second deadline count
  env PP_SESSION="$owner" "$pp" --await "$channel" --wait 4 > "$caseRoot/read-1" 2>&1 &
  first=$!
  actorPids+=("$first")
  env PP_SESSION="$owner" "$pp" --await "$channel" --wait 4 > "$caseRoot/read-2" 2>&1 &
  second=$!
  actorPids+=("$second")
  # Both readers must remain blocked before the positive probe.
  deadline=$((SECONDS + 2))
  while [ "$SECONDS" -lt "$deadline" ]; do
    kill -0 "$first" "$second"
    sleep 0.1
  done
  send_mail exactly-one-reader
  wait "$first" || [ "$?" = 124 ]
  wait "$second" || [ "$?" = 124 ]
  count=$(cat "$caseRoot/read-1" "$caseRoot/read-2" | rg -c '^exactly-one-reader$')
  [ "$count" = 1 ]
}

mail_close() {
  setup_receiver
  send_mail survives-close
  request receiver "$pp" --close "$channel"
  rg -qi 'unread|pending' "$lastRequest.out"
  request receiver "$pp" --gc
  wait_until has_mail survives-close
  request receiver "$pp" --await "$channel" --wait 2
  rg -q '^survives-close$' "$lastRequest.out"
}

pid_reuse() {
  setup_receiver
  request receiver "$pp" --unkeep "$channel"
  local ownerFile="$XDG_STATE_HOME/ping-pong/$channel.a.owner"
  rg -q '^birth=' "$ownerFile"
  sed -i 's/^birth=.*/birth=wrong-process-incarnation/' "$ownerFile"
  request receiver "$pp" --info "$channel"
  rg -q 'gone|stale' "$lastRequest.out"
}

stale_await() {
  setup_receiver
  local oldReader oldOwner="claude:$(cat "$caseRoot/receiver/pid")" deadline
  env PP_SESSION="$oldOwner" PP_AWAIT_POLL=10 "$pp" --await "$channel" --wait 40 > "$caseRoot/old-reader.out" 2>&1 &
  oldReader=$!
  actorPids+=("$oldReader")
  # Pause in the idle sleep, not halfway through keeper_state: a suspended
  # command substitution can otherwise cache "inactive" during adoption and
  # exit 3 before exercising the ownership recheck at all.
  local pauseTarget=
  reader_sleeping() {
    pauseTarget=$(python3 - "$oldReader" <<'TREE'
from pathlib import Path
import sys
pending=[int(sys.argv[1])]
while pending:
    pid=pending.pop()
    try:
        children=Path(f'/proc/{pid}/task/{pid}/children').read_text().split()
        for child in children:
            if Path(f'/proc/{child}/comm').read_text().strip() == 'sleep':
                print(pid)
                raise SystemExit(0)
            pending.append(int(child))
    except (FileNotFoundError, ProcessLookupError):
        pass
raise SystemExit(1)
TREE
    )
  }
  wait_until reader_sleeping
  actorPids+=("$pauseTarget")
  kill -STOP "$pauseTarget"
  flock -n "$XDG_STATE_HOME/ping-pong/$channel.a.mail-lock" true
  start_actor claude replacement
  request replacement "$pp" --adopt "$channel"
  request replacement "$pp" --keep "$channel"
  kill -CONT "$pauseTarget"
  send_mail belongs-to-replacement
  wait "$oldReader" || [ "$?" = 1 ]
  assert_absent '^belongs-to-replacement$' "$caseRoot/old-reader.out"
  request replacement "$pp" --await "$channel" --wait 2
  rg -q '^belongs-to-replacement$' "$lastRequest.out"
}

adopt_during_drain() {
  setup_receiver
  start_actor claude replacement
  local owner="claude:$(cat "$caseRoot/receiver/pid")" drainer adopter
  { printf 'held-drain\n'; head -c 262144 /dev/zero | tr '\0' x; printf '\n'; } > "$caseRoot/large-message"
  env XDG_STATE_HOME="$caseRoot/sender" PP_SESSION=nosession \
    "$pp" --send "$channel" < "$caseRoot/large-message"
  wait_until has_mail held-drain
  # Real stdout backpressure holds dd inside the drain transaction.
  (
    env PP_SESSION="$owner" "$pp" --await "$channel" --wait 3 |
      { IFS= read -r header; printf '%s\n' "$header" > "$caseRoot/drain-started"
        wait_until test -f "$caseRoot/release-drain"
        cat > "$caseRoot/drained-body"; }
  ) &
  drainer=$!; actorPids+=("$drainer")
  wait_until test -s "$caseRoot/drain-started"
  ( request replacement "$pp" --adopt "$channel" ) &
  adopter=$!; actorPids+=("$adopter")
  wait_until inactive a
  kill -0 "$adopter"
  rg -qx "session=$owner" "$XDG_STATE_HOME/ping-pong/$channel.a.owner"
  touch "$caseRoot/release-drain"
  wait "$drainer"
  wait "$adopter"
  cmp "$caseRoot/large-message" "$caseRoot/drained-body"
  rg -qx "session=claude:$(cat "$caseRoot/replacement/pid")" "$XDG_STATE_HOME/ping-pong/$channel.a.owner"
}

protected_unkeep() {
  setup_receiver
  start_actor claude outsider
  if request outsider "$pp" --unkeep "$channel"; then return 1; fi
  active a
}

leash_mail() {
  local journalSince; journalSince=$(date --iso-8601=seconds)
  setup_receiver
  send_mail survives-owner-death
  kill -TERM "$(cat "$caseRoot/receiver/pid")"
  wait_until inactive a
  test ! -d "$PP_BUS_ROOT/$channel"
  test -f "$XDG_STATE_HOME/ping-pong/$channel.a.closed"
  has_mail survives-owner-death
  # A short-lived child can log before journald resolves its user-unit field.
  # Match the unique channel and executable, not only _SYSTEMD_USER_UNIT.
  journal_has_pending() {
    journalctl --user --since "$journalSince" -t pp --grep="$channel" \
      --no-pager -o cat > "$caseRoot/keeper-journal"
    rg -q "^pp: channel $channel side a .*UNREAD" "$caseRoot/keeper-journal"
  }
  wait_until journal_has_pending
  env PP_SESSION=nosession "$pp" --await "$channel" --wait 2 > "$caseRoot/recovered"
  rg -q '^survives-owner-death$' "$caseRoot/recovered"
}

whoami() {
  local harness
  for harness in claude codex grok; do
    start_actor "$harness" "$harness"
    request "$harness" "$pp" --whoami
    rg -qx "harness=$harness" "$lastRequest.out"
    rg -qx "session=$harness:$(cat "$caseRoot/$harness/pid")" "$lastRequest.out"
    rg -q "/reference/harness-$harness.md$" "$lastRequest.out"
  done
  "$pp" --whoami > "$caseRoot/human"
  rg -qx 'session=nosession' "$caseRoot/human"
  env PP_SESSION=grok:123 "$pp" --whoami > "$caseRoot/override"
  rg -qx 'session=grok:123' "$caseRoot/override"
}

setup_wake() {
  start_actor codex receiver
  open_actor receiver
  request receiver "$pp" --keep "$channel"
  mkdir -p "$caseRoot/fake-bin" "$caseRoot/sender"
  # Record argv as JSON, without running an agent or touching its queue.
  python3 - "$caseRoot" <<'FAKE'
import pathlib, sys
root=pathlib.Path(sys.argv[1])
f=root/'fake-bin/codex'
f.write_text("#!/usr/bin/python3\nimport json, pathlib, sys\nr=pathlib.Path("+repr(str(root))+" )\nwith (r/'queue.jsonl').open('a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\nmode=(r/'queue-mode').read_text().strip() if (r/'queue-mode').exists() else ''\ncount=len((r/'queue.jsonl').read_text().splitlines())\nsys.exit(1 if mode=='fail' or (mode=='once' and count==1) else 0)\n")
f.chmod(0o755)
FAKE
  env XDG_STATE_HOME="$caseRoot/sender" PP_SESSION=nosession "$pp" --join "$channel" --as sender
}
arm_wake() {
  request receiver env PATH="$caseRoot/fake-bin:$PATH" \
    CODEX_THREAD_ID=11111111-2222-3333-4444-555555555555 \
    PP_WAKE_RETRY_DELAY=1 PP_WAKE_TIMEOUT=2 PP_LEASH_POLL=1 \
    "$pp" --wake "$channel"
}
queue_count() {
  local count=0
  [ ! -f "$caseRoot/queue.jsonl" ] || count=$(wc -l < "$caseRoot/queue.jsonl")
  [ "$count" = "$1" ]
}
quiet_queue() {
  local expected=$1 deadline=$((SECONDS + 3))
  while [ "$SECONDS" -lt "$deadline" ]; do queue_count "$expected"; sleep 0.1; done
}
wake_batch() {
  setup_wake
  arm_wake
  quiet_queue 0
  send_mail 'PEER-BODY $(touch never) --message injected'
  wait_until queue_count 1
  send_mail second-undrained
  quiet_queue 1
  # Rearming a stopped unit must not ring again for the same cursor.
  request receiver "$pp" --unwake "$channel"
  arm_wake
  quiet_queue 1
  request receiver "$pp" --await "$channel" --wait 2
  send_mail after-drain
  wait_until queue_count 2
  python3 - "$caseRoot/queue.jsonl" "$channel" <<'CHECK'
import json, sys
rows=[json.loads(x) for x in open(sys.argv[1])]
expected=['queue','--thread','11111111-2222-3333-4444-555555555555','--message',f'Ping-pong: drain channel {sys.argv[2]} with pp --await {sys.argv[2]}.']
assert rows == [expected, expected], rows
CHECK
}
wake_retry() {
  setup_wake
  printf 'once\n' > "$caseRoot/queue-mode"
  arm_wake
  send_mail retry-once
  wait_until queue_count 2
  quiet_queue 2
  request receiver "$pp" --await "$channel" --wait 2
  printf 'fail\n' > "$caseRoot/queue-mode"
  send_mail retry-exhausted
  wait_until queue_count 5
  quiet_queue 5
  test -s "$XDG_STATE_HOME/ping-pong/$channel.a.inbox"
}
wake_dead() {
  setup_wake
  printf 'fail\n' > "$caseRoot/queue-mode"
  arm_wake
  send_mail pending-when-owner-dies
  wait_until queue_count 1
  kill -TERM "$(cat "$caseRoot/receiver/pid")"
  wait_until inactive a
  quiet_queue 1
  local state pid
  state=$(systemctl --user show "pp-wake-$channel-a.service" -p ActiveState --value)
  pid=$(systemctl --user show "pp-wake-$channel-a.service" -p MainPID --value)
  [ "$state" = inactive ] && [ "$pid" = 0 ]
  env PP_SESSION=nosession "$pp" --await "$channel" > "$caseRoot/recovered"
  rg -q '^pending-when-owner-dies$' "$caseRoot/recovered"
}
wake_reject() {
  setup_wake
  if request receiver env -u CODEX_THREAD_ID "$pp" --wake "$channel"; then return 1; fi
  if request receiver env CODEX_THREAD_ID=not-a-uuid "$pp" --wake "$channel"; then return 1; fi
  start_actor grok outsider
  if request outsider env CODEX_THREAD_ID=11111111-2222-3333-4444-555555555555 "$pp" --wake "$channel"; then return 1; fi
  queue_count 0
  arm_wake
  systemctl --user is-active --quiet "pp-wake-$channel-a.service"
}

install_fixture() {
  installHome="$caseRoot/home"
  canonical="$installHome/.claude/plugins/marketplaces/ping-pong-skills/skills/ping-pong"
  mkdir -p "$(dirname "$canonical")"
  cp -a "$repo/skills/ping-pong" "$canonical"
}
install_links() {
  install_fixture
  if env HOME="$installHome" "$pp" --install --check; then return 1; fi
  env HOME="$installHome" "$pp" --install
  env HOME="$installHome" "$pp" --install
  env HOME="$installHome" "$pp" --install --check
  test -L "$installHome/.local/bin/pp"
  test -L "$installHome/.codex/skills/ping-pong"
  test "$installHome/.local/bin/pp" -ef "$canonical/bin/pp"
  test "$installHome/.codex/skills/ping-pong/SKILL.md" -ef "$canonical/SKILL.md"
}
install_old() {
  install_fixture
  mkdir -p "$installHome/.codex/skills" "$installHome/.local/bin"
  cp -a "$canonical" "$installHome/.codex/skills/ping-pong"
  cp "$canonical/bin/pp" "$installHome/.local/bin/pp"
  env HOME="$installHome" "$pp" --install > "$caseRoot/install.out"
  rg -q 'legacy.*backup' "$caseRoot/install.out"
  env HOME="$installHome" "$pp" --install --check
  local backups=("$installHome/.codex/skills/"ping-pong.pre-link-*)
  [ "${#backups[@]}" = 1 ]
  cmp "${backups[0]}/SKILL.md" "$canonical/SKILL.md"
}
install_refuse() {
  install_fixture
  mkdir -p "$installHome/.codex/skills/ping-pong" "$installHome/.local/bin"
  printf 'unrelated\n' > "$installHome/.codex/skills/ping-pong/precious"
  if env HOME="$installHome" "$pp" --install; then return 1; fi
  test ! -e "$installHome/.local/bin/pp"
  rg -qx unrelated "$installHome/.codex/skills/ping-pong/precious"
  gio trash "$installHome/.codex/skills/ping-pong"
  ln -s "$caseRoot" "$installHome/.local/bin/pp"
  if env HOME="$installHome" "$pp" --install; then return 1; fi
  [ "$(readlink "$installHome/.local/bin/pp")" = "$caseRoot" ]
  test ! -e "$installHome/.codex/skills/ping-pong"
}

version() { bash "$repo/tools/check-version-chain.sh"; }

cleanup_case() {
  local side pid status=0
  # The channel may already have been deleted by a successful close/leash.
  # Its recorded id still names both units; a missing bus directory is not proof
  # that either cgroup has finished shutting down.
  if [ -n "$channel" ]; then
    for side in a b; do
      systemctl --user stop "pp-wake-$channel-$side.service" >/dev/null 2>&1 || true
      systemctl --user reset-failed "pp-wake-$channel-$side.service" >/dev/null 2>&1 || true
      local wakeState wakePid
      wakeState=$(systemctl --user show "pp-wake-$channel-$side.service" -p ActiveState --value)
      wakePid=$(systemctl --user show "pp-wake-$channel-$side.service" -p MainPID --value)
      [ "$wakeState" = inactive ] && [ "$wakePid" = 0 ] || status=1
      systemctl --user stop "pp-keep-$channel-$side.service" >/dev/null 2>&1 || true
      systemctl --user reset-failed "pp-keep-$channel-$side.service" >/dev/null 2>&1 || true
      wait_until inactive "$side" || status=1
    done
  fi
  for pid in "${actorPids[@]}"; do
    kill -CONT "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  return "$status"
}

if [ "${1:-}" = --case ]; then
    set -eE
    caseName=$2
    caseRoot="$testRoot/$caseName"
    export XDG_CONFIG_HOME="$caseRoot/config" XDG_STATE_HOME="$caseRoot/state" PP_BUS_ROOT="$caseRoot/bus"
    mkdir -p "$XDG_CONFIG_HOME/ping-pong" "$XDG_STATE_HOME" "$PP_BUS_ROOT"
    printf 'bus_mode=local\nbus_ssh=\n' > "$XDG_CONFIG_HOME/ping-pong/config"
    actorPids=() requestCount=0 lastRequest= channel=
    trap 'caseStatus=$?; cleanup_case || caseStatus=1; exit "$caseStatus"' EXIT
    trap 'exit 124' TERM INT HUP
    trap 'printf "failed: %s\n" "$BASH_COMMAND" >&2' ERR
    "$caseName"
    exit
fi

failures=0
for caseName in identity_claude identity_codex identity_grok identity_human \
  keeper_codex keeper_grok same_machine mail_restart mail_concurrent mail_close pid_reuse \
  stale_await adopt_during_drain protected_unkeep leash_mail version \
  whoami wake_batch wake_retry wake_dead wake_reject install_links install_old install_refuse; do
  timeout --kill-after=10 60 "$repo/tools/selftest.sh" --case "$caseName" "$testRoot" > "$testRoot/$caseName.log" 2>&1 &
  casePid=$!
  if wait "$casePid"; then
    printf 'PASA %s\n' "$caseName"
  else
    printf 'NO PASA %s\n' "$caseName"
    failures=$((failures + 1))
  fi
  if [ -n "${PP_SELFTEST_LOG_DIR:-}" ]; then
    mkdir -p "$PP_SELFTEST_LOG_DIR"
    cp "$testRoot/$caseName.log" "$PP_SELFTEST_LOG_DIR/$caseName.log"
  fi
done
[ "$failures" = 0 ]
