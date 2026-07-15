[CmdletBinding()]
param([switch]$AllowPlaceholders)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$errors = [System.Collections.Generic.List[string]]::new()
$requiredFiles = @(
    'README.md', 'AGENTS.md', 'PROJECT-BRIEF.md', 'DECISIONS.md',
    'OPEN-QUESTIONS.md', 'SOURCES.md', 'GLOSSARY.md', 'HANDOFF.md',
    'CHANGELOG.md', 'OBSIDIAN.md', 'TEMPLATE-LICENSE', 'TEMPLATE-VERSION'
)
$requiredProperties = @('title', 'aliases', 'type', 'status', 'created', 'updated', 'tags')

function Test-PathInsideRoot([string]$Root, [string]$Candidate) {
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
    $candidateFull = [System.IO.Path]::GetFullPath($Candidate)
    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    return $candidateFull.Equals($rootFull, $comparison) -or
        $candidateFull.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, $comparison)
}

function Test-IsoDate([string]$Value) {
    [DateTime]$parsed = [DateTime]::MinValue
    return [DateTime]::TryParseExact(
        $Value,
        'yyyy-MM-dd',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$parsed
    )
}

foreach ($file in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $file) -PathType Leaf)) {
        $errors.Add("Отсутствует обязательный файл: $file")
    }
}

$templateVersionPath = Join-Path $root 'TEMPLATE-VERSION'
if (Test-Path -LiteralPath $templateVersionPath -PathType Leaf) {
    $templateVersion = [System.IO.File]::ReadAllText($templateVersionPath).Trim()
    if ($templateVersion -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
        $errors.Add('TEMPLATE-VERSION: некорректная семантическая версия')
    }
}

$markdown = Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.md' |
    Where-Object { $_.Name -ne 'PROJECT.md' -and $_.FullName -notmatch '[\\/]_templates[\\/]' }

foreach ($file in $markdown) {
    $relative = [System.IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
    $text = [System.IO.File]::ReadAllText($file.FullName)
    if (-not $AllowPlaceholders -and $text -match '\{\{(PROJECT_TITLE|PROJECT_SLUG|DATE)\}\}') {
        $errors.Add("${relative}: остались маркеры инициализации")
    }
    $lines = @(($text -replace "`r`n", "`n") -split "`n")
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') {
        $errors.Add("${relative}: отсутствует YAML-заголовок")
        continue
    }
    $end = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') { $end = $i; break }
    }
    if ($end -lt 0) { $errors.Add("${relative}: YAML-заголовок не закрыт"); continue }
    $fields = @{}
    for ($i = 1; $i -lt $end; $i++) {
        if ($lines[$i] -match '^([A-Za-z0-9_-]+):\s*(.*?)\s*$') {
            $field = $Matches[1]
            if ($fields.ContainsKey($field)) {
                $errors.Add("${relative}: свойство $field встречается более одного раза")
            }
            else {
                $fields[$field] = $Matches[2].Trim()
            }
        }
    }
    foreach ($property in $requiredProperties) {
        if (-not $fields.ContainsKey($property)) {
            $errors.Add("${relative}: отсутствует свойство $property")
        }
    }
    if ($fields.ContainsKey('title')) {
        $title = $fields['title']
        if ([string]::IsNullOrWhiteSpace($title)) {
            $errors.Add("${relative}: свойство title не должно быть пустым")
        }
        elseif ($title.StartsWith('"') -and
            $title -notmatch '^"(?:[^"\\]|\\["\\/bfnrt]|\\u[0-9A-Fa-f]{4})*"$') {
            $errors.Add("${relative}: некорректная строка YAML в свойстве title")
        }
        elseif ($title.StartsWith("'") -and $title -notmatch "^'(?:[^']|'')*'$") {
            $errors.Add("${relative}: некорректная строка YAML в свойстве title")
        }
    }
    foreach ($property in @('created', 'updated')) {
        if (-not $fields.ContainsKey($property)) { continue }
        $date = $fields[$property]
        if ($date.StartsWith('"')) {
            if ($date -notmatch '^"(?<value>[^"]*)"$') {
                $errors.Add("${relative}: некорректная строка YAML в свойстве $property")
                continue
            }
            $date = $Matches['value']
        }
        elseif ($date.StartsWith("'")) {
            if ($date -notmatch "^'(?<value>[^']*)'$") {
                $errors.Add("${relative}: некорректная строка YAML в свойстве $property")
                continue
            }
            $date = $Matches['value']
        }
        if (-not (Test-IsoDate $date)) {
            $errors.Add("${relative}: свойство $property должно быть календарной датой ГГГГ-ММ-ДД")
        }
    }
    foreach ($match in [regex]::Matches($text, '\[[^\]]+\]\((?<target>[^)]+)\)')) {
        $target = $match.Groups['target'].Value.Split('#')[0]
        if ([string]::IsNullOrWhiteSpace($target) -or $target -match '^(https?://|mailto:|#)') { continue }
        try {
            $decoded = [System.Uri]::UnescapeDataString($target)
            $full = [System.IO.Path]::GetFullPath((Join-Path $file.DirectoryName $decoded))
            if (-not (Test-PathInsideRoot $root $full)) {
                $errors.Add("${relative}: ссылка выходит за пределы проекта -> $target")
            }
            elseif (-not (Test-Path -LiteralPath $full)) {
                $errors.Add("${relative}: битая ссылка -> $target")
            }
        }
        catch {
            $errors.Add("${relative}: некорректная ссылка -> $target")
        }
    }
}

foreach ($entry in @(
    @{ File = 'DECISIONS.md'; Pattern = '^\|\s*(?<id>[DA]-\d+)\s*\|' },
    @{ File = 'OPEN-QUESTIONS.md'; Pattern = '^\|\s*(?<id>Q-\d+)\s*\|' },
    @{ File = 'SOURCES.md'; Pattern = '^\|\s*(?<id>S-\d+)\s*\|' }
)) {
    $seen = @{}
    $path = Join-Path $root $entry.File
    if (-not (Test-Path -LiteralPath $path)) { continue }
    foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -match $entry.Pattern) {
            $id = $Matches['id']
            if ($seen.ContainsKey($id)) { $errors.Add("$($entry.File): ID $id встречается более одного раза") }
            $seen[$id] = $true
        }
    }
}

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "Проверка не пройдена: ошибок — $($errors.Count). $($errors -join '; ')"
}
Write-Host "Проверка пройдена: файлов — $($markdown.Count), ошибок нет."
