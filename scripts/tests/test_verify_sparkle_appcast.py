import base64
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "scripts" / "verify-sparkle-appcast.py"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


class VerifySparkleAppcastTests(unittest.TestCase):
    def run_validator(
        self,
        appcast: Path,
        archive: Path,
        *,
        url: str | None = None,
        signature_output: Path | None = None,
        release_notes: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        expected_url = url or (
            "https://github.com/caezium/Burrow/releases/download/"
            f"v0.11.0/{archive.name}"
        )
        command = [
            sys.executable,
            str(VALIDATOR),
            str(appcast),
            "--archive",
            str(archive),
            "--version",
            "0.11.0",
            "--build",
            "21",
            "--url",
            expected_url,
        ]
        if signature_output is not None:
            command.extend(["--signature-output", str(signature_output)])
        if release_notes is not None:
            command.extend(["--release-notes", str(release_notes)])
        return subprocess.run(
            command,
            capture_output=True,
            text=True,
        )

    def test_accepts_exact_signed_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "Burrow-0.11.0.zip"
            archive.write_bytes(b"not-a-real-zip")
            signature = base64.b64encode(bytes(64)).decode("ascii")
            content = (
                '<?xml version="1.0" encoding="utf-8"?>\n'
                f'<rss xmlns:sparkle="{SPARKLE_NS}" version="2.0">\n'
                "<channel><item>\n"
                "<sparkle:version>21</sparkle:version>\n"
                "<sparkle:shortVersionString>0.11.0</sparkle:shortVersionString>\n"
                f'<enclosure url="https://github.com/caezium/Burrow/releases/download/v0.11.0/{archive.name}" '
                f'length="{archive.stat().st_size}" type="application/octet-stream" '
                f'sparkle:edSignature="{signature}" />\n'
                "</item></channel></rss>\n"
            )
            appcast = root / "appcast.xml"
            signature_output = root / "archive-signature.txt"
            appcast.write_text(
                content
                + "<!-- sparkle-signatures:\n"
                + f"edSignature: {signature}\n"
                + f"length: {len(content.encode('utf-8'))}\n"
                + "-->\n",
                encoding="utf-8",
            )

            result = self.run_validator(
                appcast, archive, signature_output=signature_output
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(signature_output.read_text(encoding="ascii"), signature)

    def test_rejects_unsigned_archive_enclosure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "Burrow-0.11.0.zip"
            archive.write_bytes(b"archive")
            content = (
                '<?xml version="1.0"?>\n'
                f'<rss xmlns:sparkle="{SPARKLE_NS}"><channel><item>'
                '<sparkle:version>21</sparkle:version>'
                '<sparkle:shortVersionString>0.11.0</sparkle:shortVersionString>'
                f'<enclosure url="https://github.com/caezium/Burrow/releases/download/v0.11.0/{archive.name}" '
                f'length="{archive.stat().st_size}" />'
                "</item></channel></rss>\n"
            )
            signature = base64.b64encode(bytes(64)).decode("ascii")
            appcast = root / "appcast.xml"
            appcast.write_text(
                content
                + "<!-- sparkle-signatures:\n"
                + f"edSignature: {signature}\nlength: {len(content.encode())}\n-->\n",
                encoding="utf-8",
            )

            result = self.run_validator(appcast, archive)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing sparkle:edSignature", result.stderr)

    def test_rejects_tampered_signed_feed_length(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "Burrow-0.11.0.zip"
            archive.write_bytes(b"archive")
            signature = base64.b64encode(bytes(64)).decode("ascii")
            content = (
                f'<rss xmlns:sparkle="{SPARKLE_NS}"><channel><item>'
                '<sparkle:version>21</sparkle:version>'
                '<sparkle:shortVersionString>0.11.0</sparkle:shortVersionString>'
                f'<enclosure url="https://github.com/caezium/Burrow/releases/download/v0.11.0/{archive.name}" '
                f'length="{archive.stat().st_size}" sparkle:edSignature="{signature}" />'
                "</item></channel></rss>\n"
            )
            appcast = root / "appcast.xml"
            appcast.write_text(
                content
                + "<!-- sparkle-signatures:\n"
                + f"edSignature: {signature}\nlength: {len(content.encode()) + 1}\n-->\n",
                encoding="utf-8",
            )

            result = self.run_validator(appcast, archive)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("signed-feed length", result.stderr)

    def test_requires_embedded_markdown_to_match_release_notes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "Burrow-0.11.0.zip"
            archive.write_bytes(b"archive")
            notes = root / "RELEASES.md"
            notes.write_text("# Burrow 0.11.0\n\nClean notes.\n", encoding="utf-8")
            signature = base64.b64encode(bytes(64)).decode("ascii")
            content = (
                f'<rss xmlns:sparkle="{SPARKLE_NS}"><channel><item>'
                '<sparkle:version>21</sparkle:version>'
                '<sparkle:shortVersionString>0.11.0</sparkle:shortVersionString>'
                '<description sparkle:format="markdown"><![CDATA['
                '<!-- leaked -->\n\n# Burrow 0.11.0\n\nClean notes.\n'
                ']]></description>'
                f'<enclosure url="https://github.com/caezium/Burrow/releases/download/v0.11.0/{archive.name}" '
                f'length="{archive.stat().st_size}" sparkle:edSignature="{signature}" />'
                "</item></channel></rss>\n"
            )
            appcast = root / "appcast.xml"
            appcast.write_text(
                content
                + "<!-- sparkle-signatures:\n"
                + f"edSignature: {signature}\nlength: {len(content.encode())}\n-->\n",
                encoding="utf-8",
            )

            result = self.run_validator(appcast, archive, release_notes=notes)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("do not exactly match", result.stderr)


if __name__ == "__main__":
    unittest.main()
