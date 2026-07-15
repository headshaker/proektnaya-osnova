[CmdletBinding()]
param(
    [string]$Profile,
    [string[]]$IncludeId = @(),
    [string[]]$Query = @(),
    [string[]]$ExpandSource = @(),
    [string[]]$SourceQuery = @(),
    [ValidateRange(1024, 1000000)]
    [int]$TokenBudget,
    [ValidateRange(256, 500000)]
    [int]$SourceTokenBudget,
    [string]$OutputPath = '.project/context/ai-package.md',
    [string]$ReportPath = '.project/context/ai-package-report.json',
    [switch]$RefreshSources,
    [switch]$Export,
    [switch]$Force,
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd([char[]]@('\', '/'))
$profilesPath = Join-Path $root 'CONTEXT-PROFILES.json'
$sourceConfigPath = Join-Path $root 'SOURCE-INGESTION.json'
$contextBuilder = Join-Path $PSScriptRoot 'build-context.ps1'
$ingestionScript = Join-Path $PSScriptRoot 'source-ingestion.py'
$utf8 = [System.Text.UTF8Encoding]::new($false)

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

function Get-PythonCommand {
    foreach ($candidate in @('python', 'python3', 'py')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return [pscustomobject]@{
                Path = $command.Source
                Prefix = if ($candidate -eq 'py') { @('-3') } else { @() }
            }
        }
    }
    throw 'Не найден Python 3.10 или новее.'
}

foreach ($required in @($profilesPath, $sourceConfigPath, $contextBuilder, $ingestionScript)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Не найден обязательный файл: $required" }
}

$profiles = [System.IO.File]::ReadAllText($profilesPath) | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($Profile)) { $Profile = [string]$profiles.defaultProfile }
$selectedProfile = @($profiles.profiles | Where-Object name -CEQ $Profile)
if ($selectedProfile.Count -ne 1) { throw "Неизвестный профиль контекста: $Profile" }
$selectedProfile = $selectedProfile[0]
if (-not $PSBoundParameters.ContainsKey('TokenBudget')) { $TokenBudget = [int]$selectedProfile.tokenBudget }

$sourceConfiguration = [System.IO.File]::ReadAllText($sourceConfigPath) | ConvertFrom-Json
$sourceProfileProperty = $sourceConfiguration.profiles.PSObject.Properties[$Profile]
if ($null -eq $sourceProfileProperty) { throw "Для профиля '$Profile' не задан бюджет источников." }
$sourceProfile = $sourceProfileProperty.Value
if (-not $PSBoundParameters.ContainsKey('SourceTokenBudget')) {
    $SourceTokenBudget = [int]$sourceProfile.sourceTokenBudget
}
if ($SourceTokenBudget -ge $TokenBudget - 512) {
    throw 'Бюджет источников должен оставлять не менее 512 токенов базовому контексту.'
}
$baseTokenBudget = $TokenBudget - $SourceTokenBudget

$outputFull = Get-SafePath $OutputPath 'OutputPath' -LocalContextOnly:(-not $Export) -ExportTarget:$Export
$reportFull = Get-SafePath $ReportPath 'ReportPath' -LocalContextOnly:(-not $Export) -ExportTarget:$Export
if ($outputFull -ceq $reportFull) { throw 'OutputPath и ReportPath должны различаться.' }
if ($Export -and -not $Force) {
    foreach ($target in @($outputFull, $reportFull)) {
        if (Test-Path -LiteralPath $target) { throw "Экспорт уже существует: $target. Для замены укажите -Force." }
    }
}

$sourceIds = @($ExpandSource |
    ForEach-Object { $_ -split ',' } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_.Trim().ToUpperInvariant() } |
    Select-Object -Unique)
foreach ($id in $sourceIds) {
    if ($id -notmatch '^S-\d+$') { throw "Некорректный ID источника: $id" }
}
$combinedIds = @($IncludeId + $sourceIds | ForEach-Object { $_ -split ',' } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_.Trim().ToUpperInvariant() } |
    Select-Object -Unique)

$baseOutputRelative = '.project/context/base-context.md'
$baseReportRelative = '.project/context/base-context-report.json'
$contextArguments = @{
    Profile = $Profile
    IncludeId = $combinedIds
    Query = $Query
    TokenBudget = $baseTokenBudget
    OutputPath = $baseOutputRelative
    ReportPath = $baseReportRelative
}
if ($Check) { $contextArguments['Check'] = $true }
& $contextBuilder @contextArguments

