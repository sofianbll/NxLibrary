#!/usr/bin/env python3
"""Reject new numeric typography, padding and radius literals in view code."""
from collections import Counter
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / "scripts/selene-token-debt.json"
SOURCES = ("Sources/NXLibrary/Views", "Sources/NXLibraryCore/Selene")
TOKENS = {"Sources/NXLibraryCore/Selene/SeleneTokens.swift"}
NUMBER = r"[+-]?(?:\d[\d_]*(?:\.[\d_]+)?|\.\d+)(?:[eE][+-]?\d+)?\b"
CALL = re.compile(
    r"(?P<font>\.font\s*\(\s*\.system\s*\(\s*size\s*:\s*|\.seleneFont\s*\(\s*)"
    r"|(?P<padding>\.padding\s*\(\s*(?:\.[a-zA-Z]\w*\s*,\s*)?)"
    r"|(?P<radius>\bcornerRadius\s*(?:\(|:)\s*)"
)
VALUE = re.compile(rf"(?:\bcanvas\s*\.\s*u\s*\(\s*)?({NUMBER})")
NON_CODE = re.compile(
    r'//[^\n]*|/\*.*?\*/|(?P<raw>\#*)"""[\s\S]*?"""(?P=raw)'
    r'|(?P<hash>\#+)"[^\n]*?"(?P=hash)|"(?:\\.|[^"\\\n])*"',
    re.DOTALL,
)


def literals(text):
    # Preserve newlines so diagnostics point to the source, not the stripped text.
    code = NON_CODE.sub(lambda m: re.sub(r"[^\n]", " ", m[0]), text)
    for call in CALL.finditer(code):
        value = VALUE.match(code, call.end())
        if value:
            signature = re.sub(r"\s+", "", call[0] + value[0])
            yield signature, code.count("\n", 0, call.start()) + 1


def scan(root=ROOT):
    return {
        path.relative_to(root).as_posix(): list(literals(path.read_text()))
        for source in SOURCES
        for path in sorted((root / source).rglob("*.swift"))
        if path.relative_to(root).as_posix() not in TOKENS
    }


def main():
    allowed = json.loads(BASELINE.read_text())
    found = scan()
    failed = False
    for path, matches in found.items():
        remaining = Counter(allowed.get(path, {}))
        for signature, line in matches:
            remaining[signature] -= 1
            if remaining[signature] < 0:
                print(f"{path}:{line}: use a Selene token instead of {signature}", file=sys.stderr)
                failed = True
        for signature, count in sorted(remaining.items()):
            if count > 0:
                print(f"{path}: remove {count} obsolete baseline allowance(s) for {signature}", file=sys.stderr)
                failed = True
    for path in allowed.keys() - found.keys():
        print(f"{path}: remove obsolete baseline file entry", file=sys.stderr)
        failed = True
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
