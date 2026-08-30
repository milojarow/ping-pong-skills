# Event-driven wake: an inotify watcher instead of relaunching `--await`

`--await` still has to be relaunched in the background once per turn (see the turn
contract in `SKILL.md`). For a session that stays open a long time, wire the spool file to
a persistent, event-driven watcher instead, so nothing has to be relaunched by hand.

**There is no webhook primitive in ping-pong** — nothing lets the peer's send reach into
the harness and invoke you directly. The combination below is the practical equivalent:
`--keep` holds a reader outside any turn's process tree and spools every delivery, and a
persistent watcher on that spool turns the OS-level write into a harness task-notification.
From the harness's side that notification **is** the webhook — it re-invokes the session
with the unread bytes already sitting in the spool, no polling loop and no timer parked
anywhere.

**Each side has to arm its own.** Waking on a delivery to your spool says nothing about
whether the peer has the same arrangement — if the peer also needs event-driven wake-up,
that is a second, independent setup on their side, worth agreeing over the channel rather
than assuming.

## The design

    keeper (`pp --keep`)   → writes each delivery into the spool
                              (`~/.local/state/ping-pong/<id>.inbox`)
    inotify                → the KERNEL fires an event when the spool is closed after a write
    a persistent watcher   → turns that event into a short notification to the session

Set up once per session with a persistent background watcher (for example a harness's
`Monitor(..., persistent=true)` wired to a small wrapper script). The notification should
carry only the **timbre** — which channel, who wrote, how many lines, the spool path — not
the message body. Dumping the whole delivery into the notification defeats the point: the
full text is already sitting in the spool for `--await` to read on demand.

## Other correctness details a wrapper script needs

Each of these is backed by a measured failure, not a hypothetical one:

- **Name each capture file with sub-second resolution (nanoseconds), not whole seconds.**
  Two deliveries landing in the same second collide on a seconds-resolution name: the
  second capture truncates the first one to empty before it is read. The observed
  symptom was a notification confidently announcing "93 lines" while the file it pointed
  to was 0 bytes — true when written, false half a second later.
- **Only notify when the capture file actually has bytes** (`[ -s "$tmp" ]`). Without that
  guard, every write that doesn't bring new mail still fires a notification that sends the
  session to go read nothing. An empty file is not a message.
- **Fail loudly if the inotify tooling isn't installed.** A pipeline built on it (piping
  its output into a read loop) silently produces nothing and returns no error when the
  binary is missing — the watcher looks armed forever and never fires. The dependency is
  not guaranteed to be present on every machine — verify before reusing a script as-is. A
  `tail -F` on the spool, which talks to the same kernel facility directly, is the portable
  fallback where the package isn't available.
- **Watch the containing directory and filter by the exact filename you expect, never a
  glob.** That directory is typically shared by every channel/project on the same
  machine — a glob picks up traffic that belongs to a completely different, unrelated
  conversation on the same box.

## This design does not apply to a DIRECT channel as-is — there is no keeper, so no spool

