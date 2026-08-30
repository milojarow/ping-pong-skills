# A standing listener: the relaunch loop belongs to a supervisor, not to the session

> **Since 1.0.0, read this only for a side with NO session on it at all.**
>
> For the ordinary case — a channel between two agent sessions — use `pp --keep`. It puts
> the reader in a `systemd --user` transient unit for you (the same domicile this document
> argues for, and for the same reason: a background task is reaped when the **turn** closes)
> but it also holds a **leash** on the owning session and stops when that session goes. That
> leash is the whole difference between a supervised listener and an immortal orphan, and it
> is why you should not hand-roll the unit below for a channel that has an owner.
>
> What follows still applies to a side that must stay reachable with nobody sitting at it —
> a headless peer, a machine with no agent session. There is no owner to leash to there, so
> the supervisor has to be the whole answer, and `Restart=always` is correct.

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

## Updating the wrapper while it is running: replace with `mv`, never edit in place

The wrapper this guard runs is a long-lived script an interpreter is still reading when you go
to change it — `bash` does not read a script file in one gulp, it reads by **offset** while
executing. Editing the file in place can shift the offsets out from under a process already
partway through it, and what it executes next is garbage or half of an unrelated line.

    # wrong — a running wrapper can read offsets that just moved
    python3 -c "...edits the wrapper file in place..."

    # right
    ...write the new version to pp-guard.new...
    bash -n pp-guard.new         # syntax check before it goes anywhere near a live process
    mv pp-guard.new pp-guard     # atomic: the old inode stays valid until the old process exits

Full cycle for a change to the wrapper: write the new version to a temp file, `bash -n` it,
`mv` it into place, **then** stop the old unit and restart with the new one — in that order.
Stopping the unit before the `mv` only widens the window where nothing is draining the inbox,
for no benefit; the `mv` itself is what makes the swap safe regardless of when you stop it.

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

## A loop parked outside every session is not a cheap supervisor

The failure above — a loop dying with its session — has a mirror image that is worse,
not milder: a relaunch loop hung off `setsid`/`nohup` with no session and no supervisor
above it either, for example `sh -c 'while true; do pp --listen <id> --retry; done'`
detached from the shell that started it.

That loop has no owner a session can be checked against, so it outlives forever and
re-registers the `listening-<side>` marker within about a second of the previous
`--listen` exiting. The effect on the two abandonment surfaces is the opposite of what
it looks like:

- `--list` gates `LOOKS ABANDONED` on whether a listener is currently alive. One live
  listener suppresses the flag.
- `--gc`'s abandoned-channel report gates the same way: any channel with a live listener
  on either side is skipped.

Neither one asks whether the *owning session* is still alive — only `--close` checks the
owner recorded in the channel's state, which is why `--close` correctly reports "previous
owner session is gone" on a channel that `--list`/`--gc` just called healthy. **A live
listener whose owning session is dead is not evidence the channel is in use — with no
owner behind it, it is the exact shape of an abandoned channel, not a live one:** the next
`--close` or `--adopt` walks in with zero resistance, because a dead owner is precisely
what makes ownership permissive.

This is also why "orphans are prevented, not swept" (above) has a boundary. It holds only
as long as the listener's process ancestry terminates in an agent session. A detached
`while true` loop breaks that chain on purpose — its parent is `nohup`/`setsid`, not a
session — so nothing downstream of the listener ever finds out the session is gone.

If a channel must survive with nobody at the keyboard, that is exactly the case this file
is for: put the loop under `systemd --user` with `Restart=always`, not a bare `nohup`.
Under systemd the loop has a name, `systemctl --user status` lists it, `stop` ends it, and
an operator sweeping for orphans can find and account for it. Under a detached `nohup` it
is invisible to everything except a manual process-tree walk, and it will out-survive both
the session that meant to own it and the channel it is keeping falsely alive.

Cleaning one up once it is found is the same recipe as [Retiring an old
guard](#retiring-an-old-guard) below: kill the loop's root process (before its `pp
--listen` child can relaunch it), confirm the marker does not come back, then `pp --close`
the channel and `pp --gc` to drop the local record.

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
