[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('benefit', 'risk', 'issue', 'dependency', 'change', 'milestone')]
    [string]$Kind,
    [Parameter(Mandatory = $true)][string]$Title,
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    [string]$Owner = 'Требует назначения',
    [string]$Due = 'Не задан',
    [string]$Status = '',
    [string]$Type = 'Риск',
    [string]$Cause = 'Не задана',
    [string]$Effect = 'Не задано',
    [string]$Probability = 'Не оценена',
    [string]$Impact = 'Не оценено',
    [string]$Response = 'Определить ответ',
    [string]$Evidence = 'Не задано',
    [string]$StrategicLink = 'PROJECT-BRIEF.md',
    [string]$Metric = 'Не задана',
    [string]$Baseline = 'Не задан',
    [string]$Target = 'Не задана',
    [string]$Provider = 'Не назначен',
    [string]$NeededBy = 'Не задана',
    [string]$Risk = 'Не оценён',
    [string]$ValueScopeImpact = 'Не оценено',
    [string]$ScheduleCostImpact = 'Не оценено',
    [string]$RiskQualityImpact = 'Не оценено',
    [string]$Approver = 'Требует назначения',
    [string]$ReviewDate = 'Не задана',
    [string]$Acceptance = 'Не задано',
    [string]$ForecastDate = 'Не задана'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Assert-IsoDate([string]$Value, [string]$Name) {
    [DateTime]$parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact(
            $Value, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$parsed
        )) { throw "$Name должен быть календарной датой ГГГГ-ММ-ДД." }
}

function Assert-Cell([string]$Value, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Name не должен быть пустым." }
    if ($Value.Length -gt 1000) { throw "$Name не должен превышать 1000 символов." }
    if ($Value -match '[\|\r\n\x00-\x08\x0B\x0C\x0E-\x1F]') {
        throw "$Name не должен содержать вертикальную черту, переносы строк или управляющие символы."
    }
}

function Get-NextId([string]$Text, [string]$Prefix) {
    $maximum = 0
    foreach ($match in [regex]::Matches($Text, "(?m)^\|\s*$Prefix-(?<number>\d+)\s*\|")) {
        $number = [int]$match.Groups['number'].Value
        if ($number -gt $maximum) { $maximum = $number }
    }
    return '{0}-{1:D3}' -f $Prefix, ($maximum + 1)
}

function Add-TableRow([string]$Text, [string]$Heading, [string]$Row) {
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (($Text -replace "`r`n", "`n") -split "`n")) { $lines.Add($line) }
    $headingIndex = $lines.IndexOf("## $Heading")
    if ($headingIndex -lt 0) { throw "Не найден раздел '## $Heading'." }
    $separatorIndex = -1
    for ($index = $headingIndex + 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^##\s+') { break }
        if ($lines[$index] -match '^\|\s*:?-{3,}') { $separatorIndex = $index; break }
    }
    if ($separatorIndex -lt 0) { throw "В разделе '$Heading' не найдена таблица." }
    $insertAt = $separatorIndex + 1
    while ($insertAt -lt $lines.Count -and $lines[$insertAt] -match '^\|') { $insertAt++ }
    $lines.Insert($insertAt, $Row)
    return ($lines -join "`n").TrimEnd() + "`n"
}

function Set-Updated([string]$Text, [string]$Value) {
    return [regex]::Replace($Text, '(?m)^updated:\s*.*$', "updated: `"$Value`"", 1)
}

Assert-IsoDate $Date 'Date'
foreach ($candidate in @($Due, $ReviewDate, $NeededBy, $ForecastDate)) {
    if ($candidate -notmatch '^Не задан[ао]?$') { Assert-IsoDate $candidate 'Дата' }
}
foreach ($entry in $PSBoundParameters.GetEnumerator()) {
    if ($entry.Key -notin @('Kind')) { Assert-Cell ([string]$entry.Value) ([string]$entry.Key) }
}

$destination = $null
switch ($Kind) {
    'benefit' {
        $destination = @{ File = 'OUTCOMES.md'; Heading = 'Ожидаемые результаты и выгоды'; Prefix = 'B'; DefaultStatus = 'Не измеряется' }
        break
    }
    'risk' {
        $destination = @{ File = 'CONTROLS.md'; Heading = 'Риски и возможности'; Prefix = 'R'; DefaultStatus = 'Открыт' }
        break
    }
    'issue' {
        $destination = @{ File = 'CONTROLS.md'; Heading = 'Возникшие проблемы'; Prefix = 'I'; DefaultStatus = 'Открыта' }
        break
    }
    'dependency' {
        $destination = @{ File = 'CONTROLS.md'; Heading = 'Зависимости'; Prefix = 'X'; DefaultStatus = 'Активна' }
        break
    }
    'change' {
        $destination = @{ File = 'CONTROLS.md'; Heading = 'Запросы на изменение'; Prefix = 'C'; DefaultStatus = 'Предложено' }
        break
    }
    'milestone' {
        $destination = @{ File = 'docs/03-delivery.md'; Heading = 'Контрольные рубежи'; Prefix = 'G'; DefaultStatus = 'Не пройден' }
        break
    }
}
if ($null -eq $destination) { throw "Неизвестный тип управляющей записи: $Kind" }
$path = Join-Path $root $destination.File
$text = [System.IO.File]::ReadAllText($path)
$id = Get-NextId $text $destination.Prefix
$anchor = '<a id="' + $id.ToLowerInvariant() + '"></a>'
$actualStatus = if ([string]::IsNullOrWhiteSpace($Status)) { $destination.DefaultStatus } else { $Status }

$row = switch ($Kind) {
    'benefit' { "| $id | $anchor$Title | $StrategicLink | $Metric | $Baseline | $Target | $Owner | $ReviewDate | $actualStatus | $Evidence |" }
    'risk' { "| $id | $anchor$Type | $Cause | $Title | $Effect | $Probability | $Impact | $Response | $Owner | $Due | $actualStatus |" }
    'issue' { "| $id | $anchor$Title | $Impact | $Response | $Owner | $Due | $actualStatus | $Evidence |" }
    'dependency' { "| $id | $anchor$Title | $Provider | $NeededBy | $Risk | $Owner | $ReviewDate | $actualStatus | $Evidence |" }
    'change' { "| $id | $anchor$Date | $Title | $ValueScopeImpact | $ScheduleCostImpact | $RiskQualityImpact | $Approver | $actualStatus | $Evidence | $ReviewDate |" }
    'milestone' { "| $id | $anchor$Title | $Effect | $Acceptance | $Evidence | $Approver | $Due | $ForecastDate | $actualStatus |" }
}

$updated = Add-TableRow $text $destination.Heading $row
$updated = Set-Updated $updated $Date
$temporary = "$path.tmp-$([Guid]::NewGuid().ToString('N'))"
try {
    [System.IO.File]::WriteAllText($temporary, $updated, $utf8)
    [System.IO.File]::Move($temporary, $path, $true)
}
finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}

& (Join-Path $PSScriptRoot 'build-status.ps1')
Write-Host "Добавлена запись $id в $($destination.File)."
