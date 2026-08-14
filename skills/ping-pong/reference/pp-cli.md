# `pp` — CLI reference

Operations are **flags**. The bare argument is **always the channel id**, so it never collides with a subcommand name. Every command prints feedback, including when the result is empty.

The script ships at `<skill base dir>/bin/pp`. For interactive use, `pp --install` copies it to `~/.local/bin/pp` — re-run it after a plugin update, since it is a copy, not a symlink.

## Setup

One-time, per machine. Nothing is auto-detected.

```bash
pp --setup --bus-local          # this machine HOSTS the bus
pp --setup --bus-ssh <alias>    # the bus is <alias>, reachable by ssh
```

`--bus-ssh` also probes the alias and warns if it cannot connect or the host lacks `mkfifo`. `<alias>` is anything your ssh config resolves — a `Host` entry, `user@host`, etc. Key-based auth is required: every call runs with `BatchMode=yes` and will not prompt for a password.

Written to `~/.config/ping-pong/config`:

```
bus_mode=ssh
bus_ssh=<alias>
```

## Operations

| Flag | Short | Argument | What it does |
|---|---|---|---|
| `--open` | `-o` | — | Creates a channel, prints the id and the line to hand over. You become side a. |
| `--join` | `-j` | channel id | Registers this machine as side b of an existing channel. |
| `--listen` | `-L` | channel id | **Blocks** until one message arrives, prints it, exits. Run it in the background. |
| `--send` | `-s` | channel id | Sends a message to the other side. |
| `--list` | `-l` | — | Open channels on the bus, with topic and which side you are. |
| `--info` | `-i` | channel id | Channel metadata plus who currently has a listener up. |
| `--close` | `-c` | channel id | Removes the channel from the bus and forgets it locally. |
| `--gc` | `-g` | — | Reaps orphaned readers, clears dead listener markers, drops stale local records. |
| `--adopt` | — | channel id | Transfers ownership of the channel to this session. |
| `--mesh` | — | — | Direct mode's first command: reports whether this machine **and the peer** are on one mesh, and prints the block to hand over when they are not. Exit 0 = ready. |
| `--setup` | — | — | Writes the bus configuration (above). |
| `--install` | — | — | Copies the script to `~/.local/bin/pp`. |
| `--help` | `-h` | — | Usage. |
| `--version` | `-V` | — | Version. |

## Modifiers

| Flag | Short | Applies to | Meaning |
|---|---|---|---|
| `--topic "..."` | `-t` | `--open` | Human-readable subject, shown in `--list` and `--info`. |
| `--as <label>` | `-a` | any | Signature on your messages. Defaults to the short hostname. Sanitized to `[A-Za-z0-9._-]`, max 32 chars. |
| `--message "..."` | `-m` | `--send` | The body. Without it, the body is read from **stdin**. |
| `--wait N` | `-w` | `--listen` | Give up after N seconds and exit **124** instead of blocking forever. |
| `--force` | `-f` | `--send` | Skip the listener check and write anyway. |
| `--adopt` | — | open/join/listen/send/close | Override an ownership refusal and claim the channel for this session. |
| `--direct` | — | `--open` / `--join` | Create or join a **direct** channel: no bus, peer-to-peer over a private mesh. |
| `--peer <addr>` | — | `--open --direct` / `--join --direct` | The peer's mesh address. **Optional** when exactly one other machine is on the mesh — there is nothing to choose, and a relayed address is only an opportunity for a typo. Required once there are two or more. |

### Direct mode

No bus host, no ssh, no shell granted. Your inbox is a TCP port on your own machine, bound to the mesh interface only; the peer connects to it.

#### `--mesh` — the first command, and the one that prevents the expensive mistake

A tailnet belongs to an **account**, not to a network. Two people who each run `tailscale up` and each authenticate with their own account land in **two separate tailnets**, each alone. Both machines report `Connected`, both hold a `100.x` address, neither prints a warning, and they cannot reach each other. Measured in production, where it survived a full round trip through two humans before anyone read the actual peer list.

