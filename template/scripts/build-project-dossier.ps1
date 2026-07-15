[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'project-dossier.manifest.json'),
    [switch]$Check,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($argument in @($RemainingArguments)) {
    if ([string]::IsNullOrWhiteSpace($argument)) { continue }
    if ($argument -eq '--check') { $Check = $true; continue }
    throw "Неизвестный аргумент: $argument"
}

function Normalize-Text([string]$Text) {
    if ($null -eq $Text) { return '' }
    return (($Text -replace "`r`n", "`n") -replace "`r", "`n")
}

function Get-FrontMatter([string]$Text, [string]$Path) {
    $lines = @((Normalize-Text $Text) -split "`n")
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') {
        throw "В файле '$Path' отсутствует YAML-заголовок."
    }
    $end = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') { $end = $i; break }
    }
    if ($end -lt 0) { throw "В файле '$Path' не закрыт YAML-заголовок." }
    $fields = @{}
    for ($i = 1; $i -lt $end; $i++) {
        if ($lines[$i] -match '^([A-Za-z0-9_-]+):\s*["'']?(.*?)["'']?\s*$') {
            $fields[$Matches[1]] = $Matches[2]
        }
    }
    $body = if ($end + 1 -lt $lines.Count) { $lines[($end + 1)..($lines.Count - 1)] -join "`n" } else { '' }
    return [pscustomobject]@{ Fields = $fields; Body = $body }
}

function Prepare-Body([string]$Text, [string]$SourcePath, [string]$Root) {
    $front = Get-FrontMatter $Text $SourcePath
    if (-not $front.Fields.ContainsKey('title') -or -not $front.Fields.ContainsKey('updated')) {
        throw "В '$SourcePath' обязательны title и updated."
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @((Normalize-Text $front.Body) -split "`n")) { $lines.Add($line) }
    while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[0])) { $lines.RemoveAt(0) }
    if ($lines.Count -gt 0 -and $lines[0] -match '^#\s+') { $lines.RemoveAt(0) }
    while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[0])) { $lines.RemoveAt(0) }

    $insideFence = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].TrimStart() -match '^(```|~~~)') { $insideFence = -not $insideFence; continue }
        if (-not $insideFence -and $lines[$i] -match '^(#{1,5})(\s+.*)$') {
            $lines[$i] = '#' + $Matches[1] + $Matches[2]
        }
    }

    $sourceDir = Split-Path -Parent (Join-Path $Root $SourcePath)
    $body = $lines -join "`n"
    $body = [regex]::Replace($body, '\((?<path>[^:)#]+\.md)(?<anchor>#[^)]*)?\)', {
        param($match)
        $target = $match.Groups['path'].Value
        if ([System.IO.Path]::IsPathRooted($target)) { return $match.Value }
        $full = [System.IO.Path]::GetFullPath((Join-Path $sourceDir $target))
        $relative = [System.IO.Path]::GetRelativePath($Root, $full).Replace('\', '/')
        return '(' + $relative + $match.Groups['anchor'].Value + ')'
    })
    return [pscustomobject]@{ Title = $front.Fields['title']; Updated = $front.Fields['updated']; Body = $body.Trim() }
}

$manifestFull = [System.IO.Path]::GetFullPath($ManifestPath)
$root = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $manifestFull) '..'))
$manifest = Get-Content -Raw -LiteralPath $manifestFull | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1) { throw 'Поддерживается только schemaVersion = 1.' }
$output = Join-Path $root $manifest.output
$latest = ''
$builder = [System.Text.StringBuilder]::new()

[void]$builder.AppendLine('---')
[void]$builder.AppendLine('title: "' + $manifest.title + '"')
[void]$builder.AppendLine('aliases: []')
[void]$builder.AppendLine('type: generated-dossier')
[void]$builder.AppendLine('status: active')
[void]$builder.AppendLine('created: "' + (Get-Date -Format 'yyyy-MM-dd') + '"')
[void]$builder.AppendLine('updated: "__LATEST__"')
[void]$builder.AppendLine('tags:')
[void]$builder.AppendLine('  - project/dossier')
[void]$builder.AppendLine('---')
[void]$builder.AppendLine()
[void]$builder.AppendLine('# ' + $manifest.title)
[void]$builder.AppendLine()
[void]$builder.AppendLine('> [!warning] Производный файл')
[void]$builder.AppendLine('> Не редактировать вручную. Источники задаются в `scripts/project-dossier.manifest.json`.')

$seen = @{}
foreach ($part in $manifest.parts) {
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## ' + $part.title)
    foreach ($relative in $part.documents) {
        if ($seen.ContainsKey($relative)) { throw "Файл '$relative' включён дважды." }
        $seen[$relative] = $true
        $full = Join-Path $root $relative
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Источник не найден: $relative" }
        $prepared = Prepare-Body ([System.IO.File]::ReadAllText($full)) $relative $root
        if ($prepared.Updated -gt $latest) { $latest = $prepared.Updated }
        [void]$builder.AppendLine()
        [void]$builder.AppendLine('### ' + $prepared.Title)
        [void]$builder.AppendLine()
        [void]$builder.AppendLine('Источник: [`' + $relative + '`](' + $relative + ')')
        [void]$builder.AppendLine()
        [void]$builder.AppendLine($prepared.Body)
    }
}

$expected = (Normalize-Text $builder.ToString()).Replace('__LATEST__', $latest).TrimEnd() + "`n"
if ($Check) {
    if (-not (Test-Path -LiteralPath $output)) { throw "Файл '$($manifest.output)' отсутствует. Сначала выполните сборку." }
    $actual = (Normalize-Text ([System.IO.File]::ReadAllText($output))).TrimEnd() + "`n"
    if ($actual -cne $expected) { throw "Файл '$($manifest.output)' устарел. Пересоберите его." }
    Write-Host "Проверка пройдена: $($manifest.output) актуален."
    exit 0
}

[System.IO.File]::WriteAllText($output, $expected, [System.Text.UTF8Encoding]::new($false))
Write-Host "Собран файл $($manifest.output)."
