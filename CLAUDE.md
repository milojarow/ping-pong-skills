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

## Updating this skill

After any session that discovers a new failure shape. Keep entries generic — patterns and causes, never machine or client data. The git log of this repo is the diary.
