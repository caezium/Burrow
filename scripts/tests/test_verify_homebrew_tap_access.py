import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VERIFIER = ROOT / "scripts" / "verify-homebrew-tap-access.sh"


class VerifyHomebrewTapAccessTests(unittest.TestCase):
    def run_verifier(
        self,
        *,
        token: str | None = "test-token",
        gh_api_exit: int = 0,
        gh_auth_exit: int = 0,
        git_clone_exit: int = 0,
        git_push_exit: int = 0,
    ) -> tuple[subprocess.CompletedProcess[str], str, str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            gh_call_log = root / "gh-calls.txt"
            git_call_log = root / "git-calls.txt"

            fake_gh = fake_bin / "gh"
            fake_gh.write_text(
                """#!/bin/bash
printf '%s\\n' "$*" >> "$GH_CALL_LOG"
if [ "$1" = "api" ]; then
  [ "$GH_API_EXIT" -eq 0 ] || echo "HTTP 403" >&2
  exit "$GH_API_EXIT"
fi
if [ "$1" = "auth" ] && [ "${2:-}" = "setup-git" ]; then
  exit "$GH_AUTH_EXIT"
fi
exit 99
""",
                encoding="utf-8",
            )
            fake_gh.chmod(0o755)

            fake_git = fake_bin / "git"
            fake_git.write_text(
                """#!/bin/bash
printf '%s\\n' "$*" >> "$GIT_CALL_LOG"
if [ "$1" = "clone" ]; then
  [ "$GIT_CLONE_EXIT" -eq 0 ] || exit "$GIT_CLONE_EXIT"
  destination="${!#}"
  mkdir -p "$destination"
  exit 0
fi
if [ "$1" = "-C" ] && [ "${3:-}" = "push" ]; then
  [ "$GIT_PUSH_EXIT" -eq 0 ] || echo "simulated push denial" >&2
  exit "$GIT_PUSH_EXIT"
fi
exit 99
""",
                encoding="utf-8",
            )
            fake_git.chmod(0o755)

            env = os.environ.copy()
            env.pop("GH_TOKEN", None)
            env.pop("GITHUB_TOKEN", None)
            env.update(
                {
                    "GH_API_EXIT": str(gh_api_exit),
                    "GH_AUTH_EXIT": str(gh_auth_exit),
                    "GH_CALL_LOG": str(gh_call_log),
                    "GIT_CALL_LOG": str(git_call_log),
                    "GIT_CLONE_EXIT": str(git_clone_exit),
                    "GIT_PUSH_EXIT": str(git_push_exit),
                    "PATH": f"{fake_bin}{os.pathsep}{env['PATH']}",
                    "RUNNER_TEMP": str(root),
                    "GITHUB_RUN_ID": "123",
                    "GITHUB_RUN_ATTEMPT": "2",
                }
            )
            if token is not None:
                env["GH_TOKEN"] = token

            result = subprocess.run(
                ["bash", str(VERIFIER)],
                capture_output=True,
                text=True,
                env=env,
            )
            gh_calls = (
                gh_call_log.read_text(encoding="utf-8")
                if gh_call_log.exists()
                else ""
            )
            git_calls = (
                git_call_log.read_text(encoding="utf-8")
                if git_call_log.exists()
                else ""
            )
            return result, gh_calls, git_calls

    def test_accepts_token_with_actual_git_push_access(self) -> None:
        result, gh_calls, git_calls = self.run_verifier()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Homebrew tap write access verified", result.stdout)
        self.assertEqual(
            gh_calls.splitlines(),
            ["api repos/caezium/homebrew-tap", "auth setup-git"],
        )
        self.assertIn(
            "clone --quiet --depth 1 https://github.com/caezium/homebrew-tap.git",
            git_calls,
        )
        self.assertIn("push --dry-run origin", git_calls)
        self.assertIn(
            "HEAD:refs/heads/burrow-release-access-probe-123-2",
            git_calls,
        )

    def test_rejects_missing_token_before_calling_github(self) -> None:
        result, gh_calls, git_calls = self.run_verifier(token=None)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TAP_PAT is missing", result.stderr)
        self.assertEqual(gh_calls, "")
        self.assertEqual(git_calls, "")

    def test_rejects_token_that_can_read_but_cannot_push(self) -> None:
        result, _, git_calls = self.run_verifier(git_push_exit=128)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("simulated push denial", result.stderr)
        self.assertIn(
            "TAP_PAT cannot push to caezium/homebrew-tap",
            result.stderr,
        )
        self.assertIn("push --dry-run origin", git_calls)

    def test_reports_github_api_failure(self) -> None:
        result, _, git_calls = self.run_verifier(gh_api_exit=1)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TAP_PAT cannot read caezium/homebrew-tap", result.stderr)
        self.assertEqual(git_calls, "")

    def test_reports_git_auth_setup_failure_before_cloning(self) -> None:
        result, _, git_calls = self.run_verifier(gh_auth_exit=1)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "Unable to configure Git authentication from TAP_PAT",
            result.stderr,
        )
        self.assertEqual(git_calls, "")


if __name__ == "__main__":
    unittest.main()
