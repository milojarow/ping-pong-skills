# inotify coalesces — count coverage, not events

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
