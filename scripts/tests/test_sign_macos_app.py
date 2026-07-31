import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SIGNER = ROOT / "scripts" / "sign-macos-app.sh"


class SignMacOSAppTests(unittest.TestCase):
    def make_app(
        self,
        root: Path,
        *,
        get_task_allow: bool | str | None = None,
    ) -> tuple[Path, Path]:
        app = root / "Burrow.app"
        executable = app / "Contents" / "MacOS" / "Burrow"
        executable.parent.mkdir(parents=True)
        # copy2 tries to preserve the system binary's immutable flags, which
        # an unprivileged process cannot apply to a temporary file on macOS.
        shutil.copyfile("/usr/bin/true", executable)
        executable.chmod(0o755)

        with (app / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleExecutable": "Burrow",
                    "CFBundleIdentifier": "dev.caezium.Burrow.SigningTest",
                    "CFBundlePackageType": "APPL",
                },
                handle,
            )

        entitlements: dict[str, bool | str] = {
            "com.apple.security.files.user-selected.read-only": True,
        }
        if get_task_allow is not None:
            entitlements["com.apple.security.get-task-allow"] = get_task_allow
        entitlements_path = root / "Burrow.entitlements"
        with entitlements_path.open("wb") as handle:
            plistlib.dump(entitlements, handle)

        return app, entitlements_path

    def run_signer(
        self,
        app: Path,
        entitlements: Path,
        *,
        env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(SIGNER), str(app), "-", "adhoc", str(entitlements)],
            capture_output=True,
            text=True,
            env=env,
        )

    def test_missing_get_task_allow_ignores_plutil_stdout_diagnostic(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, entitlements = self.make_app(root)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_plutil = fake_bin / "plutil"
            fake_plutil.write_text(
                """#!/bin/bash
if [ "$1" = "-extract" ] && [ "$2" = 'com\\.apple\\.security\\.get-task-allow' ]; then
  echo '<stdin>: Could not extract value, error: No value at that key path'
  exit 1
fi
exec /usr/bin/plutil "$@"
""",
                encoding="utf-8",
            )
            fake_plutil.chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"

            result = self.run_signer(app, entitlements, env=env)

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn("Could not extract value", result.stdout + result.stderr)

    def test_get_task_allow_true_still_blocks_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, entitlements = self.make_app(root, get_task_allow=True)

            result = self.run_signer(app, entitlements)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "release app contains invalid com.apple.security.get-task-allow=true",
                result.stderr,
            )

    def test_get_task_allow_false_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, entitlements = self.make_app(root, get_task_allow=False)

            result = self.run_signer(app, entitlements)

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_non_boolean_get_task_allow_blocks_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, entitlements = self.make_app(root, get_task_allow="")

            result = self.run_signer(app, entitlements)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "could not extract plist key "
                "'com\\.apple\\.security\\.get-task-allow' as bool",
                result.stderr,
            )

    def test_present_get_task_allow_extraction_failure_blocks_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, entitlements = self.make_app(root, get_task_allow=False)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_plutil = fake_bin / "plutil"
            fake_plutil.write_text(
                """#!/bin/bash
if [ "$1" = "-extract" ] && [ "$2" = 'com\\.apple\\.security\\.get-task-allow' ]; then
  echo '<stdin>: simulated extraction failure'
  exit 1
fi
exec /usr/bin/plutil "$@"
""",
                encoding="utf-8",
            )
            fake_plutil.chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"

            result = self.run_signer(app, entitlements, env=env)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("could not extract plist key", result.stderr)


if __name__ == "__main__":
    unittest.main()
