import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "scripts" / "validate-release-notes.py"


class ReleaseNotesValidationTests(unittest.TestCase):
    def run_validator(
        self, content: str, version: str = "1.2.3"
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            notes = Path(directory) / "RELEASES.md"
            notes.write_text(content, encoding="utf-8")
            return subprocess.run(
                ["python3", str(VALIDATOR), str(notes), "--version", version],
                text=True,
                capture_output=True,
                check=False,
            )

    def test_accepts_single_latest_release_without_hidden_markup(self) -> None:
        result = self.run_validator("# Burrow 1.2.3\n\nUseful release notes.\n")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Release notes validated", result.stdout)

    def test_rejects_html_comments_that_sparkle_renders_as_text(self) -> None:
        result = self.run_validator(
            "<!-- contributor instruction -->\n\n# Burrow 1.2.3\n\nNotes.\n"
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HTML comments", result.stderr)

    def test_rejects_a_heading_that_does_not_match_the_release(self) -> None:
        result = self.run_validator("# Burrow 1.2.4\n\nNotes.\n")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("first line", result.stderr)

    def test_rejects_accumulated_top_level_release_sections(self) -> None:
        result = self.run_validator(
            "# Burrow 1.2.3\n\nCurrent.\n\n# Burrow 1.2.2\n\nOld.\n"
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exactly one top-level heading", result.stderr)

    def test_checked_in_release_notes_are_safe_for_sparkle(self) -> None:
        project = (ROOT / "macos" / "project.yml").read_text(encoding="utf-8")
        versions = re.findall(
            r'^\s+MARKETING_VERSION: "([0-9]+\.[0-9]+\.[0-9]+)"$',
            project,
            re.MULTILINE,
        )
        self.assertEqual(len(versions), 1)
        version = versions[0]
        result = subprocess.run(
            [
                "python3",
                str(VALIDATOR),
                str(ROOT / "RELEASES.md"),
                "--version",
                version,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
