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
        read_exit: int = 0,
        write_exit: int = 0,
        write_sha: str = TAP_SHA,
    ) -> tuple[subprocess.CompletedProcess[str], str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            call_log = root / "gh-calls.txt"

            fake_gh = fake_bin / "gh"
            fake_gh.write_text(
                """#!/bin/bash
printf '%s\\n' "$*" >> "$GH_CALL_LOG"
if [[ "$*" == *"--method PATCH"* ]]; then
  [ "$GH_WRITE_EXIT" -eq 0 ] || { echo "HTTP 403" >&2; exit "$GH_WRITE_EXIT"; }
  printf '%s\\n' "$GH_WRITE_SHA"
  exit 0
fi
if [[ "$*" == *"git/ref/heads/main"* ]]; then
  [ "$GH_READ_EXIT" -eq 0 ] || { echo "HTTP 403" >&2; exit "$GH_READ_EXIT"; }
  printf '%s\\n' "$GH_READ_SHA"
  exit 0
fi
exit 99
""",
                encoding="utf-8",
            )
            fake_gh.chmod(0o755)

            env = os.environ.copy()
            env.pop("GH_TOKEN", None)
            env.pop("GITHUB_TOKEN", None)
            env.update(
                {
                    "GH_CALL_LOG": str(call_log),
                    "GH_READ_EXIT": str(read_exit),
                    "GH_READ_SHA": TAP_SHA,
                    "GH_WRITE_EXIT": str(write_exit),
                    "GH_WRITE_SHA": write_sha,
                    "PATH": f"{fake_bin}{os.pathsep}{env['PATH']}",
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
            calls = (
                call_log.read_text(encoding="utf-8")
                if call_log.exists()
                else ""
            )
            return result, calls

    def test_accepts_token_with_contents_write_access(self) -> None:
        result, calls = self.run_verifier()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("write access verified", result.stdout)
        self.assertIn("git/ref/heads/main --jq .object.sha", calls)
        self.assertIn("--method PATCH", calls)
        self.assertIn("git/refs/heads/main", calls)
        self.assertIn(f"-f sha={TAP_SHA}", calls)
        self.assertIn("-F force=false", calls)

    def test_rejects_missing_token_before_calling_github(self) -> None:
        result, calls = self.run_verifier(token=None)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TAP_PAT is missing", result.stderr)
        self.assertEqual(calls, "")

    def test_rejects_token_that_can_read_but_cannot_write(self) -> None:
        result, calls = self.run_verifier(write_exit=1)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HTTP 403", result.stderr)
        self.assertIn(
            "TAP_PAT cannot push to caezium/homebrew-tap",
            result.stderr,
        )
        self.assertIn("--method PATCH", calls)

    def test_reports_reference_read_failure(self) -> None:
        result, calls = self.run_verifier(read_exit=1)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TAP_PAT cannot read caezium/homebrew-tap", result.stderr)
        self.assertNotIn("--method PATCH", calls)

    def test_rejects_unexpected_write_response(self) -> None:
        result, _ = self.run_verifier(write_sha="0" * 40)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected ref SHA", result.stderr)


if __name__ == "__main__":
    unittest.main()
