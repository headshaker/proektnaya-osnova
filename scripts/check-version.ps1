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
$templateStatePath = Join-Path $root 'template/TEMPLATE-STATE.json'
$migrationManifestPath = Join-Path $root 'template/migrations/manifest.json'
$setupPackagePath = Join-Path $root 'template/setup-ui/package.json'
$setupLockPath = Join-Path $root 'template/setup-ui/package-lock.json'

foreach ($path in @($versionPath, $templateVersionPath, $changelogPath, $templateStatePath, $migrationManifestPath, $setupPackagePath, $setupLockPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Отсутствует обязательный файл версии: $path"
    }
}

$version = [System.IO.File]::ReadAllText($versionPath).Trim()
if ($version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
    throw "VERSION содержит некорректную семантическую версию: '$version'."
}

$templateState = [System.IO.File]::ReadAllText($templateStatePath) | ConvertFrom-Json
if ($templateState.templateVersion -cne $version) {
    throw "TEMPLATE-STATE.json ($($templateState.templateVersion)) и VERSION ($version) не совпадают."
}
$migrationManifest = [System.IO.File]::ReadAllText($migrationManifestPath) | ConvertFrom-Json
if ($migrationManifest.targetVersion -cne $version) {
    throw "Цель миграций ($($migrationManifest.targetVersion)) и VERSION ($version) не совпадают."
}

$templateVersion = [System.IO.File]::ReadAllText($templateVersionPath).Trim()
if ($templateVersion -cne $version) {
    throw "VERSION ($version) и template/TEMPLATE-VERSION ($templateVersion) не совпадают."
}

$setupPackage = [System.IO.File]::ReadAllText($setupPackagePath) | ConvertFrom-Json
$setupLock = [System.IO.File]::ReadAllText($setupLockPath) | ConvertFrom-Json -AsHashtable -Depth 100
if ([string]$setupPackage.version -cne $version -or [string]$setupLock['version'] -cne $version -or
    [string]$setupLock['packages']['']['version'] -cne $version) {
    throw "Версия Electron-мастера не совпадает с VERSION ($version)."
}
$electronVersion = [string]$setupPackage.devDependencies.electron
if ($electronVersion -notmatch '^\d+\.\d+\.\d+$' -or
    [string]$setupLock['packages']['']['devDependencies']['electron'] -cne $electronVersion) {
    throw 'Версия Electron должна быть точной и совпадать с package-lock.json.'
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
