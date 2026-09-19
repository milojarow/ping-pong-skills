# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Project Overview

This is the **ping-pong-skills** repository — an isolated two-party message channel between agent sessions, on the same machine or across machines.

**Repository**: https://github.com/milojarow/ping-pong-skills

## Repository Structure

```
ping-pong-skills/
├── .claude-plugin/          # Claude Code plugin configuration
├── CLAUDE.md                # This file
├── README.md                # Project overview
├── LICENSE                  # MIT License
├── evaluations/             # Test scenarios for the skill (GREEN findability, eval-NNN.json)
├── hooks/                   # SessionEnd hook: closes the channels this session owns
├── tools/                   # Repo gates: check-version-chain.sh (the three version links agree)
└── skills/
    └── ping-pong/
        ├── SKILL.md          # Entry point (router, ≤250 lines): roles, wake events, turn contract
        ├── bin/pp            # The CLI, shipped next to the skill
        └── reference/        # protocol, pp-cli, direct-mode, inotify-wake, troubleshooting, …
```

**`SKILL.md` is a router and stays under 250 lines.** Claude Code keeps only the first ~5,000
tokens of an invoked skill across a compaction, so the operational sections (roles, wake events,
turn contract) sit at the top and every long-form section lives in `reference/`. It was 565
lines once; the turn contract sat past the cut and vanished after every compaction.

**Repo gate:** `tools/check-version-chain.sh` must print `OK` before a release commit. It
checks that `plugin.json`, `marketplace.json` and `PP_VERSION` in `bin/pp` agree; it stayed
FAIL from 1.0.0 to 1.0.27 because enrichment bumps touched the manifests and never the constant.

`bin/` lives **inside** the skill directory on purpose: the harness announces the skill's base directory when the skill loads, so the agent can resolve `<base>/bin/pp` without globbing a versioned plugin cache path.

## The skill

### ping-pong
Opening, joining, and running a private channel between two agent sessions: the initiator/joiner roles, the turn contract that keeps the exchange race-free, the `pp` CLI, and the failure shapes (one-shot reads, no queueing, listener presence that cannot be probed with `fuser`).

## Skill Activation

Activates when this session must talk to another agent session — the operator asks to open a channel or hands over a `pp-xxxxxx` id, a peer message needs an answer, several pairs must stay isolated, or a channel misbehaves.

## Conventions

