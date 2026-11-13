#!/usr/bin/env python3
"""Fails when a string catalog key lacks a finished Norwegian translation or is stale.

Usage: python3 -I scripts/check-translations.py [catalog.xcstrings ...]
With no arguments it checks the app's Localizable and AppShortcuts catalogs.
"""

import json
import sys
from pathlib import Path

LANGUAGE = "nb"
ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CATALOGS = [
    ROOT / "MacUnclog/Resources/Localizable.xcstrings",
    ROOT / "MacUnclog/Resources/AppShortcuts.xcstrings",
]


def units(localization):
    """Every stringUnit/stringSet in a localization, including plural and device variations."""
    for kind in ("stringUnit", "stringSet"):
        if kind in localization:
            yield localization[kind]
    for cases in localization.get("variations", {}).values():
        for case in cases.values():
            yield from units(case)


def problem(entry):
    if entry.get("extractionState") == "stale":
        return "stale (no longer in the code; delete it from the catalog)"
    localization = entry.get("localizations", {}).get(LANGUAGE)
    if localization is None:
        return f"no {LANGUAGE} translation"
    states = [unit.get("state") for unit in units(localization)]
    if not states:
        return f"empty {LANGUAGE} translation"
    unfinished = sorted({state for state in states if state != "translated"})
    if unfinished:
        return f"{LANGUAGE} state is {', '.join(map(str, unfinished))}"
    return None


def main(paths):
    failures = 0
    for path in paths:
        catalog = json.loads(Path(path).read_text(encoding="utf-8"))
        for key, entry in sorted(catalog.get("strings", {}).items()):
            if entry.get("shouldTranslate") is False:
                continue
            reason = problem(entry)
            if reason:
                failures += 1
                print(f"{Path(path).name}: {json.dumps(key, ensure_ascii=False)}: {reason}")
    print(f"{failures} missing or stale translation(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or DEFAULT_CATALOGS))
