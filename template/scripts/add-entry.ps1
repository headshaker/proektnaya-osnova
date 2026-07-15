[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('decision', 'question', 'source')]
    [string]$Kind,

    [Parameter(Mandatory = $true)]
    [string]$Title,

    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),

    [string]$Context = 'Не задано',
    [string]$Consequences = 'Не задано',
    [string]$Basis = 'Не задано',
    [string]$Review = 'При изменении исходных условий',

    [ValidateSet('P0', 'P1', 'P2')]
    [string]$Priority = 'P1',
    [string]$Importance = 'Не задано',
    [string]$Owner = 'Требует назначения',
    [string]$NextStep = 'Определить следующий шаг',
    [string]$Closure = 'Получен проверяемый ответ',
    [string]$Due = 'Не задан',

    [ValidateSet('project', 'external')]
    [string]$SourceClass = 'external',
    [string]$SourceType = 'Первичный материал',
    [string]$Publisher = 'Не указан',
    [string]$Evidence = 'Не задано',
    [string]$DocumentDate = 'Не задана',
    [string]$Scope = 'Не задана',
    [string]$Verified = $Date,
    [string]$Recheck = 'При изменении подтверждаемого тезиса'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stateDirectory = Join-Path $root '.project'
$lockPath = Join-Path $stateDirectory 'add-entry.lock'
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Assert-IsoDate([string]$Value, [string]$Name) {
    [DateTime]$parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact(
            $Value,
            'yyyy-MM-dd',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$parsed
        )) {
        throw "$Name должен быть существующей календарной датой в формате ГГГГ-ММ-ДД."
    }
}

function Assert-Cell([string]$Value, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name не должен быть пустым."
    }
    if ($Value.Length -gt 1000) {
        throw "$Name не должен превышать 1000 символов."
    }
    if ($Value -match '[\|\r\n\x00-\x08\x0B\x0C\x0E-\x1F]') {
        throw "$Name не должен содержать вертикальную черту, переносы строк или управляющие символы."
    }
    if ($Value -match '\{\{(?:PROJECT_TITLE|PROJECT_SLUG|DATE)\}\}') {
        throw "$Name не должен содержать служебные маркеры шаблона."
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
    $normalized = $Text.Replace("`r`n", "`n")
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($normalized -split "`n")) { $lines.Add($line) }

    $headingIndex = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index].Trim() -ceq "## $Heading") {
            $headingIndex = $index
            break
        }
    }
    if ($headingIndex -lt 0) { throw "Не найден раздел '## $Heading'." }

    $separatorIndex = -1
    for ($index = $headingIndex + 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^##\s+') { break }
        if ($lines[$index] -match '^\|\s*:?-{3,}') {
            $separatorIndex = $index
            break
        }
    }
    if ($separatorIndex -lt 0) { throw "В разделе '$Heading' не найдена Markdown-таблица." }

    $insertAt = $separatorIndex + 1
    while ($insertAt -lt $lines.Count -and $lines[$insertAt] -match '^\|') {
        $insertAt++
    }
    $lines.Insert($insertAt, $Row)
    return ($lines -join "`n").TrimEnd() + "`n"
}

function Set-UpdatedDate([string]$Text, [string]$Value) {
    $pattern = [regex]::new('(?m)^updated:\s*.*$')
    if (-not $pattern.IsMatch($Text)) { throw 'В целевом файле отсутствует свойство updated.' }
    return $pattern.Replace($Text, "updated: `"$Value`"", 1)
}

function Write-AtomicUtf8([string]$Path, [string]$Text) {
    $temporary = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($temporary, $Text, $utf8)
        [System.IO.File]::Move($temporary, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

Assert-IsoDate $Date 'Date'
foreach ($value in @{
        Title = $Title; Context = $Context; Consequences = $Consequences; Basis = $Basis;
        Review = $Review; Importance = $Importance; Owner = $Owner; NextStep = $NextStep;
        Closure = $Closure; Due = $Due; SourceType = $SourceType; Publisher = $Publisher;
        Evidence = $Evidence; DocumentDate = $DocumentDate; Scope = $Scope;
        Verified = $Verified; Recheck = $Recheck
    }.GetEnumerator()) {
    Assert-Cell ([string]$value.Value) ([string]$value.Key)
}
if ($Verified -ne 'Не задано') { Assert-IsoDate $Verified 'Verified' }
if ($DocumentDate -ne 'Не задана') { Assert-IsoDate $DocumentDate 'DocumentDate' }

[System.IO.Directory]::CreateDirectory($stateDirectory) | Out-Null
$lock = $null
try {
    for ($attempt = 0; $attempt -lt 50 -and $null -eq $lock; $attempt++) {
        try {
            $lock = [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )
        }
        catch [System.IO.IOException] {
            if ((Test-Path -LiteralPath $lockPath) -and
                (Get-Item -LiteralPath $lockPath).LastWriteTimeUtc -lt (Get-Date).ToUniversalTime().AddMinutes(-5)) {
                Remove-Item -LiteralPath $lockPath -Force
                continue
            }
            Start-Sleep -Milliseconds 100
        }
    }
    if ($null -eq $lock) { throw 'Не удалось получить блокировку реестров за 5 секунд.' }

    $writer = [System.IO.StreamWriter]::new($lock, $utf8, 1024, $true)
    try {
        $writer.Write("PID=$PID`nUTC=$((Get-Date).ToUniversalTime().ToString('O'))`n")
        $writer.Flush()
    }
    finally {
        $writer.Dispose()
    }

    switch ($Kind) {
        'decision' {
            $path = Join-Path $root 'DECISIONS.md'
            $text = [System.IO.File]::ReadAllText($path)
            $id = Get-NextId $text 'D'
            $row = "| $id | $Date | $Title | $Context | $Consequences | $Basis | $Review |"
            $updated = Add-TableRow $text 'Действующие решения' $row
        }
        'question' {
            $path = Join-Path $root 'OPEN-QUESTIONS.md'
            $text = [System.IO.File]::ReadAllText($path)
            $id = Get-NextId $text 'Q'
            $heading = switch ($Priority) {
                'P0' { 'P0 — блокирует ближайший контрольный рубеж' }
                'P1' { 'P1 — существенно влияет на решение' }
                'P2' { 'P2 — можно отложить' }
            }
            $row = "| $id | $Title | $Importance | $Owner | $NextStep | $Closure | $Due |"
            $updated = Add-TableRow $text $heading $row
        }
        'source' {
            $path = Join-Path $root 'SOURCES.md'
            $text = [System.IO.File]::ReadAllText($path)
            $id = Get-NextId $text 'S'
            if ($SourceClass -eq 'project') {
                $heading = 'Первичные материалы проекта'
                $row = "| $id | $Title | $SourceType | $Evidence | $DocumentDate | $Verified | $Owner | $Recheck |"
            }
            else {
                $heading = 'Внешние источники'
                $row = "| $id | $Title | $Publisher | $Evidence | $Scope | $Verified | $Recheck |"
            }
            $updated = Add-TableRow $text $heading $row
        }
    }

    $updated = Set-UpdatedDate $updated $Date
    Write-AtomicUtf8 $path $updated
    Write-Host "Добавлена запись $id в $([System.IO.Path]::GetFileName($path))."
}
finally {
    if ($null -ne $lock) {
        $lock.Dispose()
        if (Test-Path -LiteralPath $lockPath) {
            Remove-Item -LiteralPath $lockPath -Force
        }
    }
}
