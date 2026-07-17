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
    $copiedProjectState = Join-Path $test '.project'
    if (Test-Path -LiteralPath $copiedProjectState) {
        Remove-Item -LiteralPath $copiedProjectState -Recurse -Force
    }
    & (Join-Path $test 'scripts/init-project.ps1') -Title 'Проверка контекста' -Slug 'context-test' -Date $Date
    $builder = Join-Path $test 'scripts/build-context.ps1'
    $healthChecker = Join-Path $test 'scripts/check-context-health.ps1'

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
    if ($report.schemaVersion -ne 2 -or
        [string]::IsNullOrWhiteSpace([string]$report.sourceFingerprint) -or
        [string]::IsNullOrWhiteSpace([string]$report.contextFingerprint) -or
        $null -eq $report.utilizationPercent -or @($report.sourceFiles).Count -eq 0) {
        throw 'Отчёт локального пакета не содержит метрики и отпечатки здоровья контекста.'
    }

    & $healthChecker -Date $Date -UpdateBaseline -Check
    $healthPath = Join-Path $test '.project/context/context-health.json'
    $baselinePath = Join-Path $test '.project/context/context-baseline.json'
    $health = [System.IO.File]::ReadAllText($healthPath) | ConvertFrom-Json
    if ($health.status -eq 'critical' -or @($health.errors).Count -gt 0 -or
        -not (Test-Path -LiteralPath $baselinePath -PathType Leaf)) {
        throw 'Проверка здоровья не подтвердила исходный пакет или не создала эталон.'
    }

    $briefPath = Join-Path $test 'PROJECT-BRIEF.md'
    $briefOriginal = [System.IO.File]::ReadAllText($briefPath)
    [System.IO.File]::WriteAllText($briefPath, $briefOriginal + "`n<!-- CONTEXT-STALE -->`n", $utf8)
    Assert-Throws {
        & $healthChecker -Date $Date -Check
    } 'контекст устарел.*PROJECT-BRIEF\.md' 'изменение канонического источника делает пакет устаревшим'
    [System.IO.File]::WriteAllText($briefPath, $briefOriginal, $utf8)

    $contextOriginal = [System.IO.File]::ReadAllText($outputPath)
    [System.IO.File]::WriteAllText($outputPath, $contextOriginal + "`n<!-- CONTEXT-TAMPER -->`n", $utf8)
    Assert-Throws {
        & $healthChecker -Date $Date -Check
    } 'пакет изменён после формирования отчёта' 'изменение собранного пакета обнаруживается'
    [System.IO.File]::WriteAllText($outputPath, $contextOriginal, $utf8)

    $handoffPath = Join-Path $test 'HANDOFF.md'
    $handoffOriginal = [System.IO.File]::ReadAllText($handoffPath)
    $oldDate = [DateTime]::ParseExact(
        $Date,
        'yyyy-MM-dd',
        [System.Globalization.CultureInfo]::InvariantCulture
    ).AddDays(-30).ToString('yyyy-MM-dd')
    $oldHandoff = $handoffOriginal -replace '(?m)^updated:\s*.*$', "updated: `"$oldDate`""
    [System.IO.File]::WriteAllText($handoffPath, $oldHandoff, $utf8)
    & $builder -Profile compact -IncludeId D-040,Q-001 -Query 'утверждает бриф' -Check
    Assert-Throws {
        & $healthChecker -Date $Date -Check
    } 'HANDOFF\.md устарел' 'просроченная точка передачи обнаруживается'
    [System.IO.File]::WriteAllText($handoffPath, $handoffOriginal, $utf8)
    & $builder -Profile compact -IncludeId D-040,Q-001 -Query 'утверждает бриф' -Check
    & $healthChecker -Date $Date -UpdateBaseline -Check

    $baseline = [System.IO.File]::ReadAllText($baselinePath) | ConvertFrom-Json
    $baseline.utilizationPercent = [Math]::Max(0, [decimal]$baseline.utilizationPercent - 20)
    [System.IO.File]::WriteAllText($baselinePath, ($baseline | ConvertTo-Json -Depth 5) + "`n", $utf8)
    & $healthChecker -Date $Date
    $regressionHealth = [System.IO.File]::ReadAllText($healthPath) | ConvertFrom-Json
    if (@($regressionHealth.regressions) -notmatch 'заполнение выросло') {
        throw 'Проверка здоровья не обнаружила ухудшение относительно эталона.'
    }
    & $healthChecker -Date $Date -UpdateBaseline -Check

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

    $handoff = [System.IO.File]::ReadAllText($handoffPath)
    $handoff = $handoff -replace '(?m)^## 6\. Что остаётся неподтверждённым\s*$', '### Раздел временно утрачен'
    [System.IO.File]::WriteAllText($handoffPath, $handoff, $utf8)
    Assert-Throws {
        & $builder -Profile compact -IncludeId D-001 -Check
    } 'неполный HANDOFF' 'неполная передача контекста обнаруживается'

    [System.IO.File]::WriteAllText($handoffPath, $handoffOriginal, $utf8)
    Assert-Throws {
        & $builder -Profile compact -TokenBudget 512 -IncludeId D-001 -Check
    } 'не вошли в бюджет|критическое заполнение' 'опасное усечение по бюджету блокируется'

    $scriptText = [System.IO.File]::ReadAllText($builder) + [System.IO.File]::ReadAllText($healthChecker)
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
