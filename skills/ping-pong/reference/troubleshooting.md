# Troubleshooting

Each entry names the **cause**, not just the fix — several of these look like a different problem than they are.

## "The send says nobody is listening" — and you are sure someone is

`--send` checks for the peer's `listening-<side>` marker before writing, and refuses in about two seconds rather than hanging for the full timeout. Two ways it can be wrong:

- **The marker is stale.** The listener died without running its cleanup trap — killed with `-9`, or the ssh carrying it was severed. The file lingers, and the send then hangs to the timeout instead.
- **The peer is listening without `pp`.** A raw `cat` on the FIFO reads fine but writes no marker.

There is a third case that does **not** produce this symptom and is far worse for it: the marker is accurate, the reader really is alive — but its session is long gone. The send then *succeeds*, into a reader nobody is watching. See [An orphaned listener outlives the session that started it](#an-orphaned-listener-outlives-the-session-that-started-it).

Confirm with `pp --info <id>`, and if you know the peer is really there, `pp --send <id> --force`.

## The listener never wakes even though the peer sent

Check them in this order:

1. **Are you on the right side?** `pp --info <id>` prints `this machine is side a` (or `b`). Both sides listening on the *same* FIFO would each wait forever. This is impossible through `pp` (side is recorded at open/join) but possible if `PP_SIDE` was set by hand.
2. **Did the peer's send actually succeed?** It prints `delivered to side <x> of channel <id>`. Without that line, nothing was written.
3. **Is the ssh still up?** A listener is a long-lived ssh. It runs with keepalives, but a laptop suspend or a network change can still drop it. The task exits non-zero rather than hanging — check the exit status, not just the empty output.

## `--listen` returned instantly with no message

The channel does not exist on the bus. Almost always: the **bus host rebooted** and wiped `/tmp`. `pp --list` will show nothing. Open a new channel — the id is disposable.

## "This channel is not registered on this machine"

You ran a channel command on a machine that never opened or joined it. The side is local state, not something derivable from the id. Run `pp --join <id>` there first. If you *did* join, check you are on the machine you think you are.

## `--info` says "no listener" while a listener is clearly running

The intuitive check is the wrong one: **a process blocked in `open(2)` on a FIFO holds no file descriptor yet.** The open has not returned, so nothing appears in `/proc/<pid>/fd` — `fuser` and `lsof` both report the FIFO as unused, no matter how many readers are waiting on it.

Generalize it: **the absence of an fd is not the absence of a waiter.**

So listener presence cannot be probed from the kernel at all; it has to be recorded. Since v0.1.0, `pp --listen` writes a `listening-<side>` marker before it blocks and removes it with an EXIT trap, and `--info` reports that marker — never `fuser`. If your `pp --version` is older, the reported state is meaningless.

Given that, "I can see a `cat` running" distinguishes nothing on its own — `pp --listen`'s reader *is* a `cat`. To tell a `pp` listener from a bare one, look at the marker, not the process:

```bash
pp --info <id>       # the authority: marker present or not
```

A reader with no marker is a raw `cat` (or a listener from an older build). Reach for `--send --force` there, and prefer switching that side to `pp --listen` so the state stays visible.

## The pid in a marker is a bus pid — checking it locally gives a confident wrong answer

Observed: a session read the `listening-<side>` marker, took the pid, ran `kill -0` **on its own machine**, found nothing, and concluded the marker was lying. It then started its own listener to replace the "dead" one — and ended with two readers blocked on the same FIFO, which is precisely the failure the marker exists to prevent. The verification produced the damage it was meant to avoid.

The process was alive the whole time. A listener runs **on the bus host**, launched over ssh, so its pid belongs to the bus's pid namespace. From anywhere else that number fails in two ways, and both are convincing:

- it does not exist locally → you conclude "dead" and double up the readers;
- it *does* exist locally, as a completely unrelated process → you conclude "alive", or you kill a stranger.

The check has to happen where the pid was issued. `pp --info <id>` already does that — its `kill -0` runs inside the ssh call, which is why its answer is the authority. Probing by hand, the `kill -0` goes *inside* the ssh session, never outside it.

Generalize it: **a pid only means something inside the pid namespace that issued it.** A pid that travels between machines is a number, not a reference — and probing it from the wrong side does not answer "unknown", it answers wrong.

## A session runs the build it started with — updating the plugin does not move it

Measured: after a new version was published and the plugin updated, a session that reloaded its skills **kept executing the binary from the previous version's directory**. The plugin cache keeps one directory per version, each held by the sessions using it; a session resolves its directory once at startup and stays there, so superseded versions are not swept while anyone still holds them.

This matters more than a wrong version number: **the guards live in the executable, not in the skill text.** A session pinned to a build from before a guard existed still suffers the failure that guard closes — and those are the sessions already mid-conversation, with the most to lose.

- `pp --version` is the ground truth for which build you are actually on. Check it before trusting the presence and ownership behavior described in this file.
- Reloading skills does **not** repin it. Only restarting the session does.
- Close your channels before restarting (`pp --close <id>`), or you leave a reader blocked on the bus — see [An orphaned listener outlives the session that started it](#an-orphaned-listener-outlives-the-session-that-started-it).

## Messages appear in the wrong conversation

Channels cannot leak into each other — separate directories, separate FIFOs. But **two sessions can end up on the same side of one channel**, and that produces exactly the same symptom from the outside. This is the failure that motivated ownership; it was observed in production with two channel pairs live.

How it happens: the per-machine state (`<id>.side`) answers "which side is this *machine* on", not "which *session* owns this". Several agent sessions share one user and one state directory, so after a dropped connection a session that re-attaches with the wrong channel id is let straight in — the machine really is a member of that channel.

What it looks like once two readers block on one FIFO — **measured**:

- the message goes to exactly **one** reader, whichever the kernel wakes;
- the other exits **with zero bytes and exit status 0** — a wake-up with no message, which no other situation produces;
- the second listener's marker **overwrites** the first, so `--info` reports the wrong owner.

Since v0.2.0 three guards close this off, and the errors name the situation:

- `--listen` / `--send` / `--close` refuse when another live session on this machine owns the channel;
- `--listen` refuses when that side already has a live listener;
- `--join` refuses when the channel already has a different partner on that side.

`--adopt` overrides any of them deliberately. Take channel ids from `pp --list`, which marks which ones are yours, rather than from memory.

## A listener woke up with zero bytes and exit 0

Not a closed channel (that exits non-zero) and not a timeout (that exits 124). Exit 0 with an empty body means **another reader consumed the message on your side**. Run `pp --info <id>` to see who holds the marker and `pp --gc` to clear a stale one. If a second session is genuinely attached, one of you is on the wrong channel.

## The whole turn hangs

`--listen` was run in the **foreground**. It is supposed to block; that is the wake-up mechanism. It must run as a background command so the session stays responsive and the harness notifies you on arrival.

## Timestamps disagree by hours between the two sides

Bus hosts commonly run UTC while workstations run local time. `pp` stamps every message in UTC precisely so headers are comparable. If you correlate a `pp` header against a local log, convert explicitly — do not subtract a hardcoded offset, since regions with daylight saving shift twice a year.

## Cleaning up

Channels are cheap but not free — each is a directory with two FIFOs on the bus.

```bash
pp --list                  # what is open
pp --close pp-k7m2qx       # remove one channel from the bus
```

### Releasing a listener that is stuck on a dead channel

Deleting a FIFO does **not** wake a reader already blocked in `open(2)` — the pending open keeps the inode alive, so the reader waits forever on a path that no longer resolves. Measured, not assumed: a plain `rm -rf` of the channel directory left the listener process alive and blocked.

That is why `pp --close` writes a "channel closed" notice into every side that has a listener marker **before** deleting the directory. The listener receives it, prints it, and exits cleanly.

Two cases `--close` cannot rescue, because there is no marker to find them by:

- a listener started with a raw `cat` instead of `pp --listen`;
- a listener whose channel directory was deleted by something other than `pp --close` (a `/tmp` cleaner, a manual `rm`).

Both have to be killed by pid. Match on the process, never with `pkill -f <pattern>` — `-f` matches every command line including the shell running your own kill command, so a self-matching pattern kills your own session.

### An orphaned listener outlives the session that started it

**Fixed at the source in 0.3.0** — a listener now dies with its session, measured at roughly two seconds. What follows is why it used to happen, because the same trap catches anything else that blocks on a remote host, and because a listener started by an older build still behaves the old way.

The mechanism that fixes it: the reader runs in the background on the bus while a **watchdog blocks reading stdin**. When the connection drops, sshd closes the remote command's stdin, the watchdog gets EOF and kills the reader; the EXIT trap clears the marker on the way out. Whichever finishes first — a delivered message or a dead client — ends the other.

Two mechanisms were tried before that one, and both failed for instructive reasons. Forcing a pty (`ssh -tt`) so the kernel would `SIGHUP` the group **does not work**: the remote processes end up with no controlling terminal and reparented to init, so there is nothing to hang up. Deleting the FIFO does not work either, for the reason below. `--gc` remains as the backstop for hard kills and for listeners started by pre-0.3.0 builds.

The original failure, for reference:

A remote listener does **not** die when its client does. Measured, not assumed: after the agent session ended and the local `pp --listen` process was gone, the reader on the bus host was still alive and blocked more than an hour later.

Nothing reaches it, for three reinforcing reasons:

- it writes nothing until a message arrives, so it never takes `EPIPE`/`SIGPIPE`;
- it is blocked in `open(2)`, not reading stdin, so the EOF of the ssh channel never touches it;
- sshd closes the channel, but sends no `SIGHUP` to a non-interactive command — there is no PTY.

Same property as the deleted-FIFO case above: what makes the listener cheap — a pure kernel block, zero CPU — is exactly what makes it deaf to everything but a writer.

Why this is not cosmetic:

- orphans accumulate on the bus, one per abandoned session;
- their `listening-<side>` markers keep claiming somebody is reading, so a `--send` **reports delivery and the message is lost** into a reader nobody will ever see — the one failure shape in this protocol that looks like success;
- reopening a session can surface a phantom background-task notification belonging to the previous one.

**Reaping one by hand.** The marker already holds what you need: the remote pid, which is also the **process-group leader**.

```
listening-a  ->  <label> pid=1001 since=<UTC>

    PID    PPID    PGID COMMAND
   1001    1000    1001 <shell> -c ... trap ... cat '<bus root>/<id>/to-a'
   1003    1001    1001  \_ cat '<bus root>/<id>/to-a'
```

Kill the **group**, not the pid: `kill -TERM -<pgid>` on the bus host takes down the shell and its `cat` together, and the shell's EXIT trap removes the marker on its way out. Kill only the shell and the `cat` is reparented to init and stays blocked, marker and all.

Two guards before firing:

- **Confirm identity first.** A pgid can be recycled once the original group is gone. Check that the group's command line still names the channel path.
- **Kill by numeric pgid, never by pattern.** `pkill -f` matches the shell running your own kill command — the same self-matching trap as above.

There is no automatic reaper in the CLI. Until there is, treat an unexplained silent peer as a possible orphan and check `--info` against whether that session still exists.
