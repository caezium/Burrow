import unittest
import json
import plistlib
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"


class ReleaseWorkflowTests(unittest.TestCase):
    def test_app_version_has_one_source_and_generated_metadata_is_checked(self) -> None:
        project = (ROOT / "macos" / "project.yml").read_text(encoding="utf-8")
        with (ROOT / "macos" / "Resources" / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        ci = (WORKFLOWS / "ci.yml").read_text(encoding="utf-8")
        mcp = (ROOT / "macos" / "Sources" / "MCP.swift").read_text(encoding="utf-8")

        self.assertEqual(
            len(re.findall(r'^\s+MARKETING_VERSION: "[0-9]+\.[0-9]+\.[0-9]+"$', project, re.MULTILINE)),
            1,
        )
        self.assertEqual(
            len(re.findall(r'^\s+CURRENT_PROJECT_VERSION: "[1-9][0-9]*"$', project, re.MULTILINE)),
            1,
        )
        self.assertIn('CFBundleShortVersionString: "$(MARKETING_VERSION)"', project)
        self.assertIn('CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"', project)
        self.assertEqual(info["CFBundleShortVersionString"], "$(MARKETING_VERSION)")
        self.assertEqual(info["CFBundleVersion"], "$(CURRENT_PROJECT_VERSION)")
        self.assertIn("verify-project-generation.py", ci)
        self.assertIn("--check-git", ci)
        self.assertNotIn('"version": "0.3.0"', mcp)

    def test_release_sources_and_tools_are_content_locked(self) -> None:
        lock = json.loads(
            (ROOT / "scripts" / "release-inputs.json").read_text(encoding="utf-8")
        )
        ci = (WORKFLOWS / "ci.yml").read_text(encoding="utf-8")
        release = (WORKFLOWS / "release.yml").read_text(encoding="utf-8")

        self.assertEqual(lock["swiftPackages"], [])
        for group in ("frameworks", "tools"):
            for dependency in lock[group].values():
                self.assertRegex(dependency["version"], r"^[0-9]+\.[0-9]+\.[0-9]+$")
                self.assertRegex(dependency["sha256"], r"^[0-9a-f]{64}$")
                self.assertTrue(dependency["url"].startswith("https://github.com/"))

        self.assertNotIn("brew install xcodegen", ci)
        self.assertNotIn("brew install xcodegen", release)
        self.assertNotIn("brew install sentry-cli", release)
        self.assertIn("fetch-xcodegen.sh", ci)
        self.assertIn("fetch-xcodegen.sh", release)
        self.assertIn("fetch-sentry-cli.sh", release)

    def test_exact_tag_runs_required_tests_before_release_build_and_publish(self) -> None:
        workflow = (WORKFLOWS / "release.yml").read_text(encoding="utf-8")

        test_gate = workflow.index("- name: Test exact tagged commit")
        release_build = workflow.index("- name: Build (Release)")
        publish = workflow.index("- name: Publish verified GitHub release")
        gate = workflow[test_gate:release_build]

        self.assertLess(test_gate, release_build)
        self.assertLess(release_build, publish)
        self.assertIn('git rev-parse HEAD', gate)
        self.assertIn('"$GITHUB_SHA"', gate)
        self.assertIn("verify-project-generation.py", gate)
        self.assertIn("--check-git", gate)
        self.assertIn("python3 -m unittest discover", gate)
        self.assertIn("node --test scripts/tests/test_site_analytics.mjs", gate)
        self.assertIn("xcodebuild test", gate)

    def test_symbols_are_required_and_match_the_distributed_binary(self) -> None:
        workflow = (WORKFLOWS / "release.yml").read_text(encoding="utf-8")

        credentials = workflow.index("- name: Require release credentials")
        upload = workflow.index("- name: Verify and upload release dSYM")
        download = workflow.index("- name: Verify downloaded release artifact")
        publish = workflow.index("- name: Publish verified GitHub release")

        self.assertIn("SENTRY_AUTH_TOKEN", workflow[credentials:upload])
        self.assertNotIn("skipped if no token", workflow)
        self.assertIn("verify-dsym-uuids.sh", workflow[upload:publish])
        self.assertIn("debug-files check", workflow[upload:download])
        self.assertIn("debug-files upload", workflow[upload:download])
        self.assertLess(upload, download)
        self.assertLess(download, publish)

    def test_release_stays_draft_until_downloaded_artifact_passes_trust_checks(self) -> None:
        workflow = (WORKFLOWS / "release.yml").read_text(encoding="utf-8")

        upload = workflow.index("- name: Upload GitHub release draft")
        verify = workflow.index("- name: Verify downloaded release artifact")
        publish = workflow.index("- name: Publish verified GitHub release")
        homebrew = workflow.index("- name: Bump Homebrew cask")
        verification = workflow[verify:publish]

        self.assertLess(upload, verify)
        self.assertLess(verify, publish)
        self.assertLess(publish, homebrew)
        self.assertIn('if [ "$IS_DRAFT" != "true" ]', workflow[upload:verify])
        self.assertIn("gh release download", verification)
        self.assertIn('steps.pkg.outputs.sha', verification)
        self.assertIn("verify-macos-release.sh", verification)
        self.assertIn("verify-dsym-uuids.sh", verification)
        self.assertIn('"$EXPECTED_TEAM_ID"', verification)
        self.assertIn('gh release edit "$GITHUB_REF_NAME" --draft=false', workflow[publish:homebrew])

    def test_macos_release_verifier_pins_the_designated_requirement(self) -> None:
        verifier = (ROOT / "scripts" / "verify-macos-release.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("codesign --verify --deep --strict", verifier)
        self.assertIn("codesign -d -r-", verifier)
        self.assertIn("anchor apple generic", verifier)
        self.assertIn("subject\\.OU", verifier)
        self.assertIn("xcrun stapler validate", verifier)
        self.assertIn("spctl --assess --type execute", verifier)

    def test_tap_permission_check_runs_before_the_release_build(self) -> None:
        workflow = (WORKFLOWS / "release.yml").read_text(encoding="utf-8")

        require_credentials = workflow.index("- name: Require release credentials")
        verify_tap = workflow.index("- name: Verify Homebrew tap write access")
        build_release = workflow.index("- name: Build (Release)")

        self.assertLess(require_credentials, verify_tap)
        self.assertLess(verify_tap, build_release)
        self.assertIn(
            "run: bash scripts/verify-homebrew-tap-access.sh",
            workflow[verify_tap:build_release],
        )

    def test_manual_tap_check_uses_the_same_isolated_verifier(self) -> None:
        workflow = (WORKFLOWS / "homebrew-tap-credential-check.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("permissions:\n  contents: read", workflow)
        self.assertIn(
            "run: bash scripts/verify-homebrew-tap-access.sh",
            workflow,
        )
        self.assertIn("persist-credentials: false", workflow)

    def test_tap_verifier_pushes_and_removes_a_temporary_ref(self) -> None:
        verifier = (ROOT / "scripts" / "verify-homebrew-tap-access.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("burrow-release-access-probe-", verifier)
        self.assertIn('push --quiet origin "HEAD:$probe_ref"', verifier)
        self.assertIn('push --quiet origin ":$probe_ref"', verifier)
        self.assertNotIn('push --dry-run origin "HEAD:$probe_ref"', verifier)

    def test_release_does_not_leak_engine_credentials_into_tap_push(self) -> None:
        workflow = (WORKFLOWS / "release.yml").read_text(encoding="utf-8")
        tap_start = workflow.index(
            "- name: Bump Homebrew cask in caezium/homebrew-tap"
        )
        tap_step = workflow[tap_start:]

        self.assertIn("persist-credentials: false", workflow)
        self.assertIn("export GIT_CONFIG_COUNT=1", workflow)
        self.assertNotIn("git config --global url.", workflow)
        self.assertIn(
            'export GIT_CONFIG_GLOBAL="$RUNNER_TEMP/burrow-tap-gitconfig"',
            tap_step,
        )
        self.assertIn('(cd "$RUNNER_TEMP" && git clone', tap_step)
        self.assertIn('cd "$TAP_DIR"', tap_step)

    def test_release_notes_are_validated_before_sparkle_embeds_them(self) -> None:
        workflow = (WORKFLOWS / "release.yml").read_text(encoding="utf-8")

        validate = workflow.index("scripts/validate-release-notes.py")
        embed = workflow.index('cp RELEASES.md "dist/Burrow-${VERSION}.md"')

        self.assertLess(validate, embed)

    def test_manual_notes_repair_is_narrow_and_fail_closed(self) -> None:
        workflow = (WORKFLOWS / "repair-sparkle-release-notes.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("workflow_dispatch:", workflow)
        self.assertNotIn("push:", workflow)
        self.assertIn("contents: write", workflow)
        self.assertIn("group: release", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertIn('if [ "$GITHUB_REF" != "refs/heads/$DEFAULT_BRANCH" ]', workflow)
        self.assertIn("scripts/validate-release-notes.py", workflow)
        self.assertIn("scripts/verify-sparkle-appcast.py", workflow)
        self.assertIn("SPARKLE_ED_PRIVATE_KEY", workflow)
        self.assertIn('gh release upload "$TAG" "$APPCAST"', workflow)
        self.assertIn("--clobber", workflow)
        self.assertIn('gh release edit "$TAG"', workflow)
        self.assertIn("--notes-file RELEASES.md", workflow)
        self.assertNotIn('gh release upload "$TAG" "$ZIP"', workflow)
        self.assertIn('sign_update" --verify', workflow)

        verify_start = workflow.index("- name: Verify the published repair")
        verify_step = workflow[verify_start:]
        self.assertIn(
            "ASSET_NAME: ${{ steps.target.outputs.asset_name }}", verify_step
        )
        self.assertIn(
            "EXPECTED_DIGEST: ${{ steps.target.outputs.asset_digest }}", verify_step
        )
        self.assertIn(
            'if [ "$PUBLISHED_DIGEST" != "$EXPECTED_DIGEST" ]', verify_step
        )

    def test_xcode_27_preview_lane_is_advisory_and_runs_the_full_suite(self) -> None:
        workflow = (WORKFLOWS / "ci.yml").read_text(encoding="utf-8")
        start = workflow.index("  xcode-27-compatibility:")
        end = workflow.index("  fclones-sidecar:", start)
        job = workflow[start:end]

        self.assertIn("runs-on: xcode-27", job)
        self.assertIn("continue-on-error: true", job)
        self.assertIn("bash ../scripts/fetch-sentry.sh", job)
        self.assertIn("bash ../scripts/fetch-sparkle.sh", job)
        self.assertIn("xcodegen generate", job)
        self.assertIn("xcodebuild test", job)


if __name__ == "__main__":
    unittest.main()
