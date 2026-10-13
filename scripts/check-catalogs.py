#!/usr/bin/env python3
"""Checks the app's string catalogs before Xcode sees them. Usage:
    python3 scripts/check-catalogs.py

- Every VibeMeeting/*.xcstrings file is valid JSON with English as its source
  language, so a hand edit can't break the build.
- The English permission prompts in InfoPlist.xcstrings say exactly what
  Info.plist says, so the two never drift apart (see docs/COPY.md).
"""
import json
import pathlib
import plistlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
app = root / "VibeMeeting"
problems = []

catalogs = sorted(app.glob("*.xcstrings"))
for required in ("Localizable.xcstrings", "InfoPlist.xcstrings"):
    if not (app / required).exists():
        problems.append(f"VibeMeeting/{required} is missing.")

loaded = {}
for path in catalogs:
    name = path.relative_to(root)
    try:
        catalog = json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        problems.append(f"{name}: not valid JSON ({error}).")
        continue
    if catalog.get("sourceLanguage") != "en":
        problems.append(f"{name}: sourceLanguage must be \"en\".")
    if not isinstance(catalog.get("version"), str):
        problems.append(f"{name}: no version.")
    if not isinstance(catalog.get("strings"), dict):
        problems.append(f"{name}: no strings object.")
        continue
    loaded[path.name] = catalog

info_plist = plistlib.loads((app / "Resources" / "Info.plist").read_bytes())
for key, entry in loaded.get("InfoPlist.xcstrings", {}).get("strings", {}).items():
    unit = entry.get("localizations", {}).get("en", {}).get("stringUnit")
    if unit is None:
        continue
    if key not in info_plist:
        problems.append(f"InfoPlist.xcstrings: {key} has an English value but isn't in Info.plist.")
    elif unit.get("value") != info_plist[key]:
        problems.append(f"InfoPlist.xcstrings: the English {key} differs from Info.plist. Change both together.")

if problems:
    print("\n".join(problems))
    sys.exit(1)
print(f"{len(catalogs)} string catalogs OK.")
