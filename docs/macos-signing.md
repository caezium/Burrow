# macOS Developer ID release runbook

Burrow’s GitHub/Homebrew release path distributes a ZIP outside the Mac App
Store, so it needs a **Developer ID Application** certificate and Apple
notarization. It does not need a Developer ID Installer certificate because it
does not ship a signed installer package.

The tag workflow is fail closed. It requires every Apple, Sparkle, and
external-tap credential before building; signs every Mach-O file with hardened
runtime and a secure timestamp; requires an accepted Apple notarization,
stapled ticket, strict code-signature verification, and Gatekeeper assessment;
then signs and verifies both the update ZIP and appcast with Sparkle Ed25519.
Only then can it publish a GitHub release or update Homebrew.

## 1. Create the certificate signing request

Follow Apple’s
[Keychain Access CSR workflow](https://developer.apple.com/help/account/certificates/create-a-certificate-signing-request):

1. Open **Keychain Access → Certificate Assistant → Request a Certificate From
   a Certificate Authority**.
2. Enter the email address attached to the Account Holder’s Apple Account.
3. Use a recognizable common name such as `Burrow Developer ID 2026`.
4. Leave the CA email address empty, choose **Saved to disk**, and save the
   `.certSigningRequest`.

The CSR is safe to upload to Apple. The private key created with it stays in the
login keychain and must never be committed, uploaded as an Actions artifact, or
sent in chat.

## 2. Create and export the Developer ID Application identity

In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list):

1. Choose **Certificates → + → Software → Developer ID → Developer ID
   Application**.
2. Upload the CSR, download the resulting `.cer`, and double-click it to install
   it in the same keychain that holds the CSR’s private key.
3. In Keychain Access, open **My Certificates**. The new `Developer ID
   Application: … (TEAMID)` certificate must expand to show its private key.
4. Export that certificate and private key together as a password-protected
   `.p12`. Generate a unique password and store it in the password manager.

Confirm the exact identity string before configuring CI:

```bash
security find-identity -v -p codesigning
```

Apple limits Developer ID certificate creation and revocation has a large
blast radius, so keep one protected release identity instead of generating a
new certificate per build.

## 3. Create the notarization API key

The workflow uses an App Store Connect **Team API key**. Apple explicitly
excludes Individual API keys from `notarytool`.

1. Open **App Store Connect → Users and Access → Integrations**. If API access
   is not enabled, the Account Holder must request it and wait for Apple’s
   approval.
2. Under **Team Keys**, generate `Burrow Notarization` with the **Developer**
   role. This is the least-privilege practical role for the release key.
3. Download `AuthKey_<KEY_ID>.p8` immediately; Apple allows the private key to
   be downloaded only once. Record the Key ID and Issuer ID beside it in the
   password manager.

Validate the key locally before creating a tag:

```bash
xcrun notarytool history \
  --key /absolute/path/to/AuthKey_KEYID.p8 \
  --key-id KEY_ID \
  --issuer ISSUER_ID
```

If Apple rejects that role for this team, revoke the key and recreate it with
the next required role; App Store Connect does not allow an existing key’s
access level to be edited.

## 4. Create the Sparkle Ed25519 key

Burrow uses a separate Ed25519 key for Sparkle archives and feeds. This is not
the Developer ID certificate, and rotating it carelessly would prevent
installed copies from accepting later updates.

Download the official Sparkle 2.9.4 release tools from
[`sparkle-project/Sparkle`](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.4)
and verify `Sparkle-2.9.4.tar.xz` has SHA-256
`ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9`.
Extract it, then run:

```bash
./bin/generate_keys --account caezium-burrow
./bin/generate_keys --account caezium-burrow \
  -x /absolute/path/to/Burrow-Sparkle-Ed25519.key
```

The first command stores the private seed in the login keychain and prints the
public key. Put that public value in `macos/project.yml` as `SUPublicEDKey`.
The exported file contains the base64 private seed: store it as a protected
Bitwarden item/attachment and never commit it, paste it into an issue, or add
it to an Actions artifact. Keep one tested backup because losing it breaks the
in-app update chain for every installed release.

## 5. Add the GitHub Actions secrets

Run these from a machine where `gh auth status` confirms access to
`caezium/Burrow`. The two pipelines stream base64 directly into GitHub and do
not print private-key material:

```bash
/usr/bin/base64 < /absolute/path/to/Burrow-Developer-ID.p12 \
  | gh secret set MACOS_CERT_P12 --repo caezium/Burrow

/usr/bin/base64 < /absolute/path/to/AuthKey_KEYID.p8 \
  | gh secret set AC_API_KEY_P8 --repo caezium/Burrow
```

