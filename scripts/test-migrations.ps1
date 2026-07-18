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

function Copy-FixtureFile([string]$FixtureRoot, [string]$FixtureName, [string]$Project, [string]$Relative) {
    $sourcePath = Join-Path $FixtureRoot $FixtureName
    $destination = Join-Path $Project $Relative
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $destination -Force
}

function Set-StateVersion([string]$Project, [string]$Version) {
    $statePath = Join-Path $Project 'TEMPLATE-STATE.json'
    $state = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    $state.templateVersion = $Version
    $state.previousTemplateVersion = $null
    [System.IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 5) + "`n", $utf8)
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
    Remove-SafePath $project 'scripts/check-context-health.ps1'
    foreach ($relative in @(
            '.ai-work',
            '.github/workflows/ai-coordination.yml',
            'AI-COORDINATION.json',
            'AI-COORDINATION.md',
            'AI-INTEGRATION-STATE.json',
            'scripts/check-ai-coordination.ps1',
            'scripts/start-ai-work.ps1',
            'scripts/sync-ai-work.ps1'
        )) {
        Remove-SafePath $project $relative
    }

    foreach ($relative in @(
            '.github/copilot-instructions.md',
            'AGENTS.override.md',
            'AI-OPERATING-MODEL.md',
            'CLAUDE.md',
            'GEMINI.md',
            'PROMPTING-GUIDE.md',
            'VIRTUAL-SPECIALISTS.md',
            'scripts/link-registry-references.py'
        )) {
        if ($Version -notin @('0.8.0', '0.8.1', '0.9.0')) { Remove-SafePath $project $relative }
    }

    foreach ($relative in @(
            '.github/workflows/project-health.yml',
            'AI-GOVERNANCE.md',
            'CONTROLS.md',
            'OUTCOMES.md',
            'PROJECT-CONFIG.json',
            'STATUS.md',
            'scripts/add-control.ps1',
            'scripts/build-status.ps1',
            'scripts/check-project-health.ps1'
        )) {
        if ($Version -notin @('0.8.0', '0.8.1', '0.9.0')) { Remove-SafePath $project $relative }
    }

    switch ($Version) {
        '0.9.0' {
            $fixture = Join-Path $root 'tests/fixtures/v0.9.0'
            Copy-FixtureFile $fixture 'REGISTRY-SCHEMA.json' $project 'REGISTRY-SCHEMA.json'
            Copy-FixtureFile $fixture 'manifest.json' $project 'migrations/manifest.json'
            Copy-FixtureFile $fixture 'baselines.json' $project 'migrations/baselines.json'
            Copy-FixtureFile $fixture 'validate-vault.ps1' $project 'scripts/validate-vault.ps1'
            Set-StateVersion $project '0.9.0'
        }
        '0.8.1' {
            Remove-SafePath $project 'START-PROJECT.cmd'
            Remove-SafePath $project 'scripts/setup-project.ps1'
            $fixture = Join-Path $root 'tests/fixtures/v0.8.1'
            Copy-FixtureFile $fixture 'REGISTRY-SCHEMA.json' $project 'REGISTRY-SCHEMA.json'
            Copy-FixtureFile $fixture 'manifest.json' $project 'migrations/manifest.json'
            Copy-FixtureFile $fixture 'baselines.json' $project 'migrations/baselines.json'
            Set-StateVersion $project '0.8.1'
        }
        '0.8.0' {
            Remove-SafePath $project 'HOME.md'
            Remove-SafePath $project 'ADMIN-SETUP.md'
            Remove-SafePath $project 'START-PROJECT.cmd'
            Remove-SafePath $project 'scripts/setup-project.ps1'
            $fixture = Join-Path $root 'tests/fixtures/v0.8.0'
            Copy-FixtureFile $fixture 'REGISTRY-SCHEMA.json' $project 'REGISTRY-SCHEMA.json'
            Copy-FixtureFile $fixture 'manifest.json' $project 'migrations/manifest.json'
            Copy-FixtureFile $fixture 'baselines.json' $project 'migrations/baselines.json'
            Set-StateVersion $project '0.8.0'
        }
        '0.7.0' {
            $fixture = Join-Path $root 'tests/fixtures/v0.7.0'
            Copy-FixtureFile $fixture 'REGISTRY-SCHEMA.json' $project 'REGISTRY-SCHEMA.json'
            Copy-FixtureFile $fixture 'manifest.json' $project 'migrations/manifest.json'
            Copy-FixtureFile $fixture 'baselines.json' $project 'migrations/baselines.json'
            Set-StateVersion $project '0.7.0'
        }
        '0.6.0' {
            $fixture = Join-Path $root 'tests/fixtures/v0.6.0'
            Copy-FixtureFile $fixture 'REGISTRY-SCHEMA.json' $project 'REGISTRY-SCHEMA.json'
            Copy-FixtureFile $fixture 'manifest.json' $project 'migrations/manifest.json'
            Copy-FixtureFile $fixture 'baselines.json' $project 'migrations/baselines.json'
            Set-StateVersion $project '0.6.0'
        }
        '0.5.0' {
            $fixture = Join-Path $root 'tests/fixtures/v0.5.0'
            Copy-FixtureFile $fixture 'REGISTRY-SCHEMA.json' $project 'REGISTRY-SCHEMA.json'
            Copy-FixtureFile $fixture 'manifest.json' $project 'migrations/manifest.json'
            Copy-FixtureFile $fixture 'baselines.json' $project 'migrations/baselines.json'
            Set-StateVersion $project '0.5.0'
        }
        '0.4.0' {
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
            $fixture = Join-Path $root 'tests/fixtures/v0.4.0'
            Copy-FixtureFile $fixture 'knowledge-base.yml' $project '.github/workflows/knowledge-base.yml'
            Copy-FixtureFile $fixture 'manifest.json' $project 'migrations/manifest.json'
            Copy-FixtureFile $fixture 'baselines.json' $project 'migrations/baselines.json'
            Set-StateVersion $project '0.4.0'
        }
        '0.3.0' {
            foreach ($relative in @(
                    'AI-CONNECTIONS.md',
                    'CONTEXT-PROFILES.json',
                    'CONTEXT-WORKFLOW.md',
                    'INGESTION-WORKFLOW.md',
                    'SOURCE-INGESTION.json',
                    'START-HERE.md',
                    'scripts/build-ai-package.ps1',
                    'scripts/build-context.ps1',
                    'scripts/ingest-sources.ps1',
                    'scripts/source-ingestion.py'
                )) {
                Remove-SafePath $project $relative
            }
            $fixture = Join-Path $root 'tests/fixtures/v0.3.0'
            Copy-FixtureFile $fixture 'knowledge-base.yml' $project '.github/workflows/knowledge-base.yml'
            Copy-FixtureFile $fixture 'REGISTRY-SCHEMA.json' $project 'REGISTRY-SCHEMA.json'
            Copy-FixtureFile $fixture 'manifest.json' $project 'migrations/manifest.json'
            Copy-FixtureFile $fixture 'baselines.json' $project 'migrations/baselines.json'
            Set-StateVersion $project '0.3.0'
        }
        default {
            foreach ($relative in @(
                    'AI-CONNECTIONS.md',
                    'CONTEXT-PROFILES.json',
                    'CONTEXT-WORKFLOW.md',
                    'INGESTION-WORKFLOW.md',
                    'MIGRATIONS.md',
                    'REGISTRY-SCHEMA.json',
                    'SOURCE-INGESTION.json',
                    'START-HERE.md',
                    'TEMPLATE-STATE.json',
                    'migrations',
                    'scripts/build-ai-package.ps1',
                    'scripts/build-context.ps1',
                    'scripts/ingest-sources.ps1',
                    'scripts/source-ingestion.py',
                    'scripts/update-project.ps1',
                    'scripts/validate-registries.ps1',
                    '.github/workflows/registry-compatibility.yml'
                )) {
                Remove-SafePath $project $relative
            }
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
    if ($WithoutVersion) { Remove-SafePath $project 'TEMPLATE-VERSION' }
    else { [System.IO.File]::WriteAllText($versionPath, "$Version`n", $utf8) }
    return $project
}

function Assert-Version([string]$Project, [string]$Expected) {
    $actual = [System.IO.File]::ReadAllText((Join-Path $Project 'TEMPLATE-VERSION')).Trim()
    if ($actual -cne $Expected) { throw "Ожидалась версия $Expected, получена $actual." }
}

function Assert-AgentFiles([string]$Project) {
    foreach ($relative in @(
            '.github/copilot-instructions.md',
            'AGENTS.override.md',
            'AI-OPERATING-MODEL.md',
            'CLAUDE.md',
            'GEMINI.md',
            'PROMPTING-GUIDE.md',
            'VIRTUAL-SPECIALISTS.md'
        )) {
        if (-not (Test-Path -LiteralPath (Join-Path $Project $relative) -PathType Leaf)) {
            throw "Миграция не добавила агентный файл: $relative"
        }
    }
}

function Assert-ControlLoopFiles([string]$Project) {
    foreach ($relative in @(
            '.github/workflows/project-health.yml',
            'AI-GOVERNANCE.md',
            'CONTROLS.md',
            'OUTCOMES.md',
            'PROJECT-CONFIG.json',
            'STATUS.md',
            'scripts/add-control.ps1',
            'scripts/build-status.ps1',
            'scripts/check-project-health.ps1'
        )) {
        if (-not (Test-Path -LiteralPath (Join-Path $Project $relative) -PathType Leaf)) {
            throw "Миграция не добавила файл управленческого цикла: $relative"
        }
    }
    & (Join-Path $Project 'scripts/build-status.ps1') -Check
    & (Join-Path $Project 'scripts/check-project-health.ps1') -AllowPlaceholders -Date '2026-07-17'
}

function Assert-AiCoordinationFiles([string]$Project) {
    foreach ($relative in @(
            '.ai-work/README.md',
            '.ai-work/changes/.gitkeep',
            '.github/workflows/ai-coordination.yml',
            'AI-COORDINATION.json',
            'AI-COORDINATION.md',
            'AI-INTEGRATION-STATE.json',
            'scripts/check-ai-coordination.ps1',
            'scripts/start-ai-work.ps1',
            'scripts/sync-ai-work.ps1'
        )) {
        if (-not (Test-Path -LiteralPath (Join-Path $Project $relative) -PathType Leaf)) {
            throw "Миграция не добавила файл координации нейросетей: $relative"
        }
    }
    $state = [System.IO.File]::ReadAllText((Join-Path $Project 'AI-INTEGRATION-STATE.json')) | ConvertFrom-Json
    if ([int]$state.sequence -ne 0 -or [string]$state.updatedAt -cne '2026-07-01') {
        throw 'Миграция создала некорректное начальное интеграционное состояние.'
    }
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

    $project090 = New-ProjectFixture 'from-090' '0.9.0'
    & $updater -ProjectPath $project090 -Date '2026-07-18' -Apply
    Assert-Version $project090 '0.10.0'
    Assert-AiCoordinationFiles $project090
    $state090 = [System.IO.File]::ReadAllText((Join-Path $project090 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state090.previousTemplateVersion -cne '0.9.0' -or $state090.templateVersion -cne '0.10.0') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.9.0 -> 0.10.0.'
    }

    $project081 = New-ProjectFixture 'from-081' '0.8.1'
    & $updater -ProjectPath $project081 -Date '2026-07-17' -Apply
    Assert-Version $project081 '0.10.0'
    Assert-AiCoordinationFiles $project081
    foreach ($relative in @('START-PROJECT.cmd', 'scripts/setup-project.ps1', 'scripts/check-context-health.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $project081 $relative) -PathType Leaf)) {
            throw "Миграция 0.8.1 не добавила новый файл выпуска: $relative"
        }
    }
    & (Join-Path $project081 'scripts/build-context.ps1') -Profile compact -IncludeId D-001,Q-001 -Check
    & (Join-Path $project081 'scripts/check-context-health.ps1') -Date '2026-07-07' -Check
    $state081 = [System.IO.File]::ReadAllText((Join-Path $project081 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state081.previousTemplateVersion -cne '0.8.1' -or $state081.templateVersion -cne '0.10.0') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.8.1 -> 0.10.0.'
    }

    $project080 = New-ProjectFixture 'from-080' '0.8.0'
    & $updater -ProjectPath $project080 -Date '2026-07-17' -Apply
    Assert-Version $project080 '0.10.0'
    Assert-AiCoordinationFiles $project080
    foreach ($relative in @('HOME.md', 'ADMIN-SETUP.md', 'START-PROJECT.cmd', 'scripts/setup-project.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $project080 $relative) -PathType Leaf)) {
            throw "Миграция 0.8.0 не добавила человеко-ориентированный файл или мастер: $relative"
        }
    }
    $state080 = [System.IO.File]::ReadAllText((Join-Path $project080 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state080.previousTemplateVersion -cne '0.8.0' -or $state080.templateVersion -cne '0.10.0') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.8.0 -> 0.10.0.'
    }

    $project070 = New-ProjectFixture 'from-070' '0.7.0'
    & $updater -ProjectPath $project070 -Date '2026-07-17' -Apply
    Assert-Version $project070 '0.10.0'
    Assert-AiCoordinationFiles $project070
    Assert-ControlLoopFiles $project070
    $state070 = [System.IO.File]::ReadAllText((Join-Path $project070 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state070.previousTemplateVersion -cne '0.7.0' -or $state070.templateVersion -cne '0.10.0') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.7.0 -> 0.10.0.'
    }

    $project060 = New-ProjectFixture 'from-060' '0.6.0'
    & $updater -ProjectPath $project060 -Date '2026-07-16' -Apply
    Assert-Version $project060 '0.10.0'
    Assert-AiCoordinationFiles $project060
    if (-not (Test-Path -LiteralPath (Join-Path $project060 'scripts/link-registry-references.py') -PathType Leaf)) {
        throw 'Миграция 0.6.0 не добавила преобразователь ссылок реестров.'
    }
    $state060 = [System.IO.File]::ReadAllText((Join-Path $project060 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state060.previousTemplateVersion -cne '0.6.0' -or $state060.templateVersion -cne '0.10.0') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.6.0 -> 0.10.0.'
    }
    & (Join-Path $project060 'scripts/validate-vault.ps1')

    $project050 = New-ProjectFixture 'from-050' '0.5.0'
    $agents050 = Join-Path $project050 'AGENTS.md'
    [System.IO.File]::AppendAllText($agents050, "`n<!-- USER-AGENT-RULE -->`n", $utf8)
    $plan050 = & $updater -ProjectPath $project050 -Date '2026-07-16' 6>&1 | Out-String
    if ($plan050 -notmatch 'Это только план' -or (Test-Path -LiteralPath (Join-Path $project050 'AI-OPERATING-MODEL.md'))) {
        throw 'План обновления 0.5.0 изменил проект или не сообщил о режиме планирования.'
    }
    & $updater -ProjectPath $project050 -Date '2026-07-16' -Apply
    Assert-Version $project050 '0.10.0'
    Assert-AiCoordinationFiles $project050
    Assert-AgentFiles $project050
    if ([System.IO.File]::ReadAllText($agents050) -notmatch 'USER-AGENT-RULE') {
        throw 'Миграция заменила пользовательский AGENTS.md.'
    }
    $state050 = [System.IO.File]::ReadAllText((Join-Path $project050 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state050.previousTemplateVersion -cne '0.5.0' -or $state050.templateVersion -cne '0.10.0') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.5.0 -> 0.10.0.'
    }
    & (Join-Path $project050 'scripts/validate-vault.ps1')

    $project040 = New-ProjectFixture 'from-040' '0.4.0'
    & $updater -ProjectPath $project040 -Date '2026-07-16' -Apply
    Assert-Version $project040 '0.10.0'
    Assert-AiCoordinationFiles $project040
    Assert-AgentFiles $project040
    & (Join-Path $project040 'scripts/build-ai-package.ps1') -Profile compact -Check

    $project030 = New-ProjectFixture 'from-030' '0.3.0'
    & $updater -ProjectPath $project030 -Date '2026-07-16' -Apply
    Assert-Version $project030 '0.10.0'
    Assert-AiCoordinationFiles $project030
    Assert-AgentFiles $project030
    & (Join-Path $project030 'scripts/build-context.ps1') -Profile compact -IncludeId D-001,Q-001 -Check

    $project020 = New-ProjectFixture 'from-020' '0.2.0'
    $decisionsPath = Join-Path $project020 'DECISIONS.md'
    [System.IO.File]::AppendAllText($decisionsPath, "`n<!-- CANONICAL-USER-DATA -->`n", $utf8)
    & $updater -ProjectPath $project020 -Date '2026-07-16' -Apply
    Assert-Version $project020 '0.10.0'
    Assert-AiCoordinationFiles $project020
    Assert-AgentFiles $project020
    if ([System.IO.File]::ReadAllText($decisionsPath) -notmatch 'CANONICAL-USER-DATA') {
        throw 'Миграция изменила канонические пользовательские данные.'
    }

    $legacy = New-ProjectFixture 'from-010' '0.1.0' -WithoutVersion -Legacy
    Copy-Item -LiteralPath (Join-Path $root 'tests/fixtures/v0.1.0/knowledge-base.yml') `
        -Destination (Join-Path $legacy '.github/workflows/knowledge-base.yml') -Force
    Assert-Throws {
        & $updater -ProjectPath $legacy -Date '2026-07-16'
    } 'Укажите проверенную исходную версию' 'проект без маркера не обновляется без FromVersion'
    & $updater -ProjectPath $legacy -FromVersion '0.1.0' -Date '2026-07-16' -Apply
    Assert-Version $legacy '0.10.0'
    Assert-AiCoordinationFiles $legacy
    Assert-AgentFiles $legacy
    if ([System.IO.File]::ReadAllText((Join-Path $legacy '.gitignore')) -notmatch '(?m)^\.project/$') {
        throw 'Миграция старого проекта не добавила .project в .gitignore.'
    }

    $dirty = New-ProjectFixture 'dirty-git' '0.2.0'
    & git -C $dirty init -b main | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось создать тестовый Git-репозиторий.' }
    & git -C $dirty -c core.autocrlf=false add -A
    & git -C $dirty -c user.name='Migration Test' -c user.email='migration@example.invalid' commit -m 'baseline' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось создать исходный тестовый коммит.' }
    [System.IO.File]::AppendAllText((Join-Path $dirty 'DECISIONS.md'), "`n<!-- DIRTY -->`n", $utf8)
    Assert-Throws {
        & $updater -ProjectPath $dirty -Date '2026-07-16' -Apply
    } 'незакоммиченные изменения' 'обновление грязного Git-репозитория требует явного разрешения'
    Assert-Version $dirty '0.2.0'

    $conflict = New-ProjectFixture 'managed-conflict' '0.2.0'
    $managedPath = Join-Path $conflict 'scripts/build-project-dossier.ps1'
    [System.IO.File]::AppendAllText($managedPath, "`n# USER-MANAGED-CHANGE`n", $utf8)
    Assert-Throws {
        & $updater -ProjectPath $conflict -Date '2026-07-16' -Apply
    } 'Найдены конфликты управляемых файлов' 'изменённый управляемый файл блокирует обновление'
    Assert-Version $conflict '0.2.0'
    & $updater -ProjectPath $conflict -Date '2026-07-16' -Apply -ForceManagedFiles
    Assert-Version $conflict '0.10.0'
    $managedBackup = Get-ChildItem -LiteralPath (Join-Path $conflict '.project/backups') -Recurse -File |
        Where-Object FullName -match 'files[\\/]scripts[\\/]build-project-dossier\.ps1$' |
        Select-Object -First 1
    if ($null -eq $managedBackup -or [System.IO.File]::ReadAllText($managedBackup.FullName) -notmatch 'USER-MANAGED-CHANGE') {
        throw 'Принудительно заменённый файл не сохранён в резервной копии.'
    }

    $rollback = New-ProjectFixture 'rollback' '0.2.0'
    $sourcesPath = Join-Path $rollback 'SOURCES.md'
    [System.IO.File]::AppendAllText($sourcesPath, "`n| S-999 | Недостаточно колонок | Ошибка |`n", $utf8)
    Assert-Throws {
        & $updater -ProjectPath $rollback -Date '2026-07-16' -Apply
    } 'Обновление отменено.*восстановлены' 'ошибка проверки вызывает откат миграции'
    Assert-Version $rollback '0.2.0'
    if (Test-Path -LiteralPath (Join-Path $rollback 'AI-OPERATING-MODEL.md')) {
        throw 'После отката остался добавленный агентный файл.'
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

    Write-Host 'Сценарии миграции проектов до 0.10.0 пройдены.'
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
