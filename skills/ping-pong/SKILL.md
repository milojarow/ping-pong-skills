---
name: ping-pong
description: Use when this session needs to talk directly to ANOTHER agent session — the operator says "abre un canal", "comunícate con la otra terminal", "habla con <the other machine>", "ping-pong", "trabajen en conjunto", or hands over a `pp-xxxxxx` channel id to join. Use when a message arrives from a peer session and needs an answer, when several conversations must stay isolated from each other, and when a channel misbehaves — the send times out, the listener never wakes, a message lands in the wrong conversation, or channels must be listed, inspected, or closed.
---

# ping-pong

A private, isolated message channel between two agent sessions — on the same machine or on different ones.

> **🏓 ACTIVE-SKILL MARKER:** While `ping-pong` is active, begin every reply with 🏓 so the operator sees at a glance that the channel is live. Do not omit it.

## Overview

Two sessions meet on a shared **bus host** and exchange messages through a private pair of named pipes (FIFOs). One channel = one conversation. Two channels never see each other's traffic, so `A <-> Z` can discuss one thing while `B <-> X` discusses another.

The mechanism that makes this work in an agent harness: **a blocking read is the wake-up signal.** `pp --listen` blocks with zero CPU until a message arrives; run it as a *background* command and the harness notifies you the moment it returns. That notification is your cue to read the message and act.

**The human's only job** is to start both sessions and carry the channel id from one to the other. Everything else is yours.

## When to use

- The operator wants this session to coordinate with another session or machine.
- The operator pastes a `pp-xxxxxx` id — that's an invitation to join.
- A peer message arrived and you must reply.
- Several agent pairs must work in parallel without crosstalk.
- A channel misbehaves: send times out, listener never fires, ids to list or close.

**Not for:** talking to subagents you spawned (use the Agent tool), sessions the harness already lists as reachable peers (use its own messaging), or shipping files (that's `scp`/a CDN — ping-pong carries text).

## First: resolve the CLI

The `pp` CLI ships next to this file. Resolve it once per session and reuse the variable:

```bash
PP="<this skill's base directory>/bin/pp"    # .../skills/ping-pong/bin/pp
"$PP" --help
```

One-time per machine, if `pp --list` complains about configuration — see [reference/pp-cli.md](reference/pp-cli.md#setup):

```bash
"$PP" --setup --bus-local          # on the machine that HOSTS the bus
"$PP" --setup --bus-ssh <alias>    # on every other machine
```

## Your two possible roles

**Invoked with no argument → you are the INITIATOR:**

1. `"$PP" --open --topic "<what this channel is about>" --as <short-label>`
2. Start your listener **in the background**: `"$PP" --listen <id>`
3. Give the operator the one line to paste into the other session: `/ping-pong <id>`
4. Stop and wait. The harness wakes you when the peer writes.

**Invoked with a `pp-xxxxxx` argument → you are the JOINER:**

1. `"$PP" --join <id> --as <short-label>`
2. Start your listener **in the background**: `"$PP" --listen <id>`
3. Send a greeting so the peer knows you're on: `"$PP" --send <id> -m "<greeting + what you're working on>"`
4. Stop and wait.

## The turn contract

Every time you are woken by a message, produce these three things **in this order**:

1. **Relaunch the listener first** — `"$PP" --listen <id>` in the background, before anything else. Your listener consumed itself delivering the message; until it is back up, the peer's next message has nowhere to land.
2. **Then do the work** the message asks for.
3. **Then reply** — `"$PP" --send <id> -m "..."`, and tell the operator what was exchanged.

Listener up, then work, then reply. That ordering is what keeps both sides race-free: at any moment exactly one side is thinking and the other is listening. Details and the failure shapes in [reference/protocol.md](reference/protocol.md).

## Quick reference

| Goal | Command |
|---|---|
| Open a channel | `pp --open --topic "..." --as <label>` |
| Join a channel | `pp --join pp-xxxxxx --as <label>` |
| Wait for one message (run in background) | `pp --listen pp-xxxxxx` |
| Send a message | `pp --send pp-xxxxxx -m "texto"` |
| Send a long/multiline message | `pp --send pp-xxxxxx < file` |
| See open channels | `pp --list` |
| Who is listening right now | `pp --info pp-xxxxxx` |
| Close and delete a channel | `pp --close pp-xxxxxx` |

Operations are flags; the bare argument is always the channel id. Full CLI, config, and environment variables: [reference/pp-cli.md](reference/pp-cli.md).

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| Running `--listen` in the foreground | The turn hangs until a message arrives; the operator sees a frozen session | Always run `--listen` as a background command |
| Replying before relaunching the listener | The peer's answer finds no reader and their send fails | Listener first, then work, then reply |
| Expecting `--listen` to keep running after a message | It delivers exactly ONE message and exits, by design | Relaunch it every turn |
| Sending to a side with no listener | Refused in ~2 s with instructions (it does not hang) | Ask the peer to start their listener, then resend |
| Reusing one channel for two topics | Both conversations interleave in one inbox | One channel per topic — open a second one |
| Assuming a channel survives a bus reboot | Channels live in a temp dir and are wiped | Open a fresh channel; ids are cheap |

More failure shapes, with the underlying cause of each: [reference/troubleshooting.md](reference/troubleshooting.md).
