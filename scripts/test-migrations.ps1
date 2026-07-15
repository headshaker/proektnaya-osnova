[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $root 'template'
$runId = [Guid]::NewGuid().ToString('N')
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $root ".tmp-migration-test-$runId"))
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Description) {
    try {
        & $Action 2>&1 | Out-Null
    }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "Негативная проверка '$Description' завершилась неожиданной ошибкой: $($_.Exception.Message)"
        }
        Write-Host "Негативная проверка пройдена: $Description."
        return
    }
    throw "Негативная проверка не сработала: $Description."
}

function Remove-SafePath([string]$Project, [string]$Relative) {
    $projectFull = [System.IO.Path]::GetFullPath($Project).TrimEnd([char[]]@('\', '/'))
    $path = [System.IO.Path]::GetFullPath((Join-Path $projectFull $Relative))
    if (-not $path.StartsWith(
            $projectFull + [System.IO.Path]::DirectorySeparatorChar,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Небезопасный путь тестового удаления: $Relative"
    }
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
}

function New-ProjectFixture(
    [string]$Name,
    [string]$Version,
    [switch]$WithoutVersion,
    [switch]$Legacy
) {
    $project = Join-Path $testRoot $Name
    Copy-Item -LiteralPath $source -Destination $project -Recurse
    & (Join-Path $project 'scripts/init-project.ps1') `
        -Title "Миграция $Name" -Slug "migration-$Name" -Date '2026-07-01'

    foreach ($relative in @(
            'AI-CONNECTIONS.md',
            'INGESTION-WORKFLOW.md',
            'SOURCE-INGESTION.json',
            'START-HERE.md',
            'scripts/build-ai-package.ps1',
            'scripts/ingest-sources.ps1',
            'scripts/source-ingestion.py'
        )) {
        Remove-SafePath $project $relative
    }

    if ($Version -ceq '0.4.0') {
        $fixtureRoot = Join-Path $root 'tests/fixtures/v0.4.0'
        Copy-Item -LiteralPath (Join-Path $fixtureRoot 'knowledge-base.yml') `
            -Destination (Join-Path $project '.github/workflows/knowledge-base.yml') -Force
        Copy-Item -LiteralPath (Join-Path $fixtureRoot 'manifest.json') `
            -Destination (Join-Path $project 'migrations/manifest.json') -Force
        Copy-Item -LiteralPath (Join-Path $fixtureRoot 'baselines.json') `
            -Destination (Join-Path $project 'migrations/baselines.json') -Force
        $statePath = Join-Path $project 'TEMPLATE-STATE.json'
        $state = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        $state.templateVersion = '0.4.0'
        [System.IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 5) + "`n", $utf8)
    }
    elseif ($Version -ceq '0.3.0') {
        foreach ($relative in @(
                'CONTEXT-PROFILES.json',
                'CONTEXT-WORKFLOW.md',
                'scripts/build-context.ps1'
            )) {
            Remove-SafePath $project $relative
        }
        $fixtureRoot = Join-Path $root 'tests/fixtures/v0.3.0'
        Copy-Item -LiteralPath (Join-Path $fixtureRoot 'knowledge-base.yml') `
            -Destination (Join-Path $project '.github/workflows/knowledge-base.yml') -Force
        Copy-Item -LiteralPath (Join-Path $fixtureRoot 'REGISTRY-SCHEMA.json') `
            -Destination (Join-Path $project 'REGISTRY-SCHEMA.json') -Force
        Copy-Item -LiteralPath (Join-Path $fixtureRoot 'manifest.json') `
            -Destination (Join-Path $project 'migrations/manifest.json') -Force
        Copy-Item -LiteralPath (Join-Path $fixtureRoot 'baselines.json') `
            -Destination (Join-Path $project 'migrations/baselines.json') -Force
        $statePath = Join-Path $project 'TEMPLATE-STATE.json'
        $state = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        $state.templateVersion = '0.3.0'
        [System.IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 5) + "`n", $utf8)
    }
    else {
        foreach ($relative in @(
                'CONTEXT-PROFILES.json',
                'CONTEXT-WORKFLOW.md',
                'MIGRATIONS.md',
                'REGISTRY-SCHEMA.json',
                'TEMPLATE-STATE.json',
                'migrations',
                'scripts/build-context.ps1',
                'scripts/update-project.ps1',
                'scripts/validate-registries.ps1',
                '.github/workflows/registry-compatibility.yml'
            )) {
            Remove-SafePath $project $relative
        }
    }

    if ($Legacy) {
        foreach ($relative in @(
                'DAILY-WORK.md',
                'WORK-PROFILES.md',
                '_templates/Commit digest.md',
                'scripts/add-entry.ps1',
                'scripts/prepare-commit-digest.ps1',
                'scripts/rotate-history.ps1'
            )) {
            Remove-SafePath $project $relative
        }
        $ignorePath = Join-Path $project '.gitignore'
        $ignore = ([System.IO.File]::ReadAllText($ignorePath) -replace '(?m)^\.project/\s*\r?\n?', '')
        [System.IO.File]::WriteAllText($ignorePath, $ignore, $utf8)
    }

    $versionPath = Join-Path $project 'TEMPLATE-VERSION'
    if ($WithoutVersion) {
        Remove-SafePath $project 'TEMPLATE-VERSION'
    }
    else {
        [System.IO.File]::WriteAllText($versionPath, "$Version`n", $utf8)
    }
    return $project
}