- The CLI's operations are **flags**; the bare argument is always the channel id. Every command prints feedback, including when the result is empty.
- Nothing about the bus is auto-detected — it is declared once per machine in `~/.config/ping-pong/config`.
- Keep the docs free of real hostnames, aliases, and usernames. The bus is always `<alias>` / "the bus host".
- **The version chain has three links, and they move together:** `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `PP_VERSION` in `skills/ping-pong/bin/pp`. Two past releases bumped the manifests and left the constant behind, so `--version` reported a stale version in two different builds — and "check which version you are running" stopped being a usable diagnostic exactly when it was needed to tell a build with guards from one without. If the executable prints its own version, that string is part of the release, not a comment.

## Shipped in 1.4.0

These changes are on the development branch; this heading records the release
content, not evidence of publication. The older design sections below are history;
current instructions are SKILL.md and the three harness recipes.

- **Identity is a process incarnation.** Claude, Codex and Grok use
  `<harness>:<pid>` plus boot id and process start ticks. PID reuse must not extend
  a dead session's ownership. PP_SESSION is a checked declaration for supervised
  units without an agent ancestor; it cannot replace a different detected agent.
  A nosession caller must explicitly adopt before operating a live owner's endpoint.
  Whoami routes by identity, never by a tool named Monitor.
- **State belongs to an endpoint.** `<id>.<a|b>.*` separates two ends under one user.
  Legacy channel-only records are ignored. Mail append, await cursor commit and
  ownership adoption share a lock; restart never truncates the spool. Close keeps
  received mail recoverable rather than erasing it with the transport.
- **The Codex bell is fixed local text.** Queue enters as a user turn, so no peer
  body, topic or label can enter its argv. A supervised unit is bound to the keeper
  and the same birth fingerprint. Queue runs outside the mailbox lock; only its
  reservation and matching result are recorded under that lock. It persists a
  three-attempt budget and one bell per unread cursor, checks life just before
  queue, and stops on close/adoption.
  Queue success is not live-only atomic delivery: exiting during/after acceptance
  can leave a durable bell. No cancellation API is implemented here.
- **Closed session means no communication.** No headless standing listener or
  deferred resume delivery is part of the product. Pending spool data is recovery
  data. Leash cleanup has a polling bound; it is not instantaneous process death.
- **Each receiver owns its recipe.** Claude backgrounds await; Grok monitors watch
  persistently; Codex arms the bell. Homogeneous pairs apply one row twice; mixed
  pairs combine two rows. All use the bus, including on one machine. Direct mode
  is explicitly degraded. Native messaging is an operator-selected alternative.
- **Maintenance and work are distinct permissions.** Draining and rearming remain
  authorized with no project assignment; peer messages never create assignments.
- **One installation source.** The marketplace checkout owns the executable and
  skill. Install preflights both links, backs up recognized legacy copies, refuses
  foreign content, and provides a read-only resolution check.

Validation: tools/selftest.sh exercises local transport, fake queue argv, retry,
closed owners and temporary-HOME installation. tools/acceptance-tmux.sh is the
operator-run real-TUI gate; event files and exact body/cursor checks decide it,
never a prompt echoed on screen. Its dry-run launches no agent. Historical
standing-listener and direct feeder recipes were retired, not replaced by hidden
background services.

## Shipped in 0.2.0: ownership + the reaper

Both of the gaps recorded here were closed in 0.2.0 and are now documented in the skill:

- **Session ownership.** A channel belongs to the session that opened or joined it, resolved by walking the process tree to the agent process. `--listen` / `--send` / `--close` refuse when another live session on the machine owns it; `--join` refuses to take an occupied seat; `--listen` refuses a second reader on a side that already has one. `--adopt` overrides deliberately. This closed a production incident where two live channel pairs got crossed after a dropped connection.
- **`--gc`.** Reaps orphaned readers (by process group, gated on a token the marker carries so a recycled pgid is never killed), clears markers whose process is dead, drops stale local records. Runs automatically before `--open` / `--join` / `--list`.

Known limitation, worth keeping: a reader started by a pre-0.2.0 build carries no token, so `--gc` cannot prove it is ours and will not reap it — it only clears the marker once that process dies. Legacy orphans are killed by pid.

The design notes below are kept because they explain *why* the implementation looks the way it does.

The shape the fix took:

1. **`--listen` must leave a LOCAL record before it blocks.** Today the machine stores only `<id>.side`. A sibling `<id>.listener` holding the local wrapper pid and the remote pgid, removed on clean exit, is the discriminant of orphanhood. It has to be written *before* blocking — afterwards there is nobody left to write it.
2. **A `--gc` pass** over each local `<id>.listener`: local alive + remote alive → healthy, leave it; local dead + remote alive → orphan, reap; both dead → drop the stale local record. Reap = `kill -TERM -<pgid>`, escalating to `-KILL` after a grace period, and only after confirming the group's command line still names the channel.
3. **Hook it to session end**, plus an opportunistic pass at the start of `--open` / `--join` / `--list` — those already talk to the bus, so it is nearly free.

**The constraint that cannot be relaxed:** several sessions on one machine share the same state directory. A gc triggered by the end of session X must never sweep "every channel on this machine" — it would kill session Y's live listeners mid-conversation. The discriminant must be **"the local listener pid no longer exists"**, never "my session ended". That is the whole reason step 1 exists: without the local record, the only implementable gc is the dangerous one.

Alternatives already considered and rejected:

- **`ssh -tt` to force a PTY.** Rejected originally on an untested assumption (that the pty would rewrite `\n` as `\r\n` and corrupt the payload). Half of that was wrong: `stty raw -echo` before the reader keeps the bytes **identical**, multi-line UTF-8 included — measured. But the reaping it was wanted for **does not happen**: the remote processes end up with no controlling terminal (`tty=?`) and reparented to init, so there is no terminal to hang up and no `SIGHUP` is delivered. Measured, and it is why -tt is not in the shipped code.
- **A watchdog reading stdin.** Rejected originally as "complexity in the wake-up path". **This is what 0.3.0 actually ships**, because it is the only mechanism measured to work: when the connection drops, sshd closes the remote command's stdin, so a process *reading stdin* gets EOF and can kill the blocked reader. Measured: the remote reader now dies on its own ~2s after its session is killed, and the EXIT trap clears the marker with it.

**The methodology lesson, twice over.** Both alternatives were dismissed in writing without a test, and both dismissals were wrong in opposite directions — one was cheaper than believed, the other was the answer all along. The reaper is real work that a ten-minute experiment would have demoted from *the fix* to *the backstop*. And during the retest, a run that appeared to vindicate `-tt` was a **false positive** produced by a sloppy harness (the client process was never actually killed): when a result contradicts a later, more faithful test, suspect the cheerful one.
- **A default `timeout N` on the listener.** Bounds the orphan's life without signal plumbing, but does not address session end at all: it trades "forever" for "N", and kills legitimately idle conversations. A secondary belt, not the fix.
- **A remote watchdog on stdin EOF.** It works — remote stdin does get EOF when the client dies — but adds a background process and a `wait` inside the wake-up path, which is complexity exactly where a bug is most expensive.

Generalizable beyond this skill: **a remote process started over ssh does not inherit the mortality of whatever started it.** If it is also blocked without reading or writing, no signal reaches it. Anything that spawns a long-lived remote block needs an explicit way to reap it, designed in from the start — and the record needed to do the reaping must be written *before* the block.

## Closed in 0.6.0: a live session no longer has to stay pinned to a stale build

A session resolves the skill's announced base directory **once, at launch**, and that directory is a
**versioned cache path**. A plugin update mid-session does not move it, and neither does reloading
skills — so a long-running session keeps executing the build it launched with, silently, because an
old `pp` still works. This produced hours of confusing behaviour reports where the guards documented
in the skill simply were not in the binary being run.

The workaround this file previously listed as **UNVERIFIED** is now verified, so the skill documents
it. All three demanded proofs, measured on two machines 2026-08-08:

- **The path exists.** `~/.claude/plugins/marketplaces/<name>/skills/ping-pong/bin/pp` is the git
  checkout that `plugin marketplace update` pulls in place; it sat at the newest commit each time.
- **The resolved script runs.** `--version`, `--gc`, `--close` and `--list` all executed through it,
  on both machines.
- **It survives an update.** Five consecutive marketplace updates in one day, each followed by that
  path returning the new version.

Meanwhile the versioned cache on the same disk held **eleven** snapshots topping out five releases
behind what was installed — and several of those snapshots carry a `PP_VERSION` older than the
directory containing them, which is the version-chain drift fossilised release by release.

Session restart is still the only way to repin the *announced* directory. It is no longer the only
remedy, because the skill now tells the agent not to depend on that directory at all, and to run
`--version` once per session and believe it.

What is still **not** built: a self-check that warns when a newer build exists alongside the running
one. `--version` makes the fact visible on demand; nothing volunteers it.

## Shipped in 1.2.0: a smaller skill with an explicit stopping point
The entrypoint now opens with the scope contract: connecting (id or greeting) is the whole
deliverable, only the operator assigns work, a peer message is information even when it
quotes the operator, an acknowledgment is never answered, and irreversible or outward-facing
requests relayed by a peer go back to the operator. The body went from ~16.7 KB to ~6.5 KB
and the description from 454 to 157 bytes; references are reached only through a symptom
table, one section at a time. Only Claude Code uses `--keep` + `--watch` under a persistent
Monitor; a harness with no Monitor (Codex, Grok) listens in the foreground with a bounded
`--listen --wait N`, only when told to wait or when its assignment depends on the peer (three
reference notes now say so where they used to say "background, always"). Two new evaluations
guard the id-only stop and the peer-cannot-assign-work rule; the turn-order evaluation now
requires operator-assigned work and the no-queue evaluation uses the real 10-second send
grace. The CLI changes only its version string.

## Shipped in 1.1.0: `--watch`, the send grace, and the systemd detector

Three changes, each measured on the live bus with a peer on another machine before shipping:

- **`--watch <id>`** — the persistent waker for a harness that streams events (Claude Code's
  `Monitor`). One line per event (`MAIL` / `KEEPER` / `GONE` / `WATCH`), never a body; the agent
  drains with `--await`. It implements every rule `reference/inotify-wake.md` had accumulated
  from hand-rolled watchers: announce by spool state (size vs cursor, dedupe guard reset when the
  spool shrinks), `close_write` only, exact spool name, pulse on keeper liveness, bus probe on a
  slow interval, loud fallback without `inotifywait`. Measured: 4 deliveries → 4 `MAIL` events,
  `unread` correct against the cursor each time, the peer's `--close` → the closing notice as
  `MAIL`, then `KEEPER … inactive`, exit 2 within one pulse. Bus mode only: direct mode has no
  keeper and therefore no spool (gap still open, below); `--watch` refuses there and names the
  feeder loop.
- **`--send` waits for a reader** (`PP_SEND_GRACE`, default 10 s) before refusing. The keeper's
  reader exits on every delivery and re-attaches a moment later; measured at 5 s over ssh, and
  the second of two back-to-back sends was refused with `has no listener` on every run. The
  refusal message now says how long it waited.
- **`have_user_systemd()`** reads the manager's state (`running|degraded|starting|maintenance|
  stopping` → yes; `offline|unknown|""` → no) instead of `is-system-running`'s exit code, which
  is 0 only for `running`. A single unrelated failed unit no longer degrades every `--keep` on
  the box to the foreground. Verified with a stubbed `systemctl` over all six states.

The skill's wake-up story changed with it: **`/loop` and `ScheduleWakeup` are not wake
mechanisms for a channel** (a scheduled tick is polling), and the per-turn relaunch of `--await`
is gone for anyone running a harness with a persistent Monitor. The SKILL.md was rewritten around
that (565 → 250 lines) and the moved content lives in `reference/direct-mode.md`,
`reference/troubleshooting.md` (safeguard recovery, resume echo, more mistakes) and
`reference/protocol.md` (the second independent observation).

## Shipped in 0.5.0: `--listen --retry`, and the local holder no longer leaks

What shipped, and the constraints it had to satisfy — all three were written
here before the code existed, and all three are honoured:

- **`--listen --retry [N]`**, an opt-in bounded retry *inside* the process the
  harness watches (default 60 attempts, 5s apart; `PP_RETRY_DEFAULT` /
  `PP_RETRY_DELAY` override). It stays a flag rather than a separate wrapper so
  the golden rule ("relaunch before you reply") is satisfiable in one call.
- **Refusals are never retried.** The classifier keys on the exit status:
  255 retries, 1 exits, 124 honours the bound, 0-with-body delivers,
  0-without-body means the peer closed. Anything else stops **loudly** — that is
  the watchdog shape, and looping over it is precisely how a retry turns a
  deterministic bug into silent flapping. The discriminant survives in the code
  and in the docs: *every one of these produces an empty body, so the empty body
  proves nothing; the status is what separates them.*
- **The flap stays visible.** Drop counts go to stderr even on success.

Two defects were found while building it, both by review rather than by running:

- **A lost link does not always kill the far reader** (measured: a remote reader
  outlived its client by 1h12m). The survivor holds the FIFO, so the next attach
  hits `ALREADY has a live listener` — a refusal, correctly not retried — and the
  retry would have surrendered in exactly the case it exists for. `gc_channel`
  cannot help: it treats a live local pid as proof of health and returns early,
  and during a retry the live local pid is us. Hence `reap_my_orphan`, gated on
  the **token** so it can only ever kill the reader this process started; any
  other token is left strictly alone rather than recreating the crossed-channels
  incident.
- **The local holder leaked.** `bus_listen_stream` cleaned up its `sleep` and
  FIFO only when ssh *returned*; killed before that, both outlived the process,
  and `--gc` never saw them because it sweeps the bus, not local `/tmp`.
  Measured on a live machine: sleeps orphaned for over a day, seven stale FIFOs.
  Now trapped on EXIT/INT/TERM/HUP. Verified against the pre-fix code as a
  control: control leaks one FIFO per kill, the fixed version leaks none.

Still true, and worth keeping: **the retry is the backup, not the answer.** When
`ListAgents` already lists the peer, the native path has no listener to keep
alive, so the failure mode does not get mitigated — it stops existing. The retry
earns its place only where a channel is mandatory.

## Shipped in 0.9.0: `--mesh`, and the state that looks like success and is not

Direct mode landed in 0.8.0 assuming the mesh was somebody else's problem. It is not: the
very first real bootstrap failed on it, and the failure is worth recording because **nothing
in the failing state looks like a failure.**

Two people each ran `tailscale up`. Each authenticated with their *own* account. Tailscale
puts a device in the tailnet of the account that completes the login, so they landed in two
separate tailnets, each alone. Both machines printed `Connected`, both held a `100.x`
address, neither logged a warning. The peer reported success in good faith. It survived a
full round trip through two humans before anyone read the actual peer list — one line.

The generalizable shape: **an identity-scoped resource looks identical from inside whichever
scope you ended up in.** Connectivity checks that stop at "the daemon is up and has an
address" cannot see it, because every one of those facts is true. The check has to name the
*other* party — here, the peer appearing in `tailscale status` with a matching account
column. `up` succeeding is evidence about the daemon, not about reachability.

What 0.9.0 does about it:

- **`pp --mesh`** — four states (not installed / not logged in / logged in but alone /
  ready), exit 0 only on ready, and in each unfinished state it prints the block the operator
  hands to their partner. The "alone" state deliberately names **both** readings, because a
  machine cannot tell "partner has not joined yet" from "partner joined the wrong tailnet"
  from its own side. Saying so is more useful than picking one.
- **`--peer` became optional** when exactly one other machine is on the mesh. The address was
  being relayed by a human between two agents that could both read it — a step whose only
  possible product is a typo, surfacing much later as a connection refused.
- **The handover is a block, not a procedure.** The CLI prints text written *for the partner*,
  and the skill tells the agent to paste it verbatim rather than paraphrase. Paraphrasing is
  how the do-not-open-the-URL rule gets dropped, and that rule is the whole point.

Two measured facts that steer troubleshooting away from dead ends, both now in the docs:

- **A default-deny host firewall does not block the mesh.** With `ufw` at `deny (incoming)`
  and no rule for the inbox port, the natural conclusion is that the peer gets dropped —
  wrong. Tailscale installs a `ts-input` chain that the input hook jumps to *before* the
  firewall's chains, with an unconditional accept for the mesh interface (verified in a live
  ruleset, with matching packet counters). Opening a port here widens exposure and fixes
  nothing. The honest corollary belongs in the handover: everything listening on `0.0.0.0`
  becomes reachable from the mesh.
- **MagicDNS is not guaranteed**, so `--peer` takes the address rather than the name. Measured
  broken (`systemd-resolved` + NetworkManager wired incorrectly) on a machine whose mesh was
  otherwise healthy — and Tailscale reports it only in a health check nothing else surfaces.
  A name is a second thing that can be broken, and it breaks at connect time, long after the
  human has walked away from the handover.

Also fixed here: `tailscale status --self --peers=false` renders the account column as a
numeric userid, while the full status table renders it as the account name. The account name
is the single field that answers "whose tailnet is this" — the entire question `--mesh`
exists to settle — so the self line is read out of the full table, with the narrow form kept
only as a fallback.

## Known gap: an empty `--send` body is delivered as success

**Not built.** As of 0.9.x, `cmd_send` accepts an empty `$body` and sends it: the
receiver gets a header with nothing under it, the sender gets `pp: delivered`, exit 0,
no warning. Measured four times in one day on a single channel.

Why it is worth closing rather than only documenting: this is the failure shape the
whole protocol is built to avoid — **it looks exactly like success on both sides**. It
also **costs the receiver a turn**, because every delivery consumes its one-shot
listener and forces a relaunch. And a message with no text has no legitimate use case
that would justify either.

The shape a fix would take, and the open questions:

- `cmd_send` refuses an empty (or whitespace-only) body with a `die`, in both the bus
  path and `cmd_send_direct`, since both glue the sender-written header to the body.
- Whether to add an `--allow-empty` escape hatch at all. Nothing legitimate is known to
  need it; adding it pre-emptively creates the exemption that the next silent-empty send
  will hide behind.
- Where the check goes: before `assert_owner` / the listener probe (cheapest, and it
  avoids consuming anything), not after.
- `--send` reading from stdin has the same hole (`pp --send <id> < empty.txt`), so the
  guard belongs after the body is assembled, not on the `-m` argument.

Until it exists, the documented remedy is the manual one in
`reference/troubleshooting.md` ("A message arrived with its HEADER and NO BODY"): check
`wc -c` before sending, build the text with a quoted heredoc, and isolate with a
literal one-liner. **Do not document a rejection or an `--allow-empty` flag in the
skill until the executable actually has it** — a version chain that promises a guard it
does not ship is exactly the drift this repo has been bitten by before.

## Closed: a reader now survives the session's turns, a channel closes with its session, and (1.1.0) nothing is relaunched per turn

**Built, in three steps:** `--keep` (the leashed keeper unit + spool + `--await`), the
`SessionEnd` hook plus the keeper's leash (clean and dirty exits), and `--watch` (1.1.0) under a
persistent Monitor. The design notes below are kept because they are what the implementation
followed; the "not built" they describe is history.

The turn contract used to keep a listener up by convention — relaunch after every
delivery — and nothing enforced it. Three independent paths leave a side deaf with no
automatic recovery: the agent simply forgets, the harness tears down the background task
(an `/exit` choice, a Monitor timeout, teardown), or the `--retry` budget runs out. All
three end the same way: the marker looks fine, the side is silent, and the operator has to
notice and ask for a relaunch.

A relaunch loop with no owner (`nohup`/`setsid ... while true; do pp --listen ...; done`,
detached from any session) does keep the side answering — by defeating the abandonment
surfaces documented in [reference/standing-listener.md](skills/ping-pong/reference/standing-listener.md#a-loop-parked-outside-every-session-is-not-a-cheap-supervisor).
It has no upper bound either: such loops have been found still running days after every
session that opened them ended, keeping channels looking healthy with dead owners on both
sides. Whatever closes the reliability gap has to be leashed to the owning session's actual
lifetime, not run forever.

The shape a fix would take: a supervisor loop that relaunches the reader with no retry cap
— never giving up the way `--retry`'s bounded budget does — but that checks the existing
`session_alive()` helper against the owning pid already recorded in the channel's marker on
every cycle, and exits the moment that pid is gone. That leash is what a bare background
loop lacks, and it is also why such a supervisor cannot double as the thing the harness
waits on: a process that never exits can never deliver a wake-up. The two roles split —
one loop holds the FIFO open and spools whatever arrives; a second, disposable one blocks
on the spool and exits on the first new line, which is what the harness actually watches.

Session end has the same shape of gap on the other requirement. The plugin ships no hooks
today (no `hooks/hooks.json`, no `hooks` key in `plugin.json`), so nothing runs when a
session ends. The listener already dies with its session; the channel object does not, and
the next session to see that id adopts it with no friction (the dead-owner case ownership
was built to make findable, not to prevent). A `SessionEnd` hook that closes only the
channels this session owns would close it on a clean exit — bus mode's `--close` already
notifies the peer's blocked reader before deleting anything, so the peer wakes with an
empty read and learns the conversation ended without needing to run anything itself.
Direct mode's close does not carry the same guarantee yet: it only forgets the local record
and tells the human to relay the news, leaving the peer's reader pointed at a socket that
will refuse forever. The fix for that transport is a best-effort one-shot notice to the
peer's inbox before forgetting the local record, treating a refused connection as
confirmation the peer is already gone, not as an error to abort on.

Open question to verify empirically before shipping the hook, not to guess: which values a
`SessionEnd` hook's `reason` field can take, and which of them must **not** close the
channel — a `resume` has to find its channel still there.

What a `SessionEnd` hook cannot reach: a hard kill, a crash, a lid closed mid-session.
Nothing fires there, and the channel is left exactly as it is today. The shape of a
mitigation is a periodic liveness stamp each side updates, with the other side's loop
surfacing a stale stamp to its agent for a decision — never closing on the heuristic
itself, which is the same "report, never close" boundary `--gc` already draws for
abandoned channels.

Separately: clearing a batch of already-abandoned channels is manual today — enumerate,
`--close` each one, kill root processes before children so they cannot respawn a marker
while working down the tree. `--gc`'s "report, never close" default is correct and should
not change; what is missing is an explicit opt-in bulk operation for once the operator has
already said yes to closing them.

## Known gap: `--as` at `--open`/`--join` is not remembered by `--send`

**Not built.** `claim_channel()` writes the `--as` label into the channel's owner file, but the
only reader of that field (`assert_owner()`) uses it for display text — the `--adopt` note and
the ownership-refusal message. Every `--send` (bus and direct) signs with its own `$label`
parameter, filled independently by that invocation's `--as` or, absent that, by
`default_label()`. So a channel opened with a chosen label silently drifts to the
`host:project` default on the second message unless the label is repeated or `PP_LABEL` is
exported. Measured behavior and the manual workaround are documented in
[reference/pp-cli.md](skills/ping-pong/reference/pp-cli.md#-as-at---open-join-does-not-sign-later-sends).

The shape a fix would take, in order of preference:

- `default_label()` checks the channel's own owner file first (`label=` for this id) before
  falling back to `PP_LABEL` / `host:project`. This matches what the operator already believes
  happens, and needs no new flag.
- If that behavior change is unwanted, `--open`/`--join` print an explicit line telling the
  agent to export `PP_LABEL` or repeat `--as`, so the gap is surfaced instead of silently hit.
- Document `PP_LABEL` in the SKILL.md quick-reference table — today it only exists inside
  `default_label()` in the source and in the environment-variables table of `pp-cli.md`.

**Do not document a "remembers `--as`" behavior in the skill until `default_label()` actually
reads the owner file** — that would be exactly the version-chain drift this repo has already
been bitten by (see the version-chain note above).

## Known gap: `--list` is bus-wide and prints other clients' topics with no way to scope it

**Not built.** `cmd_list` walks every `pp-*` directory under `$BUS_ROOT` unconditionally and
prints each one's `--topic` verbatim plus both sides' labels and owner — there is no filter by
session, by `cwd`, or by ownership. An operator running several sessions for different clients
gets the full inventory of everyone else's channels the moment they check whether their own is
still up. Measured behavior and the interim mitigation (read narrowly, don't paste the raw
output across a client boundary) are documented in
[reference/pp-cli.md](skills/ping-pong/reference/pp-cli.md#--list-is-bus-wide-not-session-scoped--and-it-prints-other-clients-topics).

The shape a fix would take, in order of preference:

- `--list` scoped by default to channels this session is part of (owner match, same as
  `--gc`'s owner check already computes), with an explicit `--all` to opt into the full-bus
  view. This is the safer default since the common case ("is my channel still up?") never
  needed the rest.
- If the default must not change: redact `--topic` and both side labels for channels this
  session does not own, printing only `<id> listeners:N keeper:up/down` — enough to know
  something else is running, without disclosing what.
- The same question applies to `--gc --close-abandoned` (can close another job's channel) and
  `--adopt <id>` (can take one) — not measured as a leak, but the same bus-wide reach, and
  worth the same review before it is called fixed.

**Do not document a `--all` flag or per-session scoping in the skill until `cmd_list` actually
implements it** — the version-chain drift this repo has already been bitten by applies here
too: a flag documented before it ships teaches an agent to run something that does not exist.

## Known gap: `--keep` and `--info` don't branch on `is_direct()`

**Not built.** `cmd_keep` and `cmd_info` both call `require_channel`, which unconditionally
runs `bus "test -p ..."` — there is no `is_direct "$id"` check at the top of either, unlike
`cmd_close` and `cmd_listen`, which already dispatch to a `_direct` variant first. On a direct
channel this makes both fail with "does not exist on the bus," a message that names the wrong
cause and contradicts what `--open --direct`'s own output tells the agent to do next. Measured
behavior and the interim workaround are documented in
[reference/troubleshooting.md](skills/ping-pong/reference/troubleshooting.md#--keep-and---info-on-a-direct-channel-say-does-not-exist-on-the-bus).

The shape a fix would take, in order of preference:

- `cmd_info`: branch on `is_direct()` and print what the local machine actually knows for a
  direct channel — peer, port, side, topic, owner, and a TCP presence check against the
  peer's port if one is easy to add — instead of the bus query.
- `cmd_keep`: either learn direct mode for real (a keeper equivalent that holds `nc -l` output
  in a spool the same way the bus keeper does), or fail immediately with a message that names
  direct mode and points at `--listen` instead of the bus's "does not exist" text.
- Either way, `require_channel` should not be the first thing either command calls when the id
  is direct — the dispatch has to happen before that, the same place `cmd_close` and
  `cmd_listen` already do it.

**Do not document `--keep`/`--info` as working in direct mode until one of these actually
ships** — direct mode currently means `--listen --retry` relaunched per turn, full stop.

## Known gap: direct mode has no keeper, so the event-driven watcher design has nothing to watch

**Not built.** [reference/inotify-wake.md](skills/ping-pong/reference/inotify-wake.md)'s design
starts from "the keeper writes the spool, inotify fires on the write." In direct mode there is
no keeper (see the gap above) and therefore no spool — `<id>.direct` / `.owner` / `.side` exist
on disk, but never `.inbox` / `.cursor`. Arming a watch on a spool that will never be created
leaves it silent forever, which is indistinguishable from a quiet peer — the exact failure mode
the design document warns about for a different cause.

The shape a fix would take, if `--keep` is not extended to direct mode (see the gap above): a
user-built loop that plays the keeper's role without any change to `bin/pp` — repeatedly runs
`pp --listen <id> --retry`, appends whatever it returns to a local spool file, and emits only
the ring (channel, sender, line count, spool path) on stdout, the same contract
`inotify-wake.md` already asks of any watcher. Run under a harness's persistent Monitor (not a
bare background loop — see the standing-listener gap already on file for why that matters), it
is leashed to the session's own lifetime and never becomes the immortal loop the SKILL.md
prohibits, and inotify becomes unnecessary because the loop already knows the instant mail
lands. All of `inotify-wake.md`'s correctness rules still apply verbatim to this variant:
nanosecond-named captures, drain-before-arm, notify only on non-empty, and emit on failure too
(a non-zero `--listen` exit, or three empty 0-exit reads in a row — the signature of a second
reader stealing delivery).

**Do not document this loop as a shipped `--keep`-equivalent** — it is a pattern to build per
session, not a flag `bin/pp` has. Since 1.1.0 `--watch` refuses on a direct channel with a
message that names this feeder loop, so an agent cannot arm a watch on a spool that will never
exist; the gap itself (a real keeper for direct mode) is unchanged.

## Known gap: local channel state inherits the process umask instead of a fixed private mode

**Not built.** Every `mkdir -p "$STATE_DIR"` in `bin/pp` (about a dozen call sites) relies on
the caller's umask; only the ssh-remote bus-root creation path forces `umask 077` / `chmod 700`
today. The local files a bare `--open`/`--join`/`--keep` creates — `<id>.side`, `<id>.owner`,
`<id>.direct`, and the keeper's spool `<id>.inbox` — are born world-readable on any machine
whose default umask is `022`, and group-writable too under `0002`. Measured behavior and the
interim, by-hand mitigation are documented in
[reference/pp-cli.md](skills/ping-pong/reference/pp-cli.md#state-on-disk-inherits-the-process-umask--a-private-channel-is-not-private-by-default).

The shape a fix would take, in order of preference:

- Force it at creation: `mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"` once, plus
  `umask 077` around every block that writes `.direct` / `.owner` / `.side` / `.inbox` —
  cheaper than auditing every call site individually, and it also covers ones added later.
