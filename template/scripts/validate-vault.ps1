[CmdletBinding()]
param([switch]$AllowPlaceholders)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$errors = [System.Collections.Generic.List[string]]::new()
$requiredFiles = @(
    'README.md', 'AGENTS.md', 'PROJECT-BRIEF.md', 'DECISIONS.md',
    'OPEN-QUESTIONS.md', 'SOURCES.md', 'GLOSSARY.md', 'HANDOFF.md',
    'CHANGELOG.md', 'OBSIDIAN.md'
)
$requiredProperties = @('title', 'aliases', 'type', 'status', 'created', 'updated', 'tags')

foreach ($file in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $file) -PathType Leaf)) {
        $errors.Add("Отсутствует обязательный файл: $file")
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
    foreach ($property in $requiredProperties) {
        if (-not ($lines[1..($end - 1)] -match ('^' + [regex]::Escape($property) + ':'))) {
            $errors.Add("${relative}: отсутствует свойство $property")
        }
    }
    foreach ($match in [regex]::Matches($text, '\[[^\]]+\]\((?<target>[^)]+)\)')) {
        $target = $match.Groups['target'].Value.Split('#')[0]
        if ([string]::IsNullOrWhiteSpace($target) -or $target -match '^(https?://|mailto:|#)') { continue }
        $decoded = [System.Uri]::UnescapeDataString($target)
        $full = [System.IO.Path]::GetFullPath((Join-Path $file.DirectoryName $decoded))
        if (-not (Test-Path -LiteralPath $full)) { $errors.Add("${relative}: битая ссылка -> $target") }
    }
}

foreach ($entry in @(
    @{ File = 'DECISIONS.md'; Pattern = '^\|\s*(?<id>[DA]-\d+)\s*\|' },
    @{ File = 'OPEN-QUESTIONS.md'; Pattern = '^\|\s*(?<id>Q-\d+)\s*\|' }
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
    throw "Проверка не пройдена: ошибок — $($errors.Count)."
}
Write-Host "Проверка пройдена: файлов — $($markdown.Count), ошибок нет."
