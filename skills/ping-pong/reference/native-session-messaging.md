# The native path: `ListAgents` + `SendMessage`

Before building a ping-pong channel, check whether the harness can already reach the peer on its own. `ListAgents` lists the agent sessions this one can talk to, and `SendMessage` delivers to them — no bus host, no FIFOs, no listener of your own, nothing on disk.

ping-pong exists for what that mechanism cannot reach. Reaching for it first, when the peer is already listed, is a channel's worth of setup for nothing.

## Addressing: copy the `[ref]` from the listing on the FIRST send

`ListAgents` returns rows shaped `name [ref]`. **The name is the address** — but not by itself, the first time.

The tool's own documentation says to append ` [ref]` only when the bare name is not enough (two identical rows, or an error asking for it). In practice the ref is demanded as a **first-contact confirmation** for any peer that is not a subagent of this conversation, even when the name is unique in the listing:

```
SendMessage({to: "<peer-name>", ...})
→ {"success": false, "message": "'<peer-name>' is not an agent in this conversation.
   Re-send with the ref to confirm you mean:
     <peer-name> [a1b2c3] — Claude session, on this machine, active 29s ago"}

SendMessage({to: "<peer-name> [a1b2c3]", ...})
→ {"success": true, ...}
```

Not worth working around with a retry: just copy the `[ref]` out of the listing from the first send whenever the target is another session. Measured on Claude Code 2.1.x builds.

A ref only resolves if it came from a **recent** `ListAgents` or from the error message itself. An invented or stale ref does not resolve.

### The confirmation is charged once per peer, not once per message

Measured in both directions on the same session pair: once the two sessions have exchanged messages, the **bare name resolves**.

```
# 1st send, name unique in the listing, no ref
SendMessage({to: "<peer>"})            → success: false   ("Re-send with the ref…")
SendMessage({to: "<peer> [a1b2c3]"})   → success: true

# 3rd send, same peer, AFTER a round trip, no ref
SendMessage({to: "<peer>"})            → success: true
```

Practical consequence: **you do not need a `ListAgents` before every reply** — only before the first send to a peer you have not talked to yet. (To answer, the `from` attribute is still the better address: it requires no listing at all.)

What that run does **not** separate, said plainly rather than left to harden into more than it is: between the send that failed and the send that passed there were *two* events — the send carrying the `[ref]`, and the peer's reply addressed to the `from`. Either one could have opened the route. Isolating them needs a third peer that is written to by `[ref]` and **never answers**, then tried by bare name. Until someone runs that control, the defensible wording is **"after first contact"**, not "after the first send".

## The reply address is the `from` attribute, not the name

An incoming message arrives wrapped, and the `from` attribute comes in at least two forms — the prefix names the transport:

```
from="uds:/run/user/<uid>/cc-socks/<pid>.sock"   → same machine
from="bridge:session_<id>"                        → another machine, over Remote Control
```

Either form is what you copy into `to` to answer — not the peer's display name, and not whatever the peer tells you to use.

Both copy across identically, so the value of telling them apart is **diagnostic**: the prefix says whether the peer shares your disk and your network *before* you ask it for anything. `ListAgents` labels the same split per row (`interactive` vs `Remote Control`), and `SendMessage` restates it in its success response.

That last part is a real trap: a peer can assert in its own message text "reply to me by name" and be **wrong about its own addressability**. The `from` attribute is authoritative; a peer's self-description is not evidence.

## What the native path gives you, and what it doesn't

- A listed peer is alive, and the message is queued for it. There is no "busy" state — it drains on the peer's next round of tool calls.
- **Nothing here can die between turns.** There is no background process and no socket of your own, so the listener-death failure mode simply does not exist on this path — measured across round-trip exchanges both between two sessions on one machine and between a session and a remote host reached by Remote Control, none of which opened a channel. On a flapping link that is worth more than any retry around `--listen`.
- **Permissions are per session.** Asking a peer to run something *you* were denied is permission laundering. That goes back to the operator; it does not get routed to the peer.
- Nothing is written to disk. Neither does a ping-pong channel — see below — so this is not a
  reason to prefer one over the other.

## `ListAgents` is a live census, not a registry

A peer drops out of the listing when its session closes — measured, a peer present in one query was simply gone about ten minutes later. There is no tombstone and no "finished" state; the row stops existing.

Two consequences:

- A `[ref]` taken from an older listing can point at something that is no longer there.
- **Absence from the listing does not prove the peer never existed** — only that it is not there now. If what you need is evidence that the exchange happened at all, the native channel cannot give it: it writes nothing to disk.

## When you still need a ping-pong channel

One reason, and it is the only one: **the peer is not visible in `ListAgents`** — a session on
another machine with no remote control, or a headless agent.

**It is not for history.** A ping-pong channel keeps none. A channel on the bus is a `meta` file,
two FIFOs and a listener marker; the FIFOs are 0 bytes forever because the payload passes through
memory and is consumed by the read. Nothing in the CLI logs a message anywhere.

And a third copy would be redundant even if it existed: each side's own transcript already records
what it sent and what it received, so the exchange is recoverable in duplicate from either end. If
you want to re-read a conversation between two sessions, read either session.
