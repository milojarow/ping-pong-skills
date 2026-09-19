# Retired pattern: a listener without a live session

The old standing-listener recipe kept a headless endpoint reachable with
`Restart=always`. It is **not part of the 1.4.0 contract**: closed sessions must not
communicate. Do not create such a unit, a detached relaunch loop, or a resume queue.

Use `pp --keep` from a live Claude, Codex or Grok session and arm its receiver
recipe. The keeper survives turns but is leashed to that process incarnation.
A human shell remains `nosession`; it can recover pending mail and close channels
with no live owner. A live owner requires explicit `--adopt`. It
cannot create a session-leashed keeper without a recognized live owner.

## Retiring an old guard on the operator's request

Identify its exact unit and channel before stopping it. Stop the supervisor first,
then its known children; killing only the listener permits the parent to recreate
it. Never use `pkill -f`. Do not sweep units belonging to another conversation.
Close the selected channel and inspect retained mail before discarding any state.

The original failure still explains the leash: a detached reader can outlive its
agent, hold a marker, and make an abandoned channel look occupied. A live listener
is not proof that its owning session is alive.
