[CmdletBinding()]
param(
    [string]$Tag
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$versionPath = Join-Path $root 'VERSION'
$templateVersionPath = Join-Path $root 'template/TEMPLATE-VERSION'
$changelogPath = Join-Path $root 'CHANGELOG.md'

foreach ($path in @($versionPath, $templateVersionPath, $changelogPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Отсутствует обязательный файл версии: $path"
    }
}

$version = [System.IO.File]::ReadAllText($versionPath).Trim()
if ($version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
    throw "VERSION содержит некорректную семантическую версию: '$version'."
}

$templateVersion = [System.IO.File]::ReadAllText($templateVersionPath).Trim()
if ($templateVersion -cne $version) {
    throw "VERSION ($version) и template/TEMPLATE-VERSION ($templateVersion) не совпадают."
}

$changelog = [System.IO.File]::ReadAllText($changelogPath)
if ($changelog -notmatch ('(?m)^##\s+' + [regex]::Escape($version) + '(?:\s|$)')) {
    throw "В CHANGELOG.md отсутствует раздел версии $version."
}

if (-not [string]::IsNullOrWhiteSpace($Tag)) {
    $tagVersion = if ($Tag.StartsWith('v')) { $Tag.Substring(1) } else { $Tag }
    if ($tagVersion -cne $version) {
        throw "Тег '$Tag' не соответствует VERSION ($version)."
    }
}

Write-Host "Версия согласована: $version."
