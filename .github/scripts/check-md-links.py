#!/usr/bin/env python3
"""Check relative links in tracked Markdown files. Offline: external URLs are skipped.

A link fails if its target is missing or lies outside the repository. Fragments are ignored.
Fenced code blocks and inline code are not treated as links.
"""
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote

INLINE = re.compile(r"!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+[\"'(][^)]*)?\)")
REFERENCE = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*<?([^\s>]+)>?", re.M)
FENCE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
SKIP = re.compile(r"^(?:[a-z][a-z0-9+.-]*:|//|#)", re.I)


def strip_code(text):
    kept, marker = [], None
    for line in text.splitlines():
        fence = FENCE.match(line)
        if marker:
            if fence and fence.group(1)[0] == marker[0] and len(fence.group(1)) >= len(marker):
                marker = None
        elif fence:
            marker = fence.group(1)
        else:
            kept.append(re.sub(r"(`+).*?\1", "", line))
        if marker or fence:
            kept.append("")
    return "\n".join(kept)


def main():
    root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()).resolve()
    files = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z", "*.md"], text=True).split("\0")
    files = [f for f in files if f]
    if not files:
        sys.exit("no Markdown files found")
    checked = bad = 0
    for name in files:
        path = root / name
        text = strip_code(path.read_text(encoding="utf-8"))
        for target in INLINE.findall(text) + REFERENCE.findall(text):
            if SKIP.match(target):
                continue
            rel = unquote(re.split(r"[#?]", target, maxsplit=1)[0])
            if not rel:
                continue
            checked += 1
            resolved = (root / rel.lstrip("/") if rel.startswith("/") else path.parent / rel).resolve()
            if not resolved.is_relative_to(root):
                print(f"{name}: {target}: outside the repository")
                bad += 1
            elif not resolved.exists():
                print(f"{name}: {target}: not found")
                bad += 1
    print(f"{len(files)} files, {checked} relative links, {bad} broken")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
