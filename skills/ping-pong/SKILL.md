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

## Choosing a mode: bus or direct

Two transports, and the choice is about **trust**, not about networking.

**Bus mode** (`--setup --bus-local` / `--bus-ssh`) puts the channel's FIFOs on one host both sides reach. It needs both sides to log into that host **as the same Unix user** — so it fits two machines that already belong to the same person. Between two *different people's* machines it does not fit: the price of a chat channel would be a shell account on somebody's box.

**Direct mode** (`--direct`) has no bus at all. Each side's inbox is a TCP port on **its own** machine, bound to a private mesh interface (Tailscale/WireGuard) that both devices joined. The peer connects to it. Nothing is exposed to the public internet, nobody gets a shell, and there is no token to mint or rotate — the mesh's device authorization is the access control.

### Direct mode: run `--mesh` first, then hand over one block

The operator's whole job is to paste **one block** into whatever they already use to talk to their partner. Everything before and after that is yours. Do not walk them through Tailscale by hand, and do not ask them to relay names or addresses you can read yourself.

```bash
pp --mesh          # ALWAYS first. Exits 0 when ready, 1 when something is missing.
```

It reports one of four states and, in each unfinished one, prints the exact text to hand over:

| State | What you do |
|---|---|
| Not installed | Give the operator the install + `up` commands it printed. Nothing to hand over yet. |
| Installed, not logged in | Same — but if the *partner* is the one who already has a tailnet, the operator must **send** their login URL rather than open it. |
| Logged in but **alone** | Hand the operator the block `--mesh` printed. That block is written for the partner and needs no editing. |
| Ready | Open the channel. `--peer` is optional when exactly one peer is on the mesh. |

```bash
# opener, once --mesh says READY
pp --open --direct --topic "what this is about"
# prints a second block to hand over, already containing:
#     /ping-pong <id> --direct --peer <your-mesh-ip>

# joiner — the operator pastes that line, and this is the whole job
pp --join <id> --direct --peer <opener-mesh-ip>

# from then on, identical to bus mode
pp --listen <id>          # in the background
pp --send <id> -m "..."
```

So the operator sees at most two hand-offs: **bootstrap** (get the partner onto the mesh) and **channel** (the `/ping-pong …` line). Both come out of the CLI verbatim. Say "hand this to your partner" and paste it — do not summarize it, and do not rewrite it into your own words, because the block is calibrated to stop the failure below.

### The trap that makes both machines look connected and unable to reach each other

**A tailnet belongs to an account, not to a network.** Two people who each run `tailscale up` and each authenticate with *their own* account end up in **two separate tailnets**, each alone. Both machines report `Connected`, both hold a `100.x` address, neither prints a warning — and they cannot see each other.

Measured in production: a peer opened their own login URL, read "Connected" as success, and the mistake survived until someone actually looked at `tailscale status` and saw a single line.

So: **`tailscale up` succeeding is not evidence of reachability.** The evidence is the *other* machine appearing in `tailscale status`, with the **same account** in the third column. `pp --mesh` checks exactly that and says so.

Exactly one tailnet must own both devices. Two ways to get there, both fine:

- **Pre-auth key** (fewer moving parts): the host mints one at `login.tailscale.com/admin/settings/keys` and sends it; the partner runs `sudo tailscale up --auth-key=<key>`. One command, no URL relay. It is a secret — single-use, short expiry.
- **URL relay**: the partner runs `sudo tailscale up` and sends the printed URL to the **host**, who opens it and authenticates with the host's account. The partner must not open it.

Recovery when the partner already joined the wrong tailnet: `sudo tailscale logout && sudo tailscale up`, then relay the new URL.

Both sides derive the **same port from the channel id**, so nothing extra travels between them and two channels between the same pair of machines land on different ports.

Use the **`100.x` address** for `--peer`, not the mesh name — MagicDNS depends on each machine's DNS wiring and is not guaranteed (measured broken on a machine whose mesh was otherwise healthy). The CLI already hands out the address for this reason.

What direct mode gives up, so you can decide with it in view:

- **No always-on middleman.** Both machines must be awake at the same time; with a bus host only the bus had to be. Neither mode stores anything, so nothing is "waiting" either way.
- **No shared metadata.** Each side keeps its own record, so `--info` reports only what this machine knows, and `--close` forgets it here — tell the peer to close too.
- **No listener marker, and none is needed.** The TCP connect *is* the presence check: `Connection refused` is ground truth, not a claim that can go stale. That whole class of failure — a marker outliving its process — does not exist here.

Requires `nc` on both machines and the device on the mesh (`tailscale up` once per device). `PP_MESH_IP` overrides the detected address if your mesh is not Tailscale.

**A default-deny host firewall is not the problem it looks like.** On a machine running `ufw` with `deny (incoming)` and no rule for the inbox port, the natural conclusion is that the peer's connection will be dropped — and it is wrong. Tailscale installs its own `ts-input` chain that the kernel's input hook jumps to **before** the firewall's chains, containing an unconditional accept for the mesh interface; verified in a live ruleset, with matching packet counters. Read the ruleset before opening a port you did not need to open. The corollary is worth stating to the operator: everything already listening on `0.0.0.0` is reachable from the mesh, so `ss -tln` is the honest disclosure to make to a partner before they join.

## First: resolve the CLI

The `pp` CLI ships inside this skill's own directory, at `bin/pp`. **Resolve it through the
marketplace path, not through the base directory the harness announced when this skill loaded:**

```bash
PP="$HOME/.claude/plugins/marketplaces/ping-pong-skills/skills/ping-pong/bin/pp"
[ -x "$PP" ] || PP="<announced-base-dir>/bin/pp"   # fallback if that layout is absent
"$PP" --version                                    # ALWAYS confirm which build you resolved
```

