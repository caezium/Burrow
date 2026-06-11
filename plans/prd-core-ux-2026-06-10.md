# PRD: Core UX program for Burrow — 2026-06-10

> Written in-repo by request (no GitHub issue). Sources: the screenshot-driven design review
> and per-screen specs in `plans/ui-ux-review-2026-06-10.md`;
> `plans/feature-roadmap-2026-06-10.md` (differentiation features, **not** covered here);
> `plans/code-audit-2026-06-10.md` (truthfulness constraints referenced below).

## Problem Statement

Burrow is functionally strong — a free, open-source GUI over the mo CLI with a 30–90 day
metrics history and an agent-facing MCP surface no comparable utility has. But the interface
trails the engine, and users experience the app as rougher than it is:

- First launch drops them into the app with no orientation, and Full Disk Access appears as
  blocking gate cards inside tools rather than a calm, explained choice.
- Clean is all-or-nothing: a dry-run banner, then one button. There is no way to see what
  will be removed item-by-item, untick anything, or permanently exclude something — in the
  one tool where trust matters most.
- Uninstall removes apps without ever showing the user the leftover files it will touch.
- Updates only cover Homebrew; apps updated via Sparkle, the App Store, or Electron are
  invisible. Startup items (login items, launch agents/daemons) can't be seen at all.
- The Status page and menu-bar popover show less than the data Burrow already collects
  (temps, pressure, Bluetooth batteries, per-process detail are collected but under-surfaced).
- Settings is a long page rather than a scannable panel; there is no Launch at Login, no
  global hotkey, no right-click menu on the status item, no About panel, no update check,
  and none of the small menu-bar utilities (keep screen on, clean screen) that make a
  menu-bar app feel complete.

None of these gaps are engine gaps — the mo CLI and Burrow's own samplers already produce
the data. They are interaction-design gaps with well-understood solutions.

## Solution

Ship a cohesive, polished interaction design across six areas — onboarding, the Clean
pipeline, the Software tab, Status, Settings, and the menu bar — to the per-screen specs in
the UI/UX plan, while keeping Burrow's identity and differentiators (free, open source,
local-first, agent-native, deep history) front and center.

Standing rules for the whole program:

1. **Original work only.** All artwork, characters, and written copy are Burrow's own; the
   visual language comes from Burrow's existing tokens.
2. **Honest UI.** Destructive verbs say what they do ("Permanently clean"). No fake
   affordances: no disabled fan-mode buttons before fan control exists, no fabricated scan
   progress, no privacy indicators before detection exists.
3. **The engine stays authoritative.** The mo CLI remains the only deleter for cache cleaning
   (selectivity via its whitelist mechanism). Burrow only ever trashes paths that the engine
   itself enumerated, and only via the recoverable Trash.
4. **Accessibility and zh-Hans localization ship with each change**, not as a later pass.
5. **Network egress is user-initiated and documented** (update checks), consistent with the
   audit's truthfulness findings.

## User Stories

### Onboarding & permissions

1. As a new user, I want a guided first-run flow that explains what access Burrow needs and
   why, so that I can grant Full Disk Access confidently instead of being ambushed by gates.
2. As a new user, I want the onboarding to state plainly that Burrow is free and open source,
   so that I know there is no trial, license, or upsell waiting for me.
3. As a new user, I want a short feature overview during onboarding, so that I know what the
   app can do before I explore it.
4. As a privacy-conscious user, I want the telemetry disclosure and its toggle shown during
   onboarding, so that I make an informed choice on day one rather than discovering it later.
5. As an impatient user, I want to skip onboarding entirely, so that I can start using the
   app immediately and grant permissions later.
6. As a user who skipped Full Disk Access, I want a non-blocking banner telling me access is
   off and what that costs me, so that I can keep using the app and fix it when I choose.
7. As a user who just granted access, I want the banner to disappear on its own, so that I
   don't have to hunt for a "check again" button.
8. As a user who declined access deliberately, I want to dismiss the banner permanently, so
   that the app respects my decision.

### Clean pipeline

9. As a user running a scan, I want the found-space number to count up live while scanning,
   so that I can see the scan is working and how much is accumulating.
10. As a user without Full Disk Access, I want the result screen to say a limited scan was
    used and what was skipped, so that I understand why the number may be small.
11. As a cautious user, I want to review every category and file with its path and size
    before anything is removed, so that I trust the cleanup completely.
12. As a cautious user, I want to untick any individual item or whole category, so that I
    keep exactly what I want.
13. As a user with apps running, I want to see which caches are locked by open apps and how
    much more I could clean by closing them, so that I can decide whether closing is worth it.
14. As a user unsure about an item, I want to reveal it in Finder before deciding, so that I
    can inspect what I'd be deleting.