`--mesh` reports which of four states you are in, and prints the hand-over text for the ones that are not ready:

| State | Exit | Output |
|---|---|---|
| `tailscale` not installed | 1 | Install + `up` commands |
| Installed, not logged in | 1 | `sudo tailscale up`, plus the warning not to open the URL if the *partner* owns the tailnet |
| Logged in but alone | 1 | A ready-to-paste block written **for the partner**, covering install, `up`, the do-not-open-the-URL rule, the logout/retry recovery, and the check that proves it worked |
| Ready | 0 | Both lines with their accounts, and the command to open the channel |

The discriminant it applies, and the one to apply by hand if you ever read a raw `tailscale status`: **the peer must appear, and column three — the account — must match yours.** `up` succeeding is not evidence of anything.

Getting both devices into one tailnet, two supported ways:

- **Pre-auth key.** The host mints one at `login.tailscale.com/admin/settings/keys`; the partner runs `sudo tailscale up --auth-key=<key>`. One command, no relay. It is a secret: single-use, short expiry.
- **URL relay.** The partner runs `sudo tailscale up` and sends the printed URL to the **host**, who opens it under the host's account.

Already in the wrong tailnet: `sudo tailscale logout && sudo tailscale up`, then relay the new URL.

#### Minting the pre-auth key: admin console or REST API — there is no CLI

Do not go hunting for a `tailscale` subcommand to mint a key; the CLI has none (its full subcommand list covers `up`/`down`/`status`/`serve`/`funnel`/`cert`/`lock` and friends — nothing for keys), and no Tailscale MCP server exists either. The only two paths are the admin console and the REST API.

    POST https://api.tailscale.com/api/v2/tailnet/-/keys
    Authorization: Bearer <access-token>

`-` in the tailnet path means "the default tailnet of the access token", which is the right choice for most callers. The part worth copying is the **nesting** — the flags live three levels down, not at the top:

```json
{
  "description": "<max 50 alphanumeric chars, hyphens allowed>",
  "expirySeconds": 3600,
  "capabilities": {
    "devices": {
      "create": {
        "reusable": false,
        "ephemeral": false,
        "preauthorized": true,
        "tags": []
      }
    }
  }
}
```

`expirySeconds` defaults to 90 days when omitted — set it short for a hand-over key. `preauthorized: true` matters when device approval is enabled on the tailnet: without it the device registers but stays unapproved, which looks exactly like a key that did not work. A key minted by an **OAuth client** must carry tags; one minted with a personal access token has no such requirement.

To read the contract yourself, the official OpenAPI 3.1.0 spec is at `https://api.tailscale.com/api/v2?outputOpenapiSchema=true` — it is **YAML** despite the JSON-looking query, so `jq` fails on it with `Invalid numeric literal`. Parse it with a YAML loader.

**The economics invert the usual advice, so state them before reaching for the API:** the access token itself can only be created in the admin console. For a ONE-OFF key the console is therefore strictly cheaper — you have to go there either way, and the API adds a token to store and rotate. The API only pays off once minting is routine.

#### Addresses, not names

`--peer` takes the `100.x` address. MagicDNS depends on each machine's DNS wiring — measured non-functional on a machine whose mesh was otherwise perfectly healthy (`systemd-resolved` and NetworkManager wired together incorrectly, which Tailscale reports only in its health check and which nothing else surfaces). An address always resolves; a name is a second thing that can be broken, and it fails at connect time, long after the handover.

#### Host firewalls do not need a hole

On a machine with `ufw` default-deny incoming and no rule for the inbox port, the obvious conclusion is that the peer will be dropped. It is wrong: Tailscale installs a `ts-input` chain that the kernel's input hook jumps to **before** the firewall's own chains, holding an unconditional accept for the mesh interface. Verified in a live ruleset, with matching packet counters. Read the ruleset before opening a port.

