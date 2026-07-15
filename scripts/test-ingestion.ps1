[CmdletBinding()]
param([string]$Date = '2026-07-16')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $root 'template'
$runId = [Guid]::NewGuid().ToString('N')
$test = [System.IO.Path]::GetFullPath((Join-Path $root ".tmp-ingestion-test-$runId"))
$utf8 = [System.Text.UTF8Encoding]::new($false)

if (-not $test.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Небезопасный путь папки теста импорта.'
}

try {
    Copy-Item -LiteralPath $source -Destination $test -Recurse
    & (Join-Path $test 'scripts/init-project.ps1') `
        -Title 'Проверка обработки файлов' -Slug 'ingestion-test' -Date $Date

    $attachment = Join-Path $test '_attachments/sample.md'
    [System.IO.File]::WriteAllText(
        $attachment,
        "# Договор`n`n## SLA`n`nДоступность 99,9%.`n`n## Ответственность`n`nШтраф 10%.`n",
        $utf8
    )
    $sourcesPath = Join-Path $test 'SOURCES.md'
    $sources = [System.IO.File]::ReadAllText($sourcesPath)
    $sources += "`n| S-002 | _attachments/sample.md | Первичный материал | SLA | $Date | $Date | Владелец | При изменении |`n"
    [System.IO.File]::WriteAllText($sourcesPath, $sources, $utf8)

    & (Join-Path $test 'scripts/ingest-sources.ps1') -SourceId S-002
    $manifestPath = Join-Path $test '.project/sources/S-002/manifest.json'
    $manifest = [System.IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    if ($manifest.cacheHit -or $manifest.chunkCount -lt 1) {
        throw 'Первичная обработка неверно описана как попадание в кэш.'
    }

    & (Join-Path $test 'scripts/ingest-sources.ps1') -SourceId S-002
    & (Join-Path $test 'scripts/build-ai-package.ps1') `
        -Profile compact -ExpandSource S-002 -SourceQuery 'SLA' -RefreshSources -Check

    $package = [System.IO.File]::ReadAllText((Join-Path $test '.project/context/ai-package.md'))
    $report = [System.IO.File]::ReadAllText((Join-Path $test '.project/context/ai-package-report.json')) | ConvertFrom-Json
    if ($package -notmatch 'S-002-C\d+' -or $package -notmatch 'Доступность 99,9' -or
        -not $report.complete -or $report.sourceIncludedTokens -le 0 -or
        $report.sourceReductionPercent -lt 0) {
        throw 'AI-пакет не содержит выбранный фрагмент или некорректный отчёт.'
    }

    [System.IO.File]::AppendAllText($attachment, "`nИзменение исходника.`n", $utf8)
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $python) { $python = Get-Command python3 -ErrorAction Stop }
    $verify = @(& $python.Source (Join-Path $test 'scripts/source-ingestion.py') verify 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Проверка кэша завершилась ошибкой: $($verify -join [Environment]::NewLine)" }
    $verifyReport = ($verify -join "`n") | ConvertFrom-Json
    if ($verifyReport.complete) { throw 'Изменение исходника не сделало кэш устаревшим.' }

    Write-Host 'Сценарии автоматической обработки файлов пройдены.'
}
finally {
    if (Test-Path -LiteralPath $test) {
        if (-not $test.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar,
                [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Небезопасное удаление папки теста импорта.'
        }
        Remove-Item -LiteralPath $test -Recurse -Force
    }
}