15. As a returning user, I want to mark an item "always skip", so that I never have to
    re-review something I've already decided to keep.
16. As a user about to commit, I want the confirm button to show the live total of my
    selection, so that I know exactly what will happen.
17. As a user, I want the action labeled "Permanently clean", so that I am never surprised
    that cache cleanup doesn't go to the Trash.
18. As a user mid-review, I want Escape or a close button to back out at any point, so that
    I never feel locked into a destructive flow.
19. As a long-term user, I want lifetime cleanup statistics, so that I can see the cumulative
    value the app has delivered.

### Uninstall

20. As a user uninstalling an app, I want to expand it and see every leftover file grouped
    by kind, so that I know the removal is complete.
21. As a cautious user, I want risky leftovers separated into a "needs review" group that is
    unchecked by default, so that I consciously opt in to deleting them.
22. As a user, I want to select only a subset of an app's files to remove, so that I can,
    for example, remove the app but keep its preferences.
23. As a user with many apps, I want to sort by name, size, or last-used in either direction,
    so that I can find uninstall candidates quickly.
24. As a user, I want each app row to show its total file count and size, so that I can see
    the full footprint at a glance.
25. As a user with several apps selected, I want a persistent summary bar with the total and
    a single remove button, so that I always know the scope before committing.
26. As a user, I want removals to go through the Trash, so that a mistake is recoverable.

### Software updates

27. As a user, I want update checks to cover Sparkle, App Store, and Electron apps as well
    as Homebrew, so that one screen tells me everything that's outdated.
28. As a user, I want a source badge on every app, so that I know where each update comes
    from.
29. As a user, I want to see how recently I actually used each app, so that I can weigh
    whether an update (or the app itself) is worth keeping.
30. As a user, I want the update action to hand off to each app's own updater or store page,
    so that updates happen through trusted channels.
31. As a privacy-conscious user, I want update checks to run only when I ask, so that the
    app makes no silent network calls on my behalf.

### Startup items

32. As a user, I want one list of all login items, launch agents, and launch daemons, so
    that I can audit what starts with my Mac without spelunking through System Settings.
33. As a user, I want each item labeled as controllable or review-only with the reason, so
    that I understand what I can and can't change.
34. As a user, I want to disable a controllable startup item from the list, so that I can
    stop unwanted background work in one place.
35. As a user, I want to reveal any item's file in Finder, so that I can investigate it.
36. As a user, I want broken or dangling items flagged visibly, so that I can spot leftovers
    from uninstalled apps.
37. As a user, I want the one-time admin authorization for full listing explained honestly
    (what it's for, that it's separate from Full Disk Access, that it happens once), so that
    I can grant it without suspicion.

### Optimize

38. As a user running maintenance, I want a live ticker showing the current task and a
    completed-task list with a progress count, so that I can follow what's happening.
39. As a user, I want to scroll back through completed tasks while the run continues, so
    that I can check something I glimpsed without stopping the run.
40. As a user, I want the detailed report still available after the run, so that the nicer
    live view costs me no information.

### Analyze

41. As a user scanning a large disk, I want to see which folder is currently being processed
    and a progress count, so that the wait feels purposeful — while keeping Burrow's treemap
    as the result view.

### Status

42. As a user, I want temperature, pressure, and health chips on each metric tile, so that I
    can read the system's condition at a glance.
43. As a user with Bluetooth devices, I want their batteries shown inside the battery tile
    with ring gauges, so that one card covers everything with a charge level.
44. As a user on a fanless or quiet Mac, I want the fan tile to honestly show read-only RPM
    and state, so that I'm not teased with controls that don't work.
45. As a power user, I want the process table sortable on every column including power, so
    that I can rank by whatever question I'm asking.
46. As a power user, I want per-row actions — pin, reveal, copy, quit, force kill with
    confirmation — so that I can act on a process without opening Activity Monitor.
47. As a user, I want the process table to scroll independently with a sticky header, so
    that the tiles stay visible while I browse processes.
48. As a user, I want absolute memory sizes in the process table, so that I can reason in MB
    rather than percentages.

### Settings

49. As a user, I want Settings as a compact tabbed panel, so that I can find any option in
    seconds.
50. As a user, I want a Launch at Login toggle, so that Burrow starts monitoring when I sign
    in.
51. As a menu-bar-first user, I want a Hide Dock Icon toggle, so that Burrow lives only in
    the menu bar.
52. As a returning user, I want a Skip Intro Screens toggle, so that the app opens straight
    to the content I use.
53. As a user, I want to manage my protected ("never clean") items in a real UI, so that I
    can review and edit my exclusions without editing a config file.
