"""The app and privileged helper inherit one version/build declaration."""

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

    def test_one_repository_wide_build_number(self) -> None:
        self.assertEqual(len(_scalar("CURRENT_PROJECT_VERSION")), 1,
                         "app and helper must inherit one build-number declaration")

    def test_one_repository_wide_marketing_version(self) -> None:
        self.assertEqual(len(_scalar("MARKETING_VERSION")), 1,
                         "app and helper must inherit one marketing-version declaration")

    def test_app_plist_references_shared_build_settings(self) -> None:
        self.assertEqual(_scalar("CFBundleVersion"), ["$(CURRENT_PROJECT_VERSION)"])
        self.assertEqual(_scalar("CFBundleShortVersionString"), ["$(MARKETING_VERSION)"])

    def test_versions_are_plausible(self) -> None:
        """Guards against the regex silently matching nothing useful."""
        build = _scalar("CURRENT_PROJECT_VERSION")[0]
        marketing = _scalar("MARKETING_VERSION")[0]
        self.assertTrue(build.isdigit(), f"build number should be an integer, got {build!r}")
        self.assertRegex(marketing, r"^\d+\.\d+(\.\d+)?$")


if __name__ == "__main__":
    unittest.main()
