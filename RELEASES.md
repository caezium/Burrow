<!-- Latest release ONLY. This file is the GitHub release body (release.yml --notes-file), so it must contain just the newest version. OVERWRITE it each release; do not accumulate. Full prose history lives in docs/releases.json → docs/releases.html (the site Releases page). -->

# Burrow 0.10.5

Burrow's MCP tools, tuned against real agent transcripts. We audited how AI
agents actually used the tools in the wild — what they called, where they
stalled, and when they gave up and fell back to raw `du`/`df` — and fixed what
tripped them up ([#302](https://github.com/caezium/Burrow/issues/302)).

## Improved
- **One `burrow_analyze` call now maps disk hotspots.** The engine reports one
  directory level per run, which forced agents into a call per directory (a
  real session made 15 in a row). `analyze` gains `depth` (descend into the
  largest subdirectories), `limit`, and `min_size`, emits compact JSON instead
  of 35–60 KB pretty-printed blobs, and always reports what it pruned
  (`entries_omitted` / `omitted_bytes`, `partial: true` when the descent hits
  its time budget). ([#303](https://github.com/caezium/Burrow/pull/303))
- **The slow tools now say they're slow.** `analyze`, `clean`, `purge`, and
  `installer` descriptions warn that big scans take minutes, so agents scope to
  a specific folder instead of hanging past their client's patience and falling
  back to shell commands. The agent docs and the `burrow-system-tools` skill
  now lead with the low-disk emergency playbook — the pattern that actually
  fires in practice. ([#303](https://github.com/caezium/Burrow/pull/303))

## Fixed
- **Killed runs no longer fail silently.** A `burrow_clean` that hit its time
  limit rendered as `{"exit_code": 9, "output": ""}` — nothing an agent could
  act on. Timed-out actions (and analyze) now return `timed_out: true` plus a
  hint. ([#303](https://github.com/caezium/Burrow/pull/303))
- **`burrow_cleanup_history` explains itself.** When engine history is
  unavailable, the error now points at `burrow_info` to check whether Burrow is
  recording at all. ([#303](https://github.com/caezium/Burrow/pull/303))
