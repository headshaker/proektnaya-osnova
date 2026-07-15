---
title: Работа с базой знаний
aliases: []
type: guide
status: active
created: "{{DATE}}"
updated: "{{DATE}}"
tags:
  - "{{PROJECT_SLUG}}"
  - project/knowledge-base
---

# Работа с базой знаний

[← Главная](README.md) | [Передача контекста](HANDOFF.md)

База использует обычный Markdown, относительные ссылки и YAML-свойства. Она открывается в Obsidian без обязательных community plugins и остаётся пригодной для GitHub и редакторов кода.

## Структура

- корень — управление, контекст и реестры;
- `docs` — канонические тематические заметки;
- `_inbox` — необработанные материалы;
- `_attachments` — исходные вложения;
- `_templates` — шаблоны заметок;
- `scripts` — воспроизводимые проверки и сборка.

## Новая заметка

1. Создать черновик в `_inbox`.
2. Применить `_templates/Project note.md`.
3. Определить канонический предмет и владельца содержания.
4. Добавить входящую ссылку из карты или профильной заметки.
5. После обработки перенести файл в `docs` или подходящий раздел.

## Обязательные свойства

`title`, `aliases`, `type`, `status`, `created`, `updated`, `tags`. Допустимые статусы: `draft`, `active`, `approved`, `archived`; `approved` используется только после явного согласования.

## Команды контроля

    pwsh ./scripts/validate-vault.ps1
    pwsh ./scripts/build-project-dossier.ps1
    pwsh ./scripts/build-project-dossier.ps1 --check
    pwsh ./scripts/rotate-history.ps1
    pwsh ./scripts/prepare-commit-digest.ps1
    python scripts/context-budget.py

`PROJECT.md` создаётся автоматически и вручную не редактируется.

Команды безопасного добавления решений, вопросов и источников описаны в [ежедневном протоколе](DAILY-WORK.md). Примеры глубины управления приведены в [рабочих профилях](WORK-PROFILES.md).
