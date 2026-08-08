#!/usr/bin/env python3
"""Read one scalar from the committed release input lock."""

from __future__ import annotations

import json
import sys
from pathlib import Path


LOCK = Path(__file__).with_name("release-inputs.json")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} dotted.key", file=sys.stderr)
        return 2
    value: object = json.loads(LOCK.read_text(encoding="utf-8"))
    try:
        for component in sys.argv[1].split("."):
            if not isinstance(value, dict):
                raise KeyError(component)
            value = value[component]
    except KeyError:
        print(f"error: no release input named {sys.argv[1]!r}", file=sys.stderr)
        return 1
    if not isinstance(value, (str, int, float)):
        print(f"error: release input {sys.argv[1]!r} is not a scalar", file=sys.stderr)
        return 1
    print(value)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