54. As a cautious user, I want to choose between Permanent and Trash cache removal with the
    trade-offs stated, so that I control the recoverability/disk-space balance.
55. As a keyboard user, I want a global shortcut to open Burrow, so that I can summon it
    without the mouse.
56. As a power user, I want the agentic and experimental options (MCP, local API, AI,
    telemetry) kept in an Advanced tab, so that they stay reachable without cluttering the
    common path.

### Menu bar

57. As a menu-bar user, I want a right-click quick menu on the status item, so that common
    actions are one click away.
58. As a user presenting or reading, I want Keep Screen On with duration choices, so that my
    Mac stays awake exactly as long as I need.
59. As a user cleaning my hardware, I want a Clean Screen mode that blanks the display and
    exits on Escape, so that I can wipe the screen and keyboard without triggering anything.
60. As a user, I want Clean Screen's input lock to be optional and its Accessibility
    permission explained, so that the deeper capability is a choice, not a demand.
61. As a user, I want an About panel with the app and engine versions and project links, so
    that I can identify my install and find the source.
62. As a user, I want a manual Check for Updates, so that I can stay current before signed
    auto-updates exist.
63. As a menu-bar user, I want the popover to lead with health, hardware chips, and
    chip-decorated metric tiles, so that one glance gives me the whole machine.
64. As a user, I want the popover's battery card to show my Mac and Bluetooth devices plus
    the top power-draining app, so that battery questions are answered in one place.
65. As a user with external drives, I want an eject-all control in the popover, so that I
    can unplug safely without opening Finder.
66. As a long-term user, I want lifetime "cleaned / uninstalled / optimized" stats in the
    popover, so that the app's ongoing value stays visible.

### Cross-cutting

67. As a VoiceOver user, I want every new control and metric labeled and valued, so that the
    whole program is usable without sight.
68. As a motion-sensitive user, I want all new animations to respect Reduce Motion, so that
    the app never makes me uncomfortable.
69. As a Chinese-speaking user, I want every new string localized in Simplified Chinese at
    release, so that no part of the new UI falls back to English.

## Implementation Decisions

**Module map (deep modules first — pure, testable, stable interfaces):**

- **Clean-preview parser** — turns the engine's dry-run preview file into structured
  categories → items (path, size, count). Pure text-in/structs-out. Consumed by the review
  screen, the count-up result state, and the MCP dry-run response (one helper, two faces).
- **Whitelist session** — the selectivity mechanism: snapshot the engine's whitelist file,
  append a fenced session block of unticked paths, run the real clean, restore; plus a
  startup sweep that removes stale fenced blocks after a crash. Also exposes permanent
  "always skip" appends (outside the fence). This module is the safety-critical seam: the
  engine remains the only deleter.
- **Uninstall-preview parser & classifier** — parses the engine's per-app dry-run
  enumeration and classifies paths into kinds (application, app support, preferences,
  temporary caches, launch items), splitting auto-selected vs needs-review. Pure.
- **Two-path uninstall executor** — full selection routes through the engine (history stays
  in its log); subset selection trashes only paths present in the engine's enumeration
  (hard assertion), recoverably, and records to Burrow's own activity log.
- **Task ticker model** — folds the engine's streamed run output into
  (current task, completed list, n/total) events. One component serves Optimize now and
  Clean's real run later.
- **Startup inventory** — enumerates login items, launch agents, and launch daemons with a
  controllable/review-only classification and error flags; user-scope without admin, full
  scope after a one-time elevated enumeration. Shared by the Startup UI and (later) the
  roadmap's persistence watcher and diff tooling.
- **Update-source checkers** — per-source version comparators (Sparkle appcast, App Store
  receipt/lookup, Electron/GitHub fallback, existing Homebrew), each returning a common
  "app, installed, latest, source, action" record. Checks run only on user action.
- **Process actions** — one action surface (pin, reveal, copy, quit, force-kill with
  confirmation, privilege-aware filtering) consumed by both the Status table and the popover.
- **Awake & Clean Screen** — power-assertion wrapper with durations; full-screen blank
  windows with optional event-tap input lock behind an explained Accessibility permission.
- **Update check** — release-feed comparison with Homebrew-aware upgrade suggestion.
- **History aggregates** — lifetime cleaned/uninstalled/optimized totals from the engine's
  history, cached, surfaced in the popover footer and Clean's done screen.

