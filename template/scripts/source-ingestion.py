#!/usr/bin/env python3
"""Локальная конвертация вложений в адресуемый Markdown-кэш.

MarkItDown используется только для локальных файлов. Сетевые URL, плагины и
облачные анализаторы этим скриптом не вызываются.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = ROOT / "SOURCE-INGESTION.json"
SOURCES_PATH = ROOT / "SOURCES.md"
ATTACHMENTS_ROOT = (ROOT / "_attachments").resolve()
CACHE_ROOT = ROOT / ".project" / "sources"
CHARS_PER_TOKEN = 2.2
TEXT_EXTENSIONS = {".md", ".txt"}


class IngestionError(RuntimeError):
    pass


def normalized_text(value: str) -> str:
    return value.replace("\r\n", "\n").replace("\r", "\n").strip() + "\n"


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_text(value: str) -> str:
    return sha256_bytes(normalized_text(value).encode("utf-8"))


def estimate_tokens(value: str) -> int:
    return max(1, int((len(value) + CHARS_PER_TOKEN - 1) / CHARS_PER_TOKEN))


def load_config() -> dict:
    if not CONFIG_PATH.is_file():
        raise IngestionError("Не найден SOURCE-INGESTION.json.")
    config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    if config.get("schemaVersion") != 1:
        raise IngestionError("Поддерживается только schemaVersion = 1 конфигурации импорта.")
    return config


def split_markdown_row(line: str) -> list[str]:
    value = line.strip()
    if not (value.startswith("|") and value.endswith("|")):
        return []
    cells: list[str] = []
    current: list[str] = []
    escaped = False
    for char in value[1:-1]:
        if escaped:
            current.append(char)
            escaped = False
        elif char == "\\":
            current.append(char)
            escaped = True
        elif char == "|":
            cells.append("".join(current).strip())
            current = []
        else:
            current.append(char)
    cells.append("".join(current).strip())
    return cells


def source_registry() -> dict[str, str]:
    if not SOURCES_PATH.is_file():
        raise IngestionError("Не найден SOURCES.md.")
    result: dict[str, str] = {}
    for line in SOURCES_PATH.read_text(encoding="utf-8").splitlines():
        cells = split_markdown_row(line)
        if cells and re.fullmatch(r"S-\d+", cells[0], re.IGNORECASE):
            result[cells[0].upper()] = cells[1]
    return result


def safe_source_path(source_id: str, config: dict) -> Path:
    registry = source_registry()
    relative = registry.get(source_id)
    if not relative:
        raise IngestionError(f"Источник {source_id} отсутствует в SOURCES.md.")
    if re.match(r"^[a-z][a-z0-9+.-]*://", relative, re.IGNORECASE):
        raise IngestionError(f"Источник {source_id} является URL. Разрешены только локальные файлы в _attachments.")
    candidate = (ROOT / relative).resolve()
    try:
        candidate.relative_to(ATTACHMENTS_ROOT)
    except ValueError as exc:
        raise IngestionError(f"Файл источника {source_id} должен находиться внутри _attachments: {relative}") from exc
    if not candidate.is_file():
        raise IngestionError(f"Файл источника {source_id} отсутствует: {relative}")
    if candidate.is_symlink():
        raise IngestionError(f"Символьные ссылки не обрабатываются: {relative}")
    extension = candidate.suffix.lower()
    allowed = {str(item).lower() for item in config.get("allowedExtensions", [])}
    if extension not in allowed:
        raise IngestionError(f"Формат {extension or '<без расширения>'} не разрешён конфигурацией.")
    max_bytes = int(config.get("maxInputBytes", 0))
    if max_bytes > 0 and candidate.stat().st_size > max_bytes:
        raise IngestionError(f"Файл превышает maxInputBytes ({max_bytes} байт): {relative}")
    return candidate


def converter_version(path: Path) -> str:
    if path.suffix.lower() in TEXT_EXTENSIONS:
        return "builtin-text-v1"
    try:
        return f"markitdown-{importlib.metadata.version('markitdown')}"
    except importlib.metadata.PackageNotFoundError as exc:
        raise IngestionError(
            "Для этого формата не установлен MarkItDown. Выполните: "
            "python -m pip install 'markitdown[pdf,docx,pptx,xlsx,xls,outlook]'"
        ) from exc


def convert_local(path: Path) -> tuple[str, str]:
    version = converter_version(path)
    if version == "builtin-text-v1":
        return normalized_text(path.read_text(encoding="utf-8")), version
    try:
        from markitdown import MarkItDown
    except ImportError as exc:
        raise IngestionError("MarkItDown не установлен.") from exc
    converter = MarkItDown(enable_plugins=False)
    result = converter.convert_local(path)
    return normalized_text(result.markdown), version


@dataclass(frozen=True)
class Chunk:
    chunk_id: str
    heading: str
    text: str
    estimated_tokens: int
    sha256: str


def paragraph_blocks(markdown: str) -> Iterable[tuple[str, str]]:
    heading = "Начало документа"
    buffer: list[str] = []
    for line in normalized_text(markdown).splitlines():
        match = re.match(r"^#{1,6}\s+(.+?)\s*$", line)
        if match:
            if buffer:
                yield heading, "\n".join(buffer).strip()
                buffer = []
            heading = match.group(1).strip()
            buffer.append(line)
        elif not line.strip() and buffer:
            yield heading, "\n".join(buffer).strip()
            buffer = []
        else:
            buffer.append(line)
    if buffer:
        yield heading, "\n".join(buffer).strip()


def split_oversized(text: str, max_chars: int) -> list[str]:
    if len(text) <= max_chars:
        return [text]
    parts: list[str] = []
    remaining = text
    while len(remaining) > max_chars:
        boundary = remaining.rfind("\n", 0, max_chars)
        if boundary < max_chars // 2:
            boundary = remaining.rfind(" ", 0, max_chars)
        if boundary < max_chars // 2:
            boundary = max_chars
        parts.append(remaining[:boundary].strip())
        remaining = remaining[boundary:].strip()
    if remaining:
        parts.append(remaining)
    return parts


def make_chunks(source_id: str, markdown: str, config: dict) -> list[Chunk]:
    chunk_tokens = int(config.get("chunkTargetTokens", 900))
    max_chars = max(400, int(chunk_tokens * CHARS_PER_TOKEN))
    blocks: list[tuple[str, str]] = []
    for heading, block in paragraph_blocks(markdown):
        if not block:
            continue
        for part in split_oversized(block, max_chars):
            blocks.append((heading, part))

    chunks: list[Chunk] = []
    current_heading = "Начало документа"
    current: list[str] = []
    current_chars = 0

    def flush() -> None:
        nonlocal current, current_chars
        if not current:
            return
        text = "\n\n".join(current).strip()
        index = len(chunks) + 1
        chunk_id = f"{source_id}-C{index:04d}"
        chunks.append(
            Chunk(
                chunk_id=chunk_id,
                heading=current_heading,
                text=text,
                estimated_tokens=estimate_tokens(text),
                sha256=sha256_text(text),
            )
        )
        current = []
        current_chars = 0

    for heading, block in blocks:
        projected = current_chars + len(block) + (2 if current else 0)
        if current and projected > max_chars:
            flush()
        if not current:
            current_heading = heading
        current.append(block)
        current_chars += len(block) + (2 if len(current) > 1 else 0)
    flush()
    return chunks


def cache_dir(source_id: str) -> Path:
    return CACHE_ROOT / source_id


def read_manifest(source_id: str) -> dict | None:
    path = cache_dir(source_id) / "manifest.json"
    return json.loads(path.read_text(encoding="utf-8")) if path.is_file() else None


def is_fresh(manifest: dict | None, source_path: Path, config: dict, converter: str | None = None) -> bool:
    if not manifest:
        return False
    if manifest.get("sourceSha256") != sha256_bytes(source_path.read_bytes()):
        return False
    if manifest.get("configurationSha256") != sha256_text(json.dumps(config, ensure_ascii=False, sort_keys=True)):
        return False
    return converter is None or manifest.get("converterVersion") == converter


def ingest(source_id: str, force: bool = False) -> dict:
    source_id = source_id.upper()
    config = load_config()
    source_path = safe_source_path(source_id, config)
    converter = converter_version(source_path)
    existing = read_manifest(source_id)
    if not force and is_fresh(existing, source_path, config, converter):
        result = dict(existing)
        result["cacheHit"] = True
        return result

    markdown, converter = convert_local(source_path)
    max_output_chars = int(config.get("maxOutputCharacters", 0))
    if max_output_chars > 0 and len(markdown) > max_output_chars:
        raise IngestionError(f"Результат преобразования превышает maxOutputCharacters ({max_output_chars}).")
    chunks = make_chunks(source_id, markdown, config)
    if not chunks:
        raise IngestionError("После преобразования документ не содержит текста.")

    target = cache_dir(source_id)
    target.mkdir(parents=True, exist_ok=True)
    (target / "full.md").write_text(markdown, encoding="utf-8", newline="\n")
    with (target / "chunks.jsonl").open("w", encoding="utf-8", newline="\n") as stream:
        for chunk in chunks:
            stream.write(json.dumps(chunk.__dict__, ensure_ascii=False, sort_keys=True) + "\n")

    manifest = {
        "schemaVersion": 1,
        "sourceId": source_id,
        "sourcePath": source_path.relative_to(ROOT).as_posix(),
        "sourceSha256": sha256_bytes(source_path.read_bytes()),
        "configurationSha256": sha256_text(json.dumps(config, ensure_ascii=False, sort_keys=True)),
        "converterVersion": converter,
        "generatedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "fullEstimatedTokens": estimate_tokens(markdown),
        "chunkCount": len(chunks),
        "cacheHit": False,
        "status": "ready",
        "warnings": [],
    }
    (target / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    return manifest


def load_chunks(source_id: str) -> list[dict]:
    path = cache_dir(source_id) / "chunks.jsonl"
    if not path.is_file():
        raise IngestionError(f"Кэш {source_id} отсутствует. Сначала выполните команду ingest.")
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def terms_from_queries(queries: list[str]) -> list[str]:
    terms: list[str] = []
    for query in queries:
        for term in re.findall(r"[\w-]{2,}", query.casefold(), flags=re.UNICODE):
            if term not in terms:
                terms.append(term)
    return terms


def select(source_id: str, queries: list[str], token_budget: int, max_chunks: int, refresh: bool) -> dict:
    source_id = source_id.upper()
    config = load_config()
    source_path = safe_source_path(source_id, config)
    if refresh:
        ingest(source_id)
    manifest = read_manifest(source_id)
    if not is_fresh(manifest, source_path, config):
        raise IngestionError(f"Кэш {source_id} отсутствует или устарел. Выполните ingest или используйте --refresh.")
    chunks = load_chunks(source_id)
    terms = terms_from_queries(queries)

    ranked: list[tuple[int, int, dict]] = []
    for index, chunk in enumerate(chunks):
        heading = str(chunk.get("heading", "")).casefold()
        text = str(chunk.get("text", "")).casefold()
        if terms:
            score = sum(8 * heading.count(term) + text.count(term) for term in terms)
            if score <= 0:
                continue
        else:
            score = max(1, 1000 - index)
        ranked.append((score, index, chunk))
    ranked.sort(key=lambda item: (-item[0], item[1]))

    selected: list[dict] = []
    used = 0
    for _score, _index, chunk in ranked:
        tokens = int(chunk.get("estimated_tokens", estimate_tokens(str(chunk.get("text", "")))))
        if selected and used + tokens > token_budget:
            continue
        if not selected and tokens > token_budget:
            continue
        selected.append(chunk)
        used += tokens
        if len(selected) >= max_chunks:
            break

    markdown_parts = [f"## Фрагменты источника {source_id}"]
    for chunk in sorted(selected, key=lambda item: item["chunk_id"]):
        markdown_parts.append(
            f"### {chunk['chunk_id']} — {chunk.get('heading', 'Без заголовка')}\n\n{chunk['text']}"
        )
    markdown = "\n\n".join(markdown_parts).strip() + "\n" if selected else ""
    full_tokens = int(manifest.get("fullEstimatedTokens", 0))
    reduction = 0.0 if full_tokens <= 0 else max(0.0, round(100 * (1 - used / full_tokens), 1))
    return {
        "schemaVersion": 1,
        "sourceId": source_id,
        "sourcePath": manifest.get("sourcePath"),
        "cacheFresh": True,
        "queries": queries,
        "matched": bool(selected),
        "includedChunkIds": [item["chunk_id"] for item in selected],
        "includedTokens": used,
        "fullEstimatedTokens": full_tokens,
        "reductionPercent": reduction,
        "markdown": markdown,
    }


def verify() -> dict:
    config = load_config()
    rows: list[dict] = []
    if CACHE_ROOT.is_dir():
        for target in sorted(CACHE_ROOT.iterdir()):
            if not target.is_dir() or not re.fullmatch(r"S-\d+", target.name):
                continue
            try:
                source = safe_source_path(target.name, config)
                fresh = is_fresh(read_manifest(target.name), source, config)
                rows.append({"sourceId": target.name, "fresh": fresh})
            except IngestionError as exc:
                rows.append({"sourceId": target.name, "fresh": False, "error": str(exc)})
    return {"schemaVersion": 1, "sources": rows, "complete": all(row["fresh"] for row in rows)}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    ingest_parser = sub.add_parser("ingest", help="Преобразовать локальный источник и создать кэш.")
    ingest_parser.add_argument("--source-id", required=True)
    ingest_parser.add_argument("--force", action="store_true")

    select_parser = sub.add_parser("select", help="Выбрать релевантные фрагменты из кэша.")
    select_parser.add_argument("--source-id", required=True)
    select_parser.add_argument("--query", action="append", default=[])
    select_parser.add_argument("--token-budget", type=int, required=True)
    select_parser.add_argument("--max-chunks", type=int, default=20)
    select_parser.add_argument("--refresh", action="store_true")

    sub.add_parser("verify", help="Проверить свежесть всех локальных кэшей.")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "ingest":
            result = ingest(args.source_id, force=args.force)
        elif args.command == "select":
            result = select(args.source_id, args.query, args.token_budget, args.max_chunks, args.refresh)
        else:
            result = verify()
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
        return 0
    except (IngestionError, OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"ОШИБКА: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
