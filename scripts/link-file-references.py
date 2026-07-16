#!/usr/bin/env python3
"""Convert code-formatted references to existing repository files into Markdown links."""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path
from urllib.parse import quote

CODE_SPAN_RE = re.compile(r"`([^`\n]+)`")
FENCE_RE = re.compile(r"^\s*(```|~~~)")
IGNORED_PARTS = {".git", ".project", "dist", "__pycache__"}
IGNORED_MARKDOWN = {"PROJECT.md"}


def repository_files(root: Path) -> tuple[set[str], dict[str, list[str]]]:
    paths: set[str] = set()
    by_name: dict[str, list[str]] = {}
    for path in root.rglob("*"):
        if not path.is_file() or any(part in IGNORED_PARTS for part in path.parts):
            continue
        relative = path.relative_to(root).as_posix()
        paths.add(relative)
        by_name.setdefault(path.name, []).append(relative)
    return paths, by_name


def markdown_files(root: Path) -> list[Path]:
    result: list[Path] = []
    for path in root.rglob("*.md"):
        if any(part in IGNORED_PARTS for part in path.parts):
            continue
        if path.name in IGNORED_MARKDOWN:
            continue
        result.append(path)
    return sorted(result)


def is_existing_link_context(text: str, start: int, end: int) -> bool:
    before = text[:start].rstrip()
    after = text[end:].lstrip()
    return before.endswith("[") and after.startswith("](")


def split_anchor(token: str) -> tuple[str, str]:
    if "#" not in token:
        return token, ""
    path, anchor = token.split("#", 1)
    return path, f"#{anchor}"


def resolve_reference(
    token: str,
    current_file: Path,
    root: Path,
    all_files: set[str],
    by_name: dict[str, list[str]],
) -> tuple[str, str] | None:
    if not token or token != token.strip():
        return None
    if any(char in token for char in ("\n", "\r", "\t", "*", "?", "{", "}", "$", "|")):
        return None
    if token.startswith(("http://", "https://", "mailto:", "#", "-")):
        return None

    raw_path, anchor = split_anchor(token)
    if not raw_path or raw_path.endswith("/"):
        return None
    normalized = raw_path.replace("\\", "/")
    if normalized.startswith("./"):
        normalized = normalized[2:]

    current_dir = current_file.parent.relative_to(root).as_posix()
    if current_dir == ".":
        current_dir = ""

    # A path relative to the current document is the least surprising result.
    relative_candidate = Path(current_dir, normalized).as_posix() if current_dir else normalized
    if relative_candidate in all_files:
        target = relative_candidate
    # An explicit repository-root path has the next priority.
    elif normalized in all_files:
        target = normalized
    # A bare basename is accepted only when it is unique in the repository.
    elif "/" not in normalized and len(by_name.get(normalized, [])) == 1:
        target = by_name[normalized][0]
    else:
        return None

    relative_target = os.path.relpath(root / target, current_file.parent).replace(os.sep, "/")
    if not relative_target.startswith("."):
        relative_target = f"./{relative_target}"
    href = quote(relative_target, safe="/._-~") + anchor
    return target, href


def transform_line(
    line: str,
    current_file: Path,
    root: Path,
    all_files: set[str],
    by_name: dict[str, list[str]],
) -> tuple[str, list[str]]:
    replacements: list[tuple[int, int, str]] = []
    linked: list[str] = []
    for match in CODE_SPAN_RE.finditer(line):
        if is_existing_link_context(line, match.start(), match.end()):
            continue
        token = match.group(1)
        resolved = resolve_reference(token, current_file, root, all_files, by_name)
        if resolved is None:
            continue
        target, href = resolved
        replacements.append((match.start(), match.end(), f"[`{token}`]({href})"))
        linked.append(target)

    for start, end, replacement in reversed(replacements):
        line = line[:start] + replacement + line[end:]
    return line, linked


def transform_file(
    path: Path,
    root: Path,
    all_files: set[str],
    by_name: dict[str, list[str]],
) -> tuple[str, list[tuple[int, str]]]:
    original = path.read_text(encoding="utf-8")
    lines = original.splitlines(keepends=True)
    in_fence = False
    output: list[str] = []
    changes: list[tuple[int, str]] = []

    for line_number, line in enumerate(lines, start=1):
        if FENCE_RE.match(line):
            in_fence = not in_fence
            output.append(line)
            continue
        if in_fence:
            output.append(line)
            continue
        transformed, linked = transform_line(line, path, root, all_files, by_name)
        output.append(transformed)
        for target in linked:
            changes.append((line_number, target))

    return "".join(output), changes


def main() -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="Rewrite Markdown files in place.")
    mode.add_argument("--check", action="store_true", help="Fail if unlinked file references remain.")
    parser.add_argument("--root", default=None, help="Repository root. Defaults to the parent of scripts/.")
    args = parser.parse_args()

    root = Path(args.root).resolve() if args.root else Path(__file__).resolve().parents[1]
    all_files, by_name = repository_files(root)
    pending: list[tuple[Path, str, list[tuple[int, str]]]] = []

    for path in markdown_files(root):
        transformed, changes = transform_file(path, root, all_files, by_name)
        original = path.read_text(encoding="utf-8")
        if transformed != original:
            pending.append((path, transformed, changes))

    if args.write:
        for path, transformed, changes in pending:
            path.write_text(transformed, encoding="utf-8", newline="\n")
            relative = path.relative_to(root).as_posix()
            print(f"updated {relative}: {len(changes)} link(s)")
        print(f"Updated Markdown files: {len(pending)}")
        return 0

    if pending:
        print("Unlinked code-formatted references to existing files:", file=sys.stderr)
        for path, _, changes in pending:
            relative = path.relative_to(root).as_posix()
            for line_number, target in changes:
                print(f"  {relative}:{line_number} -> {target}", file=sys.stderr)
        print("Run: python scripts/link-file-references.py --write", file=sys.stderr)
        return 1

    print("All code-formatted references to existing files are interactive links.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
