# Troubleshooting

Each entry names the **cause**, not just the fix — several of these look like a different problem than they are.

## "The send says nobody is listening" — and you are sure someone is

`--send` checks for the peer's `listening-<side>` marker before writing, and refuses in about two seconds rather than hanging for the full timeout. Two ways it can be wrong:

- **The marker is stale.** The listener died without running its cleanup trap — killed with `-9`, or the ssh carrying it was severed. The file lingers, and the send then hangs to the timeout instead.
- **The peer is listening without `pp`.** A raw `cat` on the FIFO reads fine but writes no marker.

Confirm with `pp --info <id>`, and if you know the peer is really there, `pp --send <id> --force`.

## The listener never wakes even though the peer sent

Check them in this order:

1. **Are you on the right side?** `pp --info <id>` prints "yo soy lado a/b". Both sides listening on the *same* FIFO would each wait forever. This is impossible through `pp` (side is recorded at open/join) but possible if `PP_SIDE` was set by hand.
2. **Did the peer's send actually succeed?** It prints `entregado a lado <x>`. Without that line, nothing was written.
3. **Is the ssh still up?** A listener is a long-lived ssh. It runs with keepalives, but a laptop suspend or a network change can still drop it. The task exits non-zero rather than hanging — check the exit status, not just the empty output.

## `--listen` returned instantly with no message

The channel does not exist on the bus. Almost always: the **bus host rebooted** and wiped `/tmp`. `pp --list` will show nothing. Open a new channel — the id is disposable.

## "This channel is not registered on this machine"

You ran a channel command on a machine that never opened or joined it. The side is local state, not something derivable from the id. Run `pp --join <id>` there first. If you *did* join, check you are on the machine you think you are.

## `--info` says "sin listener" while a listener is clearly running

Fixed in the current version, but worth knowing why, because the intuitive check is wrong: **a process blocked in `open(2)` on a FIFO holds no file descriptor yet.** The open has not returned, so nothing appears in `/proc/<pid>/fd` — `fuser` and `lsof` both report the FIFO as unused. Listener presence therefore cannot be probed from the kernel's fd tables; it has to be recorded explicitly. `pp --listen` writes a `listening-<side>` marker before it blocks and removes it via an EXIT trap.

Generalize it: **the absence of an fd is not the absence of a waiter.**

## Messages appear in the wrong conversation

Only possible if both conversations share one channel id. Channels cannot leak into each other — separate directories, separate FIFOs. Open one channel per topic and label them with `--topic`.

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
