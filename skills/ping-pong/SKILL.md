---
name: ping-pong
description: Use when this session needs to talk directly to ANOTHER agent session — the operator says "abre un canal", "comunícate con la otra terminal", "habla con <the other machine>", "ping-pong", "🏓", "trabajen en conjunto", or hands over a `pp-xxxxxx` channel id to join. Use when a message arrives from a peer session and needs an answer, when several conversations must stay isolated from each other, and when a channel misbehaves — the send times out, the listener never wakes, the operator says the shell fell ("se cayó la shell") and a listener must be relaunched, a message lands in the wrong conversation, or channels must be listed, inspected, or closed.
---

# ping-pong

A private, isolated message channel between two agent sessions — on the same machine or on different ones.

> **🏓 ACTIVE-SKILL MARKER:** While `ping-pong` is active, begin every reply with 🏓 so the operator sees at a glance that the channel is live. Do not omit it.

## Overview

Two sessions meet on a shared **bus host** and exchange messages through a private pair of named pipes (FIFOs). One channel = one conversation. Two channels never see each other's traffic, so `A <-> Z` can discuss one thing while `B <-> X` discusses another.

Isolation has **two layers, and both are load-bearing**:

1. **Per channel** — separate directory, separate pipes. Structural; nothing can cross.
2. **Per session** — a channel belongs to the session that opened or joined it. Several agent sessions share one machine, one user and one state directory, so *which machine* is not enough to tell them apart. Without this layer a second session on the same box can attach to a channel that is not its own — and then two readers block on one pipe, one silently swallows the message and the other wakes with **zero bytes**. See [Ownership](#ownership-a-channel-belongs-to-a-session-not-a-machine).

The mechanism that makes this work in an agent harness: **a blocking read is the wake-up signal.** `pp --listen` blocks with zero CPU until a message arrives; run it as a *background* command and the harness notifies you the moment it returns. That notification is your cue to read the message and act.

**The human's only job** is to start both sessions and carry the channel id from one to the other. Everything else is yours.

## When to use

- The operator wants this session to coordinate with another session or machine.
- The operator pastes a `pp-xxxxxx` id — that's an invitation to join.
- A peer message arrived and you must reply.
- Several agent pairs must work in parallel without crosstalk.
- A channel misbehaves: send times out, listener never fires, ids to list or close.

**Not for:** talking to subagents you spawned (use the Agent tool), sessions the harness already lists as reachable peers (use its own messaging), or shipping files (that's `scp`/a CDN — ping-pong carries text).

## Before you open a channel: check the native path

If `ListAgents` already lists the peer, the harness's own `SendMessage` reaches it with no bus host, no files and no listener — use that instead. Open a ping-pong channel for one reason only: **the peer is not on that list** — a session on a
machine with no remote control, or a headless agent.

Two addressing gotchas decide whether that path works on the first try: the `[ref]` from the listing is demanded as first-contact confirmation even when the name is unique, and the reply address is the incoming message's `from` attribute — not the peer's name, and not what the peer claims about itself. See [reference/native-session-messaging.md](reference/native-session-messaging.md).

## First: resolve the CLI

The `pp` CLI ships inside this skill's own directory, at `bin/pp`. When this skill loaded, the harness printed its base directory — that path plus `/bin/pp` is the CLI. Resolve it once per session into a variable and reuse it:

```bash
PP="/absolute/path/announced/for/this/skill/bin/pp"
"$PP" --version        # confirms you resolved it
```

Never hardcode a plugin-cache path: it contains the version number and breaks on the next update. Use the announced base directory — but know that it is resolved **once, when the session starts**. A plugin update mid-session does not move it, and neither does reloading skills; `--version` tells you which build you are actually running, and only restarting the session picks up a newer one. That matters because the guards live in the executable, not in this text — see [reference/troubleshooting.md](reference/troubleshooting.md).

One-time per machine, if any command says "not configured yet" — see [reference/pp-cli.md](reference/pp-cli.md#setup):

```bash
"$PP" --setup --bus-local          # on the machine that HOSTS the bus
"$PP" --setup --bus-ssh <alias>    # on every other machine
```

## Your two possible roles

**Invoked with no argument → you are the INITIATOR:**

1. `"$PP" --open --topic "<what this channel is about>" --as <short-label>`
2. Start your listener **in the background**: `"$PP" --listen <id> --retry`
   (`--retry` rides out a dropped link instead of waking you to relaunch; see
   [reference/troubleshooting.md](reference/troubleshooting.md).)
3. Give the operator the one line to paste into the other session: `/ping-pong <id>`
4. Stop and wait. The harness wakes you when the peer writes.

**Invoked with a `pp-xxxxxx` argument → you are the JOINER:**

1. `"$PP" --join <id> --as <short-label>`
2. Start your listener **in the background**: `"$PP" --listen <id> --retry`
   (`--retry` rides out a dropped link instead of waking you to relaunch; see
   [reference/troubleshooting.md](reference/troubleshooting.md).)
3. Send a greeting so the peer knows you're on: `"$PP" --send <id> -m "<greeting + what you're working on>"`
4. Stop and wait.

## Ownership: a channel belongs to a session, not a machine

`--open` and `--join` stamp the channel with the identity of **this session**. Every later `--listen`, `--send` and `--close` checks it, and refuses when the channel belongs to a different session that is still alive on this machine.

What that buys you: after a dropped tunnel or a restart, attaching to the wrong channel id **fails loudly** instead of quietly wiring you into someone else's conversation. That failure used to be silent and it crossed two live conversations.

- If the owning session has ended, the channel is adopted automatically and you are told.
- If it is still alive and the channel really is yours, take it over deliberately: `pp --adopt <id>`, or pass `--adopt` to the command you were running.
- Invoked from a plain shell rather than an agent session, ownership cannot be determined and the checks stay permissive — that is for the operator, not for you.

**One side, one listener.** `--listen` also refuses to attach when that side of the channel already has a live listener, for the same reason: a second reader on one pipe does not duplicate the message, it steals it.

## Reading what arrived

`--listen` prints the message on stdout and exits. Run as a background command, that means: **the background task's output IS the message.** When the harness notifies you the listen task finished, read that task's output — first line is the header (`=== ping-pong <id> | from: <label> (side x) | <UTC> ===`), the rest is the body. The header is how you tell which channel woke you when you hold more than one.

Two non-message outcomes to recognize:

- **Empty output, non-zero exit** — the channel was closed or the connection dropped.
- **Empty output, exit 0** — something else consumed the message on your side. That is the signature of a second reader on your pipe; run `pp --info <id>` and `pp --gc`.

Both are covered in [reference/troubleshooting.md](reference/troubleshooting.md).

## Housekeeping

Since 0.3.0 a listener **dies with its session** — about two seconds after the session goes, the reader on the bus is gone and its marker with it. Orphans are prevented, not swept.

`pp --gc` stays as the backstop for what prevention cannot reach: a hard kill of the whole tree, and listeners started by pre-0.3.0 builds. It reaps readers on the bus whose session is gone, clears markers whose process is already dead, and drops local records for channels that no longer exist. It runs automatically before `--open`, `--join` and `--list`, so in normal use you never call it — reach for it when `--listen` refuses because of a listener you believe is stale.

## The turn contract

Every time you are woken by a message, produce these three things **in this order**:

1. **Relaunch the listener first** — `"$PP" --listen <id> --retry` in the background, before anything else. Your listener consumed itself delivering the message; until it is back up, the peer's next message has nowhere to land.
2. **Then do the work** the message asks for.
3. **Then reply** — `"$PP" --send <id> -m "..."`, and tell the operator what was exchanged.

Listener up, then work, then reply. That ordering is what keeps both sides race-free: at any moment exactly one side is thinking and the other is listening. Details and the failure shapes in [reference/protocol.md](reference/protocol.md).

**The trigger is a message ARRIVING, not a message going out.** Only a delivery to your own inbox consumes your listener; `--send` writes to the *peer's* inbox and never touches your reader. So relaunch exactly when the previous `--listen` returned **content** — concretely, when the background task's output is non-empty. Relaunching after a send is always redundant: the listener you started last turn is still up, the second one is refused, and the wake-up it costs you is already spent. The phrase "before you reply" invites this, because you are usually about to reply — read it as *after you received*.

A completion notification with a **0-byte** output is not a message: the listener died or was refused. Read the output before deciding; never relaunch reflexively on the notification alone.

**And if a background-task event is the first thing you see after a resume, do nothing.**

When the operator quits with a listener still blocked, `/exit` makes them choose what to do with
the background process. Whatever they pick, the next `claude -c` / `--resume` delivers an event for
that task **before they have typed a single word**, and a session that obeys the relaunch rule wakes
up and picks yesterday's collaboration back up on its own. Measured, twice, in the operator's words:

> *"por qué acabo de hacer --resume de sesión y tú ya tenías como trabajos background, o sea,
> todavía no te decía nada y tú ya estabas trabajando?"*

**Do not key the guard on the task having *completed*.** It usually has not. The observed case
arrived with no completion record at all, and the harness says so in as many words — this exact
text is your recognition signal:

> No completion record was found for this background shell command from the previous session. It
> may have been stopped (via the UI, Monitor timeout, or agent teardown — these leave no transcript
> marker), or it may have been running when the previous Claude Code process exited.

So the discriminant is neither the exit status nor the word *completed*: it is **a background-task
event arriving as the first thing after a resume, with no operator input in between.** Its output
file is 0 bytes, because a listener that was killed never read anything.

That is not a message and not a request — it is the echo of a process that outlived, or died with,
the previous session. Say one line naming the channel it came from, and stop. Do not relaunch the
listener, do not resume the old collaboration, do not touch the repo you were working in. The
operator opens the session to give it work; wait for that. The empty body alone does not say *what* killed it — the exit status does, and `255` with a broken pipe means the link went away, not the channel. See [reference/troubleshooting.md](reference/troubleshooting.md).

**It is also how a collision recovers.** If both sides happen to send at the same instant on an idle channel, both messages are delivered correctly — measured — but both listeners end up down at once. Relaunching before you reply absorbs that on the next turn with no extra logic. Two consequences for you: **read the header before assuming a message answers what you asked** (in a tie it is the peer's own initiative, not a reply), and if your send is refused with `has no listener` right after an exchange that looked simultaneous, just wait for the peer to relaunch and resend. See [reference/protocol.md](reference/protocol.md).

**If you already broke the order** — you did the work with your listener down — relaunch the listener now, then send. Anything the peer tried to send during that window was *refused at their end*, not queued for you, so ask them to resend rather than waiting for it.

## When the exchange is over, close the channel

Ending the session is the operator's call, not yours. But leaving a listener blocked once the
collaboration is finished is not neutral — they pay for it three times:

- **At exit.** `/exit` warns about a background process and makes them choose. There is no good
  option: "exit anyway" kills the listener, "keep the process" leaves an orphan behind.
- **On the next launch.** The kill completes the background task, and its notification is delivered
  before they type anything — see the rule above.
- **On the next channel.** A reader on the bus can outlive the client that started it (measured at
  1h12m), so its marker stays and the next `--listen` on that side is refused with
  `ALREADY has a live listener`, which reads as the channel being broken.

So when the work the channel was opened for is done, wind it down instead of leaving it blocked:

```bash
"$PP" --send <id> -m "done here — closing the channel"
"$PP" --close <id>
```

`--close` signals the peer's blocked listener before deleting the FIFOs, so their side wakes with an
empty read and learns the conversation is over rather than hanging. After that neither side has a
background process, `/exit` is silent, and the next launch starts on the operator's prompt.

If you are unsure whether the collaboration is really finished, ask the operator in one line rather
than leaving a listener up by default. A channel is cheap to reopen; a session that wakes itself up
is not.

## Several channels at once

Channels are isolated by construction — separate directories, separate pipes — so nothing special is needed for two *pairs* of sessions to work in parallel: each pair opens its own channel and neither can see the other's traffic.

A single session can also hold more than one channel. What that costs you:

- **One background listener per channel.** They are independent; one firing does not disturb the others.
- **Route by the header.** The `=== ping-pong <id> ... ===` line names the channel the message came from.
- **The turn contract applies per channel.** Relaunch the listener for *that* channel before replying on it; leave the others alone.
- **To bring a peer into a second channel**, open it and send the new id over the channel you already share — or hand it to the operator to paste. The peer runs `--join` on it and starts a second listener.

Keep one topic per channel. Two topics in one channel produce an interleaved inbox that neither side can untangle.

## Quick reference

| Goal | Command |
|---|---|
| Open a channel | `pp --open --topic "..." --as <label>` |
| Join a channel | `pp --join pp-xxxxxx --as <label>` |
| Wait for one message (run in background) | `pp --listen pp-xxxxxx --retry` |
| Send a message (preferred — no shell expansion) | `pp --send pp-xxxxxx < file` |
| Send a short one-liner | `pp --send pp-xxxxxx -m 'texto'` |
| See open channels | `pp --list` |
| Who is listening, and who owns it | `pp --info pp-xxxxxx` |
| Close and delete a channel | `pp --close pp-xxxxxx` |
| Reap orphans, clear stale state | `pp --gc` |
| Take over a channel for this session | `pp --adopt pp-xxxxxx` |

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
| Reaching for `--force` when the peer simply isn't up yet | It skips the check and blocks for the full send timeout, then fails — the turn stalls for a minute | `--force` is only for a peer you *know* is reading without `pp`. Otherwise wait for their listener |
| Re-attaching to a channel id from memory after a dropped connection | You can land on a *different* channel this machine also belongs to, and cross two conversations | Take the id from `pp --list`, which marks which channels are YOURS |
| Passing `--adopt` to get past an ownership refusal | You take a live channel away from another working session | `--adopt` is for a channel whose owner session is gone, or one you are certain is yours |
| Inventing a `--as` label per message | The peer sees a different author each time and cannot tell who it is talking to | Pick one short, stable label for the whole channel — the machine or the role, not the task |
| Putting backticks (or `$VAR`) inside `-m "..."` | Your shell expands them before `pp` sees the argument — the message is delivered **missing exactly those words**, still grammatical, and the peer cannot tell | Send through stdin: `pp --send <id> < file`. Keep `-m` for a short line, in single quotes |
| Relaunching `--listen` after a `--send` | Your send consumed nothing, so the previous listener is still up: the new one is refused and a whole wake-up is spent arriving at an empty output | Relaunch only when the previous `--listen` actually returned content |
| Deciding a listener is dead because its pid is absent on **your** machine | That pid lives in the bus host's pid namespace; you start a second reader and two block on one FIFO | `pp --info <id>` — it runs the liveness check on the bus, where the pid means something |

**A marker is evidence, not proof.** A listener whose session already ended can stay blocked on the bus for hours, marker and all. The send then *succeeds* and the message is lost into a reader nobody is watching. If a peer goes quiet right after a delivery that looked clean, suspect an orphaned listener — [reference/troubleshooting.md](reference/troubleshooting.md).

**"No listener" has two different causes — do not treat them as one.** If `--send` refuses, the ordinary cause is that the peer has not started their listener: ask them to, then resend. But if you can *see* their reader running and `--info` still says no listener, that is a different problem with a non-obvious cause — start at [reference/troubleshooting.md](reference/troubleshooting.md), not with `--force`.

More failure shapes, with the underlying cause of each: [reference/troubleshooting.md](reference/troubleshooting.md).
