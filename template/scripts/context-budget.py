#!/usr/bin/env python3
"""Оценочный контроль размера контекста без сети и внешних зависимостей."""

from pathlib import Path
import argparse
import sys

ROOT = Path(__file__).resolve().parent.parent
CHARS_PER_TOKEN = 2.2
SOFT_CORE_BUDGET = 55_000
SUMMARY_THRESHOLD = 20_000
CORE = ["AGENTS.md", "README.md", "HANDOFF.md", "PROJECT-BRIEF.md"]
EXCLUDED = {"PROJECT.md"}


def tokens(text: str) -> int:
    return int(len(text) / CHARS_PER_TOKEN)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--strict",
        action="store_true",
        help="завершиться с ошибкой при предупреждениях",
    )
    args = parser.parse_args()
    rows = []
    warnings = []
    for path in sorted(ROOT.rglob("*.md")):
        if path.name in EXCLUDED or "_templates" in path.parts or ".project" in path.parts:
            continue
        text = path.read_text(encoding="utf-8")
        count = tokens(text)
        rel = path.relative_to(ROOT).as_posix()
        rows.append((rel, count, len(text)))
        if count >= SUMMARY_THRESHOLD and "\n## Резюме" not in text:
            warnings.append(f"{rel}: длинная заметка без раздела «Резюме»")

    print(f"{'Файл':45} {'Токены':>10} {'Символы':>10}")
    for name, count, chars in sorted(rows, key=lambda row: -row[1]):
        print(f"{name:45} {count:>10,} {chars:>10,}")

    core_total = sum(tokens((ROOT / name).read_text(encoding="utf-8")) for name in CORE)
    print(f"\nБазовое погружение: ~{core_total:,} / {SOFT_CORE_BUDGET:,} токенов (класс C)")
    if core_total > SOFT_CORE_BUDGET:
        warnings.append("базовое погружение превысило мягкий бюджет")
    for warning in warnings:
        print(f"ПРЕДУПРЕЖДЕНИЕ: {warning}")
    return 1 if args.strict and warnings else 0


if __name__ == "__main__":
    sys.exit(main())
