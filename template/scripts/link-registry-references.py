#!/usr/bin/env python3
"""Create exact interactive links for registry IDs in Markdown files.

The registry schema is the source of truth. Canonical table rows keep the plain ID
in the first cell for compatibility, while an HTML anchor is inserted at the start
of the second cell. References outside canonical definition rows become relative
Markdown links to that exact anchor.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote

FENCE_RE = re.compile(r"^\s*(```|~~~)")
ROW_ID_RE = re.compile(r"^(?P<prefix>\|\s*)(?P<id>[A-Za-z]+-\d+)(?P<between>\s*\|\s*)(?P<rest>.*)$")
INLINE_TOKEN_RE = re.compile(
    r"!?\[[^\]\n]*\]\([^\)\n]+\)"  # existing Markdown link/image
    r"|<[^>\n]+>"                       # HTML tags and autolinks
    r"|`[^`\n]*`"                       # inline code
    r"|https?://[^\s<>()]+"             # bare URL
    r"|\b[A-Za-z]+-\d+\b"             # candidate registry ID
)
IGNORED_PARTS = {".git", ".project", "dist", "__pycache__"}
IGNORED_MARKDOWN = {"PROJECT.md"}


@dataclass(frozen=True)
class RegistryTarget:
    registry_path: str
    anchor: str


def normalize_id(value: str) -> str:
    return value.strip().upper()


def anchor_for(value: str) -> str:
    return normalize_id(value).lower()


def markdown_files(root: Path) -> list[Path]:
    result: list[Path] = []
    for path in root.rglob("*.md"):
        if any(part in IGNORED_PARTS for part in path.parts):
            continue
        if path.name in IGNORED_MARKDOWN:
            continue
        result.append(path)
    return sorted(result)


def load_schema(root: Path) -> list[dict]:
    path = root / "REGISTRY-SCHEMA.json"
    if not path.is_file():
        raise RuntimeError("Не найден REGISTRY-SCHEMA.json.")
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schemaVersion") != 1:
        raise RuntimeError("Поддерживается только schemaVersion = 1 для реестров.")
    registries = data.get("registries")
    if not isinstance(registries, list) or not registries:
        raise RuntimeError("В REGISTRY-SCHEMA.json не описаны реестры.")
    return registries


def supported_patterns(registry: dict) -> list[re.Pattern[str]]:
    patterns: list[re.Pattern[str]] = []
    for item in registry.get("formats", []):
        raw = item.get("idPattern")
        if raw:
            patterns.append(re.compile(str(raw), re.IGNORECASE))
    return patterns


def registry_targets(root: Path, registries: list[dict]) -> dict[str, RegistryTarget]:
    targets: dict[str, RegistryTarget] = {}
    for registry in registries:
        relative = str(registry.get("path", "")).strip()
        if not relative:
            continue
        path = root / relative
        if not path.is_file():
            raise RuntimeError(f"Отсутствует реестр: {relative}")
        patterns = supported_patterns(registry)
        for line in path.read_text(encoding="utf-8").splitlines():
            match = ROW_ID_RE.match(line)
            if not match:
                continue
            registry_id = normalize_id(match.group("id"))
            if patterns and not any(pattern.fullmatch(registry_id) for pattern in patterns):
                continue
            existing = targets.get(registry_id)
            target = RegistryTarget(relative, anchor_for(registry_id))
            if existing and existing != target:
                raise RuntimeError(f"ID {registry_id} определён более чем в одном реестре.")
            targets[registry_id] = target
    return targets


def relative_href(current_file: Path, root: Path, target: RegistryTarget) -> str:
    relative = os.path.relpath(root / target.registry_path, current_file.parent).replace(os.sep, "/")
    if not relative.startswith("."):
        relative = f"./{relative}"
    return f"{quote(relative, safe='/._-~')}#{target.anchor}"


def ensure_definition_anchor(line: str, known: dict[str, RegistryTarget], current_relative: str) -> tuple[str, bool]:
    match = ROW_ID_RE.match(line)
    if not match:
        return line, False
    registry_id = normalize_id(match.group("id"))
    target = known.get(registry_id)
    if target is None or target.registry_path != current_relative:
        return line, False
    marker = f'<a id="{target.anchor}"></a>'
    rest = match.group("rest")
    if rest.startswith(marker):
        return line, False
    cleaned = re.sub(r'^<a\s+id=["\']' + re.escape(target.anchor) + r'["\']\s*></a>\s*', "", rest, flags=re.IGNORECASE)
    updated = f'{match.group("prefix")}{registry_id}{match.group("between")}{marker}{cleaned}'
    return updated, updated != line


def transform_inline(text: str, current_file: Path, root: Path, known: dict[str, RegistryTarget]) -> tuple[str, list[str]]:
    output: list[str] = []
    linked: list[str] = []
    cursor = 0
    for match in INLINE_TOKEN_RE.finditer(text):
        output.append(text[cursor:match.start()])
        token = match.group(0)
        replacement = token
        if token.startswith("`") and token.endswith("`"):
            inner = token[1:-1]
            registry_id = normalize_id(inner)
            target = known.get(registry_id)
            if target and inner.strip().upper() == registry_id:
                replacement = f"[`{registry_id}`]({relative_href(current_file, root, target)})"
                linked.append(registry_id)
        elif re.fullmatch(r"[A-Za-z]+-\d+", token):
            registry_id = normalize_id(token)
            target = known.get(registry_id)
            if target:
                replacement = f"[{registry_id}]({relative_href(current_file, root, target)})"
                linked.append(registry_id)
        output.append(replacement)
        cursor = match.end()
    output.append(text[cursor:])
    return "".join(output), linked


def transform_file(path: Path, root: Path, known: dict[str, RegistryTarget]) -> tuple[str, list[tuple[int, str]]]:
    original = path.read_text(encoding="utf-8")
    lines = original.splitlines(keepends=True)
    in_fence = False
    current_relative = path.relative_to(root).as_posix()
    output: list[str] = []
    changes: list[tuple[int, str]] = []

    for line_number, line in enumerate(lines, start=1):
        if FENCE_RE.match(line):
            in_fence = not in_fence
            output.append(line)
            continue
        if in_fence or line.startswith(("    ", "\t")):
            output.append(line)
            continue

        body = line.rstrip("\r\n")
        ending = line[len(body):]
        anchored, anchor_changed = ensure_definition_anchor(body, known, current_relative)
        if anchor_changed:
            registry_id = normalize_id(ROW_ID_RE.match(anchored).group("id"))  # type: ignore[union-attr]
            changes.append((line_number, f"anchor:{registry_id}"))
            output.append(anchored + ending)
            continue

        definition = ROW_ID_RE.match(body)
        if definition:
            registry_id = normalize_id(definition.group("id"))
            target = known.get(registry_id)
            if target and target.registry_path == current_relative:
                output.append(body + ending)
                continue

        transformed, linked = transform_inline(body, path, root, known)
        output.append(transformed + ending)
        for registry_id in linked:
            changes.append((line_number, f"link:{registry_id}"))

    return "".join(output), changes


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="Обновить Markdown-файлы на месте.")
    mode.add_argument("--check", action="store_true", help="Завершиться с ошибкой, если ссылки или якоря требуют обновления.")
    parser.add_argument("--root", default=None, help="Корень проекта. По умолчанию родитель папки scripts.")
    args = parser.parse_args()

    root = Path(args.root).resolve() if args.root else Path(__file__).resolve().parents[1]
    registries = load_schema(root)
    known = registry_targets(root, registries)
    if not known:
        raise RuntimeError("В реестрах не найдено ни одного поддерживаемого ID.")

    pending: list[tuple[Path, str, list[tuple[int, str]]]] = []
    for path in markdown_files(root):
        transformed, changes = transform_file(path, root, known)
        original = path.read_text(encoding="utf-8")
        if transformed != original:
            pending.append((path, transformed, changes))

    if args.write:
        for path, transformed, changes in pending:
            path.write_text(transformed, encoding="utf-8", newline="\n")
            relative = path.relative_to(root).as_posix()
            print(f"updated {relative}: {len(changes)} change(s)")
        print(f"Updated Markdown files: {len(pending)}; registry IDs: {len(known)}")
        return 0

    if pending:
        print("Registry references require interactive links or exact anchors:", file=sys.stderr)
        for path, _, changes in pending:
            relative = path.relative_to(root).as_posix()
            for line_number, description in changes:
                print(f"  {relative}:{line_number} -> {description}", file=sys.stderr)
        print("Run: python scripts/link-registry-references.py --write", file=sys.stderr)
        return 1

    print(f"All references to {len(known)} registry IDs are interactive and anchored.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
