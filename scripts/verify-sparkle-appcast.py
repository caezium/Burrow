#!/usr/bin/env python3
"""Fail-closed structural validation for Burrow's generated Sparkle feed."""

from __future__ import annotations

import argparse
import base64
import binascii
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SIGNED_FEED = re.compile(
    rb"(?s)(?P<content>.*)"
    rb"<!-- sparkle-signatures:\r?\n"
    rb"edSignature: (?P<signature>[A-Za-z0-9+/]+={0,2})\r?\n"
    rb"length: (?P<length>[0-9]+)\r?\n"
    rb"-->\s*\Z"
)


class ValidationError(Exception):
    pass


def valid_ed25519_signature(value: str, label: str) -> None:
    try:
        decoded = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValidationError(f"{label} is not valid base64") from error
    if len(decoded) != 64:
        raise ValidationError(f"{label} must decode to a 64-byte Ed25519 signature")


def validate(
    appcast_path: Path,
    archive_path: Path,
    expected_version: str,
    expected_build: str,
    expected_url: str,
    expected_release_notes_path: Path | None = None,
) -> str:
    if not appcast_path.is_file():
        raise ValidationError(f"appcast does not exist: {appcast_path}")
    if not archive_path.is_file():
        raise ValidationError(f"archive does not exist: {archive_path}")

    raw = appcast_path.read_bytes()
    match = SIGNED_FEED.fullmatch(raw)
    if match is None:
        raise ValidationError("appcast is missing Sparkle's signed-feed block")

    content = match.group("content")
    declared_feed_length = int(match.group("length"))
    if declared_feed_length != len(content):
        raise ValidationError(
            "signed-feed length does not match the bytes covered by its signature"
        )
    valid_ed25519_signature(match.group("signature").decode("ascii"), "feed signature")

    try:
        root = ET.fromstring(content)
    except ET.ParseError as error:
        raise ValidationError(f"appcast XML is invalid: {error}") from error

    items = list(root.iter("item"))
    if len(items) != 1:
        raise ValidationError(f"expected exactly one update item, found {len(items)}")
    item = items[0]

    enclosures = list(item.iter("enclosure"))
    if len(enclosures) != 1:
        raise ValidationError(
            f"expected exactly one full update enclosure, found {len(enclosures)}"
        )
    enclosure = enclosures[0]
    delta_key = f"{{{SPARKLE_NS}}}deltaFrom"
    if delta_key in enclosure.attrib:
        raise ValidationError("first signed release must not contain delta updates")
    if any(element.tag == f"{{{SPARKLE_NS}}}deltas" for element in root.iter()):
        raise ValidationError("first signed release must not contain a deltas section")

    enclosure_expected = {
        "url": expected_url,
        "length": str(archive_path.stat().st_size),
    }
    for key, expected_value in enclosure_expected.items():
        actual = enclosure.attrib.get(key)
        if actual != expected_value:
            raise ValidationError(
                f"enclosure {key} is {actual!r}, expected {expected_value!r}"
            )

    item_expected = {
        "version": expected_build,
        "shortVersionString": expected_version,
    }
    for name, expected_value in item_expected.items():
        element = item.find(f"{{{SPARKLE_NS}}}{name}")
        actual = None if element is None else element.text
        if actual != expected_value:
            raise ValidationError(
                f"item {name} is {actual!r}, expected {expected_value!r}"
            )

    if expected_release_notes_path is not None:
        try:
            expected_release_notes = expected_release_notes_path.read_text(
                encoding="utf-8"
            )
        except OSError as error:
            raise ValidationError(
                f"could not read expected release notes: {error}"
            ) from error
        description = item.find("description")
        if description is None:
            raise ValidationError("item is missing embedded release notes")
        if description.attrib.get(f"{{{SPARKLE_NS}}}format") != "markdown":
            raise ValidationError("embedded release notes are not marked as markdown")
        actual_release_notes = description.text or ""
        if actual_release_notes != expected_release_notes:
            raise ValidationError(
                "embedded release notes do not exactly match the validated source"
            )

    archive_signature = enclosure.attrib.get(f"{{{SPARKLE_NS}}}edSignature")
    if archive_signature is None:
        raise ValidationError("archive enclosure is missing sparkle:edSignature")
    valid_ed25519_signature(archive_signature, "archive signature")
    return archive_signature


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("appcast", type=Path)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument(
        "--signature-output",
        type=Path,
        help="write the validated archive signature for sign_update --verify",
    )
    parser.add_argument(
        "--release-notes",
        type=Path,
        help="require embedded markdown to exactly match this file",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        archive_signature = validate(
            args.appcast,
            args.archive,
            args.version,
            args.build,
            args.url,
            args.release_notes,
        )
        if args.signature_output is not None:
            args.signature_output.write_text(archive_signature, encoding="ascii")
    except (OSError, ValidationError) as error:
        print(f"appcast validation failed: {error}", file=sys.stderr)
        return 1
    print(
        f"Verified signed Sparkle feed for Burrow {args.version} "
        f"(build {args.build})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
