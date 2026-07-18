[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ReportPath = '.project/context/context-report.json',
    [string]$HealthReportPath = '.project/context/context-health.json',
    [string]$BaselinePath = '.project/context/context-baseline.json',
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    [switch]$UpdateBaseline,
    [switch]$AllowPlaceholders,
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd([char[]]@('\', '/'))
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Normalize-Text([string]$Text) {
    if ($null -eq $Text) { return '' }
    return (($Text -replace "`r`n", "`n") -replace "`r", "`n")
}

function Get-TextSha256([string]$Text) {
    $normalized = (Normalize-Text $Text).TrimEnd() + "`n"
    $bytes = $utf8.GetBytes($normalized)
    return [Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData($bytes)
    ).ToLowerInvariant()
}

function Get-SafePath([string]$Relative, [string]$Label, [switch]$LocalContextOnly) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [System.IO.Path]::IsPathRooted($Relative)) {
        throw "$Label должен быть относительным путём внутри проекта: $Relative"
    }
    $normalized = $Relative.Replace('\', '/')
    if ($normalized -match '(^|/)\.\.(/|$)') { throw "$Label выходит за пределы проекта: $Relative" }
    if ($LocalContextOnly -and $normalized -notmatch '^\.project/context(?:/|$)') {
        throw "$Label должен находиться внутри .project/context: $Relative"
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
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    $temporary = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($temporary, (Normalize-Text $Text).TrimEnd() + "`n", $utf8)
        [System.IO.File]::Move($temporary, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-PolicyInteger([object]$Policy, [string]$Name, [int]$DefaultValue) {
    if ($null -eq $Policy) { return $DefaultValue }
    $property = $Policy.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    return [int]$property.Value
}

function Get-IsoDate([string]$Value, [string]$Label) {
    [DateTime]$parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact(
            $Value,
            'yyyy-MM-dd',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$parsed
        )) {
        throw "$Label должен быть существующей датой ГГГГ-ММ-ДД."
    }
    return $parsed
}

function Get-UpdatedValue([string]$Relative) {
    $path = Get-SafePath $Relative $Relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $match = [regex]::Match(
        [System.IO.File]::ReadAllText($path),
        '(?m)^updated:\s*["'']?(?<value>[^"''\r\n]+)["'']?\s*$'
    )
    if (-not $match.Success) { return $null }
    return $match.Groups['value'].Value.Trim()
}

$today = Get-IsoDate $Date 'Date'
$reportFull = Get-SafePath $ReportPath 'ReportPath'
$healthReportFull = Get-SafePath $HealthReportPath 'HealthReportPath' -LocalContextOnly
$baselineFull = Get-SafePath $BaselinePath 'BaselinePath' -LocalContextOnly
if ($reportFull -in @($healthReportFull, $baselineFull) -or $healthReportFull -ceq $baselineFull) {
    throw 'Пути отчёта, здоровья и эталона должны различаться.'
}
if (-not (Test-Path -LiteralPath $reportFull -PathType Leaf)) {
    throw "Не найден отчёт контекста: $ReportPath. Сначала выполните build-context.ps1."
}

$report = [System.IO.File]::ReadAllText($reportFull) | ConvertFrom-Json
if ($report.schemaVersion -ne 2) {
    throw 'Отчёт контекста создан устаревшим сборщиком. Пересоберите пакет текущей версией build-context.ps1.'
}

$profilesPath = Get-SafePath 'CONTEXT-PROFILES.json' 'CONTEXT-PROFILES.json'
$configuration = [System.IO.File]::ReadAllText($profilesPath) | ConvertFrom-Json
$healthPolicyProperty = $configuration.PSObject.Properties['healthPolicy']
$policy = if ($null -eq $healthPolicyProperty) { $null } else { $healthPolicyProperty.Value }
$warningUtilizationPercent = Get-PolicyInteger $policy 'warningUtilizationPercent' 75
$criticalUtilizationPercent = Get-PolicyInteger $policy 'criticalUtilizationPercent' 90
$minimumCompletenessScore = Get-PolicyInteger $policy 'minimumCompletenessScore' 100
$maxHandoffAgeDays = Get-PolicyInteger $policy 'maxHandoffAgeDays' 14
$maxStatusAgeDays = Get-PolicyInteger $policy 'maxStatusAgeDays' 7
$warningUtilizationIncreasePoints = Get-PolicyInteger $policy 'warningUtilizationIncreasePoints' 10
if ($warningUtilizationPercent -lt 1 -or $criticalUtilizationPercent -gt 100 -or
    $warningUtilizationPercent -ge $criticalUtilizationPercent -or
    $minimumCompletenessScore -lt 1 -or $minimumCompletenessScore -gt 100 -or
    $maxHandoffAgeDays -lt 0 -or $maxStatusAgeDays -lt 0 -or
    $warningUtilizationIncreasePoints -lt 1) {
    throw 'CONTEXT-PROFILES.json содержит некорректную политику здоровья контекста.'
}

$errors = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
$changedSources = [System.Collections.Generic.List[string]]::new()
$missingSources = [System.Collections.Generic.List[string]]::new()

if (-not [bool]$report.complete) { $errors.Add('исходный отчёт помечает пакет как неполный') }
if ([int]$report.completenessScore -lt $minimumCompletenessScore) {
    $errors.Add("полнота $($report.completenessScore)% ниже минимума $minimumCompletenessScore%")
}
$utilizationPercent = [decimal]$report.utilizationPercent
if ($utilizationPercent -ge $criticalUtilizationPercent) {
    $errors.Add("заполнение $utilizationPercent% достигло критического порога $criticalUtilizationPercent%")
}
elseif ($utilizationPercent -ge $warningUtilizationPercent) {
    $warnings.Add("заполнение $utilizationPercent% достигло предупредительного порога $warningUtilizationPercent%")
}

$currentSourceFiles = [System.Collections.Generic.List[object]]::new()
foreach ($source in @($report.sourceFiles)) {
    $relative = [string]$source.path
    $path = Get-SafePath $relative "Источник $relative"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $missingSources.Add($relative)
        $currentSourceFiles.Add([ordered]@{ path = $relative; exists = $false; sha256 = $null })
        continue
    }
    $currentHash = Get-TextSha256 ([System.IO.File]::ReadAllText($path))
    $currentSourceFiles.Add([ordered]@{ path = $relative; exists = $true; sha256 = $currentHash })
    if (-not [bool]$source.exists -or $currentHash -cne [string]$source.sha256) {
        $changedSources.Add($relative)
    }
}
if ($missingSources.Count -gt 0) { $errors.Add('исчезли источники: ' + ($missingSources -join ', ')) }
if ($changedSources.Count -gt 0) { $errors.Add('контекст устарел после изменения: ' + ($changedSources -join ', ')) }

$currentFingerprintMaterial = @($currentSourceFiles | Sort-Object path | ForEach-Object {
        "$($_.path)|$($_.exists)|$($_.sha256)"
    }) -join "`n"
$currentSourceFingerprint = Get-TextSha256 $currentFingerprintMaterial
if ($currentSourceFingerprint -cne [string]$report.sourceFingerprint -and
    $changedSources.Count -eq 0 -and $missingSources.Count -eq 0) {
    $errors.Add('совокупный отпечаток источников не совпадает с отчётом')
}

$contextPath = Get-SafePath ([string]$report.outputPath) 'outputPath из отчёта'
$contextFingerprint = $null
if (-not (Test-Path -LiteralPath $contextPath -PathType Leaf)) {
    $errors.Add("не найден собранный пакет: $($report.outputPath)")
}
else {
    $contextFingerprint = Get-TextSha256 ([System.IO.File]::ReadAllText($contextPath))
    if ($contextFingerprint -cne [string]$report.contextFingerprint) {
        $errors.Add('собранный пакет изменён после формирования отчёта')
    }
}

$ages = [ordered]@{}
foreach ($ageRule in @(
        [pscustomobject]@{ Path = 'HANDOFF.md'; Maximum = $maxHandoffAgeDays },
        [pscustomobject]@{ Path = 'STATUS.md'; Maximum = $maxStatusAgeDays }
    )) {
    $updated = Get-UpdatedValue $ageRule.Path
    if ($null -eq $updated) {
        $errors.Add("$($ageRule.Path): отсутствует поле updated")
        continue
    }
    if ($updated -match '^\{\{.+\}\}$' -and $AllowPlaceholders) {
        $ages[$ageRule.Path] = $null
        continue
    }
    try { $updatedDate = Get-IsoDate $updated "$($ageRule.Path): updated" }
    catch { $errors.Add($_.Exception.Message); continue }
    $ageDays = ($today - $updatedDate).Days
    $ages[$ageRule.Path] = $ageDays
    if ($ageDays -lt 0) { $errors.Add("$($ageRule.Path): дата updated находится в будущем") }
    elseif ($ageDays -gt $ageRule.Maximum) {
        $errors.Add("$($ageRule.Path) устарел: $ageDays дн. при пределе $($ageRule.Maximum)")
    }
}

$regressions = [System.Collections.Generic.List[string]]::new()
$baselineAvailable = Test-Path -LiteralPath $baselineFull -PathType Leaf
if ($baselineAvailable -and -not $UpdateBaseline) {
    $baseline = [System.IO.File]::ReadAllText($baselineFull) | ConvertFrom-Json
    if ($baseline.schemaVersion -ne 1) { $errors.Add('эталон контекста имеет неподдерживаемую схему') }
    elseif ([string]$baseline.profile -ceq [string]$report.profile) {
        $completenessDrop = [int]$baseline.completenessScore - [int]$report.completenessScore
        $utilizationIncrease = [decimal]$report.utilizationPercent - [decimal]$baseline.utilizationPercent
        if ($completenessDrop -gt 0) {
            $regressions.Add("полнота снизилась на $completenessDrop п.п.")
        }
        if ($utilizationIncrease -ge $warningUtilizationIncreasePoints) {
            $regressions.Add("заполнение выросло на $utilizationIncrease п.п.")
        }
        foreach ($regression in $regressions) { $warnings.Add("регрессия относительно эталона: $regression") }
    }
}

$status = if ($errors.Count -gt 0) { 'critical' } elseif ($warnings.Count -gt 0) { 'warning' } else { 'healthy' }
$health = [ordered]@{
    schemaVersion = 1
    checkedAtUtc = (Get-Date).ToUniversalTime().ToString('O')
    checkedForDate = $Date
    status = $status
    profile = [string]$report.profile
    reportPath = $ReportPath.Replace('\', '/')
    contextPath = [string]$report.outputPath
    completenessScore = [int]$report.completenessScore
    utilizationPercent = $utilizationPercent
    sourceFingerprint = $currentSourceFingerprint
    contextFingerprint = $contextFingerprint
    agesDays = $ages
    baselineAvailable = $baselineAvailable -or [bool]$UpdateBaseline
    regressions = @($regressions)
    changedSources = @($changedSources)
    missingSources = @($missingSources)
    warnings = @($warnings)
    errors = @($errors)
}
Write-AtomicUtf8 $healthReportFull ($health | ConvertTo-Json -Depth 10)

if ($UpdateBaseline) {
    if ($errors.Count -gt 0) { throw 'Нельзя обновить эталон для критически деградировавшего контекста.' }
    $baseline = [ordered]@{
        schemaVersion = 1
        capturedAtUtc = (Get-Date).ToUniversalTime().ToString('O')
        profile = [string]$report.profile
        completenessScore = [int]$report.completenessScore
        utilizationPercent = $utilizationPercent
        sourceFingerprint = $currentSourceFingerprint
        contextFingerprint = $contextFingerprint
    }
    Write-AtomicUtf8 $baselineFull ($baseline | ConvertTo-Json -Depth 5)
    Write-Host "Эталон контекста обновлён: $BaselinePath"
}

Write-Host "Здоровье контекста: $status; полнота $($report.completenessScore)%; заполнение $utilizationPercent%."
Write-Host "Отчёт: $HealthReportPath"
foreach ($warning in $warnings) { Write-Warning $warning }
if ($Check -and $errors.Count -gt 0) {
    throw 'Обнаружена деградация контекста: ' + ($errors -join '; ')
}
