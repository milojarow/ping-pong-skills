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

## Known gap: a live session stays pinned to the build it started with

Measured, and now documented in `reference/troubleshooting.md` as a diagnosis with a manual remedy (check `--version`; restart the session to repin, closing channels first). **The remedy is manual only — nothing in the CLI mitigates it yet.** What is *not* built:

- **No self-check.** `pp` does not compare the build it is running against the newest one installed, so a session pinned to a pre-guard build gets no warning at the moment it matters. A cheap version could be a note on `--open` / `--join` when a newer version directory exists alongside its own.
- **The "invoke through a non-versioned path" workaround is UNVERIFIED.** The idea is that calling the CLI through a stable, non-versioned marketplace path (rather than the session's versioned cache directory) would give an old session the new executable — guards included — even with stale skill text. That path was never confirmed to exist or to be stable across updates, and the harness's own guidance is to use the announced base directory. **Do not document it in the skill until someone verifies the path exists, survives an update, and that the resolved script actually runs.** Documenting an unverified path teaches every future session to run something that may silently fail.

Until one of these is built and verified, the skill must keep presenting session restart as the only reliable repin.

## Known gap: `--listen` has no retry mode, so a flapping link burns agent turns

Measured, and now documented in `reference/troubleshooting.md` as a diagnosis with a manual remedy (wrap the background command in your own bounded retry loop). **The remedy is manual only — `pp` ships no retry of its own.** On a link that flaps, each drop produces a background-task notification with a 0-byte output file, which re-invokes the agent to do nothing but relaunch; four drops in a few hours were measured on a tethered connection.

**The cause is now established, and it settles whether the retry is a fix or a cover-up.** The deaths are **transport** — the ssh client dying with `exit 255` plus a broken pipe / `Network is unreachable` — and *not* the 0.3.0 stdin-EOF watchdog. A watchdog kill cannot produce that signature: on that path the connection is healthy, the remote reader is what dies, and ssh returns the **remote command's** status, never 255 with a broken pipe. Two independent instruments agree (explicit 255s on a tethered link; four `NetworkManager` disconnect cycles across a WiFi run while the wired end held eight hours). The side-by-side asymmetry that first implicated the watchdog — zero survivors on the ssh side across four channels versus 4h20m and 1h12m on the local-bus side — is explained by the same transport cause, since only the ssh side has a link to lose.

Why that decides the design: against transport failure a bounded retry is **exactly** the right remedy; against a watchdog kill the same retry would have converted a deterministic bug into silent flapping. So the retry is worth building — and whatever ships should preserve the discriminant (**0 bytes with an exit status other than 255 = watchdog, not transport**) so a future regression cannot hide inside the loop. No such death has been recorded yet.

What is *not* built:

- **No `--listen` retry/persist mode.** The natural shape is an opt-in bounded retry inside the process the harness is watching, so the agent is woken only on a real message: retry on transport failure, re-emit captured stdout on success, and stop after a bounded number of attempts. Whether this belongs as a flag on `--listen` or as a separate wrapper the skill ships in `bin/` is undecided — a flag keeps the golden rule ("relaunch `--listen` before you reply") satisfiable in one call, which is the point.
- **The refusal cases must not be retried.** `ALREADY has a live listener` means another session owns the reader, not that the link broke; retrying it would attach a second reader to one FIFO, which is exactly the failure ownership exists to prevent. Any built-in retry has to classify the failure before looping — transport failure retries, refusal exits distinctly, a closed channel exits.
- **A retry loop hides the flap it is papering over.** If it ships, it should still surface *that* it retried and how many times, or the underlying network problem becomes invisible precisely when it is degrading everything else on the machine.

**Do not document a retry flag in the skill until it exists in `bin/pp`.** The troubleshooting entry deliberately presents the loop as shell the caller writes, labelled as not a `pp` feature; documenting it as a flag would teach every future session to run something that fails.

## Updating this skill

After any session that discovers a new failure shape. Keep entries generic — patterns and causes, never machine or client data. The git log of this repo is the diary.
