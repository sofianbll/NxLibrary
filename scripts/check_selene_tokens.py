#!/usr/bin/env python3
"""Reject new numeric typography, padding and radius literals in view code."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / "scripts/selene-token-debt.json"
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
        for path in sorted((root / "Sources").rglob("*.swift"))
        if path.relative_to(root).as_posix() not in TOKENS
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", help="Git revision whose baseline must not grow")
    args = parser.parse_args()
    allowed = json.loads(BASELINE.read_text())
    found = scan()
    failed = False
    if args.base:
        relative = BASELINE.relative_to(ROOT).as_posix()
        tracked = subprocess.check_output(["git", "ls-tree", args.base, "--", relative], cwd=ROOT)
        if tracked:
            original = json.loads(subprocess.check_output(["git", "show", f"{args.base}:{relative}"], cwd=ROOT))
            for path, allowances in baseline_additions(allowed, original).items():
                for signature, count in sorted(allowances.items()):
                    print(f"{path}: baseline grows by {count} for {signature}", file=sys.stderr)
                    failed = True
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


def baseline_additions(current, original):
    return {
        path: extra
        for path, allowances in current.items()
        if (extra := Counter(allowances) - Counter(original.get(path, {})))
    }


if __name__ == "__main__":
    sys.exit(main())
