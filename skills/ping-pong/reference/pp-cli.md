# `pp` — CLI reference

Operations are **flags**. The bare argument is **always the channel id**, so it never collides with a subcommand name. Every command prints feedback, including when the result is empty.

The script ships at `<skill base dir>/bin/pp`. For interactive use, `pp --install` copies it to `~/.local/bin/pp` — re-run it after a plugin update, since it is a copy, not a symlink.

## Setup

One-time, per machine. Nothing is auto-detected.

```bash
pp --setup --bus-local          # this machine HOSTS the bus
pp --setup --bus-ssh <alias>    # the bus is <alias>, reachable by ssh
```

`--bus-ssh` also probes the alias and warns if it cannot connect or the host lacks `mkfifo`. `<alias>` is anything your ssh config resolves — a `Host` entry, `user@host`, etc. Key-based auth is required: every call runs with `BatchMode=yes` and will not prompt for a password.

Written to `~/.config/ping-pong/config`:

```
bus_mode=ssh
bus_ssh=<alias>
```

## Operations

| Flag | Short | Argument | What it does |
|---|---|---|---|
| `--open` | `-o` | — | Creates a channel, prints the id and the line to hand over. You become side a. |
| `--join` | `-j` | channel id | Registers this machine as side b of an existing channel. |
| `--listen` | `-L` | channel id | **Blocks** until one message arrives, prints it, exits. Run it in the background. |
| `--send` | `-s` | channel id | Sends a message to the other side. |
| `--list` | `-l` | — | Open channels on the bus, with topic and which side you are. |
| `--info` | `-i` | channel id | Channel metadata plus who currently has a listener up. |
| `--close` | `-c` | channel id | Removes the channel from the bus and forgets it locally. |
| `--setup` | — | — | Writes the bus configuration (above). |
| `--install` | — | — | Copies the script to `~/.local/bin/pp`. |
| `--help` | `-h` | — | Usage. |
| `--version` | `-V` | — | Version. |

## Modifiers

| Flag | Short | Applies to | Meaning |
|---|---|---|---|
| `--topic "..."` | `-t` | `--open` | Human-readable subject, shown in `--list` and `--info`. |
| `--as <label>` | `-a` | any | Signature on your messages. Defaults to the short hostname. Sanitized to `[A-Za-z0-9._-]`, max 32 chars. |
| `--message "..."` | `-m` | `--send` | The body. Without it, the body is read from **stdin**. |
| `--wait N` | `-w` | `--listen` | Give up after N seconds and exit **124** instead of blocking forever. |
| `--force` | `-f` | `--send` | Skip the listener check and write anyway. |

### Choosing a `--as` label

Pick **one short, stable label per channel** and reuse it for every message: the machine name, or the role the session is playing (`builder`, `reviewer`). It is what the peer sees as the author on each message, so a label that changes per message makes the transcript unreadable. It is cosmetic — it never affects routing, which is decided entirely by channel id and side.

### When `--wait` is right

Default to a bare `--listen` with no timeout. A conversation has no deadline, the wait costs nothing, and an untimed listener is the wake-up mechanism the whole design rests on.

Reach for `--wait N` only when you need the session to regain control if the peer never answers — a handoff you must report on, or a channel you suspect is dead. Exit 124 means "nothing arrived"; the channel is still open, and you can listen again.

### What `--force` actually does

It skips the marker check, nothing more. The write still needs a reader on the other end: with nobody there it blocks for `PP_SEND_TIMEOUT` (60 s by default) and then fails with exit 124 — a stalled turn and an undelivered message.

So `--force` is correct in exactly one case: the peer **is** reading, but not through `pp` (a raw `cat` leaves no marker), or its marker went stale after an unclean exit. It is the wrong tool when the peer simply has not started yet — there, wait for their listener.

## Sending long or structured messages

`-m` is for one-liners. Anything longer goes through stdin, which preserves newlines and UTF-8 exactly:

```bash
pp --send pp-k7m2qx < report.md
printf 'line one\nline two\n' | pp --send pp-k7m2qx
```

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `PP_BUS_ROOT` | `/tmp/ping-pong` | Channel root on the bus host. Must match on both sides. |
| `PP_SEND_TIMEOUT` | `60` | Seconds `--send` waits for the write to complete before giving up. |
| `PP_LABEL` | short hostname | Default `--as` label. |
| `PP_SIDE` | — | Forces the side (`a` or `b`), overriding local state. Only needed to drive both ends from one machine while testing. |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success. For `--listen`, a message was received and printed. |
| 1 | Error — the message on stderr names the cause and the fix. |
| 124 | `--listen --wait N` timed out, or a send exceeded `PP_SEND_TIMEOUT`. The channel is still open. |

## Files

| Path | Where | Contents |
|---|---|---|
| `~/.config/ping-pong/config` | each machine | Bus mode and ssh alias. |
| `~/.local/state/ping-pong/<id>.side` | each machine | Which side this machine is on that channel. |
| `$PP_BUS_ROOT/<id>/` | bus host | The channel: `meta`, the two FIFOs, listener markers. |

Channel ids match `pp-[a-z0-9]{4,16}` and every command validates that pattern before the id reaches a shell — ids are the only user input that crosses into a remote command.
