[CmdletBinding()]
param(
    [string]$OutputPath
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

& (Join-Path $PSScriptRoot 'test-template.ps1')

$parent = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Path $parent -Force | Out-Null
if (Test-Path -LiteralPath $OutputPath) {
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

