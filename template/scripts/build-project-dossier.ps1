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

function Get-SafeProjectPath([string]$Root, [string]$Candidate, [string]$Label) {
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
    $candidateFull = [System.IO.Path]::GetFullPath($Candidate)
    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidateFull.Equals($rootFull, $comparison) -and -not $candidateFull.StartsWith($prefix, $comparison)) {
        throw "$Label выходит за пределы проекта: $candidateFull"
    }
    return $candidateFull
}

function ConvertFrom-YamlScalar([string]$Raw, [string]$Path, [string]$Field) {
    $value = $Raw.Trim()
    if ($value.StartsWith('"')) {
        if ($value -notmatch '^"(?:[^"\\]|\\["\\/bfnrt]|\\u[0-9A-Fa-f]{4})*"$') {
            throw "В '$Path' поле '$Field' содержит некорректную строку YAML."
        }
        return [System.Text.Json.JsonSerializer]::Deserialize[string]($value)
    }
    if ($value.StartsWith("'")) {
        if ($value -notmatch "^'(?:[^']|'')*'$" ) {
            throw "В '$Path' поле '$Field' содержит некорректную строку YAML."
        }
        return $value.Substring(1, $value.Length - 2).Replace("''", "'")
    }
    return $value
}

function Assert-IsoDate([string]$Value, [string]$Path, [string]$Field) {
    [DateTime]$parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact(
            $Value,
            'yyyy-MM-dd',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$parsed
        )) {
        throw "В '$Path' поле '$Field' должно быть календарной датой в формате ГГГГ-ММ-ДД."
    }
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
        if ($lines[$i] -match '^([A-Za-z0-9_-]+):\s*(.*?)\s*$') {
            $field = $Matches[1]
            if ($fields.ContainsKey($field)) {
                throw "В файле '$Path' поле '$field' указано более одного раза."
            }
            $fields[$field] = ConvertFrom-YamlScalar $Matches[2] $Path $field
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
    if ([string]::IsNullOrWhiteSpace($front.Fields['title'])) {
        throw "В '$SourcePath' поле title не должно быть пустым."
    }
    Assert-IsoDate $front.Fields['updated'] $SourcePath 'updated'
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

    $sourceFull = Get-SafeProjectPath $Root (Join-Path $Root $SourcePath) "Источник '$SourcePath'"
    $sourceDir = Split-Path -Parent $sourceFull
    $body = $lines -join "`n"
    $body = [regex]::Replace($body, '\((?<path>[^:)#]+\.md)(?<anchor>#[^)]*)?\)', {
        param($match)
        $target = $match.Groups['path'].Value
        if ([System.IO.Path]::IsPathRooted($target)) { return $match.Value }
        $full = Get-SafeProjectPath $Root (Join-Path $sourceDir $target) "Ссылка '$target' в '$SourcePath'"
        $relative = [System.IO.Path]::GetRelativePath($Root, $full).Replace('\', '/')
        return '(' + $relative + $match.Groups['anchor'].Value + ')'
    })
    return [pscustomobject]@{ Title = $front.Fields['title']; Updated = $front.Fields['updated']; Body = $body.Trim() }
}

$manifestFull = [System.IO.Path]::GetFullPath($ManifestPath)
$root = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $manifestFull) '..'))
$manifest = Get-Content -Raw -LiteralPath $manifestFull | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1) { throw 'Поддерживается только schemaVersion = 1.' }
if ([string]::IsNullOrWhiteSpace($manifest.output)) { throw 'В манифесте не задан output.' }
if ([string]::IsNullOrWhiteSpace($manifest.title)) { throw 'В манифесте не задан title.' }
if ($null -eq $manifest.parts -or @($manifest.parts).Count -eq 0) { throw 'В манифесте не заданы parts.' }
$yamlManifestTitle = [System.Text.Json.JsonSerializer]::Serialize[string]([string]$manifest.title)
$output = Get-SafeProjectPath $root (Join-Path $root $manifest.output) 'Выходной файл манифеста'
$indexPath = Get-SafeProjectPath $root (Join-Path $root 'README.md') 'Главный файл проекта'
$indexFront = Get-FrontMatter ([System.IO.File]::ReadAllText($indexPath)) 'README.md'
if (-not $indexFront.Fields.ContainsKey('created')) {
    throw "В 'README.md' обязательно поле created."
}
$created = $indexFront.Fields['created']
Assert-IsoDate $created 'README.md' 'created'
$latest = ''
$builder = [System.Text.StringBuilder]::new()

[void]$builder.AppendLine('---')
[void]$builder.AppendLine('title: ' + $yamlManifestTitle)
[void]$builder.AppendLine('aliases: []')
[void]$builder.AppendLine('type: generated-dossier')
[void]$builder.AppendLine('status: active')
[void]$builder.AppendLine('created: "' + $created + '"')
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
    if ([string]::IsNullOrWhiteSpace($part.title)) { throw 'В манифесте найден раздел без title.' }
    if ($null -eq $part.documents -or @($part.documents).Count -eq 0) {
        throw "В разделе '$($part.title)' не заданы documents."
    }
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## ' + $part.title)
    foreach ($relative in $part.documents) {
        if ([string]::IsNullOrWhiteSpace($relative)) { throw "В разделе '$($part.title)' найден пустой путь." }
        if ([System.IO.Path]::GetExtension($relative) -ne '.md') {
            throw "Источник '$relative' должен быть Markdown-файлом."
        }
        if ($seen.ContainsKey($relative)) { throw "Файл '$relative' включён дважды." }
        $seen[$relative] = $true
        $full = Get-SafeProjectPath $root (Join-Path $root $relative) "Источник '$relative'"
        if ($full -eq $output) { throw "Выходной файл '$($manifest.output)' нельзя использовать как источник." }
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
