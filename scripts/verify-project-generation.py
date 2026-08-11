#!/usr/bin/env python3
"""Prove XcodeGen output is deterministic and tracked metadata is current."""

from __future__ import annotations

import argparse
import hashlib
import plistlib
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MACOS = ROOT / "macos"
GENERATED = (
    MACOS / "Resources" / "Info.plist",
    MACOS / "Tests" / "Info.plist",
    MACOS / "Burrow.xcodeproj" / "project.pbxproj",
    MACOS
    / "Burrow.xcodeproj"
    / "xcshareddata"
    / "xcschemes"
    / "Burrow.xcscheme",
)
TRACKED_METADATA = (
    "macos/Resources/Info.plist",
    "macos/Tests/Info.plist",
)


def digest_generated_files() -> dict[str, str]:
    missing = [str(path.relative_to(ROOT)) for path in GENERATED if not path.is_file()]
    if missing:
        raise RuntimeError(f"XcodeGen did not produce: {', '.join(missing)}")
    return {
        str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in GENERATED
    }


def generate(xcodegen: Path) -> None:
    subprocess.run([str(xcodegen), "generate"], cwd=MACOS, check=True)


def verify_version_contract() -> None:
    project = (MACOS / "project.yml").read_text(encoding="utf-8")
    marketing_versions = re.findall(
        r'^\s+MARKETING_VERSION: "([0-9]+\.[0-9]+\.[0-9]+)"$', project, re.MULTILINE
    )
    build_numbers = re.findall(
        r'^\s+CURRENT_PROJECT_VERSION: "([1-9][0-9]*)"$', project, re.MULTILINE
    )
    if len(marketing_versions) != 1:
        raise RuntimeError("project.yml must declare the marketing version exactly once")
    if len(build_numbers) != 1:
        raise RuntimeError("project.yml must declare the build number exactly once")

    with (MACOS / "Resources" / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    expected = {
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    }
    for key, value in expected.items():
        if info.get(key) != value:
            raise RuntimeError(f"generated Info.plist has drifted: {key}={info.get(key)!r}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--xcodegen", required=True, type=Path)
    parser.add_argument(
        "--check-git",
        action="store_true",
        help="also fail when generation changes tracked plist metadata",
    )
    args = parser.parse_args()

    if not args.xcodegen.is_file():
        parser.error(f"xcodegen not found: {args.xcodegen}")

    try:
        generate(args.xcodegen)
        first = digest_generated_files()
        generate(args.xcodegen)
        second = digest_generated_files()
        if first != second:
            changed = sorted(path for path in first if first[path] != second[path])
            raise RuntimeError(
                "XcodeGen output changed across identical runs: " + ", ".join(changed)
            )
        verify_version_contract()
        if args.check_git:
            subprocess.run(
                ["git", "diff", "--exit-code", "--", *TRACKED_METADATA],
                cwd=ROOT,
                check=True,
            )
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print("XcodeGen output is deterministic and version metadata is aligned.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
