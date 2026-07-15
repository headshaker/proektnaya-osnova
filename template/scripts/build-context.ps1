[CmdletBinding()]
param(
    [string]$Profile,
    [string[]]$IncludeId = @(),
    [string[]]$Query = @(),
    [ValidateRange(512, 1000000)]
    [int]$TokenBudget,
    [string]$OutputPath = '.project/context/context.md',
    [string]$ReportPath = '.project/context/context-report.json',
    [switch]$Export,
    [switch]$Force,
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd([char[]]@('\', '/'))
$profilesPath = Join-Path $root 'CONTEXT-PROFILES.json'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$charsPerToken = 2.2
$registryPaths = @('DECISIONS.md', 'OPEN-QUESTIONS.md', 'SOURCES.md')
$handoffSections = @(
    '1. Текущая позиция',
    '2. Что изменено (последние 14 дней)',
    '3. Действующие решения, которые нельзя откатывать молча',
    '4. Главные блокирующие условия',
    '5. Следующие действия',
    '6. Что остаётся неподтверждённым',
    '7. Перед завершением работы'
)

function Normalize-Text([string]$Text) {
    if ($null -eq $Text) { return '' }
    return (($Text -replace "`r`n", "`n") -replace "`r", "`n")
}

function Get-SafePath([string]$Relative, [string]$Label, [switch]$LocalContextOnly, [switch]$ExportTarget) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [System.IO.Path]::IsPathRooted($Relative)) {
        throw "$Label должен быть относительным путём внутри проекта: $Relative"
    }
    $normalized = $Relative.Replace('\', '/')
    if ($normalized -match '(^|/)\.\.(/|$)') { throw "$Label выходит за пределы проекта: $Relative" }
    if ($LocalContextOnly -and $normalized -notmatch '^\.project/context(?:/|$)') {
        throw "$Label в локальном режиме должен находиться внутри .project/context: $Relative"
    }
    if ($ExportTarget -and $normalized -notmatch '^(?:exports|\.project/context)(?:/|$)') {
        throw "$Label в режиме экспорта должен находиться внутри exports или .project/context: $Relative"
    }

    $candidate = [System.IO.Path]::GetFullPath((Join-Path $root $Relative))
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if (-not $candidate.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, $comparison)) {
        throw "$Label выходит за пределы проекта: $Relative"
    }

    $current = $root
    foreach ($segment in ($normalized -split '/')) {
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Label проходит через ссылку или точку повторного анализа: $Relative"
            }
        }
    }
    return $candidate
}

