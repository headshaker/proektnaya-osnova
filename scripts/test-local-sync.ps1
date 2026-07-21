[CmdletBinding()]
param([string]$Date = '2026-07-18')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $root 'template'
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $root ".tmp-local-sync-test-$([Guid]::NewGuid().ToString('N'))"))
$seed = Join-Path $testRoot 'seed'
$remote = Join-Path $testRoot 'remote.git'
$manager = Join-Path $testRoot 'manager'
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Invoke-Git([string]$Path, [string[]]$Arguments) {
    $output = @(& git -C $Path @Arguments)
    if ($LASTEXITCODE -ne 0) { throw "Ошибка тестового Git: git $($Arguments -join ' ')" }
    return @($output)
}

function Read-Json([string]$Path) {
    return [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
}

if (-not $testRoot.StartsWith(
        $root + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase
    )) { throw 'Небезопасный путь теста локальной синхронизации.' }

try {
    Copy-Item -LiteralPath $source -Destination $seed -Recurse
    & (Join-Path $seed 'scripts/init-project.ps1') -Title 'Синхронизация команды' -Slug 'team-sync' -Date $Date
    Invoke-Git $seed @('init', '-b', 'main') | Out-Null
    Invoke-Git $seed @('config', 'user.name', 'Sync Test') | Out-Null
    Invoke-Git $seed @('config', 'user.email', 'sync-test@example.invalid') | Out-Null
    Invoke-Git $seed @('add', '.') | Out-Null
    Invoke-Git $seed @('commit', '-m', 'Initial project') | Out-Null
    & git init --bare $remote | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось создать тестовый удалённый репозиторий.' }
    Invoke-Git $seed @('remote', 'add', 'origin', $remote) | Out-Null
    Invoke-Git $seed @('push', '-u', 'origin', 'main') | Out-Null
    Invoke-Git $remote @('symbolic-ref', 'HEAD', 'refs/heads/main') | Out-Null
    & git clone $remote $manager | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось клонировать тестовую папку руководителя.' }
    Invoke-Git $manager @('config', 'user.name', 'Manager Test') | Out-Null
    Invoke-Git $manager @('config', 'user.email', 'manager-test@example.invalid') | Out-Null

    $installationText = (& (Join-Path $manager 'scripts/install-local-sync.ps1') -Apply -SkipScheduledTask -Json | Out-String).Trim()
    $installation = $installationText | ConvertFrom-Json
    $hooksPath = (Invoke-Git $manager @('config', '--local', '--get', 'core.hooksPath') | Select-Object -First 1).Trim()
    if ([int]$installation.schemaVersion -ne 2 -or
        -not $installation.gitHooksConfigured -or $hooksPath -cne '.githooks' -or
        -not (Test-Path -LiteralPath (Join-Path $manager '.project/local-sync.log') -PathType Leaf)) {
        throw 'Локальная установка не включила проектные Git-хуки.'
    }
    $installerText = [System.IO.File]::ReadAllText((Join-Path $manager 'scripts/install-local-sync.ps1'))
    if ($installerText -notmatch [regex]::Escape('-WindowStyle Hidden') -or
        $installerText -notmatch [regex]::Escape('run-local-sync-background.ps1')) {
        throw 'Windows-задача не использует скрытый фоновый обработчик.'
    }

    $initialText = (& (Join-Path $manager 'scripts/sync-project.ps1') -NoFetch -ForceContextRefresh -Json | Out-String).Trim()
    $initial = $initialText | ConvertFrom-Json
    if ($initial.status -cne 'current' -or -not $initial.current -or
        -not (Test-Path -LiteralPath (Join-Path $manager '.project/context/ai-package.md') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $manager '.project/LOCAL-SYNC-STATUS.md') -PathType Leaf)) {
        throw "Первая синхронизация не собрала актуальный общий контекст: $($initial | ConvertTo-Json -Depth 8 -Compress)"
    }

    & (Join-Path $manager 'scripts/run-local-sync-background.ps1') -ProjectPath $manager
    $backgroundLog = [System.IO.File]::ReadAllText((Join-Path $manager '.project/local-sync.log'))
    if ($backgroundLog -notmatch '\[INFO\].*status=current') {
        throw 'Успешная фоновая проверка не записалась в журнал.'
    }

    $disabledText = (& (Join-Path $manager 'scripts/install-local-sync.ps1') `
            -Apply -Disable -SkipScheduledTask -Json | Out-String).Trim()
    $disabled = $disabledText | ConvertFrom-Json
    $disabledSyncText = (& (Join-Path $manager 'scripts/sync-project.ps1') -NoFetch -Json | Out-String).Trim()
    $disabledSync = $disabledSyncText | ConvertFrom-Json
    $hooksAfterDisable = @(& git -C $manager config --local --get core.hooksPath 2>$null)
    if ([string]$disabled.status -cne 'disabled-local' -or $disabled.enabled -ne $false -or
        [string]$disabledSync.status -cne 'disabled-local' -or $hooksAfterDisable.Count -gt 0) {
        throw 'Локальное отключение не остановило задачу и Git-хуки этого компьютера.'
    }

    $enabledText = (& (Join-Path $manager 'scripts/install-local-sync.ps1') `
            -Apply -Enable -SkipScheduledTask -Json | Out-String).Trim()
    $enabledInstallation = $enabledText | ConvertFrom-Json
    $hooksAfterEnable = @(& git -C $manager config --local --get core.hooksPath 2>$null)
    if ($enabledInstallation.enabled -ne $true -or
        ($hooksAfterEnable | Select-Object -First 1) -cne '.githooks') {
        throw 'Повторное включение не восстановило локальное обновление.'
    }

    $brokenRoot = Join-Path $testRoot 'broken-background-project'
    [System.IO.Directory]::CreateDirectory((Join-Path $brokenRoot '.project')) | Out-Null
    $brokenLog = Join-Path $brokenRoot '.project/local-sync.log'
    try {
        & (Join-Path $manager 'scripts/run-local-sync-background.ps1') `
            -ProjectPath $brokenRoot -LogPath $brokenLog
        throw 'Ошибочный фоновый запуск неожиданно завершился успешно.'
    }
    catch {
        if ($_.Exception.Message -ceq 'Ошибочный фоновый запуск неожиданно завершился успешно.') { throw }
    }
    if (-not (Test-Path -LiteralPath $brokenLog -PathType Leaf) -or
        [System.IO.File]::ReadAllText($brokenLog) -notmatch '\[ERROR\].*Не найден сценарий синхронизации') {
        throw 'Ошибка фоновой проверки не сохранилась в журнале.'
    }

    Add-Content -LiteralPath (Join-Path $seed 'HANDOFF.md') -Value "`n<!-- remote-update-1 -->" -Encoding utf8NoBOM
    Invoke-Git $seed @('add', 'HANDOFF.md') | Out-Null
    Invoke-Git $seed @('commit', '-m', 'Update shared project') | Out-Null
    Invoke-Git $seed @('push', 'origin', 'main') | Out-Null
    $expectedCommit = (Invoke-Git $seed @('rev-parse', 'HEAD') | Select-Object -First 1).Trim()

    $updatedText = (& (Join-Path $manager 'scripts/sync-project.ps1') -Json | Out-String).Trim()
    $updated = $updatedText | ConvertFrom-Json
    $managerCommit = (Invoke-Git $manager @('rev-parse', 'HEAD') | Select-Object -First 1).Trim()
    $contextState = Read-Json (Join-Path $manager '.project/context/local-context-state.json')
    if ($updated.status -cne 'updated' -or -not $updated.current -or -not $updated.updated -or
        $managerCommit -cne $expectedCommit -or [string]$contextState.commit -cne $expectedCommit) {
        throw 'Изменение main не обновило папку руководителя и контекст до одной редакции.'
    }

    [System.IO.File]::WriteAllText((Join-Path $manager 'LOCAL-NOTE.txt'), 'Незавершённый локальный ввод', $utf8)
    Add-Content -LiteralPath (Join-Path $seed 'HANDOFF.md') -Value "`n<!-- remote-update-2 -->" -Encoding utf8NoBOM
    Invoke-Git $seed @('add', 'HANDOFF.md') | Out-Null
    Invoke-Git $seed @('commit', '-m', 'Second shared update') | Out-Null
    Invoke-Git $seed @('push', 'origin', 'main') | Out-Null
    $beforeBlocked = (Invoke-Git $manager @('rev-parse', 'HEAD') | Select-Object -First 1).Trim()
    $blockedText = (& (Join-Path $manager 'scripts/sync-project.ps1') -Json | Out-String).Trim()
    $blocked = $blockedText | ConvertFrom-Json
    $afterBlocked = (Invoke-Git $manager @('rev-parse', 'HEAD') | Select-Object -First 1).Trim()
    if ($blocked.status -cne 'local-changes' -or $beforeBlocked -cne $afterBlocked) {
        throw 'Защита локальной работы не остановила автоматическое обновление.'
    }

    Remove-Item -LiteralPath (Join-Path $manager 'LOCAL-NOTE.txt') -Force
    Invoke-Git $manager @('pull', '--ff-only', 'origin', 'main') | Out-Null
    $manualPullCommit = (Invoke-Git $manager @('rev-parse', 'HEAD') | Select-Object -First 1).Trim()
    $manualPullState = Read-Json (Join-Path $manager '.project/context/local-context-state.json')
    if ([string]$manualPullState.commit -cne $manualPullCommit -or
        [string]$manualPullState.status -cne 'ready') {
        throw 'Git-хук ручного pull не обновил общий контекст.'
    }
    Invoke-Git $manager @('switch', '-c', 'agent/context-check') | Out-Null

    Add-Content -LiteralPath (Join-Path $seed 'HANDOFF.md') -Value "`n<!-- remote-update-3 -->" -Encoding utf8NoBOM
    Invoke-Git $seed @('add', 'HANDOFF.md') | Out-Null
    Invoke-Git $seed @('commit', '-m', 'Third shared update') | Out-Null
    Invoke-Git $seed @('push', 'origin', 'main') | Out-Null
    $staleText = (& (Join-Path $manager 'scripts/sync-project.ps1') -Json | Out-String).Trim()
    $stale = $staleText | ConvertFrom-Json
    if ($stale.status -cne 'agent-branch-stale' -or $stale.current) {
        throw 'Устаревшая ветка нейросети не была остановлена.'
    }

    $scriptText = [System.IO.File]::ReadAllText((Join-Path $manager 'scripts/sync-project.ps1'))
    if ($scriptText -match '(?i)reset\s+--hard|push\s+--force|clean\s+-fd') {
        throw 'Синхронизация содержит разрушительную Git-команду.'
    }

    Write-Host 'Автоматическое обновление локальной папки и контекста прошло проверку.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        if (-not $testRoot.StartsWith(
                $root + [System.IO.Path]::DirectorySeparatorChar,
                [System.StringComparison]::OrdinalIgnoreCase
            )) { throw 'Небезопасное удаление теста локальной синхронизации.' }
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
