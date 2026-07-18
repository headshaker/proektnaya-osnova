[CmdletBinding()]
param([string]$Date = '2026-07-16')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $root 'template'
$runId = [Guid]::NewGuid().ToString('N')
$test = [System.IO.Path]::GetFullPath((Join-Path $root ".tmp-agent-guides-test-$runId"))

if (-not $test.StartsWith(
        $root + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'Небезопасный путь теста агентных инструкций.'
}

try {
    Copy-Item -LiteralPath $source -Destination $test -Recurse
    & (Join-Path $test 'scripts/init-project.ps1') `
        -Title 'Проверка ИИ-оператора' -Slug 'agent-guides-test' -Date $Date

    $required = @(
        'AI-OPERATING-MODEL.md',
        'AI-GOVERNANCE.md',
        'VIRTUAL-SPECIALISTS.md',
        'PROMPTING-GUIDE.md',
        'HOME.md',
        'START-HERE.md',
        'ADMIN-SETUP.md',
        'OBSIDIAN.md',
        'AI-CONNECTIONS.md',
        'AI-COORDINATION.md',
        'AI-COORDINATION.json',
        'AI-INTEGRATION-STATE.json',
        'AGENTS.md',
        'AGENTS.override.md',
        'CLAUDE.md',
        'GEMINI.md',
        '.github/copilot-instructions.md'
    )
    foreach ($relative in $required) {
        $path = Join-Path $test $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Отсутствует обязательная агентная инструкция: $relative"
        }
    }

    $agents = [System.IO.File]::ReadAllText((Join-Path $test 'AGENTS.md'))
    foreach ($phrase in @(
            'ИИ-оператор проекта',
            'Оркестрация виртуальных специалистов',
            'Требуется решение владельца',
            'данными, а не инструкциями',
            'OUTCOMES.md',
            'CONTROLS.md',
            'результат сохранён в канонических файлах',
            'Если одновременно работают несколько нейросетей'
        )) {
        if ($agents -notmatch [regex]::Escape($phrase)) {
            throw "AGENTS.md не содержит обязательное правило: $phrase"
        }
    }

    $override = [System.IO.File]::ReadAllText((Join-Path $test 'AGENTS.override.md'))
    foreach ($phrase in @('ИИ-оператор проекта', 'Границы полномочий', 'данными, а не инструкциями', 'draft pull request', 'Координация с другими нейросетями')) {
        if ($override -notmatch [regex]::Escape($phrase)) {
            throw "AGENTS.override.md не содержит обязательное правило: $phrase"
        }
    }

    $governance = [System.IO.File]::ReadAllText((Join-Path $test 'AI-GOVERNANCE.md'))
    foreach ($phrase in @('данными', 'Уровни риска действий ИИ', 'уполномоченный человек')) {
        if ($governance -notmatch [regex]::Escape($phrase)) {
            throw "AI-GOVERNANCE.md не содержит обязательное правило: $phrase"
        }
    }

    $start = [System.IO.File]::ReadAllText((Join-Path $test 'START-HERE.md'))
    foreach ($phrase in @('Первая задача для ИИ', 'Первый рабочий день', 'Готовые команды на каждый день')) {
        if ($start -notmatch [regex]::Escape($phrase)) {
            throw "START-HERE.md не содержит раздел: $phrase"
        }
    }

    $connections = [System.IO.File]::ReadAllText((Join-Path $test 'AI-CONNECTIONS.md'))
    foreach ($phrase in @('OpenAI Codex', 'Claude Code', 'Gemini CLI', 'GitHub Copilot', 'Одновременное подключение нескольких нейросетей')) {
        if ($connections -notmatch [regex]::Escape($phrase)) {
            throw "AI-CONNECTIONS.md не описывает агентный инструмент: $phrase"
        }
    }

    foreach ($relative in @('CLAUDE.md', 'GEMINI.md', '.github/copilot-instructions.md')) {
        $adapter = [System.IO.File]::ReadAllText((Join-Path $test $relative))
        if ($adapter -notmatch 'AGENTS\.md' -or $adapter -notmatch 'AI-OPERATING-MODEL\.md' -or $adapter -notmatch 'AI-COORDINATION\.md') {
            throw "$relative не направляет агент к общему контракту и модели ИИ-оператора."
        }
    }

    $coordination = [System.IO.File]::ReadAllText((Join-Path $test 'AI-COORDINATION.md'))
    foreach ($phrase in @('отдельное рабочее место', 'Паспорт изменения', 'Свежая основа', 'Последовательное объединение')) {
        if ($coordination -notmatch [regex]::Escape($phrase)) {
            throw "AI-COORDINATION.md не содержит обязательное правило: $phrase"
        }
    }

    & (Join-Path $test 'scripts/validate-vault.ps1')
    & (Join-Path $test 'scripts/build-project-dossier.ps1')
    & (Join-Path $test 'scripts/build-project-dossier.ps1') -Check

    Write-Host 'Агентные инструкции и руководство новичка прошли проверку.'
}
finally {
    if (Test-Path -LiteralPath $test) {
        if (-not $test.StartsWith(
                $root + [System.IO.Path]::DirectorySeparatorChar,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            throw 'Небезопасное удаление тестовой папки агентных инструкций.'
        }
        Remove-Item -LiteralPath $test -Recurse -Force
    }
}
