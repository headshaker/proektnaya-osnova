[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateRange(1, 3650)]
    [int]$Days = 14,
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$handoffPath = Join-Path $root 'HANDOFF.md'
$changelogPath = Join-Path $root 'CHANGELOG.md'
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Get-IsoDate([string]$Value, [string]$Name) {
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
    return $parsed
}

function Get-Lines([string]$Text) {
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Text.Replace("`r`n", "`n") -split "`n")) { $result.Add($line) }
    return ,$result
}

function Get-Section([System.Collections.Generic.List[string]]$Lines, [string]$Heading) {
    $start = -1
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index].Trim() -ceq "## $Heading") { $start = $index; break }
    }
    if ($start -lt 0) { throw "Не найден раздел '## $Heading'." }
    $end = $Lines.Count
    for ($index = $start + 1; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^##\s+') { $end = $index; break }
    }
    return [pscustomobject]@{ Start = $start; End = $end }
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

function Add-ArchiveEntries(
    [string]$Text,
    [System.Collections.Generic.List[string]]$Entries
) {
    $lines = Get-Lines $Text
    $section = Get-Section $lines 'Журнал изменений между выпусками'
    $archiveHeading = '### Оперативная история'
    $archiveIndex = -1
    for ($index = $section.Start + 1; $index -lt $section.End; $index++) {
        if ($lines[$index].Trim() -ceq $archiveHeading) { $archiveIndex = $index; break }
    }

    if ($archiveIndex -lt 0) {
        $insertAt = $section.End
        while ($insertAt -gt $section.Start + 1 -and [string]::IsNullOrWhiteSpace($lines[$insertAt - 1])) {
            $insertAt--
        }
        $block = [System.Collections.Generic.List[string]]::new()
        $block.Add('')
        $block.Add($archiveHeading)
        $block.Add('')
        foreach ($entry in $Entries) { $block.Add($entry) }
        $lines.InsertRange($insertAt, $block)
    }
    else {
        $insertAt = $section.End
        for ($index = $archiveIndex + 1; $index -lt $section.End; $index++) {
            if ($lines[$index] -match '^#{2,3}\s+') { $insertAt = $index; break }
        }
        while ($insertAt -gt $archiveIndex + 1 -and [string]::IsNullOrWhiteSpace($lines[$insertAt - 1])) {
            $insertAt--
        }
        $block = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $Entries) { $block.Add($entry) }
        $lines.InsertRange($insertAt, $block)
    }
    return ($lines -join "`n").TrimEnd() + "`n"
}

foreach ($path in @($handoffPath, $changelogPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Отсутствует обязательный файл: $path"
    }
}

$asOf = Get-IsoDate $Date 'Date'
$cutoff = $asOf.AddDays(-($Days - 1))
$handoffText = [System.IO.File]::ReadAllText($handoffPath)
$handoffLines = Get-Lines $handoffText
$history = Get-Section $handoffLines '2. Что изменено (последние 14 дней)'
$moveIndexes = [System.Collections.Generic.List[int]]::new()
$moveEntries = [System.Collections.Generic.List[string]]::new()

for ($index = $history.Start + 1; $index -lt $history.End; $index++) {
    if ($handoffLines[$index] -notmatch '^-\s+(?<date>\d{4}-\d{2}-\d{2}):\s+\S') { continue }
    $entryDate = Get-IsoDate $Matches['date'] "Дата оперативной записи в HANDOFF.md"
    if ($entryDate -lt $cutoff) {
        $moveIndexes.Add($index)
        $moveEntries.Add($handoffLines[$index])
    }
}

if ($moveEntries.Count -eq 0) {
    Write-Host "Ротация не требуется: все записи входят в последние $Days дней."
    return
}

$changelogText = [System.IO.File]::ReadAllText($changelogPath)
$newEntries = [System.Collections.Generic.List[string]]::new()
foreach ($entry in ($moveEntries | Sort-Object -Descending)) {
    if ($changelogText -notmatch ('(?m)^' + [regex]::Escape($entry) + '$')) {
        $newEntries.Add($entry)
    }
}
if ($newEntries.Count -gt 0) {
    $changelogText = Add-ArchiveEntries $changelogText $newEntries
    $changelogText = Set-UpdatedDate $changelogText $Date
}

for ($index = $moveIndexes.Count - 1; $index -ge 0; $index--) {
    $handoffLines.RemoveAt($moveIndexes[$index])
}

$hasHistoryContent = $false
$updatedHistory = Get-Section $handoffLines '2. Что изменено (последние 14 дней)'
for ($index = $updatedHistory.Start + 1; $index -lt $updatedHistory.End; $index++) {
    if (-not [string]::IsNullOrWhiteSpace($handoffLines[$index])) {
        $hasHistoryContent = $true
        break
    }
}
if (-not $hasHistoryContent) {
    $handoffLines.Insert($updatedHistory.Start + 1, '')
    $handoffLines.Insert($updatedHistory.Start + 2, "- За последние $Days дней изменений нет.")
}

$handoffText = ($handoffLines -join "`n").TrimEnd() + "`n"
$handoffText = Set-UpdatedDate $handoffText $Date

if ($PSCmdlet.ShouldProcess('HANDOFF.md и CHANGELOG.md', "перенести записей: $($moveEntries.Count)")) {
    if ($newEntries.Count -gt 0) {
        Write-AtomicUtf8 $changelogPath $changelogText
    }
    Write-AtomicUtf8 $handoffPath $handoffText
}
Write-Host "Ротация завершена: перенесено записей — $($moveEntries.Count)."