The announced base directory is a **versioned cache path**, and it is resolved **once, when the
session started**. A plugin update mid-session does not move it and neither does reloading skills,
so a long-running session keeps executing whatever build it launched with — silently, with no error,
because an old `pp` still works. It is the single most common source of confusing behaviour reports:
the guards live in the executable, not in this text.

The marketplace path is a git checkout that `plugin marketplace update` pulls in place, so it always
resolves to the newest installed build. Measured on two machines: it exists, it runs, and it kept
returning the current version across five consecutive marketplace updates in one day — while the
versioned cache on the same disk still topped out five releases behind, and several of its snapshots
had a `PP_VERSION` older than the directory they sat in.

`--version` is the check that makes this visible, so run it once per session and believe it over any
assumption about what is installed. For convenience on a machine you use often, symlink it onto PATH
once — `ln -s "$PP" ~/.local/bin/pp` — and `pp` tracks the current build from then on. Do **not**
`--install` a copy: a copy never updates.

One-time per machine, if any command says "not configured yet" — see [reference/pp-cli.md](reference/pp-cli.md#setup):

```bash
"$PP" --setup --bus-local          # on the machine that HOSTS the bus
"$PP" --setup --bus-ssh <alias>    # on every other machine
```

## Your two possible roles

**Invoked with no argument → you are the INITIATOR:**

0. **Pick the mode before anything else.** Is the other session on a machine that shares a bus with this one — same person, same Unix user? Then bus mode. Is it *someone else's* machine? Then direct mode, and your first command is `"$PP" --mesh`. If it does not say `READY`, hand the operator the block it printed and stop; there is no channel to open yet.
1. `"$PP" --open --topic "<what this channel is about>" --as <short-label>`
   (direct mode: add `--direct`; `--peer` only when more than one machine is on the mesh)
2. Start your listener **in the background**: `"$PP" --listen <id> --retry`
   (`--retry` rides out a dropped link instead of waking you to relaunch; see
   [reference/troubleshooting.md](reference/troubleshooting.md).)
3. Hand the operator the block the CLI printed, verbatim, with one sentence: *"pass this to your partner."* In bus mode that block is the single line `/ping-pong <id>`.
4. Stop and wait. The harness wakes you when the peer writes.

**Invoked with a `pp-xxxxxx` argument → you are the JOINER:**

1. `"$PP" --join <id> --as <short-label>`
   (direct mode: the operator's pasted line already carries `--direct --peer <ip>` — pass it through unchanged. If the join is refused because this machine is not on the mesh, run `"$PP" --mesh` and hand over what it prints.)
2. Start your listener **in the background**: `"$PP" --listen <id> --retry`
   (`--retry` rides out a dropped link instead of waking you to relaunch; see
   [reference/troubleshooting.md](reference/troubleshooting.md).)
3. Send a greeting so the peer knows you're on: `"$PP" --send <id> -m "<greeting + what you're working on>"`
4. Stop and wait.

**In both roles, the operator's total workload is pasting what you hand them.** Never ask them to read a `tailscale status`, relay an IP, or decide between transports — you can read all of that yourself, and every relay step is a chance for a typo that surfaces much later as a connection refused.

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

**Channels outlive the sessions that opened them, and that is the dangerous kind of leftover.** A channel costs almost nothing on disk and disappears when the bus reboots — but while it sits there it is a **decoy**: it looks exactly like a working channel, and the ownership guard *helps in the wrong direction*, because a dead owner means the next session adopts it without friction. Since 0.7.0 both surfaces make it visible instead:

- `--list` shows how long each channel has been quiet and how many listeners are actually alive, and marks `LOOKS ABANDONED` when nobody is on either side and it has been silent past `PP_STALE_HOURS` (24 by default).
- `--gc` reports those channels by id and topic.

**Neither one closes them, and that is deliberate.** A channel is a conversation, and "no listener right now" is a *normal* state between turns — the turn contract has that window by design. A rule that deleted on this heuristic would be right most times and wrong once, and the once costs a live conversation. Confirm with the operator, then `pp --close <id>`.

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
| **Direct mode: am I and my partner on one mesh?** | `pp --mesh` |
| Open a channel | `pp --open --topic "..." --as <label>` |
| Open a direct channel (someone else's machine) | `pp --open --direct --topic "..."` |
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
| Reading `tailscale up` succeeding as "we are connected" | Each of you authenticated with your own account, so you are in two separate tailnets, both alone, both saying `Connected` — and unreachable | `pp --mesh`. Ready means the *other* machine is listed, with the **same account** in column three |
| Walking the operator through Tailscale yourself | Every relayed name and address is a typo that shows up later as a connection refused, far from its cause | Hand them the block `--mesh` or `--open` printed, verbatim. Their whole job is pasting it |
| Opening a firewall port so the peer can reach your inbox | Tailscale's own chain already accepts the mesh interface *before* the firewall's chains — you widened your exposure for nothing | Read the live ruleset first. The mesh needs no port opened |

**A marker is evidence, not proof.** A listener whose session already ended can stay blocked on the bus for hours, marker and all. The send then *succeeds* and the message is lost into a reader nobody is watching. If a peer goes quiet right after a delivery that looked clean, suspect an orphaned listener — [reference/troubleshooting.md](reference/troubleshooting.md).

**"No listener" has two different causes — do not treat them as one.** If `--send` refuses, the ordinary cause is that the peer has not started their listener: ask them to, then resend. But if you can *see* their reader running and `--info` still says no listener, that is a different problem with a non-obvious cause — start at [reference/troubleshooting.md](reference/troubleshooting.md), not with `--force`.

More failure shapes, with the underlying cause of each: [reference/troubleshooting.md](reference/troubleshooting.md).
