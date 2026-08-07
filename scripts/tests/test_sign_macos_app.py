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
        helper: bool = True,
        helper_plist_overrides: dict[str, object] | None = None,
        helper_plist: bool = True,
    ) -> tuple[Path, Path]:
        app = root / "Burrow.app"
        executable = app / "Contents" / "MacOS" / "Burrow"
        executable.parent.mkdir(parents=True)
        # copy2 tries to preserve the system binary's immutable flags, which
        # an unprivileged process cannot apply to a temporary file on macOS.
        shutil.copyfile("/usr/bin/true", executable)
        executable.chmod(0o755)

        # The privileged helper and its launchd declaration. Present by
        # default because the signer treats them as mandatory: a release that
        # ships the helper half-wired is worse than one without it, so
        # "absent" has to be an error rather than a skip.
        if helper:
            helper_binary = app / "Contents" / "MacOS" / "BurrowHelper"
            shutil.copyfile("/usr/bin/true", helper_binary)
            helper_binary.chmod(0o755)

        if helper_plist:
            plist_path = (
                app / "Contents" / "Library" / "LaunchDaemons"
                / "dev.caezium.Burrow.privileged-helper.plist"
            )
            plist_path.parent.mkdir(parents=True, exist_ok=True)
            contents: dict[str, object] = {
                "Label": "dev.caezium.Burrow.privileged-helper",
                "BundleProgram": "Contents/MacOS/BurrowHelper",
                "MachServices": {"dev.caezium.Burrow.privileged-helper": True},
            }
            contents.update(helper_plist_overrides or {})
            with plist_path.open("wb") as handle:
                plistlib.dump(contents, handle)

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


class PrivilegedHelperGateTests(SignMacOSAppTests):
    """The signer's fail-closed checks on the root helper.

    Each case here is a way to ship a helper that launchd would either refuse
    to start or, worse, start as something other than the binary this pipeline
    verified. None of them is caught by `codesign --verify --deep`, which is
    why they are checked explicitly.
    """

    def test_missing_helper_binary_blocks_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, entitlements = self.make_app(root, helper=False)

            result = self.run_signer(app, entitlements)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("privileged helper missing", result.stderr)

    def test_missing_launchd_plist_blocks_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, entitlements = self.make_app(root, helper_plist=False)

            result = self.run_signer(app, entitlements)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("launchd plist missing", result.stderr)

    def test_wrong_label_blocks_release(self) -> None:
        # SMAppService and launchd both key off the label; a typo means a
        # daemon that silently never runs.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, entitlements = self.make_app(
                root, helper_plist_overrides={"Label": "dev.caezium.Burrow.helpr"}
            )

            result = self.run_signer(app, entitlements)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("launchd Label is", result.stderr)

    def test_missing_mach_service_blocks_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, entitlements = self.make_app(
                root, helper_plist_overrides={"MachServices": {"something.else": True}}
            )

            result = self.run_signer(app, entitlements)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not vend the dev.caezium.Burrow.privileged-helper Mach service", result.stderr)

    def test_bundle_program_pointing_elsewhere_blocks_release(self) -> None:
        """The sharpest one.

        BundleProgram is what launchd actually executes as root. If it names
        anything other than the executable the pipeline just signed and
        verified, the daemon running with full privileges is not the binary
        this release vouched for.
        """
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, entitlements = self.make_app(
                root, helper_plist_overrides={"BundleProgram": "Contents/MacOS/Burrow"}
            )

            result = self.run_signer(app, entitlements)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("BundleProgram is", result.stderr)

    def test_bundle_program_that_does_not_exist_blocks_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, entitlements = self.make_app(root, helper=False)
            # Restore only the plist so the failure is specifically the
            # dangling BundleProgram rather than the missing-binary check.
            result = self.run_signer(app, entitlements)

            self.assertNotEqual(result.returncode, 0)

    def test_wellformed_helper_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, entitlements = self.make_app(root, get_task_allow=False)

            result = self.run_signer(app, entitlements)

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("privileged helper verified", result.stdout)


if __name__ == "__main__":
    unittest.main()
