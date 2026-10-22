#!/usr/bin/env python3
"""Check the three shipped catalogs and their formatting contracts."""
import collections
import json
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
resources = root / "Sources/OpenIslandCore/Resources"
expected = {"en", "es", "ru"}
actual = {path.stem for path in resources.glob("*.lproj")}
errors = []
if actual != expected:
    errors.append(f"Languages must be exactly en, es, ru; found {sorted(actual)}")

catalogs = {}
entry = re.compile(r'^"((?:\\.|[^"\\])*)"\s*=\s*("(?:\\.|[^"\\])*")\s*;', re.MULTILINE)
placeholder = re.compile(r"%(?:\d+\$)?[-+# 0]*(?:\d+|\*)?(?:\.\d+)?(?:hh|ll|[hlzjtL])?[@diuoxXfFeEgGaAcCsSp]")
for language in sorted(expected & actual):
    path = resources / f"{language}.lproj/Localizable.strings"
    content = path.read_text()
    result = subprocess.run(["plutil", "-lint", str(path)], capture_output=True, text=True)
    if result.returncode:
        errors.append(result.stdout + result.stderr)
        continue
    entries = [(json.loads('"' + key + '"'), json.loads(value)) for key, value in entry.findall(content)]
    duplicates = [key for key, count in collections.Counter(key for key, _ in entries).items() if count > 1]
    if duplicates:
        errors.append(f"{language}: duplicate keys: {duplicates}")
    catalogs[language] = dict(entries)
    if any(not value.strip() for _, value in entries):
        errors.append(f"{language}: empty translations")

english = catalogs.get("en", {})
for language, catalog in catalogs.items():
    if catalog.keys() != english.keys():
        errors.append(f"{language}: missing {sorted(english.keys() - catalog.keys())}; extra {sorted(catalog.keys() - english.keys())}")
    for key in catalog.keys() & english.keys():
        source = placeholder.findall(english[key].replace("%%", ""))
        target = placeholder.findall(catalog[key].replace("%%", ""))
        if source != target:
            errors.append(f"{language}/{key}: format mismatch {source} != {target}")
if any(re.search(r"[\u0400-\u04ff\u4e00-\u9fff]", value) for value in english.values()):
    errors.append("English catalog contains untranslated Cyrillic or Chinese text")

# Literal lookups must resolve; dynamic plural keys are validated by catalog parity.
lookup = re.compile(r'(?:L10n\.tr|\b(?:lang|languageManager)\.t)\("([^"\\]+)"')
for path in (root / "Sources").rglob("*.swift"):
    for key in lookup.findall(path.read_text()):
        if key not in english:
            errors.append(f"{path.relative_to(root)}: missing key {key}")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"Localization checks passed: {len(english)} keys in English, Spanish, and Russian.")
