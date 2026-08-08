import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
UPDATER = ROOT / "scripts" / "update-homebrew-tap.py"
OLD_SHA = "b" * 64
NEW_SHA = "a" * 64
CURRENT_README = "Burrow's current cask is Developer ID signed and notarized.\n"
OLD_README_NOTE = """- These are currently self-signed pre-1.0 builds (not yet notarized), so the
  casks clear the Gatekeeper quarantine flag automatically on install. If macOS
  still blocks an app, right-click it and choose **Open**.
"""
CURRENT_CASK = f'''cask "burrow" do
  version "0.11.0"
  sha256 "{OLD_SHA}"
  homepage "https://github.com/caezium/Burrow"

  auto_updates true

  app "Burrow.app"
end
'''
CASK_WITHOUT_AUTO_UPDATES = f'''cask "burrow" do
  version "0.11.0"
  sha256 "{OLD_SHA}"

  url "https://github.com/caezium/Burrow/releases/download/v#{{version}}/Burrow-#{{version}}.zip"
  name "Burrow"
  desc "Free, open-source native GUI for the Mole CLI"
  homepage "https://github.com/caezium/Burrow"

  depends_on macos: :sonoma
  app "Burrow.app"
end
'''
LEGACY_CASK_BLOCK = """  # Pre-1.0 builds aren't notarized yet, so clear the quarantine flag to
  # avoid a Gatekeeper block on first launch. Remove this once the app
  # ships signed + notarized.
  postflight do
    system_command "/usr/bin/xattr", args: ["-cr", "#{appdir}/Burrow.app"], sudo: false
  end

  caveats <<~EOS
    Burrow is an unsigned pre-1.0 build. If macOS still blocks it, right-click
    the app and choose Open, or run:  xattr -cr "#{appdir}/Burrow.app"
  EOS

"""


class UpdateHomebrewTapTests(unittest.TestCase):
    def make_tap(
        self,
        root: Path,
        cask: str = CURRENT_CASK,
        readme: str = CURRENT_README,
    ) -> Path:
        tap = root / "tap"
        casks = tap / "Casks"
        casks.mkdir(parents=True)
        (casks / "burrow.rb").write_text(cask, encoding="utf-8")
        (tap / "README.md").write_text(readme, encoding="utf-8")
        return tap

    def run_updater(
        self,
        tap: Path,
        *,
        version: str = "0.12.0",
        sha256: str = NEW_SHA,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(UPDATER),
                str(tap),
                "--version",
                version,
                "--sha256",
                sha256,
            ],
            capture_output=True,
            text=True,
        )

    def assert_rejected_without_changes(
        self,
        error: str,
        *,
        cask: str = CURRENT_CASK,
        readme: str = CURRENT_README,
        version: str = "0.12.0",
        sha256: str = NEW_SHA,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tap = self.make_tap(Path(directory), cask, readme)

            result = self.run_updater(tap, version=version, sha256=sha256)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
            self.assertEqual(
                (tap / "Casks" / "burrow.rb").read_text(encoding="utf-8"), cask
            )
            self.assertEqual((tap / "README.md").read_text(encoding="utf-8"), readme)

    def test_updates_release_and_inserts_auto_updates_after_homepage(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tap = self.make_tap(Path(directory), CASK_WITHOUT_AUTO_UPDATES)

            result = self.run_updater(tap)

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            cask = (tap / "Casks" / "burrow.rb").read_text(encoding="utf-8")
            self.assertIn('version "0.12.0"', cask)
            self.assertIn(f'sha256 "{NEW_SHA}"', cask)
            self.assertIn(
                'homepage "https://github.com/caezium/Burrow"\n\n'
                "  auto_updates true\n\n"
                "  depends_on macos: :sonoma",
                cask,
            )
            self.assertEqual(cask.count("auto_updates true"), 1)

    def test_rejects_legacy_quarantine_bypass(self) -> None:
        legacy_cask = CURRENT_CASK.replace("  auto_updates true\n\n", LEGACY_CASK_BLOCK)
        self.assert_rejected_without_changes(
            "cask security block has drifted", cask=legacy_cask
        )

    def test_moves_existing_auto_updates_to_the_homepage_stanza(self) -> None:
        misplaced = CURRENT_CASK.replace(
            f'  sha256 "{OLD_SHA}"\n',
            f'  auto_updates true\n  sha256 "{OLD_SHA}"\n',
        ).replace("\n  auto_updates true\n\n  app", "\n  app")
        with tempfile.TemporaryDirectory() as directory:
            tap = self.make_tap(Path(directory), misplaced)

            result = self.run_updater(tap)

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            cask = (tap / "Casks" / "burrow.rb").read_text(encoding="utf-8")
            self.assertNotIn('version "0.12.0"\n  auto_updates true', cask)
            self.assertIn(
                'homepage "https://github.com/caezium/Burrow"\n\n'
                "  auto_updates true\n\n"
                '  app "Burrow.app"',
                cask,
            )

    def test_rejects_invalid_sha(self) -> None:
        self.assert_rejected_without_changes(
            "sha256 must be 64 lowercase hexadecimal characters",
            sha256="not-a-sha",
        )

    def test_rejects_invalid_version(self) -> None:
        self.assert_rejected_without_changes(
            "version must be a semantic release version",
            version='0.12.0"\n  postflight do',
        )

    def test_rejects_ambiguous_cask_fields(self) -> None:
        ambiguous = CURRENT_CASK.replace(
            '  version "0.11.0"',
            '  version "0.11.0"\n  version "unexpected-second-version"',
        )
        self.assert_rejected_without_changes(
            "expected exactly one version line", cask=ambiguous
        )

    def test_readme_drift_fails_before_writing_the_cask(self) -> None:
        self.assert_rejected_without_changes(
            "tap README security note has drifted", readme="unknown security copy\n"
        )

    def test_keeps_an_already_correct_auto_updates_stanza_stable(self) -> None:
        cask_with_comment = CURRENT_CASK.replace(
            '  app "Burrow.app"',
            '  # Keep this comment directly below the stanza.\n  app "Burrow.app"',
        )
        with tempfile.TemporaryDirectory() as directory:
            tap = self.make_tap(Path(directory), cask_with_comment)

            result = self.run_updater(tap)

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            cask = (tap / "Casks" / "burrow.rb").read_text(encoding="utf-8")
            self.assertIn(
                "  auto_updates true\n\n"
                "  # Keep this comment directly below the stanza.",
                cask,
            )
            self.assertNotIn("  auto_updates true\n\n\n", cask)

    def test_rejects_remaining_legacy_cask_security_copy(self) -> None:
        stale = CURRENT_CASK.replace(
            "  auto_updates true\n\n",
            LEGACY_CASK_BLOCK
            + "  # Burrow is an unsigned pre-1.0 build (stale duplicate).\n",
        )
        self.assert_rejected_without_changes(
            "cask security block has drifted", cask=stale
        )

    def test_rejects_stale_readme_security_copy(self) -> None:
        self.assert_rejected_without_changes(
            "tap README security note has drifted",
            readme=OLD_README_NOTE,
        )


if __name__ == "__main__":
    unittest.main()
