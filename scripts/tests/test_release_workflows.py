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


if __name__ == "__main__":
    unittest.main()