function Write-AtomicUtf8([string]$Path, [string]$Text) {
    $directory = Split-Path -Parent $Path
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($temporary, (Normalize-Text $Text).TrimEnd() + "`n", $utf8)
        [System.IO.File]::Move($temporary, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Estimate-Tokens([string]$Text) {
    return [int][Math]::Ceiling($Text.Length / $charsPerToken)
}

function Split-MarkdownRow([string]$Line) {
    $value = $Line.Trim()
    if (-not $value.StartsWith('|') -or -not $value.EndsWith('|')) { return @() }
    $cells = [System.Collections.Generic.List[string]]::new()
    $builder = [System.Text.StringBuilder]::new()
    $escaped = $false
    for ($i = 1; $i -lt $value.Length - 1; $i++) {
        $character = $value[$i]
        if ($escaped) {
            [void]$builder.Append($character)
            $escaped = $false
        }
        elseif ($character -eq '\') {
            [void]$builder.Append($character)
            $escaped = $true
        }
        elseif ($character -eq '|') {
            $cells.Add($builder.ToString().Trim())
            [void]$builder.Clear()
        }
        else {
            [void]$builder.Append($character)
        }
    }
    $cells.Add($builder.ToString().Trim())
    return @($cells)
}

function Get-RegistryRows([string]$Relative) {
    $path = Get-SafePath $Relative "Реестр $Relative"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Реестр отсутствует: $Relative" }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in ((Normalize-Text ([System.IO.File]::ReadAllText($path))) -split "`n")) {
        $cells = @(Split-MarkdownRow $line)
        if ($cells.Count -eq 0 -or $cells[0] -notmatch '^(?:D|A|Q|S)-\d+$') { continue }
        $rows.Add([pscustomobject]@{ Path = $Relative; Id = $cells[0]; Text = $line.Trim(); Search = ($cells -join ' ') })
    }
    return @($rows)
}

if (-not (Test-Path -LiteralPath $profilesPath -PathType Leaf)) {
    throw 'Не найден CONTEXT-PROFILES.json.'
}
$configuration = [System.IO.File]::ReadAllText($profilesPath) | ConvertFrom-Json
if ($configuration.schemaVersion -ne 1) { throw 'Поддерживается только schemaVersion = 1 профилей контекста.' }
if ([string]::IsNullOrWhiteSpace($Profile)) { $Profile = [string]$configuration.defaultProfile }
$selectedProfile = @($configuration.profiles | Where-Object name -CEQ $Profile)
if ($selectedProfile.Count -ne 1) {
    $available = @($configuration.profiles | ForEach-Object name) -join ', '
    throw "Неизвестный профиль '$Profile'. Доступны: $available."
}
$selectedProfile = $selectedProfile[0]
if ($selectedProfile.tokenBudget -lt 512 -or $selectedProfile.reserveTokens -lt 0 -or
    $selectedProfile.reserveTokens -ge $selectedProfile.tokenBudget) {
    throw "Профиль '$Profile' содержит некорректный бюджет."
}
if (-not $PSBoundParameters.ContainsKey('TokenBudget')) { $TokenBudget = [int]$selectedProfile.tokenBudget }
$reserveTokens = [Math]::Min([int]$selectedProfile.reserveTokens, [int][Math]::Floor($TokenBudget * 0.25))
$contentBudget = $TokenBudget - $reserveTokens

$outputFull = Get-SafePath $OutputPath 'OutputPath' -LocalContextOnly:(-not $Export) -ExportTarget:$Export
$reportFull = Get-SafePath $ReportPath 'ReportPath' -LocalContextOnly:(-not $Export) -ExportTarget:$Export
if ($outputFull -ceq $reportFull) { throw 'OutputPath и ReportPath должны различаться.' }
if ($Export -and -not $Force) {
    foreach ($target in @($outputFull, $reportFull)) {
        if (Test-Path -LiteralPath $target) {
            throw "Экспорт уже существует: $target. Для замены укажите -Force."
        }
    }
}

$normalizedIds = @($IncludeId |
    ForEach-Object { $_ -split ',' } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_.Trim().ToUpperInvariant() } |
    Select-Object -Unique)
foreach ($id in $normalizedIds) {
    if ($id -notmatch '^(?:D|A|Q|S)-\d+$') { throw "Некорректный ID для адресной загрузки: $id" }
}
$normalizedQueries = @($Query |
    ForEach-Object { $_ -split ',' } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object Trim |
    Select-Object -Unique)
$targeted = $normalizedIds.Count -gt 0 -or $normalizedQueries.Count -gt 0

$allRows = [System.Collections.Generic.List[object]]::new()
foreach ($registry in $registryPaths) {
    foreach ($row in @(Get-RegistryRows $registry)) { $allRows.Add($row) }
}
Write-Verbose ("Загружено строк реестров: {0}; ID: {1}" -f $allRows.Count, (($allRows | ForEach-Object Id) -join ', '))
$selectedRows = [System.Collections.Generic.List[object]]::new()
$seenRows = @{}
$matchedIds = [System.Collections.Generic.List[string]]::new()
$matchedQueries = [System.Collections.Generic.List[string]]::new()

if ($targeted) {
    foreach ($row in $allRows) {
        $include = $false
        Write-Verbose ("Проверяется {0}: запрошен={1}" -f $row.Id, ($normalizedIds -contains $row.Id))
        if ($normalizedIds -contains $row.Id) {
            $include = $true
            if (-not $matchedIds.Contains($row.Id)) { $matchedIds.Add($row.Id) }
        }
        foreach ($term in $normalizedQueries) {
            if ($row.Search.IndexOf($term, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $include = $true
                if (-not $matchedQueries.Contains($term)) { $matchedQueries.Add($term) }
            }
        }
        $key = "$($row.Path):$($row.Id)"
        if ($include -and -not $seenRows.ContainsKey($key)) { $seenRows[$key] = $true; $selectedRows.Add($row) }
    }
}
else {
    foreach ($registry in $registryPaths) {
        $limitProperty = $selectedProfile.registryLimits.PSObject.Properties[$registry]
        $limit = if ($null -eq $limitProperty) { 0 } else { [int]$limitProperty.Value }
        foreach ($row in @($allRows | Where-Object Path -CEQ $registry | Select-Object -First $limit)) {
            $selectedRows.Add($row)
        }
    }
}

$documentPieces = [System.Collections.Generic.List[object]]::new()
foreach ($relative in @($selectedProfile.documents)) {
    $path = Get-SafePath ([string]$relative) "Документ профиля '$Profile'"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $documentPieces.Add([pscustomobject]@{ Path = [string]$relative; Missing = $true; Text = ''; Tokens = 0 })
        continue
    }
    $content = (Normalize-Text ([System.IO.File]::ReadAllText($path))).Trim()
    $piece = "## Документ: $relative`n`n$content`n"
    $documentPieces.Add([pscustomobject]@{ Path = [string]$relative; Missing = $false; Text = $piece; Tokens = (Estimate-Tokens $piece) })
}

$registryPieces = [System.Collections.Generic.List[object]]::new()
foreach ($registry in $registryPaths) {
    $rows = @($selectedRows | Where-Object Path -CEQ $registry)
    if ($rows.Count -eq 0) { continue }
    $text = "## Адресный срез: $registry`n`n" + (($rows | ForEach-Object Text) -join "`n") + "`n"
    $registryPieces.Add([pscustomobject]@{ Path = $registry; Text = $text; Tokens = (Estimate-Tokens $text) })
}

$includedDocuments = [System.Collections.Generic.List[string]]::new()
$missingDocuments = [System.Collections.Generic.List[string]]::new()
$omittedDocuments = [System.Collections.Generic.List[string]]::new()
$includedRegistryIds = [System.Collections.Generic.List[string]]::new()
$builder = [System.Text.StringBuilder]::new()
$mode = if ($Export) { 'export' } else { 'local' }
[void]$builder.AppendLine('# Пакет контекста')
[void]$builder.AppendLine()
[void]$builder.AppendLine("- Профиль: $Profile")
[void]$builder.AppendLine("- Режим: $mode")
[void]$builder.AppendLine("- Полный бюджет: $TokenBudget")
[void]$builder.AppendLine("- Резерв ответа: $reserveTokens")
[void]$builder.AppendLine('- Передача содержимого выполнена: нет')
[void]$builder.AppendLine()
[void]$builder.AppendLine('> Пакет создан локальным скриптом без сетевых запросов. Проверьте его перед ручной передачей.')

$usedTokens = Estimate-Tokens $builder.ToString()
foreach ($piece in $documentPieces) {
    if ($piece.Missing) { $missingDocuments.Add($piece.Path); continue }
    if ($usedTokens + $piece.Tokens -gt $contentBudget) { $omittedDocuments.Add($piece.Path); continue }
    [void]$builder.AppendLine()
    [void]$builder.Append($piece.Text)
    $usedTokens += $piece.Tokens
    $includedDocuments.Add($piece.Path)
}
foreach ($piece in $registryPieces) {
    if ($usedTokens + $piece.Tokens -gt $contentBudget) {
        foreach ($row in @($selectedRows | Where-Object Path -CEQ $piece.Path)) { $omittedDocuments.Add("$($piece.Path):$($row.Id)") }
        continue
    }
    [void]$builder.AppendLine()
    [void]$builder.Append($piece.Text)
    $usedTokens += $piece.Tokens
    foreach ($row in @($selectedRows | Where-Object Path -CEQ $piece.Path)) { $includedRegistryIds.Add($row.Id) }
}

$handoffPath = Get-SafePath 'HANDOFF.md' 'HANDOFF.md'
$handoffText = if (Test-Path -LiteralPath $handoffPath -PathType Leaf) { Normalize-Text ([System.IO.File]::ReadAllText($handoffPath)) } else { '' }
$presentHandoffSections = [System.Collections.Generic.List[string]]::new()
$missingHandoffSections = [System.Collections.Generic.List[string]]::new()
foreach ($section in $handoffSections) {
    if ($handoffText -match ('(?m)^##\s+' + [regex]::Escape($section) + '\s*$')) { $presentHandoffSections.Add($section) }
    else { $missingHandoffSections.Add($section) }
}

$missingIds = @($normalizedIds | Where-Object { -not $includedRegistryIds.Contains($_) })
$missingQueries = @($normalizedQueries | Where-Object { -not $matchedQueries.Contains($_) })
$checksTotal = $documentPieces.Count + $handoffSections.Count + $normalizedIds.Count + $normalizedQueries.Count
$checksPassed = $includedDocuments.Count + $presentHandoffSections.Count + ($normalizedIds.Count - $missingIds.Count) + ($normalizedQueries.Count - $missingQueries.Count)
$score = if ($checksTotal -eq 0) { 100 } else { [int][Math]::Round(100 * $checksPassed / $checksTotal) }
$complete = $missingDocuments.Count -eq 0 -and $omittedDocuments.Count -eq 0 -and
    $missingIds.Count -eq 0 -and $missingQueries.Count -eq 0 -and $missingHandoffSections.Count -eq 0

$report = [ordered]@{
    schemaVersion = 1
    profile = $Profile
    mode = $mode
    localOnly = -not [bool]$Export
    transmissionPerformed = $false
    networkRequests = 0
    tokenBudget = $TokenBudget
    reserveTokens = $reserveTokens
    contentBudget = $contentBudget
    estimatedTokens = $usedTokens
    completenessScore = $score
    complete = $complete
    requiredDocuments = @($documentPieces.Path)
    includedDocuments = @($includedDocuments)
    missingDocuments = @($missingDocuments)
    omittedByBudget = @($omittedDocuments)
    requestedIds = @($normalizedIds)
    includedRegistryIds = @($includedRegistryIds | Select-Object -Unique)
    missingRequestedIds = @($missingIds)
    queries = @($normalizedQueries)
    unmatchedQueries = @($missingQueries)
    presentHandoffSections = @($presentHandoffSections)
    missingHandoffSections = @($missingHandoffSections)
}

Write-AtomicUtf8 $outputFull $builder.ToString()
Write-AtomicUtf8 $reportFull ($report | ConvertTo-Json -Depth 8)
Write-Host "Пакет контекста создан: $OutputPath (~$usedTokens токенов, полнота $score%)."
Write-Host "Отчёт: $ReportPath"

if ($Check -and -not $complete) {
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($missingDocuments.Count -gt 0) { $reasons.Add('нет документов: ' + ($missingDocuments -join ', ')) }
    if ($omittedDocuments.Count -gt 0) { $reasons.Add('не вошли в бюджет: ' + ($omittedDocuments -join ', ')) }
    if ($missingIds.Count -gt 0) { $reasons.Add('не найдены ID: ' + ($missingIds -join ', ')) }
    if ($missingQueries.Count -gt 0) { $reasons.Add('нет совпадений: ' + ($missingQueries -join ', ')) }
    if ($missingHandoffSections.Count -gt 0) { $reasons.Add('неполный HANDOFF.md: ' + ($missingHandoffSections -join ', ')) }
    throw 'Пакет контекста неполон: ' + ($reasons -join '; ')
}
