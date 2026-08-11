#!/usr/bin/env python3
"""Reduce Sentry issue/event JSON to fields approved for a public tracker."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


SLUG = re.compile(r"^(?=.{1,63}$)[a-z0-9]+(?:-[a-z0-9]+)*$")
SHORT_ID = re.compile(r"^(?=.{3,80}$)[A-Z0-9]+(?:-[A-Z0-9]+)+$")
ISSUE_ID = re.compile(r"^[0-9]{1,20}$")
BOUNDED_VALUE = re.compile(r"^[A-Za-z0-9._:+@-]{1,80}$")
TIMESTAMP = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.+-]{8,32}Z?$")
LEVELS = {"debug", "info", "warning", "error", "fatal"}


def load_object(path: Path) -> dict[str, Any]:
    if path.stat().st_size > 10 * 1024 * 1024:
        raise ValueError(f"input is unexpectedly large: {path}")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"input is not a JSON object: {path}")
    return value


def bounded(value: Any, default: str = "unknown") -> str:
    if isinstance(value, str) and BOUNDED_VALUE.fullmatch(value):
        return value
    return default


def timestamp(value: Any) -> str:
    if isinstance(value, str) and TIMESTAMP.fullmatch(value):
        return value
    return "unknown"


def event_tag(event: dict[str, Any], key: str) -> str:
    tags = event.get("tags")
    if not isinstance(tags, list):
        return "unknown"
    for tag in tags[:200]:
        if isinstance(tag, dict) and tag.get("key") == key:
            return bounded(tag.get("value"))
    return "unknown"


def release_value(event: dict[str, Any]) -> str:
    release = event.get("release")
    if isinstance(release, dict):
        release = release.get("version")
    return bounded(release)


def make_summary(
    issue: dict[str, Any], event: dict[str, Any], org: str, project: str
) -> dict[str, Any]:
    if not SLUG.fullmatch(org) or not SLUG.fullmatch(project):
        raise ValueError("organization and project must be fixed Sentry slugs")
    issue_id = issue.get("id")
    short_id = issue.get("shortId")
    if not isinstance(issue_id, str) or not ISSUE_ID.fullmatch(issue_id):
        raise ValueError("Sentry issue has no safe numeric id")
    if not isinstance(short_id, str) or not SHORT_ID.fullmatch(short_id):
        raise ValueError("Sentry issue has no safe short id")

    count = issue.get("count")
    if isinstance(count, int) and count >= 0:
        public_count = str(count)
    elif (
        isinstance(count, str)
        and 1 <= len(count) <= 20
        and count.isascii()
        and count.isdigit()
    ):
        public_count = str(int(count))
    else:
        public_count = "unknown"

    level = issue.get("level")
    public_level = level if isinstance(level, str) and level in LEVELS else "unknown"
    issue_type = issue.get("issueType") if isinstance(issue.get("issueType"), str) else ""
    title = issue.get("title") if isinstance(issue.get("title"), str) else ""
    hang_probe = f"{issue_type} {title}".lower()

    return {
        "shortId": short_id,
        "sentryUrl": f"https://sentry.io/organizations/{org}/issues/{issue_id}/",
        "project": project,
        "level": public_level,
        "count": public_count,
        "release": release_value(event),
        "osBuild": event_tag(event, "os_build"),
        "launchPhase": event_tag(event, "launch_phase"),
        "statusItem": event_tag(event, "status_item_state"),
        "firstSeen": timestamp(issue.get("firstSeen")),
        "lastSeen": timestamp(issue.get("lastSeen")),
        "isAppHang": bool(re.search(r"app[ _-]?hang|hanging", hang_probe)),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--issue-file", required=True, type=Path)
    parser.add_argument("--event-file", required=True, type=Path)
    parser.add_argument("--org", required=True)
    parser.add_argument("--project", required=True)
    args = parser.parse_args()
    try:
        summary = make_summary(
            load_object(args.issue_file),
            load_object(args.event_file),
            args.org,
            args.project,
        )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"error: refusing unsafe Sentry summary: {error}", file=sys.stderr)
        return 1
    json.dump(summary, sys.stdout, sort_keys=True, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