Everything above starts from "the keeper writes the spool, inotify fires on the write." A
channel opened with `--open --direct` has no keeper today (`--keep`/`--info` hit the bus and
fail there — see [troubleshooting.md](troubleshooting.md#--keep-and---info-on-a-direct-channel-say-does-not-exist-on-the-bus)),
and therefore never gets a `.inbox` / `.cursor` pair — a direct channel's state on disk is only
`<id>.direct`, `<id>.owner`, `<id>.side`. Arming a watch on a spool path that will never be
created is not a broken watcher, it is a correctly-armed watch on nothing: it stays silent
forever, and that silence is indistinguishable from a quiet peer, which is exactly the failure
mode this whole document exists to design around.

**The fix does not need a bus.** Direct mode already has what a feeder needs — a blocking
read (`pp --listen <id> --retry`) — it is just not wired to a spool. A loop that supplies the
missing half, entirely outside `bin/pp`:

```bash
# direct-mode feeder: plays the keeper's role for one channel, no bus involved
while :; do
  body=$(pp --listen "$id" --retry 2>>"$err")
  rc=$?
  [ $rc -eq 0 ] && [ -n "$body" ] || continue        # empty/refused: nothing to spool
  printf '%s\n' "$body" >> "$spool"
  n=$(printf '%s\n' "$body" | wc -l)
  echo "MAIL $id from:$(printf '%s' "$body" | sed -n 's/.*from: \([^ ]*\).*/\1/p') lines:$n spool:$spool"
done
```

Run under the harness's persistent Monitor (never a bare background loop — see
[standing-listener.md](standing-listener.md#a-loop-parked-outside-every-session-is-not-a-cheap-supervisor)
for why that distinction matters), it is leashed to the session's own lifetime, so it cannot
become the immortal loop SKILL.md prohibits — and inotify becomes unnecessary, because the
loop already knows the instant mail lands; it does not need the kernel to tell it.

Every correctness rule already on this page still applies to that spool once it exists:
nanosecond-resolution capture names, notify only when the capture actually has bytes, drain
before arming, and the guard-plus-drain pairing for the cursor covered later in this document
— any hand-rolled reader over this spool must copy it, not just the "pending mail" half.

**One more detail specific to the direct-mode loop above:** run `--listen --retry`, never a
bare `--listen`. Between one iteration and the next the inbox port is released and re-bound,
and that gap is a race — a send that lands during it is a transport failure, not a real
absence of mail. A bare `--listen` has no recovery from that and the feeder loop dies silently;
`--retry` re-attaches on exactly that class of failure and keeps surfacing on a real refusal or
a closed channel, so no genuine failure gets swallowed by the retry.

The proposal to make this a real `--keep` for direct mode — instead of a loop built per
session — is tracked as a known gap in `CLAUDE.md`; nothing here should be read as saying that
exists today.

## Two different silences: the keeper is down vs. the bus is gone

A spool that has stopped growing looks identical to a peer that has gone quiet. A watcher
built to check only "did it grow" inherits that same blindness: measured, a first version
watching just spool growth and keeper liveness stayed silent through two separate channel
disappearances in one day, because the only thing it could report was "the expected signal
did not arrive" — indistinguishable from "nobody has written yet." **Watch the pipe, not
only the content**: growth proves a message arrived, keeper-liveness proves a reader is
still there, and channel presence (`pp --info <id>` / `pp --list`) proves the pipe itself
still exists. A watcher that only watches the first one can never report the absence of the
other two.

There are two distinct causes behind the spool going quiet, and only one of them is visible
to the obvious check:

| cause | how to detect it |
|---|---|
| the keeper process died | a service-manager liveness check on the keeper unit — cheap, immediate |
| the underlying bus/channel was reset out from under a still-running keeper | the liveness check keeps reporting the unit as `active` |

The second case is the trap, and it was measured, not assumed: the channel's backing
directory was removed out from under a live keeper, and the keeper's own supervisor kept
calling it healthy for over a minute afterward, its reader blocked on a pipe that no
longer existed. What actually catches it is asking the channel itself — `pp --info <id>`
reports the channel as gone once the bus no longer has it, and full metadata with no false
alarm while it's alive. That probe is slower than the local liveness check (it can cost a
network round trip), so poll it on a longer interval than the cheap check; a costly probe
run too often becomes its own denial of service.

This matters because the failure mode in both cases is **silence**, which is
indistinguishable from the peer simply not having written anything yet. Without a pulse
check, a session can believe it is listening for hours while nothing is actually being
watched.

## inotify coalesces — count coverage, not events

A tempting control for any watcher built on inotify is "write twice, confirm exactly 2
events fire." That control is invalid, and it fails in a way that looks like flakiness
rather than a wrong test: three identical runs of "write twice to the same file, expect 2
events" returned 2, 2, 1 — the control did not agree with itself across repeated runs,
which makes the control the suspect, not the watcher.

**Cause:** inotify coalesces events that are identical (same watch descriptor, mask,
cookie and name) if the reader has not drained its queue between them — see `inotify(7)`.
Two writes close together can be delivered as a single event; the same two writes spaced
apart are delivered as two. The event count you observe depends on timing, so a test that
only exercises the spaced-out case is testing the comfortable path, not the real one.

**Consequence for design, not just for testing:** one event is not one message. A watcher
that does a single read per event drops mail silently — no error, no log line. The
correct control does not count events at all — it asks, once things settle, whether
*everything that was written* is accounted for. That guarantee has to live in a cursor a
reader advances as it drains, not in a tally of kernel wake-ups. The design that gets this
for free: the inotify event only WAKES the reader; the actual read drains everything past
a stored cursor in one call and advances it — so a burst of coalesced writes still ends up
fully delivered on the next drain.

## The blind window at startup

Between the moment a channel is opened and the moment a watch is actually armed on it
there is a gap. Anything written into the spool during that gap fires no future event and
sits there forever with the read cursor behind it — worse for a watcher built on a
`tail -F`-style follow, which starts reading at end-of-file by definition. The fix: drain
the spool once, unconditionally, *before* arming the watch, not after and not only on
error. That single drain has recovered a real message that the watch itself would never
have reported.

## Readiness: don't `sleep` past the arming step

Waiting for a watch to be armed with a blind `sleep` is a race, not a fix, and is what
made an early version of this flaky to reproduce. `inotifywait` run without `-q` prints
`Watches established.` on stderr — that line is the actual ready signal, not a guessed
delay.

## The pending-mail guard and the drain that advances the cursor are one mechanism, not two

Shipping half of this pair does not weaken the bug, it inverts it. Any hand-rolled watcher
built on this spool needs both pieces below, and needs them changing the same cursor file.

Three versions of the same pre-arm check, in the order they get tried:

1. **`[ -s "$SPOOL" ]`** — "the spool has bytes" is not "there is unread mail". The spool is
   append-only and never truncated, so this fires PENDING on every single re-arm for the rest
   of the channel's life, even once everything in it has already been read. Symmetric with the
   failure already named above: a full file is not new mail either, the same way an empty one
   is not silence.
2. **Compare against a cursor that nothing ever advances.** This looks like the fix and is
   worse: since the cursor never moves, the reported backlog only grows, turn after turn —
   louder than (1), and louder in the wrong direction.
3. **Compare against a cursor that the drain step always advances on a successful read.**
   Correct — but only if the guard and the drain are the same pipeline, not a guard that fires
   and a separate command someone has to remember to run.

```bash
# guard, inside the watcher, before it arms
off=$(cat "$STATE/$ID.cursor" 2>/dev/null || echo 0)
size=$(wc -c < "$SPOOL")
[ "$size" -gt "$off" ] && echo "PENDING $ID | $((size-off)) bytes undrained"

# drain, run when the watcher wakes the session
off=$(cat "$CUR" 2>/dev/null || echo 0); size=$(wc -c < "$SPOOL")
[ "$size" -le "$off" ] && { echo "(nothing new)"; exit 0; }
tail -c +$((off+1)) "$SPOOL"; printf '%s' "$size" > "$CUR"
```

**Put the drain in a script, not a command typed by hand.** As long as advancing the cursor
depends on the agent remembering the right `tail` invocation, the guarantee lives in the
agent's memory, not in the cursor on disk — the opposite of what a cursor is for.

## Reopening a channel under the same id can leave the cursor pointing past the new spool's end

A cursor file survives a clean channel close even though the spool it was tracking does not.
Rejoin the same id later and the read cursor can be far ahead of a spool that was just
recreated from empty — and from there, messages vanish with **no signal at all**: no error, no
log line, nothing in `--list`.

Why it is silent: the drain's own `tail -c +$((off+1))` on a cursor past end-of-file reads
nothing and reports nothing wrong. And the pre-arm guard from the section above —
`size > off` — is **false** whenever the cursor is ahead of the spool, so it does not even
raise PENDING. Both sides end up believing the channel is quiet.

**The built-in `pp` already carries the fix, in `cmd_await`, as one line:**

    size=$(stat -c %s "$spool"); [ "$size" -lt "$cur" ] && cur=0

Any hand-rolled reader built directly on the spool — which is exactly what the event-driven
design on this page invites — has to copy this line itself; nothing enforces it from outside
`cmd_await`. Add it to both the watcher's guard and the drain:

    if [ "$size" -lt "$off" ]; then
      echo "STALE CURSOR: cursor=$off > spool=$size — reset to 0"
      off=0; printf '0' > "$CUR"
    fi

**Verify with a negative control, not just a positive one.** A run that behaves correctly with
the guard in place proves less than a run that behaves *incorrectly* without it — the negative
control is what confirms the guard is the thing changing the outcome, not coincidence. Without
the fix, a drainer facing a cursor far past the spool's size reports something like
`(nothing new: cursor=999999 spool=3166)` — the two numbers it prints in the same breath already
contradict the claim, but nothing reads them before affirming "nothing new."

**Confirmed against a live reopen, not only synthetically:** the same asymmetric cleanup that
clears `.direct`/`.owner`/`.side`/`.inbox` on close but leaves the separately-written `.cursor`
behind reproduced this on the very first ordinary reopen after the fix landed — a larger
backlog than the case that motivated the fix in the first place, because the cursor had
accumulated a full prior conversation's worth of bytes. The guard caught it and reset to 0
before the first message was lost.

This only shows up on a **reopen** of the same channel id — a channel opened once and never
revisited cannot exhibit it, which is exactly why it is easy to ship a reader that has never
seen the bug.

## Nothing is lost if the watcher crashes

The spool is append-only and the read cursor only advances on a successful drain, so a
dead watcher does not lose mail — the next `--await` (manual or re-armed) picks up
everything written since the last successful read. This was confirmed by recovering a
complete message with a direct read of the spool after a naming bug had made it vanish
from the watcher's own output file.
