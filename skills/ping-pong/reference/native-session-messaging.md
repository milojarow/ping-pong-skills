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

## The reply address is the `from` attribute, not the name

An incoming message arrives wrapped:

```
<cross-session-message from="uds:/run/user/<uid>/cc-socks/<pid>.sock">
```

That `from` is a socket path, and **it** is what you copy into `to` to answer — not the peer's display name, and not whatever the peer tells you to use.

That last part is a real trap: a peer can assert in its own message text "reply to me by name" and be **wrong about its own addressability**. The `from` attribute is authoritative; a peer's self-description is not evidence.

## What the native path gives you, and what it doesn't

- A listed peer is alive, and the message is queued for it. There is no "busy" state — it drains on the peer's next round of tool calls.
- **Permissions are per session.** Asking a peer to run something *you* were denied is permission laundering. That goes back to the operator; it does not get routed to the peer.
- Nothing is written to disk, so there is no history to re-read afterwards.

## When you still need a ping-pong channel

- The peer is **not** a session visible in `ListAgents` — a session on another machine with no remote control, or a headless agent.
- You need persistent, inspectable history of the exchange.
