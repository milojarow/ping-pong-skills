# Direct mode: a channel between two people's machines, with no bus

Two transports, and the choice is about **trust**, not about networking.

**Bus mode** (`--setup --bus-local` / `--bus-ssh`) puts the channel's FIFOs on one host both
sides reach. It needs both sides to log into that host **as the same Unix user**, so it fits two
machines that already belong to the same person. Between two *different people's* machines it
does not fit: the price of a chat channel would be a shell account on somebody's box.

**Direct mode** (`--direct`) has no bus at all. Each side's inbox is a TCP port on **its own**
machine, bound to a private mesh interface (Tailscale/WireGuard) that both devices joined. The
peer connects to it. Nothing is exposed to the public internet, nobody gets a shell, and there is
no token to mint or rotate: the mesh's device authorization is the access control.

## Run `--mesh` first, then hand over one block

The operator's whole job is to paste **one block** into whatever they already use to talk to
their partner. Everything before and after that is yours. Do not walk them through Tailscale by
hand, and do not ask them to relay names or addresses you can read yourself.

```bash
pp --mesh          # ALWAYS first. Exits 0 when ready, 1 when something is missing.
```

It reports one of four states and, in each unfinished one, prints the exact text to hand over:

| State | What you do |
|---|---|
| Not installed | Give the operator the install + `up` commands it printed. Nothing to hand over yet. |
| Installed, not logged in | Same, but if the *partner* is the one who already has a tailnet, the operator must **send** their login URL rather than open it. |
| Logged in but **alone** | Hand the operator the block `--mesh` printed. That block is written for the partner and needs no editing. |
| Ready | Open the channel. `--peer` is optional when exactly one peer is on the mesh. |

```bash
# opener, once --mesh says READY
pp --open --direct --topic "what this is about"
# prints a second block to hand over, already containing:
#     /ping-pong <id> --direct --peer <your-mesh-ip>

# joiner: the operator pastes that line, and this is the whole job
pp --join <id> --direct --peer <opener-mesh-ip>

# from then on
pp --listen <id> --retry   # in the background, relaunched per turn (no keeper in direct mode)
pp --send <id> -m "..."
```

So the operator sees at most two hand-offs: **bootstrap** (get the partner onto the mesh) and
**channel** (the `/ping-pong …` line). Both come out of the CLI verbatim. Say "hand this to your
partner" and paste it. Do not summarize it and do not rewrite it into your own words: the block
is calibrated to stop the failure below.

## The trap that makes both machines look connected and unable to reach each other

**A tailnet belongs to an account, not to a network.** Two people who each run `tailscale up`
and each authenticate with *their own* account end up in **two separate tailnets**, each alone.
Both machines report `Connected`, both hold a `100.x` address, neither prints a warning, and
they cannot see each other.

Measured in production: a peer opened their own login URL, read "Connected" as success, and the
mistake survived until someone actually looked at `tailscale status` and saw a single line.

So: **`tailscale up` succeeding is not evidence of reachability.** The evidence is the *other*
machine appearing in `tailscale status`, with the **same account** in the third column.
`pp --mesh` checks exactly that and says so.

Exactly one tailnet must own both devices. Two ways to get there, both fine:

- **Pre-auth key** (fewer moving parts): the host mints one at
  `login.tailscale.com/admin/settings/keys` and sends it; the partner runs
  `sudo tailscale up --auth-key=<key>`. One command, no URL relay. It is a secret: single-use,
  short expiry. There is **no CLI subcommand and no MCP** that mints a key, so do not go looking
  for one: it is the console or the REST API, and for a one-off hand-over the console is strictly
  cheaper. Contract and body nesting in [pp-cli.md](pp-cli.md).
- **URL relay**: the partner runs `sudo tailscale up` and sends the printed URL to the **host**,
  who opens it and authenticates with the host's account. The partner must not open it.

Recovery when the partner already joined the wrong tailnet: `sudo tailscale logout && sudo
tailscale up`, then relay the new URL.

