import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BUNDLER = ROOT / "macos/scripts/bundle-burrow.sh"


class BundleEngineLicenseTests(unittest.TestCase):
    def make_fixture(self, root: Path) -> tuple[Path, Path, dict[str, str]]:
        source = root / "engine source"
        resources = root / "Burrow.app/Contents/Resources"
        files = {
            "LICENSE.md": "Fixture engine license\n",
            "THIRD-PARTY-NOTICES.md": "[Mole](LICENSES/Mole-MIT.txt)\n",
            "LICENSES/Mole-MIT.txt": "Fixture Mole notice\n",
            "LICENSES/Stats-MIT.txt": "Fixture Stats notice\n",
            "LICENSES/fclones-MIT.txt": "Fixture fclones notice\n",
            "LICENSES/cargo/example-1.2.3/LICENSE-MIT": "Fixture dependency notice\n",
            "LICENSES/cargo/example-1.2.3/NOTICE": "Fixture nested notice\n",
            "Cargo.toml": "[package]\nname = 'fixture'\n",
            "src/main.rs": "// Source must not be distributed by the bundler.\n",
            "keys/private.p8": "FAKE KEY: fixture only\n",
            ".env": "FAKE_SECRET=fixture\n",
        }
        inventory = [{"name": "example", "version": "1.2.3", "texts": [
            {"file": "LICENSES/cargo/example-1.2.3/LICENSE-MIT"},
            {"file": "LICENSES/cargo/example-1.2.3/NOTICE"},
        ]}]
        files["LICENSES/cargo-packages.json"] = json.dumps(inventory)
        for filename, contents in files.items():
            path = source / filename
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
        resources.mkdir(parents=True)
        fake_bin = root / "bin"
        fake_bin.mkdir()
        commands = {
            "cargo": """#!/bin/bash
set -eu
printf 'cargo %s\\n' "$*" >> "$BURROW_BUNDLE_CALLS"
slice="${!#}"
mkdir -p "target/$slice/release" target/release
printf 'fixture %s\\n' "$slice" > "target/$slice/release/burrow-engine"
""",
            "lipo": """#!/bin/bash
set -eu
printf 'lipo %s\\n' "$*" >> "$BURROW_BUNDLE_CALLS"
if [ "$1" = '-create' ]; then
  cat "$4" "$5" > "$3"
elif [ "$1" = '-archs' ]; then
  echo 'arm64 x86_64'
else
  exit 99
fi
""",
            "codesign": """#!/bin/bash
printf 'codesign %s\\n' "$*" >> "$BURROW_BUNDLE_CALLS"
exit 0
""",
            "rustup": """#!/bin/bash
printf 'rustup %s\\n' "$*" >> "$BURROW_BUNDLE_CALLS"
exit 0
""",
        }
        for name, body in commands.items():
            path = fake_bin / name
            path.write_text(body)
            path.chmod(0o755)
        env = os.environ.copy()
        env.update(
            PATH=str(fake_bin) + os.pathsep + env["PATH"],
            BURROW_BUNDLE_CALLS=str(root / "commands.log"),
            EXPANDED_CODE_SIGN_IDENTITY="fixture-signing-identity",
        )
        return source, resources, env

    def bundle(self, source: Path, resources: Path, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["bash", str(BUNDLER), str(source), str(resources)], env=env,
                              text=True, capture_output=True, timeout=10)

    def test_packages_complete_notice_tree_without_source_or_keys(self) -> None:
        with tempfile.TemporaryDirectory(prefix="burrow licenses ") as directory:
            source, resources, env = self.make_fixture(Path(directory))
            notices = resources / "licenses/burrow-engine"
            notices.mkdir(parents=True)
            (notices / "obsolete.txt").write_text("stale payload")
            result = self.bundle(source, resources, env)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            expected = {"LICENSE.md", "THIRD-PARTY-NOTICES.md"} | {
                path.relative_to(source).as_posix() for path in (source / "LICENSES").rglob("*") if path.is_file()
            }
            actual = {path.relative_to(notices).as_posix() for path in notices.rglob("*") if path.is_file()}
            self.assertEqual(actual, expected)
            for filename in expected:
                self.assertEqual((notices / filename).read_bytes(), (source / filename).read_bytes())
            packaged = {path.relative_to(resources).as_posix() for path in resources.rglob("*") if path.is_file()}
            self.assertEqual(packaged, {"burrow"} | {"licenses/burrow-engine/" + name for name in expected})
            calls = Path(env["BURROW_BUNDLE_CALLS"]).read_text()
            self.assertIn("cargo build --release --bin burrow-engine --target aarch64-apple-darwin", calls)
            self.assertIn("cargo build --release --bin burrow-engine --target x86_64-apple-darwin", calls)
            self.assertIn("codesign --force --sign fixture-signing-identity", calls)

    def test_missing_notices_fail_before_build_or_binary_replacement(self) -> None:
        missing_paths = ("LICENSE.md", "THIRD-PARTY-NOTICES.md", "LICENSES", "LICENSES/Mole-MIT.txt",
                         "LICENSES/Stats-MIT.txt", "LICENSES/fclones-MIT.txt", "LICENSES/cargo-packages.json",
                         "LICENSES/cargo/example-1.2.3/NOTICE")
        for missing in missing_paths:
            with self.subTest(missing=missing), tempfile.TemporaryDirectory(prefix="burrow licenses ") as directory:
                source, resources, env = self.make_fixture(Path(directory))
                path = source / missing
                if path.is_dir():
                    shutil.rmtree(path)
                else:
                    path.unlink()
                binary = resources / "burrow"
                binary.write_text("previous engine")
                result = self.bundle(source, resources, env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("license", result.stderr)
                self.assertEqual(binary.read_text(), "previous engine")
                self.assertFalse(Path(env["BURROW_BUNDLE_CALLS"]).exists(), "A missing notice reached a build/signing tool")


if __name__ == "__main__":
    unittest.main()
