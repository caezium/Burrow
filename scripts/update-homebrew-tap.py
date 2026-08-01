#!/usr/bin/env python3
"""Update Burrow's external Homebrew tap after a verified release."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


class UpdateError(Exception):
    pass


def replace_one(text: str, pattern: str, replacement: str, label: str) -> str:
    count = len(re.findall(pattern, text, flags=re.MULTILINE))
    if count != 1:
        raise UpdateError(
            f"expected exactly one {label} line in the Burrow cask, found {count}"
        )
    return re.sub(pattern, replacement, text, count=1, flags=re.MULTILINE)


def update_cask(text: str, version: str, sha256: str) -> str:
    text = replace_one(
        text,
        r'^  version "[^"]+"$',
        f'  version "{version}"',
        "version",
    )
    text = replace_one(
        text,
        r'^  sha256 "[^"]+"$',
        f'  sha256 "{sha256}"',
        "sha256",
    )

    auto_updates_count = len(
        re.findall(r"^  auto_updates true$", text, flags=re.MULTILINE)
    )
    if auto_updates_count > 1:
        raise UpdateError("Burrow cask must contain exactly one auto_updates true line")
    if auto_updates_count == 1:
        text = re.sub(
            r"^  auto_updates true$(?:\n\n?)?",
            "",
            text,
            count=1,
            flags=re.MULTILINE,
        )
    text = replace_one(
        text,
        r'^(  homepage "[^"]+"\n)',
        r"\1\n  auto_updates true\n",
        "homepage",
    )

    if re.search(r"xattr.*-cr|Burrow is an unsigned pre-1\.0 build", text):
        raise UpdateError(
            "Burrow cask security block has drifted; remove it deliberately"
        )
    return text


def validate_readme(text: str) -> None:
    has_current_note = (
        "Burrow's current cask is Developer ID signed and notarized" in text
    )
    has_stale_note = "These are currently self-signed pre-1.0 builds" in text
    if not has_current_note or has_stale_note:
        raise UpdateError(
            "tap README security note has drifted; update it deliberately"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("tap", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--sha256", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    cask_path = args.tap / "Casks" / "burrow.rb"
    readme_path = args.tap / "README.md"
    try:
        if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.version) is None:
            raise UpdateError(
                "version must be a semantic release version (for example, 0.12.0)"
            )
        if re.fullmatch(r"[0-9a-f]{64}", args.sha256) is None:
            raise UpdateError("sha256 must be 64 lowercase hexadecimal characters")
        cask = update_cask(
            cask_path.read_text(encoding="utf-8"), args.version, args.sha256
        )
        validate_readme(readme_path.read_text(encoding="utf-8"))
        cask_path.write_text(cask, encoding="utf-8")
    except (OSError, UpdateError) as error:
        print(f"Homebrew tap update failed: {error}", file=sys.stderr)
        return 1
    print(f"Prepared Homebrew tap for Burrow {args.version}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
