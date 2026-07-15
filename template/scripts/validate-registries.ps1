[CmdletBinding()]
param(
    [string]$ProjectPath = (Join-Path $PSScriptRoot '..')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath($ProjectPath)
$schemaPath = Join-Path $root 'REGISTRY-SCHEMA.json'
$versionPath = Join-Path $root 'TEMPLATE-VERSION'
$errors = [System.Collections.Generic.List[string]]::new()

function Split-MarkdownRow([string]$Line) {
    $trimmed = $Line.Trim()
    if (-not $trimmed.StartsWith('|')) { return @() }
    $body = $trimmed.Substring(1)
    if ($body.EndsWith('|')) { $body = $body.Substring(0, $body.Length - 1) }
    return @([regex]::Split($body, '(?<!\\)\|') | ForEach-Object { $_.Trim() })
}

foreach ($path in @($schemaPath, $versionPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Отсутствует обязательный файл проверки реестров: $path"
    }
}

$schema = [System.IO.File]::ReadAllText($schemaPath) | ConvertFrom-Json
if ($schema.schemaVersion -ne 1) { throw 'Поддерживается только schemaVersion = 1 для реестров.' }
if ($null -eq $schema.registries -or @($schema.registries).Count -eq 0) {
    throw 'В REGISTRY-SCHEMA.json не описаны реестры.'
}
$templateVersion = [System.IO.File]::ReadAllText($versionPath).Trim()
if (@($schema.compatibleTemplateVersions) -notcontains $templateVersion) {
    $errors.Add("Версия шаблона $templateVersion не указана как совместимая со схемой реестров.")
}

foreach ($registry in $schema.registries) {
    if ([string]::IsNullOrWhiteSpace($registry.path)) {
        $errors.Add('В схеме найден реестр без path.')
        continue
    }
    $path = Join-Path $root $registry.path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $errors.Add("Отсутствует реестр: $($registry.path)")
        continue
    }
    $formats = @($registry.formats)
    if ($formats.Count -eq 0) {
        $errors.Add("Для $($registry.path) не описаны форматы строк.")
        continue
    }
    $seen = @{}
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $path) {
        $lineNumber++
        $cells = @(Split-MarkdownRow $line)
        if ($cells.Count -eq 0) { continue }
        $id = $cells[0]
        if ($id -notmatch '^[A-Z]-\d+$') { continue }

        $matching = @($formats | Where-Object { $id -match $_.idPattern })
        if ($matching.Count -eq 0) {
            $errors.Add("$($registry.path):$($lineNumber): ID $id не поддерживается этим реестром")
            continue
        }
        $supportedWidths = @($matching | ForEach-Object { @($_.columns) } | Select-Object -Unique)
        if ($supportedWidths -notcontains $cells.Count) {
            $errors.Add(
                "$($registry.path):$($lineNumber): строка $id содержит колонок — $($cells.Count), поддерживается: $($supportedWidths -join ', ')"
            )
        }
        if ($seen.ContainsKey($id)) {
            $errors.Add("$($registry.path): ID $id встречается более одного раза")
        }
        $seen[$id] = $true
    }
}

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "Проверка реестров не пройдена: ошибок — $($errors.Count). $($errors -join '; ')"
}
Write-Host "Проверка реестров пройдена: схема — $($schema.schemaVersion), версия шаблона — $templateVersion."