Set the remaining values interactively so they do not enter shell history:

```bash
gh secret set MACOS_CERT_PASSWORD --repo caezium/Burrow
gh secret set MACOS_SIGN_IDENTITY --repo caezium/Burrow
gh secret set AC_API_KEY_ID --repo caezium/Burrow
gh secret set AC_API_ISSUER_ID --repo caezium/Burrow
gh secret set SPARKLE_ED_PRIVATE_KEY --repo caezium/Burrow \
  < /absolute/path/to/Burrow-Sparkle-Ed25519.key
```

`TAP_PAT` is also required. It should remain the existing fine-grained token
scoped only to `caezium/homebrew-tap`, with repository **Contents: Read and
write** permission.

The required names are:

- `MACOS_CERT_P12`
- `MACOS_CERT_PASSWORD`
- `MACOS_SIGN_IDENTITY`
- `AC_API_KEY_ID`
- `AC_API_ISSUER_ID`
- `AC_API_KEY_P8`
- `SPARKLE_ED_PRIVATE_KEY`
- `TAP_PAT`

`MACOS_SIGN_IDENTITY` is the full output name, including the team ID:
`Developer ID Application: Name (TEAMID)`.

Confirm only the names and timestamps, never their values:

```bash
gh secret list --app actions --repo caezium/Burrow \
  | grep -E '^(MACOS_|AC_API_|SPARKLE_|TAP_PAT)'
```

After creating or rotating `TAP_PAT`, run the manual credential check before
cutting a tag:

```bash
gh workflow run homebrew-tap-credential-check.yml --repo caezium/Burrow
```

The check clones the tap, pushes a uniquely named temporary ref through the
same Git transport used by the release, verifies it, and immediately deletes
it. The real push requires effective **Contents: Read and write** permission; a
successful check leaves no branch or commit behind. The repository API's
`permissions.push` field, `git push --dry-run`, and a same-SHA API update are
all insufficient because GitHub can accept them without authorizing a Git
write. The tag workflow runs the same create-and-delete check before any build,
signing, or notarization work. Open the run URL printed by `gh` and require a
successful result.

After the secrets are stored, move every exported private-key file out of
Downloads and into the password manager’s encrypted file storage. Keep tested
backups of the `.p12` and Sparkle seed: losing either one prevents future
releases from extending its respective trust chain.

## 6. Cut and verify a signed release

Choose the next app version and build number, update the release notes, and
merge the release change before tagging. Never move a tag after its GitHub
release has published.

`RELEASES.md` is user-facing runtime content: the release workflow embeds it
verbatim in Sparkle's signed appcast and also uses it as the GitHub release
body. Keep only the newest release, begin directly with `# Burrow VERSION`, and
put contributor instructions in this runbook rather than HTML comments—Sparkle
renders those comments as visible text. Full site history belongs in
`docs/releases.json` and is generated into `docs/releases.html`.

The workflow order is:

1. Require all Apple, Sparkle, Sentry-symbol, and external-tap secrets, then
   verify that `TAP_PAT` can write `caezium/homebrew-tap`.
2. Fetch the checksum-locked release inputs and prove that XcodeGen produces
   identical metadata twice from the checked-in version/build source.
3. Require the triggering tag to name the checked-out SHA exactly, then run the
   release-helper, website, and complete macOS unit suites on that commit.
4. Build and confirm the bundled conductor, engine, and fclones sidecar.
5. Require the app binary UUIDs to exactly match its dSYM, validate the dSYM,
   and upload it without source files before release publication can continue.
6. Require the Sparkle private seed to match the public key embedded in the app.
7. Sign every executable and the outer app with Developer ID, preserving bundle
   ID `dev.caezium.Burrow` and Team ID `YGSM2722TZ` in the designated requirement.
8. Require Apple’s notarization result to be `Accepted`, staple the ticket, then
   require strict code-signature, designated-requirement, and Gatekeeper checks.
9. Package the exact verified app, generate the signed appcast, and
   cryptographically verify the ZIP and feed before uploading either to a draft.
10. Download both draft assets again, match the ZIP SHA and dSYM UUIDs, extract
    the app, and repeat Developer ID, requirement, ticket, Gatekeeper, and
    Sparkle checks before making the release public.
11. Update `caezium/homebrew-tap`: normalize `auto_updates true` beside the
   homepage stanza and fail if the legacy quarantine bypass, unsigned warning,
   or stale security note ever reappears.

CI waits up to 60 minutes for Apple and preserves the submission ID even when
that wait expires. A timeout still blocks stapling, packaging, the GitHub
release, and the tap update. Query the existing ID with `notarytool info`
instead of submitting a duplicate; a failed runner cannot resume its discarded
build, so create one fresh release build only after the existing submission
reaches a terminal state.

