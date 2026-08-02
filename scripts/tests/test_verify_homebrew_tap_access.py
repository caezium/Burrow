import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VERIFIER = ROOT / "scripts" / "verify-homebrew-tap-access.sh"
TAP_SHA = "9a2357bf9419b9e39836cd69391dfa2a5d5bd421"


class VerifyHomebrewTapAccessTests(unittest.TestCase):
    def run_verifier(
        self,
        *,
        token: str | None = "test-token",
        auth_exit: int = 0,
        clone_exit: int = 0,
        create_exit: int = 0,
        delete_exit: int = 0,
        remote_sha: str = TAP_SHA,
    ) -> tuple[subprocess.CompletedProcess[str], str, str, bool]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            gh_call_log = root / "gh-calls.txt"
            git_call_log = root / "git-calls.txt"
            ref_state = root / "probe-ref-exists"

            fake_gh = fake_bin / "gh"
            fake_gh.write_text(
                """#!/bin/bash
printf '%s\\n' "$*" >> "$GH_CALL_LOG"
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
if [ "$1" = "-C" ] && [ "${3:-}" = "rev-parse" ]; then
  printf '%s\\n' "$GIT_HEAD_SHA"
  exit 0
fi
if [ "$1" = "-C" ] && [ "${3:-}" = "push" ]; then
  refspec="${!#}"
  if [[ "$refspec" == :refs/heads/* ]]; then
    [ "$GIT_DELETE_EXIT" -eq 0 ] || { echo "HTTP 500" >&2; exit "$GIT_DELETE_EXIT"; }
    rm -f "$GIT_REF_STATE"
    exit 0
  fi
  [ "$GIT_CREATE_EXIT" -eq 0 ] || { echo "HTTP 403" >&2; exit "$GIT_CREATE_EXIT"; }
  touch "$GIT_REF_STATE"
  exit 0
fi
if [ "$1" = "-C" ] && [ "${3:-}" = "ls-remote" ]; then
  [ -f "$GIT_REF_STATE" ] || exit 2
  printf '%s\\t%s\\n' "$GIT_REMOTE_SHA" "${!#}"
  exit 0
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
                    "GH_AUTH_EXIT": str(auth_exit),
                    "GH_CALL_LOG": str(gh_call_log),
                    "GIT_CALL_LOG": str(git_call_log),
                    "GIT_CLONE_EXIT": str(clone_exit),
                    "GIT_CREATE_EXIT": str(create_exit),
                    "GIT_DELETE_EXIT": str(delete_exit),
                    "GIT_HEAD_SHA": TAP_SHA,
                    "GIT_REF_STATE": str(ref_state),
                    "GIT_REMOTE_SHA": remote_sha,
                    "GITHUB_RUN_ATTEMPT": "2",
                    "GITHUB_RUN_ID": "123",
                    "PATH": f"{fake_bin}{os.pathsep}{env['PATH']}",
                    "RUNNER_TEMP": str(root),
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
            return result, gh_calls, git_calls, ref_state.exists()

    def test_accepts_token_with_actual_git_push_access(self) -> None:
        result, gh_calls, git_calls, ref_exists = self.run_verifier()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("write access verified", result.stdout)
        self.assertEqual(gh_calls.splitlines(), ["auth setup-git"])
        self.assertIn(
            "clone --quiet --depth 1 https://github.com/caezium/homebrew-tap.git",
            git_calls,
        )
        self.assertIn(
            "push --quiet origin HEAD:refs/heads/burrow-release-access-probe-123-2",
            git_calls,
        )
        self.assertIn(
            "push --quiet origin :refs/heads/burrow-release-access-probe-123-2",
            git_calls,
        )
        self.assertNotIn("--dry-run", git_calls)
        self.assertFalse(ref_exists)

    def test_rejects_missing_token_before_calling_tools(self) -> None:
        result, gh_calls, git_calls, ref_exists = self.run_verifier(token=None)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TAP_PAT is missing", result.stderr)
        self.assertEqual(gh_calls, "")
        self.assertEqual(git_calls, "")
        self.assertFalse(ref_exists)

    def test_reports_git_auth_setup_failure_before_cloning(self) -> None:
        result, _, git_calls, ref_exists = self.run_verifier(auth_exit=1)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unable to configure Git authentication", result.stderr)
        self.assertEqual(git_calls, "")
        self.assertFalse(ref_exists)

    def test_reports_clone_failure(self) -> None:
        result, _, git_calls, ref_exists = self.run_verifier(clone_exit=1)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot clone", result.stderr)
        self.assertIn("clone --quiet --depth 1", git_calls)
        self.assertFalse(ref_exists)

    def test_rejects_token_that_can_clone_but_cannot_push(self) -> None:
        result, _, git_calls, ref_exists = self.run_verifier(create_exit=1)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HTTP 403", result.stderr)
        self.assertIn("TAP_PAT cannot push", result.stderr)
        self.assertIn("push --quiet origin HEAD:", git_calls)
        self.assertFalse(ref_exists)

    def test_rejects_unexpected_remote_sha_and_removes_probe(self) -> None:
        result, _, git_calls, ref_exists = self.run_verifier(
            remote_sha="0" * 40
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected ref SHA", result.stderr)
        self.assertIn("push --quiet origin :refs/heads/", git_calls)
        self.assertFalse(ref_exists)

    def test_fails_closed_when_probe_cannot_be_removed(self) -> None:
        result, _, git_calls, ref_exists = self.run_verifier(delete_exit=1)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not remove it", result.stderr)
        self.assertIn("push --quiet origin :refs/heads/", git_calls)
        self.assertTrue(ref_exists)


if __name__ == "__main__":
    unittest.main()
