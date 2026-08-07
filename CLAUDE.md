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

## Known gap: reaping orphaned remote listeners

A listener on the bus survives the death of the session that launched it — diagnosis and the manual remedy are in `reference/troubleshooting.md`. The shipped CLI has **no automatic reaper**; do not document one until it exists.

The shape a fix should take:

1. **`--listen` must leave a LOCAL record before it blocks.** Today the machine stores only `<id>.side`. A sibling `<id>.listener` holding the local wrapper pid and the remote pgid, removed on clean exit, is the discriminant of orphanhood. It has to be written *before* blocking — afterwards there is nobody left to write it.
2. **A `--gc` pass** over each local `<id>.listener`: local alive + remote alive → healthy, leave it; local dead + remote alive → orphan, reap; both dead → drop the stale local record. Reap = `kill -TERM -<pgid>`, escalating to `-KILL` after a grace period, and only after confirming the group's command line still names the channel.
3. **Hook it to session end**, plus an opportunistic pass at the start of `--open` / `--join` / `--list` — those already talk to the bus, so it is nearly free.

**The constraint that cannot be relaxed:** several sessions on one machine share the same state directory. A gc triggered by the end of session X must never sweep "every channel on this machine" — it would kill session Y's live listeners mid-conversation. The discriminant must be **"the local listener pid no longer exists"**, never "my session ended". That is the whole reason step 1 exists: without the local record, the only implementable gc is the dangerous one.

Alternatives already considered and rejected:

- **`ssh -tt` to force a PTY.** It does fix the root cause — with a PTY, disconnection sends `SIGHUP` to the foreground group. But terminal processing rewrites `\n` as `\r\n` on the way out, **corrupting the message bytes**. Unacceptable on a data channel.
- **A default `timeout N` on the listener.** Bounds the orphan's life without signal plumbing, but does not address session end at all: it trades "forever" for "N", and kills legitimately idle conversations. A secondary belt, not the fix.
- **A remote watchdog on stdin EOF.** It works — remote stdin does get EOF when the client dies — but adds a background process and a `wait` inside the wake-up path, which is complexity exactly where a bug is most expensive.

Generalizable beyond this skill: **a remote process started over ssh does not inherit the mortality of whatever started it.** If it is also blocked without reading or writing, no signal reaches it. Anything that spawns a long-lived remote block needs an explicit way to reap it, designed in from the start — and the record needed to do the reaping must be written *before* the block.

## Updating this skill

After any session that discovers a new failure shape. Keep entries generic — patterns and causes, never machine or client data. The git log of this repo is the diary.
