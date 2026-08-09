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
├── evaluations/             # Test scenarios for the skill
└── skills/
    └── ping-pong/
        ├── SKILL.md          # Entry point: roles, turn contract, quick reference
        ├── bin/pp            # The CLI, shipped next to the skill
        └── reference/        # protocol, pp-cli, troubleshooting
```

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

## Updating this skill

After any session that discovers a new failure shape. Keep entries generic — patterns and causes, never machine or client data. The git log of this repo is the diary.
