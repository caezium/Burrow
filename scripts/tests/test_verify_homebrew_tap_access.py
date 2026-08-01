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
        gh_body: str,
        *,
        token: str | None = "test-token",
    ) -> tuple[subprocess.CompletedProcess[str], str | None]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            call_log = root / "gh-call.txt"
            fake_gh = fake_bin / "gh"
            fake_gh.write_text(
                f'#!/bin/bash\nprintf \'%s\\n\' "$*" > "$GH_CALL_LOG"\n{gh_body}\n',
                encoding="utf-8",
            )
            fake_gh.chmod(0o755)
            env = os.environ.copy()
            env.pop("GH_TOKEN", None)
            env.pop("GITHUB_TOKEN", None)
            env.update(
                {
                    "GH_CALL_LOG": str(call_log),
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
            call = (
                call_log.read_text(encoding="utf-8").strip()
                if call_log.exists()
                else None
            )
            return result, call

    def test_accepts_token_with_push_access(self) -> None:
        result, call = self.run_verifier("printf 'true\\n'")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Homebrew tap write access verified", result.stdout)
        self.assertEqual(
            call,
            "api repos/caezium/homebrew-tap --jq .permissions.push",
        )

    def test_rejects_missing_token_before_calling_github(self) -> None:
        result, call = self.run_verifier("printf 'true\\n'", token=None)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TAP_PAT is missing", result.stderr)
        self.assertIsNone(call)

    def test_rejects_token_without_push_access(self) -> None:
        result, _ = self.run_verifier("printf 'false\\n'")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "TAP_PAT cannot push to caezium/homebrew-tap",
            result.stderr,
        )

    def test_reports_github_api_failure(self) -> None:
        result, _ = self.run_verifier("echo 'HTTP 403' >&2\nexit 1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "Unable to verify TAP_PAT access to caezium/homebrew-tap",
            result.stderr,
        )


if __name__ == "__main__":
    unittest.main()
