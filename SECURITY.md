# Security Policy

## Supported Version

The Windows branch is currently a preview. Security fixes target the latest `v0.1.x-preview` line.

## Reporting a Vulnerability

Do not open a public issue for a vulnerability. Report it privately to the maintainers of the Burrow Windows branch. Include:

- affected version or commit,
- reproduction steps,
- expected and actual behavior,
- whether a destructive operation can be triggered without explicit user confirmation.

## Local Trust Boundaries

- HTTP binds to `127.0.0.1` only.
- HTTP requests from non-loopback addresses are rejected.
- MCP destructive actions are disabled unless the user enables them in Settings.
- Cleanup, optimize, purge, installer cleanup, uninstall, and leftover removal flows must remain preview-first or confirmation-gated.
- The preview ZIP is unsigned. Users should verify `SHA256SUMS.txt` before running a release.

## Out of Scope for Preview

- Remote HTTP access.
- Silent destructive system maintenance.
- Elevation bypasses.
- Store/MSIX signing guarantees.
