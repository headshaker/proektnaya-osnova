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
$checksumPath = $OutputPath + '.sha256'

foreach ($target in @($OutputPath, $checksumPath)) {
    if (-not (Test-Path -LiteralPath $target)) { continue }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        throw "Выходной путь не является файлом: $target"
    }
    if (-not $Force) {
        throw "Файл уже существует: $target. Для замены укажите -Force."
    }
}

& (Join-Path $PSScriptRoot 'test-template.ps1')

$parent = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$temporaryId = [Guid]::NewGuid().ToString('N')
$temporaryArchive = Join-Path $parent ('.' + [System.IO.Path]::GetFileName($OutputPath) + ".$temporaryId.tmp")
$temporaryChecksum = $temporaryArchive + '.sha256'
try {
    $archiveStream = [System.IO.File]::Open(
        $temporaryArchive,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    try {
        $writer = [System.IO.Compression.ZipArchive]::new(
            $archiveStream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $true
        )
        try {
            $files = Get-ChildItem -LiteralPath $source -Recurse -File -Force |
                Where-Object {
                    $candidate = [System.IO.Path]::GetRelativePath($source, $_.FullName).Replace('\', '/')
                    $candidate -notmatch '^setup-ui/(?:node_modules|\.npm-cache)/'
                } |
                Sort-Object { [System.IO.Path]::GetRelativePath($source, $_.FullName).Replace('\', '/') }
            $fixedTimestamp = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            foreach ($file in $files) {
                $relative = [System.IO.Path]::GetRelativePath($source, $file.FullName).Replace('\', '/')
                $compression = if ($relative.StartsWith('setup-ui/runtime/', [System.StringComparison]::Ordinal)) {
                    [System.IO.Compression.CompressionLevel]::Optimal
                }
                else {
                    [System.IO.Compression.CompressionLevel]::NoCompression
                }
                $entry = $writer.CreateEntry($relative, $compression)
                $entry.LastWriteTime = $fixedTimestamp
                $outputStream = $entry.Open()
                try {
                    if ([System.IO.Path]::GetExtension($file.Name) -ceq '.cmd') {
                        $text = [System.IO.File]::ReadAllText($file.FullName)
                        $crlfText = $text.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", "`r`n")
                        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($crlfText)
                        $outputStream.Write($bytes, 0, $bytes.Length)
                    }
                    else {
                        $inputStream = [System.IO.File]::OpenRead($file.FullName)
                        try { $inputStream.CopyTo($outputStream) }
                        finally { $inputStream.Dispose() }
                    }
                }
                finally {
                    $outputStream.Dispose()
                }
            }
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $archiveStream.Dispose()
    }

    $archive = [System.IO.Compression.ZipFile]::OpenRead($temporaryArchive)
    try {
        if ($archive.Entries.Count -eq 0) {
            throw 'Создан пустой архив.'
        }
        $entryCount = $archive.Entries.Count
    }
    finally {
        $archive.Dispose()
    }

    $hash = (Get-FileHash -LiteralPath $temporaryArchive -Algorithm SHA256).Hash
    $checksumLine = $hash + '  ' + [System.IO.Path]::GetFileName($OutputPath) + "`n"
    [System.IO.File]::WriteAllText(
        $temporaryChecksum,
        $checksumLine,
        [System.Text.UTF8Encoding]::new($false)
    )

    foreach ($target in @($OutputPath, $checksumPath)) {
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            Remove-Item -LiteralPath $target -Force
        }
    }

    Move-Item -LiteralPath $temporaryArchive -Destination $OutputPath
    Move-Item -LiteralPath $temporaryChecksum -Destination $checksumPath
    Write-Host "Архив создан: $OutputPath ($entryCount файлов)."
    Write-Host "SHA-256: $checksumPath"
}
finally {
    foreach ($temporary in @($temporaryArchive, $temporaryChecksum)) {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}
