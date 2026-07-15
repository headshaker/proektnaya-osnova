[CmdletBinding()]
param([string]$Date = '2026-07-15')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $root 'template'
$runId = [Guid]::NewGuid().ToString('N')
$test = [System.IO.Path]::GetFullPath((Join-Path $root ".tmp-context-test-$runId"))
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Description) {
    try { & $Action 2>&1 | Out-Null }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "Негативная проверка '$Description' завершилась неожиданной ошибкой: $($_.Exception.Message)"
        }
        Write-Host "Негативная проверка пройдена: $Description."
        return
    }
    throw "Негативная проверка не сработала: $Description."
}

if (-not $test.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Небезопасный путь тестовой папки контекста.'
}

try {
    Copy-Item -LiteralPath $source -Destination $test -Recurse
    & (Join-Path $test 'scripts/init-project.ps1') -Title 'Проверка контекста' -Slug 'context-test' -Date $Date
    $builder = Join-Path $test 'scripts/build-context.ps1'

    $decisionsPath = Join-Path $test 'DECISIONS.md'
    $decisions = [System.IO.File]::ReadAllText($decisionsPath)
    foreach ($number in 2..40) {
        $id = 'D-{0:D3}' -f $number
        $decisions += "`n| $id | $Date | Решение $number | Контекст $number | Последствие $number | Основание $number | Пересмотр $number |"
    }
    [System.IO.File]::WriteAllText($decisionsPath, $decisions + "`n", $utf8)

    & $builder -Profile compact -IncludeId D-040,Q-001 -Query 'утверждает бриф' -Check
    $outputPath = Join-Path $test '.project/context/context.md'
    $reportPath = Join-Path $test '.project/context/context-report.json'
    $output = [System.IO.File]::ReadAllText($outputPath)
    $report = [System.IO.File]::ReadAllText($reportPath) | ConvertFrom-Json
    if ($output -notmatch 'D-040' -or $output -notmatch 'Q-001' -or $output -match 'D-002') {
        throw 'Адресная загрузка реестра не выделила только требуемые записи.'
    }
    if (-not $report.complete -or $report.completenessScore -ne 100 -or
        -not $report.localOnly -or $report.transmissionPerformed -or $report.networkRequests -ne 0) {
        throw 'Отчёт локального пакета содержит неверную полноту или режим передачи.'
    }

    & pwsh -NoProfile -File $builder -Profile compact -IncludeId 'D-040,Q-001' `
        -OutputPath '.project/context/cli-context.md' `
        -ReportPath '.project/context/cli-report.json' -Check
    if ($LASTEXITCODE -ne 0) { throw 'Вызов build-context.ps1 через pwsh завершился ошибкой.' }
    $cliReport = [System.IO.File]::ReadAllText((Join-Path $test '.project/context/cli-report.json')) | ConvertFrom-Json
    if (@($cliReport.includedRegistryIds) -notcontains 'D-040' -or
        @($cliReport.includedRegistryIds) -notcontains 'Q-001') {
        throw 'Список ID через запятую не распознан при вызове через pwsh.'
    }

    Assert-Throws {
        & $builder -Profile compact -IncludeId D-999 -Check
    } 'не найдены ID' 'отсутствующий адресный ID делает пакет неполным'

    Assert-Throws {
        & $builder -Profile compact -OutputPath 'context.md'
    } 'внутри \.project/context' 'локальный режим не пишет передаваемый файл в корень'

    Assert-Throws {
        & $builder -Profile compact -Export -OutputPath 'README.md' -ReportPath 'exports/report.json'
    } 'внутри exports' 'экспорт не заменяет канонический файл'

    $handoffPath = Join-Path $test 'HANDOFF.md'
    $handoff = [System.IO.File]::ReadAllText($handoffPath)
    $handoff = $handoff -replace '(?m)^## 6\. Что остаётся неподтверждённым\s*$', '### Раздел временно утрачен'
    [System.IO.File]::WriteAllText($handoffPath, $handoff, $utf8)
    Assert-Throws {
        & $builder -Profile compact -IncludeId D-001 -Check
    } 'неполный HANDOFF' 'неполная передача контекста обнаруживается'

    $scriptText = [System.IO.File]::ReadAllText($builder)
    if ($scriptText -match '(?i)Invoke-WebRequest|Invoke-RestMethod|System\.Net\.Http|curl\b|wget\b|\bgh\s') {
        throw 'Локальный сборщик содержит сетевую операцию.'
    }

    Write-Host 'Сценарии управления контекстом пройдены.'
}
finally {
    if (Test-Path -LiteralPath $test) {
        if (-not $test.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Небезопасное удаление тестовой папки контекста.'
        }
        Remove-Item -LiteralPath $test -Recurse -Force
    }
}
