[CmdletBinding()]
param(
    [string]$OutputPath,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $root 'template'
$dist = Join-Path $root 'dist'
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $dist 'proektnaya-osnova-template.zip'
}
elseif (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $root $OutputPath
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$sourcePrefix = [System.IO.Path]::GetFullPath($source).TrimEnd([char[]]@('\', '/')) +
    [System.IO.Path]::DirectorySeparatorChar
$comparison = if ($IsWindows) {
    [System.StringComparison]::OrdinalIgnoreCase
}
else {
    [System.StringComparison]::Ordinal
}
if ([System.IO.Path]::GetExtension($OutputPath) -ne '.zip') {
    throw 'Выходной файл должен иметь расширение .zip.'
}
if ($OutputPath.StartsWith($sourcePrefix, $comparison)) {
    throw 'Нельзя создавать архив внутри папки template.'
}

& (Join-Path $PSScriptRoot 'test-template.ps1')

$parent = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Path $parent -Force | Out-Null
if (Test-Path -LiteralPath $OutputPath) {
    if (-not $Force) {
        throw "Файл уже существует: $OutputPath. Для замены укажите -Force."
    }
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        throw "Выходной путь не является файлом: $OutputPath"
    }
    Remove-Item -LiteralPath $OutputPath -Force
}
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $source,
    $OutputPath,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $false
)

$archive = [System.IO.Compression.ZipFile]::OpenRead($OutputPath)
try {
    if ($archive.Entries.Count -eq 0) {
        throw 'Создан пустой архив.'
    }
    Write-Host "Архив создан: $OutputPath ($($archive.Entries.Count) файлов)."
}
finally {
    $archive.Dispose()
}
