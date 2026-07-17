[CmdletBinding()]
param([switch]$Check)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$outputPath = Join-Path $root 'STATUS.md'
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Read-ProjectFile([string]$Relative) {
    $path = Join-Path $root $Relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Не найден обязательный источник статуса: $Relative"
    }
    return [System.IO.File]::ReadAllText($path)
}

function Normalize-Text([string]$Text) {
    return (($Text -replace "`r`n", "`n") -replace "`r", "`n").TrimEnd() + "`n"
}

function Get-YamlField([string]$Text, [string]$Name) {
    $match = [regex]::Match($Text, "(?m)^$([regex]::Escape($Name)):\s*(?<value>.*?)\s*$")
    if (-not $match.Success) { throw "В HANDOFF.md отсутствует свойство $Name." }
    $value = $match.Groups['value'].Value.Trim()
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
        ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        return $value.Substring(1, $value.Length - 2)
    }
    return $value
}

function Get-Section([string]$Text, [string]$Heading) {
    $pattern = "(?ms)^##\s+$([regex]::Escape($Heading))\s*\r?\n(?<body>.*?)(?=^##\s+|\z)"
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { throw "Не найден раздел '$Heading'." }
    return $match.Groups['body'].Value.Trim()
}

function Split-MarkdownRow([string]$Line) {
    $trimmed = $Line.Trim()
    if (-not $trimmed.StartsWith('|')) { return @() }
    $body = $trimmed.Substring(1)
    if ($body.EndsWith('|')) { $body = $body.Substring(0, $body.Length - 1) }
    return @([regex]::Split($body, '(?<!\\)\|') | ForEach-Object { $_.Trim() })
}

function Get-RegistryRows([string]$Text, [string]$Prefix) {
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in (($Text -replace "`r`n", "`n") -split "`n")) {
        $cells = @(Split-MarkdownRow $line)
        if ($cells.Count -gt 0 -and $cells[0] -match "^$([regex]::Escape($Prefix))-\d+$") {
            $rows.Add($cells)
        }
    }
    return @($rows)
}

function Clean-Cell([string]$Value) {
    return ([regex]::Replace($Value, '^<a\s+id=["''][^"'']+["'']\s*></a>\s*', '')).Trim()
}

function Get-ActiveCount([object[]]$Rows, [int]$StatusIndex) {
    return @($Rows | Where-Object {
            $_.Count -gt $StatusIndex -and
            (Clean-Cell ([string]$_[$StatusIndex])) -notmatch '^(Закрыт[ао]?|Принят[ао]?|Заверш[её]н[ао]?|Closed|Accepted|Done)$'
        }).Count
}

$config = (Read-ProjectFile 'PROJECT-CONFIG.json') | ConvertFrom-Json
$handoff = Read-ProjectFile 'HANDOFF.md'
$outcomes = Read-ProjectFile 'OUTCOMES.md'
$controls = Read-ProjectFile 'CONTROLS.md'
$questions = Read-ProjectFile 'OPEN-QUESTIONS.md'
$delivery = Read-ProjectFile 'docs/03-delivery.md'

$created = Get-YamlField $handoff 'created'
$updated = Get-YamlField $handoff 'updated'
$currentPosition = Get-Section $handoff '1. Текущая позиция'
$nextActions = Get-Section $handoff '5. Следующие действия'
$p0Section = Get-Section $questions 'P0 — блокирует ближайший контрольный рубеж'

$benefits = @(Get-RegistryRows $outcomes 'B')
$p0Questions = @(Get-RegistryRows $p0Section 'Q')
$risks = @(Get-RegistryRows $controls 'R')
$issues = @(Get-RegistryRows $controls 'I')
$dependencies = @(Get-RegistryRows $controls 'X')
$changes = @(Get-RegistryRows $controls 'C')
$milestones = @(Get-RegistryRows $delivery 'G')

$milestoneSummary = 'Не задан'
if ($milestones.Count -gt 0) {
    $milestone = $milestones[0]
    $milestoneId = Clean-Cell ([string]$milestone[0])
    $milestoneName = if ($milestone.Count -gt 1) { Clean-Cell ([string]$milestone[1]) } else { 'Без названия' }
    $milestoneStatus = if ($milestone.Count -gt 0) { Clean-Cell ([string]$milestone[$milestone.Count - 1]) } else { 'Не задан' }
    $milestoneSummary = "[$milestoneId](./docs/03-delivery.md#$($milestoneId.ToLowerInvariant())) — $milestoneName ($milestoneStatus)"
}

