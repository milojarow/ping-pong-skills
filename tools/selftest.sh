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
inactive() { ! active "$1"; }
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
  env PP_SESSION="$oldOwner" "$pp" --await "$channel" --wait 10 > "$caseRoot/old-reader.out" 2>&1 &
  oldReader=$!
  actorPids+=("$oldReader")
  deadline=$((SECONDS + 2))
  while [ "$SECONDS" -lt "$deadline" ]; do kill -0 "$oldReader"; sleep 0.1; done
  # Pause only outside the critical section, otherwise adoption would correctly
  # wait for the suspended reader to release its lock.
  deadline=$((SECONDS + 5))
  while :; do
    kill -STOP "$oldReader"
    if flock -n "$XDG_STATE_HOME/ping-pong/$channel.a.mail-lock" true; then break; fi
    kill -CONT "$oldReader"
    [ "$SECONDS" -lt "$deadline" ]
    sleep 0.1
  done
  start_actor claude replacement
  request replacement "$pp" --adopt "$channel"
  request replacement "$pp" --keep "$channel"
  kill -CONT "$oldReader"
  send_mail belongs-to-replacement
  wait "$oldReader" || [ "$?" = 1 ]
  assert_absent '^belongs-to-replacement$' "$caseRoot/old-reader.out"
  request replacement "$pp" --await "$channel" --wait 2
  rg -q '^belongs-to-replacement$' "$lastRequest.out"
}

version() { bash "$repo/tools/check-version-chain.sh"; }

cleanup_case() {
  local dir id side pid
  for dir in "$PP_BUS_ROOT"/pp-*; do
    [ -d "$dir" ] || continue
    id=${dir##*/}
    for side in a b; do
      systemctl --user stop "pp-keep-$id-$side.service" >/dev/null 2>&1 || true
      systemctl --user reset-failed "pp-keep-$id-$side.service" >/dev/null 2>&1 || true
    done
  done
  for pid in "${actorPids[@]}"; do
    kill -CONT "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}

if [ "${1:-}" = --case ]; then
    set -eE
    caseName=$2
    caseRoot="$testRoot/$caseName"
    export XDG_CONFIG_HOME="$caseRoot/config" XDG_STATE_HOME="$caseRoot/state" PP_BUS_ROOT="$caseRoot/bus"
    mkdir -p "$XDG_CONFIG_HOME/ping-pong" "$XDG_STATE_HOME" "$PP_BUS_ROOT"
    printf 'bus_mode=local\nbus_ssh=\n' > "$XDG_CONFIG_HOME/ping-pong/config"
    actorPids=() requestCount=0 lastRequest= channel=
    trap cleanup_case EXIT
    trap 'exit 124' TERM INT HUP
    trap 'printf "failed: %s\n" "$BASH_COMMAND" >&2' ERR
    "$caseName"
    exit
fi

failures=0
for caseName in identity_claude identity_codex identity_grok identity_human \
  keeper_codex keeper_grok same_machine mail_restart mail_concurrent mail_close pid_reuse stale_await version; do
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