- Extend `--gc` to also tighten permissions on what is already on disk for existing
  installations, not just reap stale records.

**Do not document a permission guarantee, or a `--gc` permission sweep, in the skill until
`pp` actually enforces one** — today the only correct claim is that state inherits the
environment's umask, and the mitigation is manual.

## Known gap (partly closed in 1.1.0): `have_user_systemd()` read the manager's health, not its existence

**The detector is fixed in 1.1.0** (state allowlist, see "Shipped in 1.1.0"). **Still open:**
the silent foreground fallback and the tree-aware reap for a foreground keeper, described at the
end of this section. Original diagnosis, kept for the record: `have_user_systemd()` gated on the
exit code of `systemctl --user is-system-running`, which is 0 only for `running`. `degraded`, `starting`,
`maintenance` and `stopping` all exit 1 even though `systemd-run --user` works fine in every
one of those states — `degraded` in particular just means some unrelated unit is `failed`.
Any single failed user unit anywhere on the machine, with nothing to do with `pp`, is enough
to make `--keep` silently fall back to the foreground mode it exists to avoid, with a message
("no user systemd here") that misnames the cause. Measured behavior and the diagnosis are
documented in
[reference/troubleshooting.md](skills/ping-pong/reference/troubleshooting.md#--keep-falls-back-to-foreground-even-though-systemctl---user-list-units-shows-plenty-running).

The shape a fix would take:

- Replace the exit-code check with a state allowlist: accept `running`, `degraded`,
  `starting`, `maintenance`; reject `offline`, `unknown`, and the empty string (the only
  answers that actually mean "no user manager here").
- Longer term, an even more honest probe answers "can I start a unit?" by attempting one
  (`systemd-run --user --unit=<probe> true`) rather than reading a health status at all —
  the same ask-vs-attempt distinction already applied elsewhere in this file's troubleshooting
  entries (see the `--info` substring-match gap in
  [reference/troubleshooting.md](skills/ping-pong/reference/troubleshooting.md#the-probe-is-the-cheap-attempt-not-a-parse-of---infos-status--and-no-listener-contains-listen)).
- `--keep` should never fall back to foreground silently. Today a false negative from
  `have_user_systemd()` degrades to foreground with only a stdout note — invisible to any
  harness that backgrounds the call — and the foreground reader still satisfies `--info`, so
  the fallback reads as health instead of failure. The fix is to make foreground an explicit
  opt-in (a `--keep --foreground` flag) and have the silent-fallback path exit non-zero with
  the `systemctl --user --failed` diagnosis instead of just proceeding.
- Neither `--unkeep` nor `--gc` currently knows how to reap a *foreground* keeper by its
  process tree — only the systemd-unit path is torn down automatically. A foreground keeper
  killed by `TERM` alone can leave a relaunched reader and an orphaned `ssh` behind (measured
  and documented as a manual recipe in
  [reference/troubleshooting.md](skills/ping-pong/reference/troubleshooting.md#--keep-falls-back-to-foreground-even-though-systemctl---user-list-units-shows-plenty-running)).
  A tree-aware reap belongs in `--unkeep`/`--gc` itself, not left as a manual `pgrep -P` walk.

**Do not document `--keep` as tolerating a `degraded` user manager, a `--keep --foreground`
flag, or a tree-aware `--unkeep`/`--gc` until each actually ships** — today a single unrelated
failed unit can degrade `--keep` on that machine permanently, the fallback is silent, and
cleaning up a stuck foreground keeper is a manual process-tree walk.

## Updating this skill

After any session that discovers a new failure shape. Keep entries generic — patterns and causes, never machine or client data. The git log of this repo is the diary.