$workSystem = [string]$config.workSystem.type
if (-not [string]::IsNullOrWhiteSpace([string]$config.workSystem.url)) {
    $workSystem = "[$workSystem]($($config.workSystem.url))"
}

$limitations = [System.Collections.Generic.List[string]]::new()
if ([string]$config.workSystem.type -eq 'not-configured') { $limitations.Add('Рабочая система не настроена.') }
if ($benefits.Count -eq 0) { $limitations.Add('Не зарегистрирована ни одна измеримая выгода.') }
if ($null -eq $config.tolerances.scheduleDays -and $null -eq $config.tolerances.costVariancePercent) {
    $limitations.Add('Допуски по сроку и стоимости не заданы.')
}
if ($p0Questions.Count -gt 0) { $limitations.Add("Открытых вопросов P0: $($p0Questions.Count).") }
if ($limitations.Count -eq 0) { $limitations.Add('Существенные ограничения среза не обнаружены.') }

$lines = [System.Collections.Generic.List[string]]::new()
foreach ($line in @(
        '---',
        'title: Исполнительный статус проекта',
        'aliases:',
        '  - Статус проекта',
        'type: generated-status',
        'status: generated',
        "created: `"$created`"",
        "updated: `"$updated`"",
        'tags:',
        "  - `"$($config.projectSlug)`"",
        '  - project/status',
        '---',
        '',
        '# Исполнительный статус проекта',
        '',
        '> Этот файл создаётся автоматически. Изменяйте канонические документы и запускайте `pwsh ./scripts/build-status.ps1`.',
        '',
        '[← Главная](README.md) | [Передача контекста](HANDOFF.md) | [Выгоды](OUTCOMES.md) | [Управляющие записи](CONTROLS.md)',
        '',
        '## Режим управления',
        '',
        '| Параметр | Значение |',
        '|---|---|',
        "| Профиль | $($config.managementProfile) |",
        "| Подход к поставке | $($config.deliveryApproach) |",
        "| Рабочая система | $workSystem |",
        "| Классификация данных | $($config.dataClassification) |",
        "| Уровень контроля ИИ | $($config.aiGovernanceLevel) |",
        '',
        '## Текущая позиция',
        '',
        $currentPosition,
        '',
        '## Контрольный срез',
        '',
        '| Показатель | Значение |',
        '|---|---|',
        "| Ближайший рубеж | $milestoneSummary |",
        "| Записей о выгодах | $($benefits.Count) |",
        "| Вопросов P0 | $($p0Questions.Count) |",
        "| Активных рисков и возможностей | $(Get-ActiveCount $risks 10) |",
        "| Открытых проблем | $(Get-ActiveCount $issues 6) |",
        "| Активных зависимостей | $(Get-ActiveCount $dependencies 7) |",
        "| Запросов на изменение | $(Get-ActiveCount $changes 7) |",
        '',
        '## Следующие действия',
        '',
        $nextActions,
        '',
        '## Ограничения среза',
        ''
    )) { $lines.Add([string]$line) }
foreach ($limitation in $limitations) { $lines.Add("- $limitation") }

$generated = Normalize-Text ($lines -join "`n")
if ($Check) {
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        throw 'STATUS.md отсутствует. Выполните build-status.ps1 без -Check.'
    }
    $current = Normalize-Text ([System.IO.File]::ReadAllText($outputPath))
    if ($current -cne $generated) {
        throw 'STATUS.md устарел. Пересоберите его командой pwsh ./scripts/build-status.ps1.'
    }
    Write-Host 'Проверка пройдена: STATUS.md актуален.'
    return
}

$temporary = "$outputPath.tmp-$([Guid]::NewGuid().ToString('N'))"
try {
    [System.IO.File]::WriteAllText($temporary, $generated, $utf8)
    [System.IO.File]::Move($temporary, $outputPath, $true)
}
finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}
Write-Host 'Собран файл STATUS.md.'