Both sides derive the **same port from the channel id**, so nothing extra travels between them
and two channels between the same pair of machines land on different ports.

Use the **`100.x` address** for `--peer`, not the mesh name. MagicDNS depends on each machine's
DNS wiring and is not guaranteed (measured broken on a machine whose mesh was otherwise
healthy). The CLI already hands out the address for this reason.

## What direct mode gives up

- **No always-on middleman.** Both machines must be awake at the same time; with a bus host only
  the bus had to be. Neither mode stores anything, so nothing is "waiting" either way.
- **No shared metadata.** Each side keeps its own record, so `--info` reports only what this
  machine knows, and `--close` forgets it here: tell the peer to close too.
- **No keeper, so no spool, so no `--watch`.** `--keep`/`--await`/`--watch` are bus-mode
  commands. In direct mode the reader is `--listen --retry`, relaunched per turn, or a feeder loop
  built per session under the harness's persistent Monitor: see
  [inotify-wake.md](inotify-wake.md#this-design-does-not-apply-to-a-direct-channel-as-is--there-is-no-keeper-so-no-spool).
- **No listener marker, and none is needed.** The TCP connect *is* the presence check,
  **when it is a real `--send`.** `Connection refused` from an actual send is ground truth, and
  the whole class of failure where a marker outlives its process does not exist here. A separate
  probe (`nc -z`, `nc -vz`, a port scan) is a *different* connect, and it is not free: it consumes
  the peer's one-shot listener without delivering anything, because the listener exits on the
  first connection regardless of payload. There is no `--info` to fall back on, so do not reach
  for a probe: **retry the `--send` itself**. A refused send costs ~2 s and consumes nothing, so a
  retry loop around `--send` is safe where a `nc -z` loop is not.

Requires `nc` on both machines and the device on the mesh (`tailscale up` once per device).
`PP_MESH_IP` overrides the detected address if your mesh is not Tailscale.

**A default-deny host firewall is not the problem it looks like.** On a machine running `ufw`
with `deny (incoming)` and no rule for the inbox port, the natural conclusion is that the peer's
connection will be dropped. It is wrong. Tailscale installs its own `ts-input` chain that the
kernel's input hook jumps to **before** the firewall's chains, containing an unconditional accept
for the mesh interface; verified in a live ruleset, with matching packet counters. Read the
ruleset before opening a port you did not need to open. The corollary is worth stating to the
operator: everything already listening on `0.0.0.0` is reachable from the mesh, so `ss -tln` is
the honest disclosure to make to a partner before they join.

## The surviving side's state outlives the peer's `--close`

Direct mode keeps no shared metadata by design, so `--close` in that mode is local plus a
courtesy notice to the peer, not a destruction of the peer's half. Measured: after the peer
exits cleanly and its hook runs `--close`, the closing notice arrives here as an ordinary
message, but this side's own state (`<id>.direct`, `<id>.owner`, `<id>.side`, and its listener)
is **not** torn down.

Consequence: a replacement session can **join the same id again**, with the same `--join`
line, and the channel comes back without opening a new one.

- **The surviving side must not close its own half on receiving the peer's closing notice.**
  Closing it is what actually destroys the id; leaving it up is what lets the replacement rejoin.
- The replacement session joins with the same id; the port is derived from the id and needs no
  hand-off.
- If the join is refused for ownership (local state still recorded under the previous session),
  `--adopt` resolves it, automatically if the previous session is already gone.
- The surviving side can tell a clean exit from a dirty one without probing anything: a closing
  notice arrived means clean; no notice means dirty. Either way the id keeps working as long as
  this side never closes it.

**For the operator:** a replacement session starts with none of the agreed context. Everything
told to the previous session has to be repeated. Open the re-briefing by naming explicitly what
is now **obsolete**, not only what still holds; the replacement can otherwise end up executing a
plan that was already revised twice. The provider-side safeguard that produces this situation
is described in [troubleshooting.md](troubleshooting.md#a-model-safeguard-can-take-down-or-degrade-one-side-mid-collaboration).
