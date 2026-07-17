[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $root 'template'
$runId = [Guid]::NewGuid().ToString('N')
$test = [System.IO.Path]::GetFullPath((Join-Path $root ".tmp-project-control-test-$runId"))
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

if (-not $test.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Небезопасный путь теста управляющего контура.'
}

try {
    Copy-Item -LiteralPath $source -Destination $test -Recurse
    & (Join-Path $test 'scripts/init-project.ps1') `
        -Title 'Проверка управляющего контура' -Slug 'project-control-test' -Date '2026-07-17'

    & (Join-Path $test 'scripts/build-status.ps1') -Check
    & (Join-Path $test 'scripts/check-project-health.ps1') -Date '2026-07-17'

    $add = Join-Path $test 'scripts/add-control.ps1'
    & $add benefit -Title 'Сократить время согласования' -Owner 'Владелец продукта' `
        -Metric 'Медианное время согласования' -Baseline '10 дней' -Target '5 дней' `
        -ReviewDate '2026-08-31' -Status 'Запланирована'
    & $add risk -Title 'Задержка исходных данных' -Cause 'Нет владельца данных' `
        -Effect 'Сдвиг контрольного рубежа' -Owner 'Руководитель поставки' -Due '2026-08-01'
    & $add issue -Title 'Недоступна тестовая среда' -Impact 'Проверка заблокирована' `
        -Owner 'Технический руководитель' -Due '2026-07-25'
    & $add dependency -Title 'Доступ к API' -Provider 'Внешняя команда' `
        -NeededBy '2026-08-10' -ReviewDate '2026-07-24' -Owner 'Интеграционный лидер'
    & $add change -Title 'Расширить пилот' -Approver 'Спонсор' -ReviewDate '2026-07-30'
    & $add milestone -Title 'Пилот принят' -Effect 'Подтверждена применимость' `
        -Acceptance 'Критерии пилота выполнены' -Approver 'Владелец проекта' `
        -Due '2026-09-01' -ForecastDate '2026-09-03'

    & (Join-Path $test 'scripts/validate-registries.ps1') -ProjectPath $test
    & (Join-Path $test 'scripts/build-status.ps1') -Check
    & (Join-Path $test 'scripts/build-context.ps1') `
        -Profile compact -IncludeId B-001,R-001,G-001 -Check

    $status = [System.IO.File]::ReadAllText((Join-Path $test 'STATUS.md'))
    if ($status -notmatch '\| Записей о выгодах \| 1 \|' -or
        $status -notmatch '\| Активных рисков и возможностей \| 1 \|') {
        throw 'STATUS.md не отразил добавленные управляющие записи.'
    }

    $handoffPath = Join-Path $test 'HANDOFF.md'
    $handoff = [System.IO.File]::ReadAllText($handoffPath)
    $handoff = $handoff.Replace(
        'Проект инициализируется. Бриф, владелец и первый контрольный рубеж требуют заполнения.',
        'Проект готовится к первому измеримому результату.'
    )
    [System.IO.File]::WriteAllText($handoffPath, $handoff, $utf8)
    Assert-Throws {
        & (Join-Path $test 'scripts/build-status.ps1') -Check
    } 'STATUS.md устарел' 'изменение канонического состояния делает STATUS.md устаревшим'
    & (Join-Path $test 'scripts/build-status.ps1')

    $configPath = Join-Path $test 'PROJECT-CONFIG.json'
    $config = [System.IO.File]::ReadAllText($configPath) | ConvertFrom-Json
    $config.managementProfile = 'unknown'
    [System.IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 10) + "`n", $utf8)
    Assert-Throws {
        & (Join-Path $test 'scripts/check-project-health.ps1') -Date '2026-07-17'
    } 'не пройдена' 'неизвестный профиль управления отклоняется'

    $config.managementProfile = 'standard'
    $config.workSystem.type = 'repository'
    $config.dataClassification = 'internal'
    $config.tolerances.scheduleDays = 14
    $config.tolerances.costVariancePercent = 10
    [System.IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 10) + "`n", $utf8)
    & (Join-Path $test 'scripts/build-status.ps1')
    & (Join-Path $test 'scripts/check-project-health.ps1') -Date '2026-07-17' -Strict

    Write-Host 'Управляющий контур проекта прошёл проверку.'
}
finally {
    if (Test-Path -LiteralPath $test) {
        if (-not $test.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar,
                [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Небезопасное удаление тестовой папки управляющего контура.'
        }
        Remove-Item -LiteralPath $test -Recurse -Force
    }
}
