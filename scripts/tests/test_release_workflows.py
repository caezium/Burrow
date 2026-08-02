import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"


class ReleaseWorkflowTests(unittest.TestCase):
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

    def test_manual_tap_check_is_read_only_and_uses_the_same_verifier(self) -> None:
        workflow = (WORKFLOWS / "homebrew-tap-credential-check.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("permissions:\n  contents: read", workflow)
        self.assertIn(
            "run: bash scripts/verify-homebrew-tap-access.sh",
            workflow,
        )
        self.assertNotIn("git push", workflow)

    def test_tap_verifier_checks_token_write_scope_without_mutating(self) -> None:
        verifier = (ROOT / "scripts" / "verify-homebrew-tap-access.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn('git -C "$tap_dir" push --dry-run', verifier)
        self.assertIn("refs/heads/burrow-release-access-probe-", verifier)
        self.assertNotIn("--jq", verifier)

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
