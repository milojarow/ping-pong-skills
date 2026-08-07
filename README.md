# ping-pong-skills

**Two agent sessions, two machines, one private channel — 🏓**

## What is this?

A Claude Code skill that lets one session talk directly to another, on the same machine or across a network. Both sessions meet on a shared **bus host** and exchange messages through a private pair of FIFOs. The operator starts both sessions and carries one channel id between them; the agents do the rest.

Every channel is isolated. Sessions `A <-> Z` can discuss one thing while `B <-> X` discusses another, at the same time, on the same bus, with no crosstalk.

### Why this skill exists

- **A blocking read is a wake-up signal.** `pp --listen` costs zero CPU and returns the instant a message lands — run as a background command, that return is what notifies the agent. No polling, no timers.
- **A FIFO read is one-shot**, and nothing is queued. Both facts change how a session must behave: relaunch the listener *before* replying, or the peer's answer has nowhere to land.
- **A process blocked in `open(2)` on a FIFO holds no file descriptor**, so `fuser` and `lsof` swear nobody is listening. Presence has to be recorded explicitly, not probed.
- **Peer-to-peer usually isn't reachable** — NAT and firewalls — so the design never tries. One reachable bus host, declared once per machine, never auto-detected.
- **Isolation is structural**, not a naming convention: separate directories, separate FIFOs. Verified — with two channels live, delivering on one leaves the other's listener blocked at zero bytes.

## The skill

| Skill | Description |
|-------|-------------|
| **ping-pong** | Open, join, and run an isolated message channel between two agent sessions; diagnose one that misbehaves. |

Invoke it with no argument to open a channel, or with a `pp-xxxxxx` id to join one:

```
/ping-pong
/ping-pong pp-k7m2qx
```

Natural language works too — "abre un canal con la otra máquina y trabajen en conjunto".

## Installation

Add this marketplace in Claude Code:

```
/plugin → Marketplaces → Add Marketplace → milojarow/ping-pong-skills
```

Then install:

```
/plugin → Discover → ping-pong-skills → Install
```

Install it on **both** machines — each session needs the skill and the CLI.

Then, once per machine:

```bash
pp --setup --bus-local          # on the machine that hosts the bus
pp --setup --bus-ssh <alias>    # on every other machine
```

## Requirements

- `bash`, `mkfifo`, `timeout` (coreutils) on both machines and on the bus host.
- Key-based ssh from every non-bus machine to the bus host. Every call runs with `BatchMode=yes` and will never prompt for a password.
- A writable temp directory on the bus host (`/tmp` by default; override with `PP_BUS_ROOT`).

## License

MIT
