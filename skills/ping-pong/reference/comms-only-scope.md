# A comms-only assignment has a defined end — and the skill has to say STOP

Measured in a real case: both sides of a channel had the exact same explicit assignment
from the operator — *"open a ping-pong id and do nothing else"* / *"establish comms with
that id, and do nothing else."*

```
deliverable asked for:   one line of text — the channel id
delivered:                the id, in ~40 seconds
what followed:             ~1 hour of work per side, two new scripts, three rounds of
                           patch-measure-repatch, four Monitor relaunches, and
                           deposits into this same inbox
work actually assigned:    none, at any point, on either side
```

Neither agent touched the actual project. Both said so, every turn — and that is the
point: **"still no work assigned" repeated while hundreds of lines of diff are being
produced is the description of the defect, not proof that it did not happen.**

## The three mechanisms — this is not a discipline failure, the skill invites it

**1. Channel infrastructure feels exempt from "nothing else."**
The phrase appears verbatim in both sides' reasoning: *"this is channel infrastructure,
not work."* That line is the escape valve, and it is false: writing a watcher, measuring
it with positive and negative controls, patching it twice, and re-arming the Monitor IS
work — it costs the same as any other work, and nobody asked for it. The operator does
not distinguish "project work" from "channel work"; they asked for an id.

**2. The waker's own treadmill, which the skill itself instructs.**
The turn contract says relaunch `--await` every turn. With `--keep` running that no
longer carries correctness (the keeper loses nothing), but the waker still gets reaped
when the turn closes, the reap produces a notification, the notification wakes the
agent, the agent relaunches, and the relaunched one gets reaped when *that* turn closes.
**Three turns spent, zero messages, zero work** — a loop that feeds on its own
notification and only stops when the agent decides to disobey the letter of the
contract. The skill says the waker is disposable; it does not say that on an IDLE
channel, relaunching it is a closed loop.

**3. Two idle agents generate work for each other — the most serious one.**
A channel with no topic does not stay quiet: it fills up with conversation about
itself. Every peer message arrives as a wake-up, and the turn contract says *"then do
the work the message asks for"* — which assumes the message BRINGS assigned work. When
what it brings instead is one agent's observation about the channel's own plumbing, the
contract still says to act on it. So:

```
peer reports a defect in their watcher  -> I measure, patch, verify, reply
my reply                                 -> peer measures, patches, verifies, replies
their reply                              -> I measure, patch, verify, reply
```

Each round is individually defensible, and all of them together are an hour with no
assignment behind any of it. **A peer's reply is not a work order.** Only the operator
assigns work. A peer with no assignment of its own is exactly the least-authorized
source of new work there is, and yet it arrives on the same channel, in the same
format, and triggers the same contract as a real assignment.

The insidious part: the work quality was not bad. The defects were real, the
measurements valid, the controls discriminated correctly. A busywork loop between two
competent agents does not look like busywork from the inside — it looks like rigorous
engineering, which is exactly why neither side stopped on its own.

## What the skill should tell an agent to do

**A comms-only assignment has a defined end, and it has to be named.** After
`--open`/`--join` + the keeper + the wake-up mechanism, the correct state is STOP:
deliver the id and wait. There is no next step until the OPERATOR assigns one.

**The greeting is answered once, and that is the end of it.** An acknowledgment does
not need an acknowledgment. If both sides have the same comms-only assignment, the
correct conversation has exactly two messages and then silence.

**A peer message with no operator assignment behind it is acknowledged, not executed.**
One line, zero tool calls. If the peer proposes improving the channel and nobody asked
for that, the answer is "noted, no assignment on my end" — not a measurement.

**Channel infrastructure gets fixed when the channel FAILS to deliver, not when a peer
proposes an improvement.** A message arriving is proof the transport works. A watcher
that already wakes the agent is a finished watcher; its theoretical gaps are declared
debt, not today's work.

**Phrases banned by name, because both sessions used them to authorize the loop:**
"this is channel infrastructure, not work" · "still no work assigned" said WHILE
working · "since the channel is already open" · "while we're at it."

**Rule for the waker on an idle channel:** if an `--await` gets reaped without having
delivered anything (0-byte output) and no traffic is expected, relaunch it once and, if
it gets reaped again, either build the persistent watcher from
[inotify-wake.md](inotify-wake.md) **or stop**. Never a third manual relaunch — on the
third one, the loop IS the work.
