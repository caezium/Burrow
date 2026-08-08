"""The app and the privileged helper must ship the same version.

The helper reports its own build over XPC and the client refuses to use a
helper whose build doesn't match the app's — that check is deliberate, because
a registered daemon outlives the app that installed it and a stale root helper
is exactly the drift worth refusing.

The cost of that design is a coupling: `macos/project.yml` spells the version
twice, once for the app target and once for the helper target, and Xcode has
no way to derive one from the other. Bump the app for a release and forget the
helper and nothing fails loudly — the helper simply stops being used, every
user silently falls back to the password-only prompt, and the feature dies
quietly.

That failure is invisible in the build, invisible in the tests, and invisible
in the release artifact. So it gets caught here instead.
"""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "macos" / "project.yml"


def _scalar(key: str) -> list[str]:
    """Every value assigned to `key` in project.yml, in file order."""
    text = PROJECT.read_text(encoding="utf-8")
    return re.findall(rf'^\s*{re.escape(key)}:\s*"([^"]+)"\s*$', text, re.MULTILINE)


class HelperVersionSyncTests(unittest.TestCase):
    def test_project_file_exists(self) -> None:
        self.assertTrue(PROJECT.is_file(), f"missing {PROJECT}")

    def test_build_number_matches_between_app_and_helper(self) -> None:
        app = _scalar("CFBundleVersion")
        helper = _scalar("CURRENT_PROJECT_VERSION")

        self.assertEqual(len(app), 1, "expected exactly one app CFBundleVersion")
        self.assertEqual(len(helper), 1, "expected exactly one helper CURRENT_PROJECT_VERSION")
        self.assertEqual(
            app[0],
            helper[0],
            "app CFBundleVersion and helper CURRENT_PROJECT_VERSION must match, "
            "or HelperVersionSkew refuses the helper at runtime and every user "
            "silently falls back to the password prompt",
        )

    def test_marketing_version_matches_between_app_and_helper(self) -> None:
        app = _scalar("CFBundleShortVersionString")
        helper = _scalar("MARKETING_VERSION")

        self.assertEqual(len(app), 1, "expected exactly one app CFBundleShortVersionString")
        self.assertEqual(len(helper), 1, "expected exactly one helper MARKETING_VERSION")
        self.assertEqual(
            app[0],
            helper[0],
            "app and helper marketing versions must match",
        )

    def test_versions_are_plausible(self) -> None:
        """Guards against the regex silently matching nothing useful."""
        build = _scalar("CFBundleVersion")[0]
        marketing = _scalar("CFBundleShortVersionString")[0]
        self.assertTrue(build.isdigit(), f"build number should be an integer, got {build!r}")
        self.assertRegex(marketing, r"^\d+\.\d+(\.\d+)?$")


if __name__ == "__main__":
    unittest.main()
