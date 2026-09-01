# Two sessions co-editing one shared file: the channel is not the hand-off surface

Ping-pong carries text messages. The moment two sessions need to co-edit a **file**
together — not just talk about it — reaching for the channel (or for any synced
directory used the same way) as the hand-off surface is the mistake, not a workaround.
Measured between two agent sessions on different machines co-editing a single shared
document through a synced directory (e.g. Syncthing) used as a copy-in/copy-out surface:

- Side A copied its version into the synced dir 16 s after side B had written its edit
  there → B's edit gone from the synced copy (it survived only in B's own repo).
- The exact mirror happened minutes later in the other direction.
- Neither copy errored. Each side silently held half of the other's work. **"Whoever
  edits, warns first" does not prevent this** — both sides warned every time; the race
  is in the COPY, not in the edit, and a warning does not serialize a `cp`.

## What actually holds up

1. **Git is the source; a synced directory is only the truck.** The document lives in
   each side's repo. Anything dropped in a synced dir for hand-off is disposable and
   never the thing either side builds on next.
2. **Hash the synced copy against the last version you read, before every write into
   it.** If it differs, someone wrote in between — read first, never blind-copy:
   ```bash
   test "$(sha256sum pond/file | cut -c1-16)" = "<sha you last read>" && cp repo/file pond/file
   ```
3. **Read the peer's version from their git remote, not from the truck and not by
   `ssh`-ing into their home.** A peer's home can be `700` by design (a read-only OS
   user, a container boundary), so `ssh peer 'cd ~/x && git …'` fails with "not a git
   repository" and reads like a wrong path when it is actually a closed door. Without
   cloning anything:
   ```bash
   gh api 'repos/<owner>/<repo>/contents/<path>?ref=main' --jq .content | base64 -d | sha256sum
   ```
   The symmetric option is a read-only clone of the peer's repo, merged with a real
   three-way merge (base = the last commit both sides had landed).
4. **Verify before announcing.** "Done editing X" sent before confirming the write
   landed is a false report waiting to happen — an edit can fail silently, or a peer's
   copy can overwrite yours in the same window. Announce the hash you verified, not the
   intention.
5. **A literal `|` inside a markdown table cell splits the row silently.** One stray
   pipe in a cell's text turns a six-column row into eight columns with no error from
   anything. A one-line gate per row catches it on either side before it lands, and run
   it on the received copy too, not only on what you wrote:
   ```bash
   awk '/^\| [A-Z][0-9] \|/ { n=gsub(/\|/,"|"); if (n!=7) print n, substr($0,1,80) }' file.md
   ```
   (7 pipes = six columns; adjust the count to the table's real column count.)

## Why this belongs here

This skill's channel is for messages, not for file transfer (see [SKILL.md's scope
note](../SKILL.md#when-to-use)). When the operator's task is two sessions building the
*same file* together, use the channel to coordinate — announce edits, hand over
verified hashes, resolve conflicts — but let git carry the content and treat any synced
directory as a disposable hand-off surface, never a merge tool.
