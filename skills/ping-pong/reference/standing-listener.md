# A standing listener: the relaunch loop belongs to a supervisor, not to the session

`--listen` delivers exactly one message and exits — that is the wake-up mechanism, and inside a
live agent session the turn contract relaunches it every turn. This page is about the other case:
**a side that must stay reachable while no agent session is up on it** — a headless peer, a VPS,
a machine the operator is not sitting at. There the relaunch has to come from somewhere else.

## Two layers, and the second one is the one that bites

1. **The listener is consumed by every message.** A single `--listen` answers one delivery and the
   side goes deaf. Any standing arrangement needs a loop that re-attaches.
2. **Where that loop lives matters more than the loop.** Started from the agent session — as a
   background command, or with `setsid nohup` from its shell — it dies when the session dies. Worse,
   the session's temporary directory can be purged **mid-run**: measured, a purge took both the
   guard script and its mailbox with it, the side stayed deaf for three hours, and `pp --list` went
   on reporting `listeners:1` from a marker nobody had cleared. Nothing surfaced the gap.

So the loop goes under a supervisor that outlives the session and restarts it — on Linux,
`systemd --user`.

## One template unit, one instance per channel

```ini
# ~/.config/systemd/user/pp-guard@.service
[Unit]
Description=ping-pong standing listener for channel %i
[Service]
Type=simple
ExecStart=%h/.local/bin/pp-guard %i
Restart=always
RestartSec=5
[Install]
WantedBy=default.target
```

```bash
systemctl --user enable --now pp-guard@pp-xxxxxx.service
```

A template unit (`@`) is what keeps this from becoming one unit file per conversation: the channel
id is `%i`.

**`systemd-run --user` is not a substitute.** A transient unit survives the turn that started it,
but nothing revives it after a crash — no `Restart=`, no supervision. That is precisely the hole
the template closes.

## The wrapper: two details that cost hours when they are missing

The script is an infinite loop around `timeout 3600 pp --listen "$channel" --retry`, spooling each
delivery into a mailbox.

- **The `timeout` is not fear of a hang.** It forces the side to re-register its listener every
  hour, so a reader that died silently on the bus gets replaced on the next pass instead of going
  on looking like a live listener.
- **Write to a `mktemp` file and `mv` it into place**, never straight to the final name. The
  redirection creates the destination *before* anything arrives, so a mailbox full of 0-byte files
  is listens in flight, not messages. Counting files as messages makes "has it arrived yet?" answer
  yes when nothing has — measured, with a plain `ls | wc -l`.

## State goes outside the session's temporary directory

The mailbox belongs in a durable per-user path — `~/.local/state/pp-guard/<channel>/` — never in
the session's temp dir, which is what a purge eats.

The same holds for the **delivery log**, the record of whether a send actually left. Lose it
mid-wait and you lose the only instrument that separates *it did not go out* from *it has not gone
out yet*. That confusion has already produced a confident wrong diagnosis — "the message was lost"
about a message that was seconds away from delivery.

## What proves it works, and what proves nothing

- **That a listener exists proves nothing.** What proves the arrangement is that it **survives a
  message**: ask the peer for a ping, then confirm in `pp --info <id>` that the side's `token`/`pid`
  *changed* and that it is back to `LISTENING`. A guard that never re-attached looks identical to a
  working one until the second message.
- **A service nobody has watched come back is an assumption in a uniform.** `kill -9` the MainPID
  and time the return — about `RestartSec` seconds.

## The side is occupied while the guard holds it

One side, one listener: a second `--listen` on a side that already has a live reader is refused. So
an interactive session that wants to take that side stops the unit first
(`systemctl --user stop pp-guard@<id>`) instead of fighting the refusal.

## Retiring an old guard

Killing the wrapper leaves its `pp --listen` children alive — they are re-parented and keep stealing
messages from that side.

- Enumerate with `pgrep -f "pp --listen <channel>"` and kill **by numeric pid**.
- Never `pkill -f` on a pattern that appears in your own command line: `-f` matches the shell running
  the kill and the session kills itself. Same trap as in
  [troubleshooting.md](troubleshooting.md#cleaning-up).
- **Filter by channel.** The same machine can hold listeners belonging to other conversations, and
  those are not yours to touch.

Then `systemctl --user disable --now pp-guard@<id>`, and `pp --gc` to clear whatever marker the
kill left behind.
