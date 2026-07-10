# FRICTION.md — QA log for Photon SDKs

Running log of confusing docs, surprising behavior, missing types, or bugs hit
while dogfooding Photon's iMessage SDKs inside Burrow. Newest first.

Environment: macOS 26.5.1, Apple M4 Pro, Bun 1.3.11, Node 20.20.2.
SDKs under test: `spectrum-ts` v9.1.0 (local mode) — which wraps
`@photon-ai/imessage-kit` v3.0.0 under the hood.

---

## F6 — cloud self-send blocked by allowlist even after registering the correct handle  [RESOLVED — needs inbound opt-in]

- **Severity:** high (blocks the primary use case — proactive self-alerts — on the
  Free/Pro plan); **resolved** once the target device texts the assigned line once.
- **Context:** switched to spectrum-ts **cloud** mode (`imessage.config()` +
  `Spectrum({ projectId, projectSecret })`) on a fresh free-tier project
  ("Burrow Alerts", shared line `+16282647704`). Connect + auth + shutdown all work.
- **What fails:** every `space.send(...)` returns
  `[spectrum-imessage] Target not allowed for this project`.
- **Onboarding friction chain:**
  1. `photon projects create` auto-creates the caller as a **project-owner user**
     with phone `+8613410272240`. Intuitively that user should be allowlisted —
     it is **not**; sends to it are rejected.
  2. `photon spectrum users add --phone +8613410272240 --invite` on that existing
     owner **silently returns the existing record** — no invite is sent, and it
     does not appear to (re)allowlist. So there's no obvious CLI path to allowlist
     the auto-created owner.
  3. Docs (`docs/troubleshooting/imessage.mdx.vel`) give two causes: (a) target not
     a user — but it **is**; (b) handle mismatch — but `chat.db` confirms the real
     iMessage handle **is** `+8613410272240` (`handle` table: `+8613410272240|iMessage`;
     account `E:8613410272240`). Neither documented cause applies, yet it's rejected.
- **Repro:** create free project → `users add` your own iMessage number →
  `space.send(text("hi"))` to `any;-;<that number>` → `Target not allowed`.
- **Impact:** the "text myself an alert" use case — arguably the most common first
  thing a solo dev tries on cloud — is blocked with no self-serve fix that worked.
  Suspected: allowlisting the **auto-owner** user is a no-op / needs the dashboard
  Users flow or debug-bot (`debug.photon.codes`) handle confirmation; possibly a
  shared-US-line → +86-China international limitation. Unconfirmed.
- **CONFIRMED ROOT CAUSE (via chat.db):** registering a user (CLI `users add`,
  even fresh + `--invite`) does **not** allowlist the target. The real gate is
  **inbound opt-in** — the recipient must text the project's *assigned* shared line
  first. Evidence: my assigned line `+16282647704` had never messaged the device
  and every send failed; meanwhile two other projects' lines (`+16282647648`
  GripCast, `+14156035536` Dayflow) had already delivered to the *same* number
  `+8613410272240` — and Dayflow's traffic included a "Thanks for the message"
  reply, proving an inbound had opened the thread. After the device texts
  `+16282647704` once, sends go through.
- **Doc gap:** `docs/troubleshooting/imessage.mdx.vel` says "Add a user … The
  target is now allowlisted." That's insufficient — it omits the required
  inbound opt-in (text the assigned line). The error should say "text <assigned
  line> from the target device to opt in," and `users add` output should surface
  the assigned line + opt-in requirement.
- **`--invite` appears to be a no-op** here: no onboarding text ever arrived from
  the assigned line (chat.db shows zero messages from `+16282647704`).
- **Workaround that works today:** local mode (`imessage.config({ local: true })`)
  delivers to the same number with no allowlist / opt-in (confirmed landing twice).

---

## F7 — cloud DM listener floods console: group-events stream is UNIMPLEMENTED on shared plan, retries forever

- **Severity:** medium (DX — the useful output is buried; also wastes a gRPC
  connection retrying indefinitely)
- **Context:** `for await (const [space, message] of app.messages)` in cloud mode
  on a free/shared project. DM messages arrive fine (confirmed: the agent got the
  inbound text). But alongside the DM stream, spectrum opens a **group-events**
  stream `imessage.groups:shared` and the shared-plan server returns
  `SubscribeGroupEvents UNIMPLEMENTED` (gRPC code 12).
- **Symptom:** endless `[spectrum.stream] WARN/ERROR stream interrupted;
  reconnecting … The server does not implement the method
  /photon.imessage.v1.GroupService/SubscribeGroupEvents` with growing backoff
  (500ms → 30s), never giving up. Dozens of stack traces per minute.
- **Two problems:** (1) no way found to tell `imessage.config()` "DM only, don't
  subscribe to group events"; the group stream is opened unconditionally. (2) it
  logs at WARN/ERROR at the default `debug` level, so it's loud by default.
- **Workaround:** set `LOG_LEVEL=silent` (otel env var; wins over `setLogLevel()`).
  The retry still happens, just quietly. Doesn't stop the wasted reconnect loop.
- **Suggested fix:** if the plan/line can't do group events, don't subscribe (or
  detect UNIMPLEMENTED once and stop retrying that stream instead of looping
  forever); and/or expose a `groups: false` / DM-only option on `imessage.config`.

---

## F4 — docs say local-mode `space.create()` throws; the code creates DM spaces fine

