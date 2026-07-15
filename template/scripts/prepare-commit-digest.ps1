[CmdletBinding()]
param(
    [string[]]$ChangedFile,
    [string[]]$Check,
    [string]$OutputPath = '.project/commit-digest.md',
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$templatePath = Join-Path $root '_templates/Commit digest.md'
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Test-PathInsideRoot([string]$Root, [string]$Candidate) {
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
    $candidateFull = [System.IO.Path]::GetFullPath($Candidate)
    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    return $candidateFull.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, $comparison)
}

function Assert-IsoDate([string]$Value) {
    [DateTime]$parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact(
            $Value,
            'yyyy-MM-dd',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$parsed
        )) {
        throw 'Date должен быть существующей календарной датой в формате ГГГГ-ММ-ДД.'
    }
}

function ConvertTo-Bullets([string[]]$Values, [string]$EmptyText) {
    $safe = @($Values | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($safe.Count -eq 0) { return "- $EmptyText" }
    foreach ($value in $safe) {
        if ($value -match '[\r\n\x00-\x08\x0B\x0C\x0E-\x1F]') {
            throw 'Элемент дайджеста не должен содержать переносы строк или управляющие символы.'
        }
    }
    return ($safe | ForEach-Object { "- ``$_``" }) -join "`n"
}

Assert-IsoDate $Date
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
    throw "Не найден шаблон дайджеста: $templatePath"
}

$outputFull = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
    [System.IO.Path]::GetFullPath($OutputPath)
}
else {
    [System.IO.Path]::GetFullPath((Join-Path $root $OutputPath))
}
if (-not (Test-PathInsideRoot $root $outputFull)) {
    throw 'OutputPath выходит за пределы проекта.'
}
if ((Test-Path -LiteralPath $outputFull) -and -not $Force) {
    throw "Файл уже существует: $OutputPath. Для замены укажите -Force."
}

if ($null -eq $ChangedFile -or $ChangedFile.Count -eq 0) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        throw 'Git не найден. Укажите изменённые файлы через -ChangedFile.'
    }
    $status = @(& git -C $root status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось получить список изменений Git.' }
    $ChangedFile = @($status | ForEach-Object {
            if ($_.Length -lt 4) { return }
            $path = $_.Substring(3)
            if ($path -match ' -> ') { $path = ($path -split ' -> ', 2)[1] }
            $path.Trim('"')
        })
}

$changedBlock = ConvertTo-Bullets $ChangedFile 'Изменённых файлов нет.'
$checkBlock = ConvertTo-Bullets $Check 'Проверки ещё не указаны.'
$text = [System.IO.File]::ReadAllText($templatePath)
$dateToken = '{{' + 'DATE' + '}}'
$changedFilesToken = '{{' + 'CHANGED_FILES' + '}}'
$checksToken = '{{' + 'CHECKS' + '}}'
$text = $text.Replace($dateToken, $Date)
$text = $text.Replace($changedFilesToken, $changedBlock)
$text = $text.Replace($checksToken, $checkBlock)

$directory = Split-Path -Parent $outputFull
[System.IO.Directory]::CreateDirectory($directory) | Out-Null
$temporary = "$outputFull.tmp-$([Guid]::NewGuid().ToString('N'))"
try {
    [System.IO.File]::WriteAllText($temporary, $text.TrimEnd() + "`n", $utf8)
    [System.IO.File]::Move($temporary, $outputFull, $true)
}
finally {
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Force
    }
}

$relative = [System.IO.Path]::GetRelativePath($root, $outputFull).Replace('\', '/')
Write-Host "Подготовлен дайджест: $relative"
