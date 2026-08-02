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

The check reads GitHub's authenticated repository permissions and requires
`push: true`; it does not modify the tap. The tag workflow runs the same check
before any build, signing, or notarization work. Open the run URL printed by
`gh` and require a successful result.

After the secrets are stored, move every exported private-key file out of
Downloads and into the password manager’s encrypted file storage. Keep tested
backups of the `.p12` and Sparkle seed: losing either one prevents future
releases from extending its respective trust chain.

## 6. Cut and verify a signed release

Choose the next app version and build number, update the release notes, and
merge the release change before tagging. Never move a tag after its GitHub
release has published.

The workflow order is:

1. Require all Apple, Sparkle, and external-tap secrets, then verify that
   `TAP_PAT` can write `caezium/homebrew-tap`.
2. Fetch and checksum-validate the official Sentry and Sparkle frameworks,
   then build and confirm the bundled conductor, engine, and fclones sidecar.
3. Require the Sparkle private seed to match the public key embedded in the app.
4. Sign every executable and the outer app with Developer ID.
5. Require Apple’s notarization result to be `Accepted`.
6. Staple and validate the ticket, then require Gatekeeper acceptance.
7. Package the exact verified app, generate the signed appcast, and
   cryptographically verify the ZIP and feed before publishing either asset.
8. Keep a new release draft until both assets exist, then publish it.
9. Update `caezium/homebrew-tap`: normalize `auto_updates true` beside the
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
xcrun stapler validate verified-release/Burrow.app
spctl --assess --type execute --verbose=4 verified-release/Burrow.app
```

The final `spctl` result must identify the source as `Notarized Developer ID`.
Check that Homebrew’s live `Casks/burrow.rb` no longer contains `postflight`,
`xattr -cr`, or an unsigned-build caveat, and that it contains
`auto_updates true`. Confirm the release has both `Burrow-VERSION.zip` and
`appcast.xml`, and that
`https://github.com/caezium/Burrow/releases/latest/download/appcast.xml`
resolves to that feed.

### 0.11.0 trust-chain baseline

The first signed release was verified on August 1, 2026. Tag `v0.11.0` points
to `b79c077df365041db6006ace4fdf6b30c9b40fe9`; the published ZIP has SHA-256
`ae3a31f15a16bdf2e87bb0ca6ae5938d22d1a8c3181dac28ec9d0fb8d05f2b65`.
The downloaded and Homebrew-installed copies both passed strict nested-signature
verification, stapler validation, and Gatekeeper assessment as
`Notarized Developer ID`. The embedded app reports version 0.11.0, build 21,
Team ID `YGSM2722TZ`, a hardened runtime, a secure timestamp,
`ITSAppUsesNonExemptEncryption=false`, and the checked-in privacy manifest.

The live `caezium/homebrew-tap` cask is 0.11.0 with the same SHA, has
`auto_updates true`, preserves quarantine, and contains no `postflight`,
`xattr -cr`, or unsigned-build warning. A real Homebrew upgrade from 0.10.2 to
0.11.0 retained `com.apple.quarantine` and passed Gatekeeper. Issues #177 and
#181 were closed only after those checks completed.

The GitHub release notes carry the #281 end-to-end caveat. The verified ZIP and
signed appcast remain byte-for-byte unchanged after publication: copy-only
clarifications belong in the release notes and site, not in a replacement
signed feed. Replace and re-sign a published feed only for a correctness or
security defect, then repeat the full asset verification above.

Keep #281 open until a real 0.11-to-successor Sparkle update completes; the
first Sparkle-enabled build cannot prove its own upgrade path without a newer
signed feed entry.

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
