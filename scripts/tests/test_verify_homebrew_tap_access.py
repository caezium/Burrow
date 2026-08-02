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
        create_exit: int = 0,
        create_ref: str = "",
        delete_exit: int = 0,
        read_exit: int = 0,
    ) -> tuple[subprocess.CompletedProcess[str], str, bool]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            call_log = root / "gh-calls.txt"
            ref_state = root / "probe-ref-exists"

            fake_gh = fake_bin / "gh"
            fake_gh.write_text(
                """#!/bin/bash
printf '%s\\n' "$*" >> "$GH_CALL_LOG"
if [[ "$*" == *"--method POST"* ]]; then
  [ "$GH_CREATE_EXIT" -eq 0 ] || { echo "HTTP 403" >&2; exit "$GH_CREATE_EXIT"; }
  requested_ref=""
  for argument in "$@"; do
    case "$argument" in
      ref=*) requested_ref="${argument#ref=}" ;;
    esac
  done
  touch "$GH_REF_STATE"
  printf '%s\\n' "${GH_CREATE_REF:-$requested_ref}"
  exit 0
fi
if [[ "$*" == *"--method DELETE"* ]]; then
  [ "$GH_DELETE_EXIT" -eq 0 ] || { echo "HTTP 500" >&2; exit "$GH_DELETE_EXIT"; }
  rm -f "$GH_REF_STATE"
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
                    "GH_CREATE_EXIT": str(create_exit),
                    "GH_CREATE_REF": create_ref,
                    "GH_DELETE_EXIT": str(delete_exit),
                    "GH_READ_EXIT": str(read_exit),
                    "GH_READ_SHA": TAP_SHA,
                    "GH_REF_STATE": str(ref_state),
                    "GITHUB_RUN_ATTEMPT": "2",
                    "GITHUB_RUN_ID": "123",
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
            return result, calls, ref_state.exists()

    def test_accepts_token_with_contents_write_access(self) -> None:
        result, calls, ref_exists = self.run_verifier()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("write access verified", result.stdout)
        self.assertIn("git/ref/heads/main --jq .object.sha", calls)
        self.assertIn("--method POST", calls)
        self.assertIn("git/refs", calls)
        self.assertIn(
            "-f ref=refs/heads/burrow-release-access-probe-123-2",
            calls,
        )
        self.assertIn(f"-f sha={TAP_SHA}", calls)
        self.assertIn("--method DELETE", calls)
        self.assertIn(
            "git/refs/heads/burrow-release-access-probe-123-2",
            calls,
        )
        self.assertFalse(ref_exists)

    def test_rejects_missing_token_before_calling_github(self) -> None:
        result, calls, ref_exists = self.run_verifier(token=None)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TAP_PAT is missing", result.stderr)
        self.assertEqual(calls, "")
        self.assertFalse(ref_exists)

    def test_rejects_token_that_can_read_but_cannot_write(self) -> None:
        result, calls, ref_exists = self.run_verifier(create_exit=1)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HTTP 403", result.stderr)
        self.assertIn(
            "TAP_PAT cannot create a temporary ref",
            result.stderr,
        )
        self.assertIn("--method POST", calls)
        self.assertNotIn("--method DELETE", calls)
        self.assertFalse(ref_exists)

    def test_reports_reference_read_failure(self) -> None:
        result, calls, ref_exists = self.run_verifier(read_exit=1)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TAP_PAT cannot read caezium/homebrew-tap", result.stderr)
        self.assertNotIn("--method POST", calls)
        self.assertFalse(ref_exists)

    def test_rejects_unexpected_create_response_and_removes_probe(self) -> None:
        result, calls, ref_exists = self.run_verifier(
            create_ref="refs/heads/unexpected"
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("created an unexpected ref", result.stderr)
        self.assertIn("--method DELETE", calls)
        self.assertFalse(ref_exists)

    def test_fails_closed_when_probe_cannot_be_removed(self) -> None:
        result, calls, ref_exists = self.run_verifier(delete_exit=1)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not remove it", result.stderr)
        self.assertIn("--method DELETE", calls)
        self.assertTrue(ref_exists)


if __name__ == "__main__":
    unittest.main()