function Assert-Version([string]$Project, [string]$Expected) {
    $actual = [System.IO.File]::ReadAllText((Join-Path $Project 'TEMPLATE-VERSION')).Trim()
    if ($actual -cne $Expected) { throw "Ожидалась версия $Expected, получена $actual." }
}

if (-not $testRoot.StartsWith(
        $root + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'Небезопасный путь папки тестов миграции.'
}

try {
    [System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $updater = Join-Path $source 'scripts/update-project.ps1'

    $project040 = New-ProjectFixture 'from-040' '0.4.0'
    $plan040 = & $updater -ProjectPath $project040 -Date '2026-07-16' 6>&1 | Out-String
    if ($plan040 -notmatch 'Это только план' -or
        (Test-Path -LiteralPath (Join-Path $project040 'START-HERE.md'))) {
        throw 'План обновления 0.4.0 изменил проект или не сообщил о режиме планирования.'
    }
    & $updater -ProjectPath $project040 -Date '2026-07-16' -Apply
    Assert-Version $project040 '0.5.0'
    $state040 = [System.IO.File]::ReadAllText((Join-Path $project040 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state040.previousTemplateVersion -cne '0.4.0' -or $state040.templateVersion -cne '0.5.0') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.4.0 -> 0.5.0.'
    }
    foreach ($relative in @(
            'START-HERE.md',
            'AI-CONNECTIONS.md',
            'INGESTION-WORKFLOW.md',
            'SOURCE-INGESTION.json',
            'scripts/build-ai-package.ps1',
            'scripts/source-ingestion.py'
        )) {
        if (-not (Test-Path -LiteralPath (Join-Path $project040 $relative) -PathType Leaf)) {
            throw "Миграция 0.4.0 не добавила файл: $relative"
        }
    }
    & (Join-Path $project040 'scripts/build-ai-package.ps1') -Profile compact -Check
    if ([System.IO.File]::ReadAllText((Join-Path $project040 '.github/workflows/knowledge-base.yml')) -notmatch 'source-ingestion\.py') {
        throw 'Workflow 0.4.0 не обновлён по историческому SHA-256.'
    }

    $project030 = New-ProjectFixture 'from-030' '0.3.0'
    $plan030 = & $updater -ProjectPath $project030 -Date '2026-07-16' 6>&1 | Out-String
    if ($plan030 -notmatch 'Это только план' -or
        (Test-Path -LiteralPath (Join-Path $project030 'CONTEXT-PROFILES.json'))) {
        throw 'План обновления 0.3.0 изменил проект или не сообщил о режиме планирования.'
    }
    & $updater -ProjectPath $project030 -Date '2026-07-16' -Apply
    Assert-Version $project030 '0.5.0'
    $state030 = [System.IO.File]::ReadAllText((Join-Path $project030 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state030.previousTemplateVersion -cne '0.3.0' -or $state030.templateVersion -cne '0.5.0') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.3.0 -> 0.5.0.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $project030 'CONTEXT-PROFILES.json') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $project030 'scripts/build-context.ps1') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $project030 'scripts/build-ai-package.ps1') -PathType Leaf)) {
        throw 'Миграция 0.3.0 не добавила файлы управления контекстом и вложениями.'
    }
    & (Join-Path $project030 'scripts/build-context.ps1') -Profile compact -IncludeId D-001,Q-001 -Check

    $project020 = New-ProjectFixture 'from-020' '0.2.0'
    $decisionsPath = Join-Path $project020 'DECISIONS.md'
    $decisions = [System.IO.File]::ReadAllText($decisionsPath) + "`n<!-- CANONICAL-USER-DATA -->`n"
    [System.IO.File]::WriteAllText($decisionsPath, $decisions, $utf8)

    $plan = & $updater -ProjectPath $project020 -Date '2026-07-16' 6>&1 | Out-String
    if ($plan -notmatch 'Это только план' -or (Test-Path -LiteralPath (Join-Path $project020 'REGISTRY-SCHEMA.json'))) {
        throw 'План обновления изменил проект или не сообщил о режиме планирования.'
    }
    Assert-Version $project020 '0.2.0'

    & $updater -ProjectPath $project020 -Date '2026-07-16' -Apply
    Assert-Version $project020 '0.5.0'
    if ([System.IO.File]::ReadAllText($decisionsPath) -notmatch 'CANONICAL-USER-DATA') {
        throw 'Миграция изменила канонические пользовательские данные.'
    }
    $state = [System.IO.File]::ReadAllText((Join-Path $project020 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state.previousTemplateVersion -cne '0.2.0' -or $state.templateVersion -cne '0.5.0') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.2.0 -> 0.5.0.'
    }
    $report = Get-ChildItem -LiteralPath (Join-Path $project020 '.project/backups') -Recurse -File -Filter 'update-report.json' |
        Select-Object -First 1
    if ($null -eq $report -or ([System.IO.File]::ReadAllText($report.FullName) | ConvertFrom-Json).result -ne 'success') {
        throw 'После успешной миграции отсутствует корректный отчёт.'
    }

    $legacyDecision = '| D-1 | 2026-07-16 | Исторический ID | Контекст | Последствие | Основание | Пересмотр |'
    [System.IO.File]::WriteAllText(
        $decisionsPath,
        [System.IO.File]::ReadAllText($decisionsPath) + "`n$legacyDecision`n",
        $utf8
    )
    & (Join-Path $project020 'scripts/validate-registries.ps1') -ProjectPath $project020

    $legacy = New-ProjectFixture 'from-010' '0.1.0' -WithoutVersion -Legacy
    Copy-Item -LiteralPath (Join-Path $root 'tests/fixtures/v0.1.0/knowledge-base.yml') `
        -Destination (Join-Path $legacy '.github/workflows/knowledge-base.yml') -Force
    Assert-Throws {
        & $updater -ProjectPath $legacy -Date '2026-07-16'
    } 'Укажите проверенную исходную версию' 'проект без маркера не обновляется без FromVersion'
    & $updater -ProjectPath $legacy -FromVersion '0.1.0' -Date '2026-07-16' -Apply
    Assert-Version $legacy '0.5.0'
    if ([System.IO.File]::ReadAllText((Join-Path $legacy '.gitignore')) -notmatch '(?m)^\.project/$') {
        throw 'Миграция старого проекта не добавила .project в .gitignore.'
    }
    if ([System.IO.File]::ReadAllText((Join-Path $legacy '.github/workflows/knowledge-base.yml')) -match 'actions/checkout@v5') {
        throw 'Исторический управляемый файл 0.1.0 не был обновлён по официальному SHA-256.'
    }

    $dirty = New-ProjectFixture 'dirty-git' '0.2.0'
    & git -C $dirty init -b main | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось создать тестовый Git-репозиторий.' }
    & git -C $dirty -c core.autocrlf=false add -A
    & git -C $dirty -c user.name='Migration Test' -c user.email='migration@example.invalid' commit -m 'baseline' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось создать исходный тестовый коммит.' }
    [System.IO.File]::WriteAllText(
        (Join-Path $dirty 'DECISIONS.md'),
        [System.IO.File]::ReadAllText((Join-Path $dirty 'DECISIONS.md')) + "`n<!-- DIRTY -->`n",
        $utf8
    )
    Assert-Throws {
        & $updater -ProjectPath $dirty -Date '2026-07-16' -Apply
    } 'незакоммиченные изменения' 'обновление грязного Git-репозитория требует явного разрешения'
    Assert-Version $dirty '0.2.0'

    $conflict = New-ProjectFixture 'managed-conflict' '0.2.0'
    $managedPath = Join-Path $conflict 'scripts/build-project-dossier.ps1'
    [System.IO.File]::WriteAllText(
        $managedPath,
        [System.IO.File]::ReadAllText($managedPath) + "`n# USER-MANAGED-CHANGE`n",
        $utf8
    )
    Assert-Throws {
        & $updater -ProjectPath $conflict -Date '2026-07-16' -Apply
    } 'Найдены конфликты управляемых файлов' 'изменённый управляемый файл блокирует обновление'
    Assert-Version $conflict '0.2.0'
    & $updater -ProjectPath $conflict -Date '2026-07-16' -Apply -ForceManagedFiles
    Assert-Version $conflict '0.5.0'
    $managedBackup = Get-ChildItem -LiteralPath (Join-Path $conflict '.project/backups') -Recurse -File |
        Where-Object FullName -match 'files[\\/]scripts[\\/]build-project-dossier\.ps1$' |
        Select-Object -First 1
    if ($null -eq $managedBackup -or [System.IO.File]::ReadAllText($managedBackup.FullName) -notmatch 'USER-MANAGED-CHANGE') {
        throw 'Принудительно заменённый файл не сохранён в резервной копии.'
    }

    $rollback = New-ProjectFixture 'rollback' '0.2.0'
    $sourcesPath = Join-Path $rollback 'SOURCES.md'
    [System.IO.File]::WriteAllText(
        $sourcesPath,
        [System.IO.File]::ReadAllText($sourcesPath) + "`n| S-999 | Недостаточно колонок | Ошибка |`n",
        $utf8
    )
    Assert-Throws {
        & $updater -ProjectPath $rollback -Date '2026-07-16' -Apply
    } 'Обновление отменено.*восстановлены' 'ошибка проверки вызывает откат миграции'
    Assert-Version $rollback '0.2.0'
    if (Test-Path -LiteralPath (Join-Path $rollback 'REGISTRY-SCHEMA.json')) {
        throw 'После отката остался добавленный файл схемы реестров.'
    }
    if (Test-Path -LiteralPath (Join-Path $rollback 'START-HERE.md')) {
        throw 'После отката остался добавленный файл версии 0.5.0.'
    }
    $rollbackReport = Get-ChildItem -LiteralPath (Join-Path $rollback '.project/backups') -Recurse -File -Filter 'update-report.json' |
        Select-Object -First 1
    if ($null -eq $rollbackReport -or
        ([System.IO.File]::ReadAllText($rollbackReport.FullName) | ConvertFrom-Json).result -ne 'rolled-back') {
        throw 'После отката отсутствует отчёт с результатом rolled-back.'
    }

    Assert-Throws {
        & $updater -ProjectPath $rollback -FromVersion '9.9.9' -Date '2026-07-16'
    } 'не совпадает с TEMPLATE-VERSION|не поддерживается' 'противоречащая или неподдерживаемая версия отклоняется'

    Write-Host 'Сценарии миграции проектов пройдены.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        if (-not $testRoot.StartsWith(
                $root + [System.IO.Path]::DirectorySeparatorChar,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            throw 'Небезопасное удаление папки тестов миграции.'
        }
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