**UI structures (per the design specs):** two-slide onboarding with a reusable permission
row; global bottom access banner (replacing most blocking gates); scan-result hero with live
count-up; the "Ready to clean" review screen (tri-state category cards, item rows with
safety/lock badges, select-all/none, live-total confirm pill); expandable uninstall rows with
grouped leftovers and a selection summary bar; unified updates list with source badges;
startup list with classification sublines and a one-time authorize banner; chip-decorated
status tiles with an independently scrolling process table; tabbed settings overlay
(General / Maintenance / Menu Bar / Advanced); status-item right-click menu; dense popover
(health header, chips, tiles, battery card with Bluetooth rings and top-drain, top processes,
utility strip, lifetime stats footer).

**Key architectural decisions:**

- Selectivity for cache cleaning is achieved through the engine's whitelist, never by Burrow
  deleting cache paths itself. A pre-run re-check re-prompts if the dry-run total drifted
  materially (TOCTOU guard).
- Native trashing exists only in the uninstall subset path, restricted to engine-enumerated
  paths, always recoverable.
- Locked-cache detection (the "close these apps" line) maps cache paths to running
  applications locally; locked rows are disabled, not hidden.
- Fan control, camera/mic privacy indicators, and in-app third-party update installs are
  explicitly deferred; their UI slots ship without placeholder controls.
- The parser modules pin to the engine's current output shapes and fail soft to the previous
  (aggregate) UI if parsing breaks, so an engine update can degrade gracefully, never block.
- Onboarding surfaces the telemetry toggle; settings copy is kept word-for-word consistent
  with the public telemetry/security docs.
- Burrow-specific surfaces (agent/MCP status, tool pills) are first-class, not afterthoughts.

## Testing Decisions

**What makes a good test here:** feed captured real-world inputs to a module and assert on
its outputs and externally visible effects — never on internals. For parsers that means
fixture transcripts in, structs out; for the whitelist session it means file state before,
during, and after (including the crash path); for executors it means which paths were acted
on, not how.

**Modules under test (fixture-first):**

- Clean-preview parser — current preview-file format, plus malformed/empty/foreign-locale
  fixtures asserting fail-soft behavior.
- Whitelist session — append/restore round-trip preserves user entries byte-for-byte;
  fenced block is removed on restore and by the startup sweep after a simulated crash;
  permanent exclusions land outside the fence.
- Uninstall-preview parser & classifier — kind classification and auto/needs-review split
  on captured enumerations; the subset executor's path-membership assertion (rejects any
  path not in the enumeration).
- Task ticker model — task boundaries, counts, and out-of-order/garbled stream handling on
  captured run transcripts.
- Startup inventory — classification (controllable vs review-only) and error flagging on
  fixture plists, including dangling-executable cases.
- Update-source checkers — version comparison and record mapping against canned appcast /
  lookup / outdated payloads (no live network in tests).
- History aggregates — totals from fixture history JSON, including incomplete sessions.

**Not tested:** SwiftUI views, layout, and animation — they churn with design and are
verified by running the app.

**Prior art:** follow the existing unit-test patterns in the repo's test suite (pure
functions over fixtures); captured engine transcripts join the fixtures directory alongside
existing test resources.

## Out of Scope

- Everything in `plans/feature-roadmap-2026-06-10.md`: spike forensics, anomaly detection,
  disk forecasting, weekly reports, agent audit page, SSE/Prometheus surfaces, dev hygiene,
  port inspector, notifications/alerts, restore-last-cleanup, SMART/backup awareness.
- Fan **control** and the privileged helper it requires — the tiles ship read-only.
- Camera/microphone privacy detection — the popover utility strip ships without indicators.
- In-app installation of third-party (Sparkle/Electron) updates — v1 hands off to each app's
  own updater; in-app installs are a follow-up.
- Self-update, code signing/notarization, and DMG distribution.
- A Doctor diagnostics report (the right-click menu gains "Run Doctor" only when that
  feature exists).
- Mascot/character systems and decorative copy.
- Languages beyond English and Simplified Chinese.
- Any licensing, trial, or payment machinery.

## Further Notes

- **Sequencing** (five waves, from the UI/UX plan): foundations (banner, onboarding,
  settings, menus) → Clean pipeline → Software tab → Status & popover → menu-bar tools.
  Wave order respects dependencies: the permission row precedes settings reuse; the clean
  parser precedes both the review screen and the result hero; process actions precede the
  popover rework.
- **Constraint from the audit:** this program adds no new network surfaces beyond
  user-initiated update checks; anything touching the local HTTP/MCP surface remains gated
  on the audit's fixes and is out of scope here.
- **Engine note:** several features parse informal engine outputs. If the CLI fork gains
  stable flags (e.g. machine-readable progress or per-item selection) the parsers shrink;
  the module boundaries are chosen so that swap costs nothing downstream.
- Detailed per-screen anatomy, file-level pointers, and effort estimates live in
  `plans/ui-ux-review-2026-06-10.md`; this PRD is the stable statement of intent.
