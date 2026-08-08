#!/usr/bin/env python3
"""Reject release-note source that is unsafe or misleading in Sparkle UI."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


class ValidationError(Exception):
    pass


def validate(path: Path, version: str) -> None:
    try:
        content = path.read_text(encoding="utf-8")
    except OSError as error:
        raise ValidationError(f"could not read release notes: {error}") from error

    if "<!--" in content or "-->" in content:
        raise ValidationError(
            "HTML comments are forbidden because Sparkle renders them as visible text"
        )

    lines = content.splitlines()
    expected_heading = f"# Burrow {version}"
    if not lines or lines[0] != expected_heading:
        actual = lines[0] if lines else "<empty>"
        raise ValidationError(
            f"first line is {actual!r}, expected {expected_heading!r}"
        )

    top_level_headings = [line for line in lines if line.startswith("# ")]
    if len(top_level_headings) != 1:
        raise ValidationError(
            "release notes must contain exactly one top-level heading "
            "(RELEASES.md is latest-only)"
        )

    if not any(line.strip() for line in lines[1:]):
        raise ValidationError("release notes have no content after the heading")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("notes", type=Path)
    parser.add_argument("--version", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        validate(args.notes, args.version)
    except ValidationError as error:
        print(f"release notes validation failed: {error}", file=sys.stderr)
        return 1
    print(f"Release notes validated for Burrow {args.version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
