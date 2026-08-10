# Burrow 0.14.0

The Touch ID helper now offers itself, and the reviewed clean says what it
removed instead of finishing silently.

## Added
- **Burrow offers the privileged helper.** The helper that lets admin
  operations authenticate with Touch ID shipped in 0.13.0 behind a single
  button in **Settings ▸ Advanced**, and nothing pointed anyone at it —
  upgraders learned about it from the release notes, fresh installs not at all.
  It is now offered the way Full Disk Access is: one banner over the window,
  informing rather than blocking. At most one notice shows at a time, and
  dismissing the helper notice is permanent, because the helper is a
  convenience rather than something Burrow needs to work.

## Fixed
- **The reviewed clean reports what it removed.** It deleted exactly what was
  ticked and then looked like it had done nothing. That path doesn't run the
  engine's cleaner — it deletes each reviewed path with `find`, which succeeds
  *silently*, so the result screen had no output to show: no items, no freed
  total, no done banner. It now reports the paths it was authorized to remove,
  grouped by category with their sizes summed, which is a statement of fact
  rather than optimism — the run only succeeds after confirming every planned
  path is gone.

Nothing changed about what the reviewed clean deletes, or about the checks it
passes before deleting: this release makes it visible, not different.