Download the release asset and verify the distributed copy:

```bash
ditto -x -k Burrow-VERSION.zip verified-release
codesign --verify --deep --strict --verbose=2 verified-release/Burrow.app
codesign -d --verbose=4 verified-release/Burrow.app
codesign -d -r- verified-release/Burrow.app
xcrun stapler validate verified-release/Burrow.app
spctl --assess --type execute --verbose=4 verified-release/Burrow.app
```

The final `spctl` result must identify the source as `Notarized Developer ID`.
The designated requirement must contain `identifier "dev.caezium.Burrow"`,
`anchor apple generic`, and Team ID `YGSM2722TZ`; changing any of those values
can break upgrade and Full Disk Access continuity even when a signature is
otherwise valid.
Check that Homebrew’s live `Casks/burrow.rb` no longer contains `postflight`,
`xattr -cr`, or an unsigned-build caveat, and that it contains
`auto_updates true`. Confirm the release has both `Burrow-VERSION.zip` and
`appcast.xml`, and that
`https://github.com/caezium/Burrow/releases/latest/download/appcast.xml`
resolves to that feed.

### 0.11.2 current release and symbol baseline

The current release was re-verified from its downloaded GitHub asset on August
8, 2026. Tag `v0.11.2` points to
`c08de9714d51b6f6aa580ce9e9b71bebf4fb86be`; the ZIP has SHA-256
`2a51a87d541be50cd3b2ab9418dfcaf20927d16499a265298b53bbc100d4eca5`,
and `appcast.xml` has SHA-256
`04ac0ea7efcade3d0ea87455a1ab849ebd853c9a288c09b545d3d59bfc04feaa`.
The extracted app reports version 0.11.2, build 23, bundle ID
`dev.caezium.Burrow`, and Team ID `YGSM2722TZ`; strict nested-signature,
designated-requirement, stapler, and Gatekeeper checks all pass.