The corollary is the disclosure worth making to a partner before they join: everything on your machine listening on `0.0.0.0` becomes reachable from the mesh. `ss -tln` lists exactly that.

| Piece | Bus mode | Direct mode |
|---|---|---|
| Inbox | a FIFO on the bus host | a TCP port on your machine |
| Blocking read (the wake-up) | `cat` on the FIFO | `nc -l` on the port |
| Send | write to the peer's FIFO | connect to the peer's port |
| Presence check | a marker file that can go stale | the TCP connect itself |
| Setup cost | one host both sides can ssh into | each device joins the mesh once |

The port is derived from the channel id, identically on both sides, so it never has to be carried across and two channels between the same pair of machines cannot collide.

Environment: `PP_MESH_IP` sets the bind address explicitly — use it when the mesh is not Tailscale, or to pin which interface the inbox listens on. Without it the address comes from `tailscale ip -4`, and a machine that is not on the mesh gets a refusal telling it to run `tailscale up`, rather than silently binding somewhere public.

### Ownership, and how a session is identified

`--open` and `--join` record the calling **session** as the channel's owner; `--listen`, `--send` and `--close` refuse when a different, still-live session on this machine owns it. The session is resolved by walking up the process tree to the agent process — its pid is stable for that session's lifetime and unique on the machine. Override it with `PP_SESSION` when scripting.

Three outcomes:

| Situation | What happens |
|---|---|
| No owner recorded yet (channel from an older version) | Claimed silently on first use |
| Owner is this session | Proceeds |
| Owner is another session, still alive | **Refused**, naming both sessions. `--adopt` overrides |
| Owner session is gone | Adopted automatically, with a note on stderr |
| Called from a plain shell, no agent ancestor | Checks are permissive — sessions cannot be told apart |

### What `--gc` sweeps

Three distinct kinds of litter, all scoped to this machine:

1. **Orphaned readers** — a reader still blocked on the bus whose local session is gone. Reaped two ways: by process group where the marker carries a token written by this machine, so a recycled pgid is never killed by mistake; and, as a backstop, any reader on the bus whose parent or grandparent is pid 1. A reader that outlived its ssh gets **reparented**, so that second check needs no token, no local record and no matching version.
2. **Dead listener markers** — the marker file outlived its process. No kill needed; left in place it makes `--send` report success into nothing and blocks a legitimate re-listen.
3. **Stale local records** — `.side` / `.owner` / `.listener` for channels that no longer exist on the bus.

It runs automatically before `--open`, `--join` and `--list`.

**Reading its output:** reaped orphans print on their own lines as they are killed. The closing `checked N listener record(s), dropped M stale channel record(s)` counts only this machine's local records, so `dropped 0` is not a statement that nothing was reaped.

A reader started by a version older than 0.2.0 has no token and so escapes the token-proved path, but the reparenting backstop still reaches it once its connection is gone. What neither path can touch is a reader that is still correctly parented to a live ssh — an abandoned-but-connected reader has to be killed by pid on the bus.

### Choosing a `--as` label

Since 0.7.0 the default is **`host:project`** — the short hostname plus the basename of the working directory (just the hostname when that would be the home directory, which carries no information). Override it with `--as` or `PP_LABEL`.

The default changed because a label of only the hostname makes **every channel between the same two machines look identical** in `--list`: `host-a <-> host-b`, repeated, distinguishable solely by a free-text topic somebody has to read carefully. That is not a weak convention, it is the absence of one — and it is how a message reached the wrong channel in production. With the project in the label the pairs separate themselves:

```
workstation:storefront  <-> server:storefront-api
workstation:billing      <-> server:billing-worker
```

If you set it by hand, pick **one short, stable label per channel** and reuse it — the peer sees it as the author on every message, so a label that changes per message makes the transcript unreadable. It never affects routing, which is decided entirely by channel id and side; its whole job is to let a human tell two channels apart at a glance.

