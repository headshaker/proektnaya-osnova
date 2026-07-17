[CmdletBinding()]
param(
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    [switch]$Strict,
    [switch]$AllowPlaceholders
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$errors = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
$datePlaceholder = '{{' + 'DATE' + '}}'

function Test-IsoDate([string]$Value) {
    if ($AllowPlaceholders -and $Value -eq $datePlaceholder) { return $true }
    [DateTime]$parsed = [DateTime]::MinValue
    return [DateTime]::TryParseExact(
        $Value, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None, [ref]$parsed
    )
}

function Split-MarkdownRow([string]$Line) {
    $trimmed = $Line.Trim()
    if (-not $trimmed.StartsWith('|')) { return @() }
    $body = $trimmed.Substring(1)
    if ($body.EndsWith('|')) { $body = $body.Substring(0, $body.Length - 1) }
    return @([regex]::Split($body, '(?<!\\)\|') | ForEach-Object { $_.Trim() })
}

function Get-Rows([string]$Relative, [string]$Prefix) {
    $path = Join-Path $root $Relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in Get-Content -LiteralPath $path) {
        $cells = @(Split-MarkdownRow $line)
        if ($cells.Count -gt 0 -and $cells[0] -match "^$([regex]::Escape($Prefix))-\d+$") { $rows.Add($cells) }
    }
    return @($rows)
}

function Test-DueRows(
    [string]$Relative,
    [string]$Prefix,
    [int]$DueIndex,
    [int]$StatusIndex
) {
    $today = [DateTime]::ParseExact($Date, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    foreach ($row in @(Get-Rows $Relative $Prefix)) {
        if ($row.Count -le $DueIndex) { continue }
        $value = [string]$row[$DueIndex]
        if ($value -match '^(Не задан[ао]?|По событию|N/A|—|)$') { continue }
        if (-not (Test-IsoDate $value)) {
            $errors.Add("${Relative}: $($row[0]) содержит некорректную дату '$value'.")
            continue
        }
        $status = if ($row.Count -gt $StatusIndex) { [string]$row[$StatusIndex] } else { '' }
        if ($status -notmatch '^(Закрыт[ао]?|Принят[ао]?|Заверш[её]н[ао]?|Closed|Accepted|Done)$' -and
            [DateTime]::ParseExact($value, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) -lt $today) {
            $warnings.Add("${Relative}: $($row[0]) просрочен с $value.")
        }
    }
}

if (-not (Test-IsoDate $Date)) { throw 'Date должен быть календарной датой ГГГГ-ММ-ДД.' }

$required = @('PROJECT-CONFIG.json', 'OUTCOMES.md', 'CONTROLS.md', 'STATUS.md', 'AI-GOVERNANCE.md')
foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf)) {
        $errors.Add("Отсутствует файл контура управления: $relative")
    }
}

$configPath = Join-Path $root 'PROJECT-CONFIG.json'
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try {
        $config = [System.IO.File]::ReadAllText($configPath) | ConvertFrom-Json
        if ($config.schemaVersion -ne 1) { $errors.Add('PROJECT-CONFIG.json: поддерживается только schemaVersion = 1.') }
        if (@('light', 'standard', 'regulated') -cnotcontains [string]$config.managementProfile) {
            $errors.Add('PROJECT-CONFIG.json: неизвестный managementProfile.')
        }
        if (@('predictive', 'incremental', 'adaptive', 'flow', 'hybrid') -cnotcontains [string]$config.deliveryApproach) {
            $errors.Add('PROJECT-CONFIG.json: неизвестный deliveryApproach.')
        }
        if (@('not-configured', 'repository', 'github-issues', 'jira', 'linear', 'other') -cnotcontains [string]$config.workSystem.type) {
            $errors.Add('PROJECT-CONFIG.json: неизвестный workSystem.type.')
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$config.workSystem.url) -and
            [string]$config.workSystem.url -notmatch '^https://') {
            $errors.Add('PROJECT-CONFIG.json: workSystem.url должен быть пустым или начинаться с https://.')
        }
        foreach ($property in @('status', 'risks', 'benefits')) {
            if (@('daily', 'weekly', 'biweekly', 'monthly', 'quarterly', 'on-demand') -cnotcontains
                [string]$config.reviewCadence.$property) {
                $errors.Add("PROJECT-CONFIG.json: неизвестный ритм reviewCadence.$property.")
            }
        }
        if (@('not-classified', 'public', 'internal', 'confidential', 'restricted') -cnotcontains
            [string]$config.dataClassification) {
            $errors.Add('PROJECT-CONFIG.json: неизвестный dataClassification.')
        }
        if (@('basic', 'standard', 'high') -cnotcontains [string]$config.aiGovernanceLevel) {
            $errors.Add('PROJECT-CONFIG.json: неизвестный aiGovernanceLevel.')
        }
        if (-not (Test-IsoDate ([string]$config.configuredAt))) {
            $errors.Add('PROJECT-CONFIG.json: configuredAt должен быть датой ГГГГ-ММ-ДД.')
        }
        foreach ($property in @('scheduleDays', 'costVariancePercent')) {
            $value = $config.tolerances.$property
            if ($null -ne $value -and [decimal]$value -lt 0) {
                $errors.Add("PROJECT-CONFIG.json: tolerances.$property не может быть отрицательным.")
            }
        }
        if ([string]$config.workSystem.type -eq 'not-configured') { $warnings.Add('Рабочая система не настроена.') }
        if ([string]$config.dataClassification -eq 'not-classified') { $warnings.Add('Классификация данных проекта не определена.') }
        if ($null -eq $config.tolerances.scheduleDays -and $null -eq $config.tolerances.costVariancePercent) {
            $warnings.Add('Допуски по сроку и стоимости не заданы.')
        }
    }
    catch {
        $errors.Add("PROJECT-CONFIG.json: некорректный JSON или структура — $($_.Exception.Message)")
    }
}

if (@(Get-Rows 'OUTCOMES.md' 'B').Count -eq 0) {
    $warnings.Add('Не зарегистрирована ни одна измеримая выгода B-xxx.')
}

Test-DueRows 'OPEN-QUESTIONS.md' 'Q' 6 99
Test-DueRows 'OUTCOMES.md' 'B' 7 8
Test-DueRows 'CONTROLS.md' 'R' 9 10
Test-DueRows 'CONTROLS.md' 'I' 5 6
Test-DueRows 'CONTROLS.md' 'X' 6 7
Test-DueRows 'CONTROLS.md' 'C' 9 7
Test-DueRows 'docs/03-delivery.md' 'G' 7 8

foreach ($warning in $warnings) { Write-Warning $warning }
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "Проверка здоровья проекта не пройдена: ошибок — $($errors.Count)."
}
if ($Strict -and $warnings.Count -gt 0) {
    throw "Строгая проверка здоровья проекта не пройдена: предупреждений — $($warnings.Count)."
}
Write-Host "Проверка здоровья проекта пройдена: ошибок — 0, предупреждений — $($warnings.Count)."