The distributed binary UUIDs are
`324C0B80-A09E-346C-8153-7BDCCB37A24C` (arm64) and
`B0DF1FAF-0575-3865-8C7F-E2CBFFD141CC` (x86_64). The
[tag workflow log](https://github.com/caezium/Burrow/actions/runs/30934193823)
records those exact two UUIDs as uploaded Sentry debug companions, proving that
the 0.11.2 dSYM matches the public release binary. That evidence does not
recover BURROW-9E by itself: the older event still needs restricted Sentry data
and an actionable frame, so the trigger below remains in force.

### 0.11.1 trust-chain baseline

The current release was verified on August 3, 2026. Tag `v0.11.1` points to
`d482544e415d10cf9cb0c606c8a8ce149ddad99d`; the published ZIP has SHA-256
`d9b2267cce68ff091d898bdfca30e0b0f861a411ee92c4a4b60b70bcf0b8bceb`, and
the signed `appcast.xml` asset has SHA-256
`1be59389da7ad1df8c8c90bc8492ad86c31f1295e29170eed0f72ddc435a5d3f`.
The downloaded copy passed strict nested-signature verification, stapler
validation, and Gatekeeper assessment as `Notarized Developer ID`. The embedded
app reports version 0.11.1, build 22, bundle ID `dev.caezium.Burrow`, Team ID
`YGSM2722TZ`, a hardened runtime, a secure timestamp,
`ITSAppUsesNonExemptEncryption=false`, the checked-in privacy manifest, and
non-empty PostHog/Sentry release configuration. Burrow, the bundled conductor,
and fclones each contain both arm64 and x86_64 slices.

The live `caezium/homebrew-tap` cask is 0.11.1 with the same ZIP SHA, has
`auto_updates true`, preserves quarantine, and contains no `postflight`,
`xattr -cr`, or unsigned-build warning. The release job passed Developer ID
signing, notarization, stapling, Gatekeeper, Sparkle verification, and GitHub
publication, then its final tap push received HTTP 403 because the build step's
global GitHub URL rewrite made Git authenticate with `ENGINE_PAT` instead of
the valid `TAP_PAT`. That engine token is deliberately scoped only to the
private engine repository. The cask was repaired with the owner credential at
tap commit
`9a2357bf9419b9e39836cd69391dfa2a5d5bd421`. The first corrections in
[#324](https://github.com/caezium/Burrow/pull/324) and
[#326](https://github.com/caezium/Burrow/pull/326) proved that Git's dry run and
a same-SHA ref update both return false positives. The current verifier pushes,
verifies, and removes a unique temporary ref through Git itself, exercising the
release's actual authentication path. The engine rewrite is now process-scoped,
and the tap step uses an isolated Git configuration so the two credentials
cannot cross. The stored `TAP_PAT` then passed a
[real Git push-and-delete credential check](https://github.com/caezium/Burrow/actions/runs/30766229249),
so it does not need rotation. Require that manual workflow to pass before every
tag.

A real Sparkle update then moved the installed signed app from 0.11.0 build 21
to 0.11.1 build 22 through the native UI without Terminal or Homebrew. The app
relaunched and again passed strict signing, stapler, and Gatekeeper checks; a
separate `Burrow --mcp` process stayed alive. This completed
[#281](https://github.com/caezium/Burrow/issues/281). Full Disk Access was
already off on that test Mac, so this run does not prove preservation of an
existing FDA grant. [#319](https://github.com/caezium/Burrow/issues/319)
remains open until an affected macOS 27 Beta 4 user verifies the notarized
compatibility build.

The next signed successor test must start with Full Disk Access enabled for the
currently installed release, update through Sparkle, and prove the relaunched
copy retains protected-folder access without another grant. The release job now
enforces the stable designated requirement on both its local app and the
downloaded draft, but the 0.11.0 → 0.11.1 test cannot supply this external TCC
evidence because Full Disk Access was off before that update.

### Symbolication incident trigger

The public report for BURROW-9E ([#306](https://github.com/caezium/Burrow/issues/306))
contains only an unknown top frame, so it does not establish a failing function
or reproduction path. The next actionable trigger is the first matching event
from a tag produced after the mandatory UUID-verified dSYM upload gate above.
In restricted Sentry, compare that event's debug ID with the UUIDs printed by
`verify-dsym-uuids.sh`; if they match, record the first symbolicated in-app frame
and the smallest reproducible launch/update condition. If the frame remains
unknown, retain Sentry's processing error and mismatched/missing debug ID there
and block the next tag until the upload is corrected. Public GitHub issues get
only a minimal privacy-reviewed diagnosis and the restricted Sentry link, never
the raw event, stack, local paths, arguments, or usernames.

### 0.11.0 historical first-signed baseline

The first signed release was verified on August 1, 2026. Tag `v0.11.0` points
to `b79c077df365041db6006ace4fdf6b30c9b40fe9`; its published ZIP has SHA-256
`ae3a31f15a16bdf2e87bb0ca6ae5938d22d1a8c3181dac28ec9d0fb8d05f2b65`.
The downloaded and Homebrew-installed copies passed strict nested-signature,
stapler, and Gatekeeper checks. A Homebrew upgrade from 0.10.2 retained
quarantine and passed Gatekeeper, after which #177 and #181 were closed.

Published ZIPs and signed appcasts remain byte-for-byte unchanged after
publication: copy-only clarifications belong in the GitHub release body and
site, not in replacement signed assets. Replace and re-sign a published feed
only for a correctness or security defect, then repeat the full verification
above.

For that exceptional repair, first merge corrected `RELEASES.md`, then run the
manual `repair-sparkle-release-notes` workflow with the current release tag.
The job refuses historical or draft releases, preserves the published ZIP,
re-signs the feed with the existing Sparkle key, verifies the embedded Markdown
byte-for-byte, replaces `appcast.xml`, and updates the GitHub release body.

## Telemetry and signing

Signing and notarization do not require in-app telemetry. CI records only
release-operational evidence in the private Actions log: the number of signed
Mach-O files, certificate authority and team ID, Apple submission ID/status,
stapler result, and Gatekeeper verdict.

Burrow independently records fixed-name Sparkle update milestones and sampled
launch diagnostics through its existing opt-out switch; those events contain
no signing credential, submission ID, request URL, or certificate detail. The
checked-in privacy manifest is the store-facing declaration, while
[`TELEMETRY.md`](../TELEMETRY.md) remains the human-readable source of truth.

## Mac App Store later

A Mac App Store build is possible only as a materially reduced product. Apple
requires App Sandbox, and embedded command-line tools inherit that sandbox.
Burrow’s core product deliberately scans broad filesystem locations, inspects
processes and ports, launches bundled cleanup tools, invokes Homebrew, and
offers administrator-assisted operations. Those behaviors do not fit the
current sandboxed bundle.

The credible store version would be a separate SKU with a separate bundle ID:
user-selected folders via security-scoped bookmarks, read-only status features,
and no broad cleanup, privileged shell, Homebrew management, or general MCP
system-tool surface. That is worth building only if App Store discovery or
managed-store deployment creates enough demand for the reduced feature set.
Developer ID plus notarized GitHub/Homebrew distribution should be proven first.
