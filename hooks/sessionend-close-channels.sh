#!/usr/bin/env bash
# SessionEnd hook - close every ping-pong channel this session owns.
#
# WHY THIS EXISTS
# A channel outlives the session that opened it, and that is the dangerous kind
# of leftover: it costs nothing on disk, it looks exactly like a working channel,
# and the ownership guard helps in the WRONG direction - a dead owner means the
# next session adopts it with no friction. Measured on one box: 8 channels open,
# all four owning sessions dead, five of them still reporting a live listener.
#
# WHY IT DOES NOT MESSAGE THE PEER
# The channel is ONE object on ONE bus, not two copies. `pp --close` writes the
# closing notice into BOTH sides' FIFOs and then deletes the channel, so the peer
# session wakes from its blocked read and learns the conversation is over. Asking
# the other agent to close its own half would be strictly worse: its listener is
# normally down between turns, so the send would bounce after the send timeout -
# which does not fit in a hook - and even delivered, it would depend on an LLM
# choosing to act while this session is already dying.
#
# WHAT IT CANNOT COVER
# A kill -9, an OOM or a crash never runs a hook. That case is the keeper's
# leash (`pp --keep`), which polls the owner session and closes the channel when
# it disappears. The two together cover clean and dirty exits; neither covers
# both alone.
#
# FAILSAFE: this must never delay or block a session closing. Any error exits 0.

trap 'exit 0' ERR
set -uo pipefail

PP="${CLAUDE_PLUGIN_ROOT:-}/skills/ping-pong/bin/pp"
[ -x "$PP" ] || PP="$(command -v pp 2>/dev/null || true)"
[ -x "$PP" ] || exit 0

# The payload (with .reason) arrives on stdin; pp parses it and decides whether
# this reason should close anything - `resume` and `clear` deliberately do not.
# A hung bus must not hold the session open, hence the timeout.
timeout 12 "$PP" --session-end >/dev/null 2>&1 || true
exit 0
