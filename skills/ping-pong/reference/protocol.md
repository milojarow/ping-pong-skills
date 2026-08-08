# The ping-pong protocol

## Why a bus host

Two sessions on two machines usually cannot both reach each other — one side is behind NAT, a CGNAT, or a firewall that blocks inbound. So ping-pong never tries to connect peer-to-peer. Both sides meet on a **bus host**: one machine that both can reach.

- The session **on** the bus host touches the channel files directly.
- Every other session touches them **over ssh**.

Each machine records which case it is, once, in `~/.config/ping-pong/config`. Nothing is auto-detected — the operator declares it (see [pp-cli.md](pp-cli.md#setup)). Pick as bus host the machine with a stable, reachable ssh endpoint.

## Channel anatomy

A channel is a directory on the bus host, under `/tmp/ping-pong/` by default:

```
/tmp/ping-pong/pp-k7m2qx/
├── meta            # id, created (UTC), side_a label, side_b label, topic
├── to-a            # FIFO — the inbox of side a
├── to-b            # FIFO — the inbox of side b
├── listening-a     # present only while side a has a listener up
└── listening-b     # present only while side b has a listener up
```

**Sides.** Whoever runs `--open` is **side a**; whoever runs `--join` is **side b**. After setup the two are symmetric. Each side listens on its own inbox and writes to the other's:

| Side | Listens on | Writes to |
|---|---|---|
| a (opened the channel) | `to-a` | `to-b` |
| b (joined the channel) | `to-b` | `to-a` |

Each machine remembers which side it is in `~/.local/state/ping-pong/<id>.side`. That is why the same channel id behaves correctly on both machines without any flag — and why running a channel command on a machine that never opened or joined fails with a clear error instead of guessing.

## Isolation

Isolation is structural, not a convention: **each channel has its own directory and its own pair of FIFOs.** A write to `pp-aaa1/to-a` is physically unable to appear in `pp-bbb2/to-a`. Two pairs of sessions can run concurrently on the same bus host, with the same users, and never see each other's traffic.

Verified behavior: with two listeners up on the same machine for two different channels, delivering a message on one leaves the other blocked with zero bytes read.

Consequence worth planning for: **one channel = one conversation.** If two topics share a channel, both sides get an interleaved inbox and no way to tell the threads apart. Opening a second channel costs one command.

## Why FIFOs, and what that buys

A FIFO read blocks in the kernel until a writer appears. That gives, for free:

- **Zero CPU while waiting.** No polling loop, no timer, no wasted tokens.
- **An exact wake-up edge.** The reader returns the instant a message lands — which, run as a background command, is exactly what makes the harness notify the agent.
- **No stale state.** Nothing is stored; a message is handed straight from writer to reader.

What it does **not** buy, and you must design around:

- **A FIFO read is one-shot.** `--listen` delivers exactly one message and exits. Relaunch it every turn.
- **There is no queue.** A message sent while nobody is listening is not stored. `--send` refuses up front rather than hanging (see below).
- **Nothing survives a reboot** of the bus host — `/tmp` is wiped. Channel ids are cheap; open a new one.

## The turn contract

The rule that keeps the protocol race-free:

> After being woken, relaunch your listener **before** you reply.

The invariant it maintains: **at any moment, exactly one side is thinking and the other is listening.** Walk one cycle:

1. Both sides listening.
2. A sends. B's listener returns and exits — B's listener is now down, A's is still up.
3. B relaunches its listener, *then* replies. A's listener is up, so the reply lands. A's listener is now down.
4. A relaunches, then replies. And so on.

Break the ordering — reply first, relaunch after — and there is a window where neither side is listening, so the peer's answer has nowhere to land.

### What consumes a listener, and therefore what triggers a relaunch

Only a message arriving at **your** inbox consumes your listener. `--send` writes to the peer's inbox (`to-<other side>`) and never touches your own reader — the same asymmetry that makes a simultaneous send safe, below. Two consequences:

- **Relaunch when the previous `--listen` returned content**, not when you are about to reply. Relaunching after a send is always redundant, and it is not free: the redundant `--listen` is refused, the background task completes, and the agent is woken with nothing to read. One wasted round trip per occurrence.
- **An empty output is not a message.** A completion notification with zero bytes means the listener died or was refused; read the output before deciding what to do.

The refusal is deliberate and **must not be retried in a wrapper loop**:

```
side <x> of channel <id> ALREADY has a live listener (pid N on the bus)
```

It exits non-zero and stops there. This is not a transient failure — retrying until it succeeds would put two readers on one FIFO, where one swallows the next message and the other wakes with zero bytes. That is precisely the failure the guard exists to prevent. Exit distinctly and let the caller decide.

The one case the contract does not cover is **both sides initiating at the same instant** on an idle channel. That case is measured, not reasoned about, and it is safe — but its consequence is the reason the contract is more than hygiene.

## A simultaneous send from both sides

**Measured**, with two machines firing against a clock-compensated schedule and a real separation of **1 ms**: both messages are delivered, `rc=0` on both sides, each side receives the *other's* message with the correct `from:` in the header, no corruption and no rejection. Neither side gets its own message back and nothing is lost.

**Why a tie cannot fail — the structural argument.** This is not timing luck, it is impossible by construction:

- Your `--send` targets the **peer's** inbox (`to-<other side>`).
- The reader of that inbox is the peer's listener, and **the only thing that consumes it is a message arriving at that inbox** — that is, yours.
- Therefore **your own send never removes the reader you are aiming at**, and the marker check has nothing to race against. Symmetric on the other side.

The TOCTOU window one imagines — check the marker, the marker disappears, write blind — does not exist here: what takes *your* listener down is the peer's message, and that message does not touch the listener *you* are writing to.

### The consequence that actually matters

After a tie **both listeners are down at the same time**. That is the one moment the invariant "exactly one side is thinking and the other is listening" breaks — and it isn't broken by a bug, it's broken by the symmetry.

Measured immediately after: replying without relaunching the listener is **refused** (`side <x> has no listener`). Which means the turn contract — relaunch *before* you reply — is not merely good practice after an ordinary turn: **it is the mechanism that recovers from a collision.** If both sides honor it, the tie absorbs itself on the very next turn and no extra logic is needed anywhere.

The only thing an agent must do differently: **read the header before assuming a message answers what you asked.** In a tie, what arrives is the peer's own initiative, not a reply.

### Proving a tie between two machines

A cross-machine tie is not produced by "firing both commands quickly" — connection latency dominates and you end up measuring a *crossing*, not a tie. You have to **compensate the clock offset**, which means being able to measure it:

- NTP-style offset: `offset = t_remote - (t_before + t_after)/2`, taking the median of several probes. The uncertainty is **±RTT/2**, so the RTT is the ceiling on your precision.
- **A fresh ssh connection per probe gives RTT ~1.4 s → ±700 ms of uncertainty: useless.** Multiplexing the connection (`ControlMaster` + `ControlPersist`) drops the RTT to ~266 ms → ±133 ms, which is enough.
- Each side waits for an absolute instant in milliseconds (`date +%s%3N`), the remote one corrected by the offset. Busy-wait, not `sleep` — a `sleep 0.02` injects jitter the size of the effect you are hunting.
- Record and report the **real** firing instant on each side and the resulting delta. Without it you cannot tell whether you tested a tie or a crossing: on the first, uncompensated run of this experiment the separation was **2 seconds**, and it read exactly like "it worked".

## Message format

`--send` frames the body with a header line so the receiver always knows the channel, the author, and the time:

```
=== ping-pong pp-k7m2qx | from: <label> (side a) | 2026-01-01T12:00:00Z ===
<body, any number of lines>
```

Timestamps are UTC by design. Bus hosts and workstations frequently run different zones, and comparing local timestamps across them silently shifts events by hours.

## Delivery guarantees, stated plainly

| Property | Guaranteed? |
|---|---|
| Message arrives intact, including UTF-8 and newlines | Yes |
| Delivered to the right channel and side | Yes |
| Delivered when nobody is listening | **No** — refused up front, message not stored |
| Survives a bus-host reboot | **No** |
| Ordered, when one side sends twice in a row | Only if the peer relistens between them |
| Encrypted in transit | Over ssh, yes. On the bus host itself, it is a mode-600 FIFO in a mode-700 directory |

`--open` refuses to run if the bus root exists but is owned by another user — cheap protection against a pre-created directory on a shared machine.
