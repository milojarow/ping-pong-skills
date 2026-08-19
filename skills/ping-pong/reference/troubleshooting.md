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
3. **Is the ssh still up?** A listener is a long-lived ssh. It runs with keepalives, but a laptop suspend or a network change can still drop it. The task exits non-zero rather than hanging — check the exit status, not just the empty output. Then read the **first line of stderr**, which says *which* of three different things broke: [`--listen` exited 255](#listen-exited-255--the-first-line-of-stderr-says-which-of-three-things-broke).

## `--listen` exited 255 — the first line of stderr says which of three things broke

Exit 255 with an empty body is not one failure, it is three, and they need opposite responses. Do not collapse them into "the channel closed or the connection dropped" — the first line of stderr separates them:

| What it says | What broke | What to do |
|---|---|---|
| `Network is unreachable` | **Your own local network.** The kernel has no route to the bus at all. | Wait for the link to come back, then relaunch. The peer never learned anything happened. |
| `Connection timed out` | The link *to* the bus. Could be your network or the bus's. | Probe the bus before concluding — see the three-step proof below. |
| Empty, with no ssh message | The channel really closed (`--close` from the other side). | `pp --list`: if the id is gone, the conversation is over. |

**`Network is unreachable` is local, always.** It is the kernel reporting it has no route out — the packet never reached the bus. Blaming the remote host, a rebooted bus or an ISP port block is a deduction the data does not support, and it sends the investigation to the wrong machine.

### A 0-byte output does not say what killed it — the exit status does

Since 0.3.0 the listener has **two** possible killers, and both leave the same empty output file, so the 0 bytes discriminate nothing:

- the **ssh client** dying because the link went away (transport);
- the **stdin-EOF watchdog** killing the reader because it believes the session went away.

They call for opposite responses — a retry fixes the first and *hides* the second — so read the exit status and the first line of stderr rather than the empty body:

| Evidence | Killer |
|---|---|
| `exit 255` **plus** `client_loop: send disconnect: Broken pipe` or `Network is unreachable` | **Transport.** 255 is the status ssh reserves for its *own* errors. |
| 0 bytes with an exit status that is **not** 255 | **The watchdog**, or the remote command itself. |

The second row is the one to keep in mind, because a watchdog kill **cannot** counterfeit the first: on that path the connection is healthy, it is the *remote reader* that dies, and ssh reports the **remote command's** status — never 255 with a broken pipe.

Every death recorded so far falls in the first row, and by two independent instruments: deaths over a phone hotspot carried explicit `exit 255` + broken pipe, while a separate run over home WiFi coincided with four full `NetworkManager` disconnect cycles as the wired end ran eight hours uninterrupted. **The cause is transport, not the watchdog.**

**The asymmetry that looks damning, and why it is not.** Counting listener survival by side: the side reaching the bus **over ssh** lost every listener across four channels, while the side whose bus is **local** kept two alive for 4h20m and 1h12m. Zero against hours is not noise, and the only structural difference between the two paths is the stdin-EOF watchdog, which exists solely on the ssh side — so it is the obvious suspect. It is still not the culprit, and the exit codes that clear it were **already recorded in past failures**. Before spending an operator's hours staging a fresh listener just to note its time of death, check whether the failures you already have answer the question.

### The three-step proof, in order

Before relaunching a second time, measure instead of assuming:

```bash
pp --info <id>            # does the channel live? is the peer still listening?
ssh <bus> uptime          # is the bus healthy and reachable RIGHT NOW?
stat -c 'born %w  died %y' <task-output-file>   # how long the listener survived
```

If `--info` answers and the peer shows `LISTENING`, **the channel is healthy and only your side died**. Relaunching is correct and sufficient. A peer that has been listening for hours without moving while your side dies three times is the evidence that the problem is yours, not the channel's.

The listener's lifetime is the datum that reveals the pattern — a socket that dies after hours is a flapping link; one that dies in seconds is something else.

### A listener is a connection, not infrastructure

Measured across three consecutive listeners on a laptop over ordinary home WiFi: **3h52m, 3h02m, 1h05m**. In the same window `NetworkManager` logged four full disconnect/reconnect cycles of the wireless interface. The listener at the other end — on a host with a stable wired link — ran eight hours without a single interruption.

So: **on a machine that suspends or whose WiFi blinks, a listener will die every few hours, and that is not a defect in the channel.** Plan around it rather than debugging it.

What matters operationally is the consequence: while your side is down, the peer's `--send` is **refused, not queued** — there is no mailbox. After recovering a listener, tell the peer to resend anything written during the gap, instead of waiting for a message that was never accepted.

### How this reaches you: the operator says the shell fell

Worth knowing in the operator's own words, because that is the wording the next report arrives in:

- They say **"se cayó la shell"** — *the shell fell* — not "the listener died". What they see is the background command disappearing.
- They experience it as **their own chore**, not as a channel fault: they have to notice which of the two sessions went deaf and tell it to relaunch. It is an attention tax rather than a visible error, so it gets under-reported.
- It shows up **once the conversation has been running a while**, never in a short one — which is exactly why it does not surface in testing.

One inference inside that report decides diagnoses: being able to *tell that session to relaunch* means **the session is still alive when its listener dies**. A finished session cannot be asked for anything. That rules out the tempting rival explanation — "the marker is empty because that session had already ended". It had not.

### Each death costs the agent a turn, not just a reconnect

Measured over a few hours on a machine tethered to a phone hotspot, where `--listen` died four times with `Network is unreachable` / `client_loop: send disconnect: Broken pipe` / exit 255.

Every death produces a **background-task completion notification with a 0-byte output file**, and that notification re-invokes the agent. The agent reads nothing, relaunches `--listen`, and the cycle repeats. On a link that flaps, the session burns turns babysitting a socket while the operator is away and nothing is being received — the turn budget goes to reconnects instead of to work.

The remedy is a flag, and it lives inside the process the harness is watching:

```bash
pp --listen <id> --retry          # 60 attempts, 5s apart (~5 min of dead link)
pp --listen <id> --retry 240      # tolerate longer outages
```

`--retry` re-attaches on **transport failure only**, so the agent is woken by a
message and not by a dropped link. What it deliberately does not swallow:

| Exit | What it is | What `--retry` does |
|---|---|---|
| `255` | the ssh client died — a lost link | re-attaches, after clearing its own reader left on the bus |
| `1` | a refusal (ownership, a live listener on this side) | exits at once; retrying would put a second reader on one FIFO |
| `124` | `--wait` elapsed | honours the bound you asked for |
| `0` + body | a real message | prints it and stops |
| `0` + nothing | the peer closed the channel | stops; there is nothing left to listen to |
| anything else | **not transport** | stops loudly — see below |

That last row is the safety property, not a detail. **Every one of these failures
produces an empty body, so "no output" proves nothing; the exit status is what
separates them.** A death with 0 bytes and a status other than 255 is the shape a
watchdog kill takes, and looping over it would convert a deterministic bug into
silent flapping — the failure mode a retry is most likely to create. `--retry`
refuses to loop there and says so.

Drops are always reported on stderr, including on success (`message received
after 2 transport drop(s)`). A retry that stays quiet hides the degrading link
exactly while it degrades everything else on the machine.

Without the flag, each drop still costs a turn — that is the pre-0.5.0 behaviour
and the reason the flag exists.

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

## A marker is a claim, not proof — and `--info` now says which

The `listening-<side>` file is removed by an EXIT trap. That works when the listener ends cleanly; it does **not** run on `SIGKILL`, so a session killed hard (restart, closed terminal, `kill -9`) leaves the file behind announcing a listener that no longer exists.

Since 0.4.0 nothing trusts the file's mere existence:

- `--info` verifies the pid **on the bus** and reports `LISTENING` or `STALE MARKER — claims … but that process is dead`.
- `--send` refuses on a stale marker instead of delivering into nothing. That was the worst failure shape in the protocol: the write looked successful and the message was gone.
- `--gc` clears the file.

If you are reading a marker by hand, remember it is a claim about a process on another machine, and see the next entry before checking it.

## The pid in a marker is a bus pid — checking it locally gives a confident wrong answer

Observed: a session read the `listening-<side>` marker, took the pid, ran `kill -0` **on its own machine**, found nothing, and concluded the marker was lying. It then started its own listener to replace the "dead" one — and ended with two readers blocked on the same FIFO, which is precisely the failure the marker exists to prevent. The verification produced the damage it was meant to avoid.

The process was alive the whole time. A listener runs **on the bus host**, launched over ssh, so its pid belongs to the bus's pid namespace. From anywhere else that number fails in two ways, and both are convincing:

- it does not exist locally → you conclude "dead" and double up the readers;
- it *does* exist locally, as a completely unrelated process → you conclude "alive", or you kill a stranger.

**Why it reads as local.** Nothing in the record says otherwise. The marker is written by the remote shell as `$$`, and the label beside it is the **side label** (`--as`) — which by convention is often a machine name, just not the machine the pid belongs to:

```
listening-a:  "<side-label> pid=1001 since=<UTC>"
                            ^^^^^^^^ a pid on the bus host, not here
```

So the line invites exactly the wrong reading: a familiar name next to a plausible pid, with no marker of which namespace issued it.

The check has to happen where the pid was issued. `pp --info <id>` already does that — its `kill -0` runs inside the ssh call, which is why its answer is the authority. Probing by hand, the `kill -0` goes *inside* the ssh session, never outside it:

```bash
ssh <bus> "ps -p <pid> -o pid=,etime="
```

And when you do not have the pid, ask the bus by channel id instead of guessing:

```bash
ssh <bus> "ps -eo pid=,pgid=,args= | grep -F '<channel-id>' | grep -v grep"
```

Generalize it: **a pid only means something inside the pid namespace that issued it.** A pid that travels between machines is a number, not a reference — and probing it from the wrong side does not answer "unknown", it answers wrong.

## `--info` says `LISTENING`, a new `--listen` is refused, and the peer's messages land nowhere

Three symptoms that only occur together, and they identify one cause:

- `pp --info <id>` reports `LISTENING`;
- `pp --listen` on that side is refused with *already has a live listener*;
- everything the peer sends is accepted as delivered and is never seen.

An **orphaned reader is swallowing them**. Not the tunnel, not the FIFO, and not a lying marker — there is a real reader holding a real pid, it simply has no session behind it. That is why the refusal is correct and the delivery reports success: every component is telling the truth about a reader nobody owns.

`pp --gc` is the remedy — it reaps disconnected readers on the bus and clears the marker, so the side is free to listen again. If it reports nothing and the symptoms persist, reap by hand: [An orphaned listener outlives the session that started it](#an-orphaned-listener-outlives-the-session-that-started-it).

Read `--gc`'s output carefully. Reaped orphans print on their own `reaped disconnected reader:` lines; the closing `checked N listener record(s), dropped M stale channel record(s)` counts only this machine's local records. **A summary of `dropped 0 stale` does not mean nothing was reaped** — the reap lines are above it.

## A session runs the build it started with — updating the plugin does not move it

Measured: after a new version was published and the plugin updated, a session that reloaded its skills **kept executing the binary from the previous version's directory**. The plugin cache keeps one directory per version, each held by the sessions using it; a session resolves its directory once at startup and stays there, so superseded versions are not swept while anyone still holds them.

This matters more than a wrong version number: **the guards live in the executable, not in the skill text.** A session pinned to a build from before a guard existed still suffers the failure that guard closes — and those are the sessions already mid-conversation, with the most to lose.

- `pp --version` is the ground truth for which build you are actually on. Check it before trusting the presence and ownership behavior described in this file.
- Reloading skills does **not** repin it. Only restarting the session does.
- Close your channels before restarting (`pp --close <id>`), or you leave a reader blocked on the bus — see [An orphaned listener outlives the session that started it](#an-orphaned-listener-outlives-the-session-that-started-it).

Since 0.4.0 you do not have to notice this yourself: `--open`, `--join` and `--listen` compare the build they are running against the newest one installed and print the newer build's **exact path** when they differ. That closes a real trap — a session correctly refused to construct a newer path by hand, because this skill tells it never to hardcode a versioned path, and so it kept running a build that was three releases old. The advice was right; what was missing was the tool handing over the path instead of leaving it to be guessed.

Running that path directly is a stopgap for a session already mid-conversation. Restarting is still the only thing that repins the session.

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

## A message arrived with its HEADER and NO BODY

Measured over a full day on one channel: four consecutive messages from one side
landed as a header with nothing under it. The sender saw `pp: delivered` all four
times and spent hours believing it had answered.

### The blame is ALWAYS the sender's — this is what saves the investigation

In `cmd_send` (and identically in the direct-mode path) the **header is written by
whoever sends**, glued to the body in the same stream:

```bash
{ printf '=== ping-pong %s | from: %s (side %s) | %s ===\n' ...
  printf '%s\n' "$body"
} | bus_stream "timeout $SEND_TIMEOUT cat > .../to-$out"
```

So: **if the header arrived intact, the transport worked.** An empty body cannot be
channel truncation, nor a `--retry` re-attach, nor the receiver's reader. It is
`$body` already empty at the moment of the call.

Corollary for the RECEIVER: do not spend a minute on your reader, your link or your
drops. Tell the sender its `$body` is going out empty and hand it the lines above.

### How `$body` ends up empty with nothing failing

All of these share one signature: exit 0, `delivered`, and no warning.

- `-m "$(cat file)"` where the file is empty, missing, or relative to another cwd —
  `$(cat nosuchfile)` expands to nothing and the command does not fail.
- A heredoc whose content never reached the file.
- A variable from an earlier turn: every Bash tool invocation starts a **new** shell,
  so `MSG="…"` set two commands ago no longer exists.
- **Backticks inside double quotes**: the shell EXECUTES them. `-m "use \`foo\`"`
  eats the word, and if the message was only that, the body is empty. Same mechanism
  as [the message that arrived with words missing](#the-message-was-delivered-but-arrived-with-words-missing)
  — this is its total case.

### The two defences

1. **Check the size BEFORE sending** — a `wc -c` is cheaper than a day of silence:

   ```bash
   cat > /tmp/m.txt <<'END'
   text with `backticks`, $vars and "quotes" kept safe
   END
   wc -c /tmp/m.txt
   pp --send <id> -m "$(cat /tmp/m.txt)"
   ```

   The **quoted** heredoc delimiter (`<<'END'`) disables every expansion, which is
   what makes building the text safe. Better still, send the file through stdin
   (`pp --send <id> < /tmp/m.txt`) — see [pp-cli.md](pp-cli.md#sending-a-message-prefer-stdin-keep--m-for-one-liners).

2. **The one-line test that isolates it**, no files and no variables:

   ```bash
   pp --send <id> -m 'BODY-TEST-1'
   ```

   Arrives with text → the problem is how you build the body. Arrives empty too →
   then it is the sender's `pp` or shell.

### Diagnosing it from the receiving side without guessing

The header's timestamp is stamped by the SENDER, so it is usable for correlation: in
the observed case two of the empty deliveries fell ~90 s and ~2 min after messages
from this side, which proved the peer was awake and answering. Beware the false
pattern, though — two of the four turned out to be **earlier** than anything this side
had sent, and comparing against the real mtimes of one's own files killed that theory
before it was believed.

**Note the cost while it lasts:** each empty delivery still CONSUMES the receiver's
listener and forces a relaunch, so it burns a turn on both sides.

## The message was delivered but arrived with words missing

Not a `pp` failure — the body was damaged by **your own shell** before `pp` received it, and the delivery that followed was perfectly correct.

The cause is `-m "..."`: inside double quotes the shell expands backticks as command substitution, plus `$VAR` and (in some shells) `!`. Each substitution runs, fails, yields an empty string, and that empty string is what gets sent. Because backticks are the habitual way to mark an identifier, the words that disappear are the technical names the message existed to convey, and the sentence still reads as grammatical — the peer cannot tell anything is absent.

**How to spot it:** look at the `--send` command's stdout. A mutilated send prints the delivery confirmation *and*, interleaved with it, a shell diagnostic such as `command not found: <word>`. The exit status is success either way, so the diagnostic line is the only signal.

**Recovery:** resend the message through stdin, and tell the peer explicitly that the previous one arrived incomplete — from their side there is nothing to notice.

```bash
pp --send pp-k7m2qx < /path/to/message.txt
```

**Prevention:** default to stdin for anything beyond a short, punctuation-free line. See [pp-cli.md](pp-cli.md#sending-a-message-prefer-stdin-keep--m-for-one-liners).

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

**Reach for `pp --gc` before doing any of that by hand.** Since 0.4.x it is the automatic reaper, and it runs on the bus, so it sees what your machine cannot: besides the token-proved orphans it owns, it kills any reader on the bus whose parent or grandparent is pid 1 — a reader that survived its ssh gets **reparented**, which is a fact no local state and no version can hide. That backstop needs no token, so it reaches listeners from builds too old to have written one. `--gc` also runs on its own before `--open`, `--join` and `--list`.

Hand-killing is for what remains after that: a reader that is still correctly parented but abandoned, or a bus you can reach only by ssh. Treat an unexplained silent peer as a possible orphan and check `--info` against whether that session still exists.