- **Severity:** medium (would wrongly steer you away from the ONLY proactive-send
  path in local mode)
- **Where:** `spectrum-ts/docs/providers/imessage/connection-and-routing.mdx.vel`
  (~line 149, and the skill's `providers/imessage.md:49`): *"Space creation
  requires cloud or dedicated mode — local mode throws"* / *"In local mode
  `space.create()` throws because the local Messages database doesn't expose chat
  creation."*
- **Reality (source + installed 9.1.0):** `packages/imessage/src/index.ts:538-556`
  (installed `dist/index.js:2420-2435`) — in local mode, **single-user** DM
  creation succeeds, returning `{ id: "any;-;<addr>", type: "dm", phone: "" }`.
  Only **multi-user (group)** creation throws. `im.space.get("any;-;<addr>")`
  likewise works (pure/synchronous, no server call).
- **Repro:** `--connect-test` in `tracer.ts` — builds `Spectrum({ providers:
  [imessage.config({ local: true })] })`, calls `im.space.get("any;-;+8613...")`,
  gets `id=any;-;+8613410272240 type=dm`, no throw. Confirmed empirically.
- **Impact:** proactive alerting (send to a handle with no inbound message) is the
  core use case, and it depends entirely on local-mode space resolution. The docs
  say it's impossible; it isn't. This nearly killed the whole approach.
- **Suggested fix:** correct the doc to "local mode supports single-user DM spaces
  via `space.get`/`space.create`; only group creation throws."

## F5 — skill shows `im.space(user)` (callable); installed API is `im.space.get(...)`

- **Severity:** low (API-shape drift; caught by a quick smoke test)
- **Where:** skill `spaces-and-users.md` shows `const dm = await im.space(alice)`
  (space as a callable) and `im.user(...)`. Installed 9.1.0 exposes
  `im.space.get(id)` / `im.space.create(user)` (namespaced), confirmed by the
  connect-test resolving via `im.space.get("any;-;...")`.
- **Impact:** copy-pasting the skill's `im.space(alice)` form would throw
  ("im.space is not a function").
- **Suggested fix:** align the skill sample with the `.get`/`.create` surface, or
  version-gate.

---

## F1 — `send()` API in the Claude "imessage" skill contradicts v3.0.0 source

- **Severity:** medium (would cause a `TypeError`/silent-miss on first call if followed)
- **Where:** the bundled `imessage` skill doc vs. `imessage-kit/src/sdk.ts:160` and
  `imessage-kit/src/types/send.ts`.
- **What the doc says:** positional call
  `await sdk.send('+1234567890', 'Hello from iMessage Kit!')`, plus a family of
  convenience methods — `sendText(to, text)`, `sendImage(to, path, text?)`,
  `sendBatch([...])`, `getMessages()`, `getUnreadMessages()`, `listChats()` with a
  `{ type: 'group' }` filter, `startWatching({ onDirectMessage, ... })`.
- **What the source actually is:** a single-object signature —
  `send(request: SendRequest): Promise<void>` where
  `SendRequest = { to: string; text?: string; attachments?: readonly string[] }`.
  No `sendText`/`sendImage`/`sendBatch` on the class; watcher callbacks are named
  `onIncomingMessage / onDirectMessage / onGroupMessage / onFromMeMessage / onError`
  and `listChats` uses `{ kind: 'group' }` (per `examples/04-send-group.ts`), not
  `{ type: 'group' }`.
- **Repro:**
  ```ts
  import { IMessageSDK } from "@photon-ai/imessage-kit"; // 3.0.0
  const sdk = new IMessageSDK();
  await sdk.send("+1XXXXXXXXXX", "hi");   // doc form -> `to` is the string, `text` undefined
  ```
  The second positional arg is ignored; `to` is set but `text` is undefined, so the
  send is malformed rather than delivering "hi".
- **Correct form:** `await sdk.send({ to: "+1XXXXXXXXXX", text: "hi" });`
- **Suggested fix:** regenerate the skill's Self-Hosted API section from v3.0.0 types,
  or version-gate it. The skill appears to describe an older/advanced API surface.

---

## F2 — "zero deps on Bun" but `bun add` still pulls better-sqlite3's build chain

- **Severity:** low (footprint/marketing, not a functional bug)
- **Where:** README / skill both say the SDK has zero extra deps on Bun (Bun's
  built-in SQLite is used instead of `better-sqlite3`).
- **What happened:** `bun add @photon-ai/imessage-kit@3.0.0` installed **39
  transitive packages** into `node_modules`. `better-sqlite3` itself is absent
  (good — it's an optionalDependency Bun skips building), but its entire
  install-time chain still resolves and lands: `prebuild-install`, `node-abi`,
  `tar-fs`, `tar-stream`, `bindings`, `napi-build-utils`, `detect-libc`,
  `simple-get`, `rc`, `bl`, `readable-stream`, etc.
- **Repro:** fresh dir, `bun add @photon-ai/imessage-kit@3.0.0`, then
  `ls node_modules | grep -v '^@' | wc -l` -> 39.
- **Impact:** the "zero deps on Bun" line is technically about the *native module*
  not building, but a user reading it expects a near-empty `node_modules`. The
  optionalDependency's dep subtree is still fetched.
- **Suggested fix:** either move `better-sqlite3` behind a peerDependency/optional
  peer so Bun users don't resolve its subtree, or soften the wording to
  "no native build step on Bun" rather than "zero deps".

---