Labels are sanitized to `[A-Za-z0-9._:-]`, max 40 characters. `/` is deliberately excluded: it would break the substitution that writes the label into the channel's `meta`.

### When `--wait` is right

Default to a bare `--listen` with no timeout. A conversation has no deadline, the wait costs nothing, and an untimed listener is the wake-up mechanism the whole design rests on.

Reach for `--wait N` only when you need the session to regain control if the peer never answers — a handoff you must report on, or a channel you suspect is dead. Exit 124 means "nothing arrived"; the channel is still open, and you can listen again.

### What `--force` actually does

It skips the marker check, nothing more. The write still needs a reader on the other end: with nobody there it blocks for `PP_SEND_TIMEOUT` (60 s by default) and then fails with exit 124 — a stalled turn and an undelivered message.

So `--force` is correct in exactly one case: the peer **is** reading, but not through `pp` (a raw `cat` leaves no marker), or its marker went stale after an unclean exit. It is the wrong tool when the peer simply has not started yet — there, wait for their listener.

## Sending a message: prefer stdin, keep `-m` for one-liners

`-m` hands the body to **your shell** before `pp` ever sees it. Anything longer than a plain sentence goes through stdin instead, which preserves newlines and UTF-8 byte for byte:

```bash
pp --send pp-k7m2qx < report.md
printf 'line one\nline two\n' | pp --send pp-k7m2qx
```

### Why stdin is the default, not just the long-message path

Inside double quotes a shell still expands backticks, `$VAR`, and — in some shells — history references. The expansion happens *before* the argument reaches `pp`, so the substitution's (usually empty) result is what gets sent.

The failure mode this produces is the worst kind: **the message is delivered successfully and arrives with words missing.** Backticks are the natural way to mark an identifier (`/some-command`, `a_table_name`, `some-flag`), so the terms that vanish are exactly the technical names the sentence was built around — and what lands on the peer's side is still grammatical, so nothing looks broken. The peer has no way to detect the gap from their end.

Measured shape of it: the command reports delivery, and mixed into the same stdout is a `command not found: <the word that was in backticks>` from the shell. Both outputs are real; only the second one tells you the message was mutilated.

Two consequences:

- **Default to stdin for any message that is not trivial.** It is not shell input, so backticks, quotes, `$`, `!`, newlines and accented characters all survive intact.
- **If you use `-m` anyway, use single quotes**, which suppress expansion — accepting that the body then cannot contain an apostrophe. That constraint is hard to hold in prose, which is why stdin is the recommendation rather than a quoting rule.

### Checking a send after the fact

Read the `--send` command's own stdout, not just its exit status. Alongside `delivered`, any `command not found` (or any other shell diagnostic) means part of the body was eaten. Resend through stdin and tell the peer the previous message arrived incomplete — they cannot see the omission themselves.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `PP_BUS_ROOT` | `/tmp/ping-pong` | Channel root on the bus host. Must match on both sides. |
| `PP_SEND_TIMEOUT` | `60` | Seconds `--send` waits for the write to complete before giving up. |
| `PP_LABEL` | short hostname | Default `--as` label. |
| `PP_SIDE` | — | Forces the side (`a` or `b`), overriding local state. Only needed to drive both ends from one machine while testing. |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success. For `--listen`, a message was received and printed. |
| 1 | Error — the message on stderr names the cause and the fix. |
| 124 | `--listen --wait N` timed out, or a send exceeded `PP_SEND_TIMEOUT`. The channel is still open. |

## Files

| Path | Where | Contents |
|---|---|---|
| `~/.config/ping-pong/config` | each machine | Bus mode and ssh alias. |
| `~/.local/state/ping-pong/<id>.side` | each machine | Which side this machine is on that channel. |
| `$PP_BUS_ROOT/<id>/` | bus host | The channel: `meta`, the two FIFOs, listener markers. |

Channel ids match `pp-[a-z0-9]{4,16}` and every command validates that pattern before the id reaches a shell — ids are the only user input that crosses into a remote command.
