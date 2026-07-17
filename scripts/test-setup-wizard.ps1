[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $root 'template'
$runId = [Guid]::NewGuid().ToString('N')
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $root ".tmp-setup-wizard-$runId"))

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

function New-WizardFixture([string]$Name) {
    $path = Join-Path $testRoot $Name
    Copy-Item -LiteralPath $source -Destination $path -Recurse
    return $path
}

if (-not $testRoot.StartsWith(
        $root + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'Небезопасный путь теста мастера настройки.'
}

try {
    [System.IO.Directory]::CreateDirectory($testRoot) | Out-Null

    $planProject = New-WizardFixture 'plan-only'
    & (Join-Path $planProject 'scripts/setup-project.ps1') `
        -Title 'План настройки' -NonInteractive -Date '2026-07-17'
    $planReadme = [System.IO.File]::ReadAllText((Join-Path $planProject 'README.md'))
    $planChanged = @(
        $planReadme -notmatch '\{\{PROJECT_TITLE\}\}'
        Test-Path -LiteralPath (Join-Path $planProject '.project/setup-report.json')
    ) -contains $true
    if ($planChanged) {
        throw 'Режим плана изменил файлы проекта.'
    }

    $project = New-WizardFixture 'configured'
    & (Join-Path $project 'scripts/setup-project.ps1') `
        -Title 'Проект Ёлка 2026' `
        -ManagementProfile regulated `
        -DeliveryApproach adaptive `
        -WorkSystemType jira `
        -WorkSystemUrl 'https://jira.example.org/project/ELKA' `
        -DataClassification confidential `
        -ScheduleToleranceDays 5 `
        -CostVariancePercent 10 `
        -NonInteractive -Apply -Date '2026-07-17'

    $config = [System.IO.File]::ReadAllText((Join-Path $project 'PROJECT-CONFIG.json')) | ConvertFrom-Json
    $configInvalid = @(
        $config.projectSlug -cne 'proekt-elka-2026'
        $config.managementProfile -cne 'regulated'
        $config.deliveryApproach -cne 'adaptive'
        $config.workSystem.type -cne 'jira'
        $config.workSystem.url -cne 'https://jira.example.org/project/ELKA'
        $config.dataClassification -cne 'confidential'
        $config.aiGovernanceLevel -cne 'high'
        $config.tolerances.scheduleDays -ne 5
        $config.tolerances.costVariancePercent -ne 10
    ) -contains $true
    if ($configInvalid) {
        throw 'Мастер неверно сохранил выбранные параметры.'
    }

    $report = [System.IO.File]::ReadAllText((Join-Path $project '.project/setup-report.json')) | ConvertFrom-Json
    $reportInvalid = @(
        $report.result -cne 'success'
        $report.projectSlug -cne 'proekt-elka-2026'
        @($report.unresolvedDecisions).Count -ne 0
        $report.nextDocument -cne 'HOME.md'
    ) -contains $true
    if ($reportInvalid) {
        throw 'Отчёт мастера не подтверждает завершённую настройку.'
    }

    & (Join-Path $project 'scripts/build-status.ps1') -Check
    & (Join-Path $project 'scripts/check-project-health.ps1') -Date '2026-07-17'
    & (Join-Path $project 'scripts/build-project-dossier.ps1') -Check
    & (Join-Path $project 'scripts/validate-vault.ps1')

    Assert-Throws {
        & (Join-Path $project 'scripts/setup-project.ps1') `
            -Title 'Повтор' -NonInteractive -Apply -Date '2026-07-17'
    } 'уже инициализирован' 'повторная инициализация отклоняется'

    $invalidUrl = New-WizardFixture 'invalid-url'
    Assert-Throws {
        & (Join-Path $invalidUrl 'scripts/setup-project.ps1') `
            -Title 'Плохой адрес' -WorkSystemType jira -WorkSystemUrl 'http://unsafe.example' `
            -NonInteractive -Apply -Date '2026-07-17'
    } 'начинаться с https://' 'небезопасный адрес рабочей системы отклоняется'
    if ([System.IO.File]::ReadAllText((Join-Path $invalidUrl 'README.md')) -notmatch '\{\{PROJECT_TITLE\}\}') {
        throw 'Ошибка проверки адреса частично инициализировала проект.'
    }

    $invalidTolerance = New-WizardFixture 'invalid-tolerance'
    Assert-Throws {
        & (Join-Path $invalidTolerance 'scripts/setup-project.ps1') `
            -Title 'Плохой допуск' -ScheduleToleranceDays -1 `
            -NonInteractive -Apply -Date '2026-07-17'
    } 'не может быть отрицательным' 'отрицательный допуск отклоняется'

    Write-Host 'Мастер первоначальной настройки прошёл проверку.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        if (-not $testRoot.StartsWith(
                $root + [System.IO.Path]::DirectorySeparatorChar,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            throw 'Небезопасное удаление папки теста мастера.'
        }
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