$baseOutputFull = Get-SafePath $baseOutputRelative 'Базовый пакет' -LocalContextOnly
$baseReportFull = Get-SafePath $baseReportRelative 'Отчёт базового пакета' -LocalContextOnly
$baseText = [System.IO.File]::ReadAllText($baseOutputFull)
$baseReport = [System.IO.File]::ReadAllText($baseReportFull) | ConvertFrom-Json

$python = if ($sourceIds.Count -gt 0) { Get-PythonCommand } else { $null }
$remainingSourceBudget = $SourceTokenBudget
$sourceResults = [System.Collections.Generic.List[object]]::new()
$sourceErrors = [System.Collections.Generic.List[string]]::new()
$sourceMarkdown = [System.Text.StringBuilder]::new()

for ($index = 0; $index -lt $sourceIds.Count; $index++) {
    $sourceId = $sourceIds[$index]
    $remainingCount = $sourceIds.Count - $index
    $perSourceBudget = [Math]::Max(1, [int][Math]::Floor($remainingSourceBudget / $remainingCount))
    $arguments = @($python.Prefix) + @(
        $ingestionScript, 'select', '--source-id', $sourceId,
        '--token-budget', [string]$perSourceBudget,
        '--max-chunks', [string][int]$sourceProfile.maxChunks
    )
    foreach ($term in @($SourceQuery | ForEach-Object { $_ -split ',' } | Where-Object { $_ })) {
        $arguments += @('--query', $term.Trim())
    }
    if ($RefreshSources) { $arguments += '--refresh' }
    $output = @(& $python.Path @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $sourceErrors.Add("${sourceId}: $($output -join [Environment]::NewLine)")
        continue
    }
    $result = ($output -join "`n") | ConvertFrom-Json
    $sourceResults.Add($result)
    if ($result.matched -and -not [string]::IsNullOrWhiteSpace([string]$result.markdown)) {
        [void]$sourceMarkdown.AppendLine()
        [void]$sourceMarkdown.Append(([string]$result.markdown).TrimEnd())
        [void]$sourceMarkdown.AppendLine()
        $remainingSourceBudget = [Math]::Max(0, $remainingSourceBudget - [int]$result.includedTokens)
    }
    elseif ($SourceQuery.Count -gt 0) {
        $sourceErrors.Add("$sourceId: по заданному запросу не найдено фрагментов")
    }
}

$package = $baseText.TrimEnd()
if ($sourceMarkdown.Length -gt 0) {
    $package += "`n`n# Адресно выбранные материалы из вложений`n"
    $package += $sourceMarkdown.ToString()
}
$sourceIncludedTokens = [int](($sourceResults | Measure-Object -Property includedTokens -Sum).Sum)
$sourceFullTokens = [int](($sourceResults | Measure-Object -Property fullEstimatedTokens -Sum).Sum)
$estimatedTokens = [int]$baseReport.estimatedTokens + $sourceIncludedTokens
$complete = [bool]$baseReport.complete -and $sourceErrors.Count -eq 0 -and $estimatedTokens -le $TokenBudget
$reduction = if ($sourceFullTokens -le 0) { 0.0 } else {
    [Math]::Max(0.0, [Math]::Round(100 * (1 - $sourceIncludedTokens / $sourceFullTokens), 1))
}

$report = [ordered]@{
    schemaVersion = 1
    profile = $Profile
    mode = if ($Export) { 'export' } else { 'local' }
    localOnly = -not [bool]$Export
    transmissionPerformed = $false
    networkRequests = 0
    tokenBudget = $TokenBudget
    baseTokenBudget = $baseTokenBudget
    sourceTokenBudget = $SourceTokenBudget
    estimatedTokens = $estimatedTokens
    complete = $complete
    baseReportPath = $baseReportRelative
    requestedSources = @($sourceIds)
    sources = @($sourceResults)
    sourceErrors = @($sourceErrors)
    sourceFullEstimatedTokens = $sourceFullTokens
    sourceIncludedTokens = $sourceIncludedTokens
    sourceReductionPercent = $reduction
}

Write-AtomicUtf8 $outputFull $package
Write-AtomicUtf8 $reportFull ($report | ConvertTo-Json -Depth 10)
Write-Host "AI-пакет создан: $OutputPath (~$estimatedTokens токенов; сокращение вложений $reduction%)."
Write-Host "Отчёт: $ReportPath"

if ($Check -and -not $complete) {
    $reasons = [System.Collections.Generic.List[string]]::new()
    if (-not $baseReport.complete) { $reasons.Add('базовый контекст неполон') }
    if ($sourceErrors.Count -gt 0) { $reasons.Add($sourceErrors -join '; ') }
    if ($estimatedTokens -gt $TokenBudget) { $reasons.Add('общий пакет превышает бюджет') }
    throw 'AI-пакет неполон: ' + ($reasons -join '; ')
}
