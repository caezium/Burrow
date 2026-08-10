# Burrow 0.13.0

Headings that rendered as empty boxes now render as text, and Burrow's MCP
server speaks the 2026-07-28 spec — without dropping any older client.

This release is mostly repair. The visible half fixes three things that were
easy to hit; the larger half is security and reliability work on the paths that
delete files and run as root, which you should never notice.

## Added
- **The scan tells you when it's done.** A cache scan can run for minutes and
  used to end by just sitting there with a number. It now posts a completion
  notification saying what it found, honouring **Settings ▸ Notify when long
  operations finish**.
- **Two more agent tools.** `burrow_anomalies` and `burrow_agent_audit` join the
  MCP surface.

## Changed
- **MCP now speaks the 2026-07-28 revision**, including its task and
  cancellation semantics. Older clients are unaffected: 2025-11-25 through
  2024-11-05 are still served, and a client that skips `initialize` entirely
  still works.

## Fixed
- **Headings rendered as empty boxes.** Geist and Geist Mono shipped as single
  variable fonts with only Regular registered, so every bold and semibold
  heading asked macOS to derive a weight at render time — and sometimes it
  produced no glyphs at all. Burrow now ships real static faces for every weight
  it uses.
- **One bad exit no longer disables the menu bar** until macOS updates.
- **The window can be made smaller again** — its minimum height is derived from
  the sidebar rather than hardcoded.
- **"Stop after current" now responds.** The stop was always queued, but nothing
  on screen said so until the in-flight update finished.
- **The clean review no longer promises what closing an app can't deliver.** An
  entry the scan refused was counted in "Close X to clean another N" even though
  no app was holding it — with no app named at all when it was the only locked
  entry.
- **A cancelled app update no longer blocks later update checks** for the rest of
  the session.
- **Root operations can't interleave their output.** stdout and stderr shared one
  line buffer, which could splice half a line from one stream onto the other.
- **Update archives are size-capped** before they're kept or expanded.
- **Diagnostics reject more credential shapes** before anything is uploaded.
