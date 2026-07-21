[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ProjectPath = (Join-Path $PSScriptRoot '..'),
    [switch]$NoFetch,
    [switch]$ForceContextRefresh,
    [switch]$Quiet,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$root = [System.IO.Path]::GetFullPath($ProjectPath).TrimEnd([char[]]@('\', '/'))
$configurationPath = Join-Path $root 'LOCAL-SYNC.json'
$reportPath = Join-Path $root '.project/local-sync-status.json'
$humanReportPath = Join-Path $root '.project/LOCAL-SYNC-STATUS.md'
$lockPath = Join-Path $root '.project/local-sync.lock'
$localDisablePath = Join-Path $root '.project/local-sync.disabled'
$lockStream = $null

function Write-AtomicJson([string]$Path, [object]$Value) {
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    $temporary = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 12) + "`n", $utf8)
        [System.IO.File]::Move($temporary, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Write-AtomicText([string]$Path, [string]$Value) {
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    $temporary = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($temporary, $Value.TrimEnd() + "`n", $utf8)
        [System.IO.File]::Move($temporary, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Invoke-Git([string[]]$Arguments) {
    $output = @(& git -C $root @Arguments)
    if ($LASTEXITCODE -ne 0) {
        throw "Git завершил операцию с кодом ${LASTEXITCODE}: git $($Arguments -join ' ')"
    }
    return @($output)
}

function Get-GitValue([string[]]$Arguments) {
    return ((Invoke-Git $Arguments | Select-Object -First 1) -as [string]).Trim()
}

function Complete-Sync(
    [string]$Status,
    [string]$Message,
    [bool]$Current,
    [bool]$Updated,
    [object]$Context = $null
) {
    $localCommit = ''
    try { $localCommit = Get-GitValue @('rev-parse', '--verify', 'HEAD^{commit}') } catch { }
    $report = [pscustomobject][ordered]@{
        schemaVersion = 1
        status = $Status
        message = $Message
        current = $Current
        updated = $Updated
        projectPath = $root
        branch = $script:branch
        canonicalBranch = $script:canonicalBranch
        remote = $script:remote
        localCommit = $localCommit
        remoteCommit = $script:remoteCommit
        context = $Context
        checkedAt = [DateTime]::UtcNow.ToString('o')
    }
    Write-AtomicJson $reportPath $report
    $safeMessage = ($Message -replace '[\r\n]+', ' ').Trim()
    $checkedLocal = ([DateTimeOffset]::Parse([string]$report.checkedAt)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')
    $humanReport = @(
        '# Состояние автоматического обновления'
        ''
        "**$safeMessage**"
        ''
        "- Статус: ``$Status``"
        "- Последняя проверка: $checkedLocal"
        "- Открытая ветка: ``$($report.branch)``"
        "- Локальная редакция: ``$($report.localCommit)``"
        "- Общая редакция: ``$($report.remoteCommit)``"
        ''
        'Если статус требует внимания, передайте это сообщение подключённой нейросети. Она выполнит безопасные технические действия.'
    ) -join "`n"
    Write-AtomicText $humanReportPath $humanReport
    if ($Json) { Write-Output ($report | ConvertTo-Json -Depth 12 -Compress) }
    elseif (-not $Quiet) { Write-Host $Message }
}

if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) {
    throw 'Не найден LOCAL-SYNC.json. Обновите шаблон проекта.'
}
[System.IO.Directory]::CreateDirectory((Split-Path -Parent $lockPath)) | Out-Null
try {
    $lockStream = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
}
catch [System.IO.IOException] {
    if (-not $Quiet) { Write-Host 'Проверка обновлений уже выполняется в другом процессе.' }
    return
}

$branch = ''
$canonicalBranch = 'main'
$remote = 'origin'
$remoteCommit = ''
try {
    $configuration = [System.IO.File]::ReadAllText($configurationPath) | ConvertFrom-Json
    $canonicalBranch = [string]$configuration.canonicalBranch
    $remote = [string]$configuration.remote
    if (-not [bool]$configuration.enabled) {
        Complete-Sync 'disabled' 'Автоматическое обновление этой папки отключено.' $false $false
        return
    }
    if (Test-Path -LiteralPath $localDisablePath -PathType Leaf) {
        Complete-Sync 'disabled-local' 'Фоновое обновление отключено на этом компьютере.' $false $false
        return
    }
    if ([string]$configuration.strategy -cne 'fast-forward-only' -or
        $remote -notmatch '^[A-Za-z0-9._-]+$' -or $remote.StartsWith('-') -or
        $canonicalBranch -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or
        $canonicalBranch -match '\.\.' -or $canonicalBranch.EndsWith('/')) {
        throw 'LOCAL-SYNC.json содержит небезопасную конфигурацию Git.'
    }
    if ($null -eq (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        Complete-Sync 'git-missing' 'Git не установлен; локальная папка не обновлена.' $false $false
        return
    }
    try {
        $gitRoot = Get-GitValue @('rev-parse', '--show-toplevel')
    }
    catch {
        Complete-Sync 'not-a-repository' 'Папка ещё не связана с Git. После клонирования повторите запуск.' $false $false
        return
    }
    $gitRootFull = [System.IO.Path]::GetFullPath($gitRoot).TrimEnd([char[]]@('\', '/'))
    $pathComparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    } else { [System.StringComparison]::Ordinal }
    if (-not $gitRootFull.Equals($root, $pathComparison)) {
        throw 'Синхронизация разрешена только из корня отдельного репозитория проекта.'
    }
    $branch = Get-GitValue @('branch', '--show-current')
    if ([string]::IsNullOrWhiteSpace($branch)) {
        Complete-Sync 'detached-head' 'Папка открыта без активной ветки; автоматическое обновление остановлено.' $false $false
        return
    }

    if (-not $NoFetch) {
        try {
            Invoke-Git @(
                'fetch', '--prune', '--no-tags', $remote,
                "refs/heads/${canonicalBranch}:refs/remotes/${remote}/${canonicalBranch}"
            ) | Out-Null
        }
        catch {
            Complete-Sync 'offline' 'Не удалось проверить GitHub. Сохранена последняя доступная локальная версия.' $false $false
            return
        }
    }
    try {
        $remoteCommit = Get-GitValue @('rev-parse', '--verify', "refs/remotes/${remote}/${canonicalBranch}^{commit}")
    }
    catch {
        Complete-Sync 'remote-branch-missing' "Не найдена общая ветка ${remote}/${canonicalBranch}." $false $false
        return
    }

    if ($branch -cne $canonicalBranch) {
        & git -C $root merge-base --is-ancestor $remoteCommit HEAD
        if ($LASTEXITCODE -ne 0) {
            Complete-Sync 'agent-branch-stale' "Ветка '$branch' отстаёт от общей версии. ИИ должен остановиться, перенести работу на свежую ${remote}/${canonicalBranch} и обновить паспорт." $false $false
            return
        }
        try {
            $refreshArguments = @{ ProjectPath = $root; Json = $true }
            if ($ForceContextRefresh) { $refreshArguments.Force = $true }
            $context = (& (Join-Path $root 'scripts/refresh-ai-context.ps1') @refreshArguments | Out-String).Trim() | ConvertFrom-Json
            Complete-Sync 'agent-branch-current' "Ветка '$branch' основана на актуальной общей версии; её локальный контекст обновлён." $true $false $context
        }
        catch {
            Complete-Sync 'context-failed' "Ветка свежая, но контекст ИИ не обновлён: $($_.Exception.Message)" $true $false
        }
        return
    }

    $dirty = @(Invoke-Git @('status', '--porcelain=v1', '--untracked-files=normal'))
    if ($dirty.Count -gt 0) {
        Complete-Sync 'local-changes' 'Найдены локальные изменения. Автоматическое обновление ничего не затёрло; сначала передайте изменения ИИ или сохраните их в отдельной ветке.' $false $false
        return
    }

    $countsText = (Invoke-Git @('rev-list', '--left-right', '--count', "HEAD...refs/remotes/${remote}/${canonicalBranch}") | Select-Object -First 1).Trim()
    if ($countsText -notmatch '^(?<ahead>\d+)\s+(?<behind>\d+)$') {
        throw 'Git вернул непонятный результат сравнения локальной и общей версий.'
    }
    $ahead = [int]$Matches.ahead
    $behind = [int]$Matches.behind
    if ($ahead -gt 0 -and $behind -gt 0) {
        Complete-Sync 'diverged' 'Локальная и общая версии разошлись. Автоматическое обновление остановлено без изменения файлов.' $false $false
        return
    }
    if ($ahead -gt 0) {
        Complete-Sync 'local-ahead' 'В локальной main есть неопубликованные коммиты. Автоматическое обновление остановлено без изменения файлов.' $false $false
        return
    }

    $updated = $false
    if ($behind -gt 0) {
        Invoke-Git @('merge', '--ff-only', '--no-edit', "refs/remotes/${remote}/${canonicalBranch}") | Out-Null
        $updated = $true
        $remoteCommit = Get-GitValue @('rev-parse', '--verify', "refs/remotes/${remote}/${canonicalBranch}^{commit}")
    }

    try {
        $refreshArguments = @{ ProjectPath = $root; Json = $true }
        if ($ForceContextRefresh) { $refreshArguments.Force = $true }
        $contextText = (& (Join-Path $root 'scripts/refresh-ai-context.ps1') @refreshArguments | Out-String).Trim()
        $context = $contextText | ConvertFrom-Json
    }
    catch {
        Complete-Sync 'context-failed' "Папка обновлена, но контекст ИИ не собран: $($_.Exception.Message)" $true $updated
        return
    }
    $message = if ($updated) {
        'Локальная папка и общий контекст нейросетей обновлены до последней версии main.'
    }
    else {
        'Локальная папка и общий контекст нейросетей актуальны.'
    }
    Complete-Sync $(if ($updated) { 'updated' } else { 'current' }) $message $true $updated $context
}
finally {
    if ($null -ne $lockStream) { $lockStream.Dispose() }
}
