[CmdletBinding()]
param(
    [string]$Date = '2026-07-15'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $root 'template'
$runId = [Guid]::NewGuid().ToString('N')
$test = [System.IO.Path]::GetFullPath((Join-Path $root ".tmp-daily-work-test-$runId"))
$outside = [System.IO.Path]::GetFullPath((Join-Path $root ".tmp-daily-work-outside-$runId.md"))
$jobs = [System.Collections.Generic.List[object]]::new()

function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Description) {
    try {
        & $Action 2>&1 | Out-Null
    }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "Негативная проверка '$Description' завершилась неожиданной ошибкой: $($_.Exception.Message)"
        }
        Write-Host "Негативная проверка пройдена: $Description."
        return
    }
    throw "Негативная проверка не сработала: $Description."
}

function Assert-Contains([string]$Path, [string]$Pattern, [string]$Description) {
    $text = [System.IO.File]::ReadAllText($Path)
    if ($text -notmatch $Pattern) { throw "Не выполнена проверка: $Description." }
}

if (-not $test.StartsWith(
        $root + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'Небезопасный путь тестовой папки ежедневной работы.'
}

try {
    Copy-Item -LiteralPath $source -Destination $test -Recurse
    $copiedProjectState = Join-Path $test '.project'
    if (Test-Path -LiteralPath $copiedProjectState) {
        Remove-Item -LiteralPath $copiedProjectState -Recurse -Force
    }
    & (Join-Path $test 'scripts/init-project.ps1') -Title 'Проверка ежедневной работы' -Slug 'daily-work-test' -Date $Date

    $addEntry = Join-Path $test 'scripts/add-entry.ps1'
    & $addEntry decision -Title 'Использовать проверяемые записи' -Date $Date `
        -Context 'Сравнивались ручной и автоматизированный способы' `
        -Consequences 'ID назначается автоматически' -Basis 'Проверка v0.2' `
        -Review 'При изменении формата реестра'
    & $addEntry question -Title 'Кто проверяет ежедневный дайджест?' -Date $Date -Priority P2 `
        -Importance 'Нужен явный контроль' -Owner 'Владелец проекта' `
        -NextStep 'Назначить проверяющего' -Closure 'Проверяющий назначен' -Due 'Не задан'
    & $addEntry source -Title 'https://example.org/specification' -Date $Date `
        -Publisher 'Пример издателя' -Evidence 'Формат проверочной записи' `
        -Scope 'Только автоматический тест' -Verified $Date -Recheck 'Не требуется'

    Assert-Contains (Join-Path $test 'DECISIONS.md') '(?m)^\| D-002 \| 2026-07-15 \| Использовать проверяемые записи \|' 'добавлено решение D-002'
    Assert-Contains (Join-Path $test 'OPEN-QUESTIONS.md') '(?m)^\| Q-002 \| Кто проверяет ежедневный дайджест\?' 'добавлен вопрос Q-002'
    Assert-Contains (Join-Path $test 'SOURCES.md') '(?m)^\| S-002 \| https://example\.org/specification \|' 'добавлен источник S-002'

    Assert-Throws {
        & $addEntry decision -Title 'Повреждение | таблицы' -Date $Date
    } 'вертикальную черту' 'разделитель Markdown-таблицы во вводе отклоняется'

    foreach ($round in 1..3) {
        $roundJobs = [System.Collections.Generic.List[object]]::new()
        foreach ($number in 1..6) {
            $job = Start-Job -ScriptBlock {
                param($ScriptPath, $Round, $Index, $EntryDate)
                & $ScriptPath question -Title "Параллельный вопрос $Round-$Index" -Date $EntryDate `
                    -Priority P1 -Importance 'Проверка блокировки' -Owner 'Тест' `
                    -NextStep 'Проверить ID' -Closure 'ID уникален' -Due 'Не задан'
            } -ArgumentList $addEntry, $round, $number, $Date
            $jobs.Add($job)
            $roundJobs.Add($job)
        }
        $roundJobs | Wait-Job | Out-Null
        $failedJobs = @($roundJobs | Where-Object State -ne 'Completed')
        $jobOutput = @($roundJobs | Receive-Job -ErrorAction Continue 2>&1)
        if ($failedJobs.Count -gt 0) {
            throw "Параллельное добавление завершилось ошибкой в раунде ${round}: $($jobOutput -join '; ')"
        }
    }
    $questionIds = @([regex]::Matches(
            [System.IO.File]::ReadAllText((Join-Path $test 'OPEN-QUESTIONS.md')),
            '(?m)^\|\s*(Q-\d+)\s*\|'
        ) | ForEach-Object { $_.Groups[1].Value })
    if (($questionIds | Sort-Object -Unique).Count -ne $questionIds.Count) {
        throw 'Параллельное добавление создало повторяющиеся ID вопросов.'
    }

    $notePath = Join-Path $test 'docs/05-link-test.md'
    $noteWithoutLinks = @"
---
title: Проверка связей
aliases: []
type: note
status: draft
created: "$Date"
updated: "$Date"
tags:
  - daily-work-test
---

# Проверка связей

Заметка без ссылок.
"@
    [System.IO.File]::WriteAllText($notePath, $noteWithoutLinks.TrimStart() + "`n", [System.Text.UTF8Encoding]::new($false))
    Assert-Throws {
        & (Join-Path $test 'scripts/validate-vault.ps1')
    } 'нет исходящей локальной ссылки' 'заметка без исходящей ссылки отклоняется'

    [System.IO.File]::WriteAllText(
        $notePath,
        $noteWithoutLinks.TrimStart() + "`n[Главная](../README.md)`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    Assert-Throws {
        & (Join-Path $test 'scripts/validate-vault.ps1')
    } 'нет входящей локальной ссылки' 'заметка без входящей ссылки отклоняется'

    $readmePath = Join-Path $test 'README.md'
    $readmeOriginal = [System.IO.File]::ReadAllText($readmePath)
    [System.IO.File]::WriteAllText(
        $readmePath,
        $readmeOriginal + "`n[Проверка связей](docs/05-link-test.md)`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    & (Join-Path $test 'scripts/validate-vault.ps1')
    [System.IO.File]::WriteAllText($readmePath, $readmeOriginal, [System.Text.UTF8Encoding]::new($false))
    Remove-Item -LiteralPath $notePath -Force

    $handoffPath = Join-Path $test 'HANDOFF.md'
    $handoff = [System.IO.File]::ReadAllText($handoffPath)
    $handoff = $handoff.Replace(
        "- $Date`: создана начальная структура базы знаний.",
        "- 2026-06-01: устаревшая оперативная запись.`n- 2026-07-02: запись на границе окна.`n- $Date`: создана начальная структура базы знаний."
    )
    [System.IO.File]::WriteAllText($handoffPath, $handoff, [System.Text.UTF8Encoding]::new($false))
    $rotate = Join-Path $test 'scripts/rotate-history.ps1'
    & $rotate -Date $Date -Days 14
    Assert-Contains (Join-Path $test 'CHANGELOG.md') '(?m)^- 2026-06-01: устаревшая оперативная запись\.$' 'старая запись перенесена в changelog'
    Assert-Contains $handoffPath '(?m)^- 2026-07-02: запись на границе окна\.$' 'граничная запись сохранена в HANDOFF'
    if ([System.IO.File]::ReadAllText($handoffPath) -match '2026-06-01') {
        throw 'Старая запись осталась в HANDOFF.md после ротации.'
    }
    & $rotate -Date $Date -Days 14
    $archiveMatches = [regex]::Matches(
        [System.IO.File]::ReadAllText((Join-Path $test 'CHANGELOG.md')),
        '(?m)^- 2026-06-01: устаревшая оперативная запись\.$'
    )
    if ($archiveMatches.Count -ne 1) { throw 'Повторная ротация продублировала архивную запись.' }

    $digest = Join-Path $test 'scripts/prepare-commit-digest.ps1'
    $digestDate = [DateTime]::ParseExact(
        $Date,
        'yyyy-MM-dd',
        [System.Globalization.CultureInfo]::InvariantCulture
    ).AddDays(1).ToString('yyyy-MM-dd')
    & $digest -Date $digestDate -ChangedFile @('DECISIONS.md', 'OPEN-QUESTIONS.md') `
        -Check @('validate-vault: успешно', 'build-project-dossier --check: успешно')
    $digestPath = Join-Path $test '.project/commit-digest.md'
    Assert-Contains $digestPath ([regex]::Escape("Дайджест перед коммитом — $digestDate")) 'дайджест использует текущую, а не начальную дату проекта'
    Assert-Contains $digestPath 'DECISIONS\.md' 'дайджест содержит изменённый файл'
    Assert-Contains $digestPath 'validate-vault: успешно' 'дайджест содержит результат проверки'
    Assert-Throws {
        & $digest -Date $digestDate -ChangedFile 'README.md'
    } 'уже существует' 'дайджест не заменяется без -Force'
    Assert-Throws {
        & $digest -Date $digestDate -ChangedFile 'README.md' -OutputPath $outside
    } 'выходит за пределы проекта' 'дайджест нельзя записать за пределы проекта'

    & (Join-Path $test 'scripts/build-project-dossier.ps1')
    & (Join-Path $test 'scripts/build-project-dossier.ps1') -Check
    & (Join-Path $test 'scripts/validate-vault.ps1')
    Write-Host 'Проверка ежедневной работы пройдена.'
}
finally {
    foreach ($job in $jobs) {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $test) {
        if (-not $test.StartsWith(
                $root + [System.IO.Path]::DirectorySeparatorChar,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            throw 'Небезопасное удаление тестовой папки ежедневной работы.'
        }
        Remove-Item -LiteralPath $test -Recurse -Force
    }
    if (Test-Path -LiteralPath $outside) {
        Remove-Item -LiteralPath $outside -Force
    }
}
