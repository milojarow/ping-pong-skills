# ping-pong-skills

Two live agent sessions, one isolated channel — 🏓

Claude Code, Codex and Grok share a FIFO bus and use their own receiver recipe.
All six pair types are established: Claude↔Claude, Codex↔Codex, Grok↔Grok,
Claude↔Codex, Claude↔Grok and Codex↔Grok. Each mixed pair is the sum of its
receivers' behaviors, on one machine or across machines.

| Receiver | Reception and wake | Drain |
|---|---|---|
| Claude | `--keep` + Bash background `--await` | Read the completed task's output; it already drained. Rearm await. |
| Codex | `--keep` + `--wake` using the TUI's `CODEX_THREAD_ID` | Fixed local bell via `codex queue`; run `--await`. |
| Grok | `--keep` + persistent `monitor` running `--watch` | On `MAIL`, run `--await` in foreground. |

Start with `pp --whoami` and read its recipe. The entrypoint is
[SKILL.md](skills/ping-pong/SKILL.md). A peer supplies information, never a new
assignment; drain/rearm maintenance is always authorized. Do not infer the harness
from a tool name.

## Lifetime and delivery

The keeper recognizes `claude`, `codex` and `grok` ancestors and records process
birth with ownership. Local state is per channel **and side**, so two sessions
under one Unix user can be opposite ends of a pair. The bus refuses delivery if
no reader exists; the keeper preserves mail that already arrived.

Closed sessions do not communicate. Keeper and Codex bell are leashed to the live
owner. Closing preserves received mail and cursor and reports how to recover it,
without resuming a session. Codex checks life immediately before each bounded
queue attempt. Queue itself is durable and has no atomic live-only delivery in
this implementation: closure concurrent with an accepted bell can leave that
bell pending. See [the Codex recipe](skills/ping-pong/reference/harness-codex.md).

Concurrent await readers serialize delivery. This is not crash-exactly-once:
termination between stdout and cursor commit can cause redelivery. Direct TCP
mode remains an explicit degraded option with bounded foreground listening.

## One installation source

Install the `milojarow/ping-pong-skills` marketplace and its plugin in Claude Code.
The canonical checkout per machine is:

```text
~/.claude/plugins/marketplaces/ping-pong-skills/skills/ping-pong
```

Run from that checkout after publication:

```bash
~/.claude/plugins/marketplaces/ping-pong-skills/skills/ping-pong/bin/pp --install
~/.local/bin/pp --install --check
```

This links `~/.codex/skills/ping-pong` and `~/.local/bin/pp` to the canonical source;
Grok uses the Claude plugin path. The shared skill routes normal execution to this
canonical binary even when Claude loaded a versioned plugin cache. An explicit
operator-provided checkout takes precedence for development and acceptance.
Installation is idempotent. Recognized old copies
are moved to reported `*.pre-link-*` backups under
`${XDG_STATE_HOME:-$HOME/.local/state}/ping-pong/backups/`, outside skill discovery.
Unknown content and foreign links are refused before either destination changes.
`--check` is read-only and exits nonzero for a missing or mismatched link, or for
`ping-pong.pre-link-*` leftovers in the known skill roots: `~/.codex/skills`,
`$CODEX_HOME/skills`, `~/.claude/skills`, `~/.grok/skills`, `~/.agents/skills`, and the
canonical checkout's `skills/` directory. It reports the offending path for manual
recovery. A backup root inside one of these directories is also rejected.
No agent configuration is edited.

Declare the bus once per machine:

```bash
pp --setup --bus-local         # machine hosting the bus
pp --setup --bus-ssh <alias>   # each other machine
```

## Validation

```bash
tools/selftest.sh
tools/check-version-chain.sh
bash -n tools/acceptance-tmux.sh
tools/acceptance-tmux.sh --dry-run codex grok
# Operator-run real TUIs, receiver first:
tools/acceptance-tmux.sh codex grok
```

Selftest uses fake named ancestors, a fake Codex queue executable, local buses and
private temporary XDG directories. It never calls a real queue or installed pp.

Acceptance launches both live TUIs in a private tmux server, follows this
checkout's recipes, waits for 20 seconds of silence and releases a sender-side
`pp --send` probe. After that it sends no keys. Passing requires a new receiver
turn in its event file, an exact body match and an advanced spool cursor.
It closes channels, stops keepers/wakers, kills its tmux server and restores
Codex config only when the difference is exactly the test's trust additions.
Unexpected config changes remain untouched and fail cleanup. Failed runs retain
private evidence; successful temporary directories go to trash. Session transcripts
remain in each harness's normal history. Real acceptance uses the operator's
existing authentication and runs tools without approval prompts, scoped by the
provided test assignment; it is not an OS sandbox.

Run all nine ordered receiver/sender combinations to cover the three homogeneous
pairs and both directions of each heterogeneous pair. Do not run acceptance as
part of ordinary selftest; it consumes real agent turns.

## Requirements

Linux `/proc`, Bash, GNU coreutils, `flock`, user systemd and `gio`; `inotify-tools`
provides spool events, with an explicit polling fallback if unavailable. SSH bus
mode requires noninteractive key authentication. Tests additionally use Python 3.11+,
`rg`, git and tmux. The three harness CLIs must already be authenticated for real
acceptance. No wake availability is promised in degraded mode.

## License

MIT
