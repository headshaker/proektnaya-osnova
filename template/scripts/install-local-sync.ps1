[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ProjectPath = (Join-Path $PSScriptRoot '..'),
    [switch]$Apply,
    [switch]$Enable,
    [switch]$Disable,
    [switch]$SkipScheduledTask,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$root = [System.IO.Path]::GetFullPath($ProjectPath).TrimEnd([char[]]@('\', '/'))
$configurationPath = Join-Path $root 'LOCAL-SYNC.json'
$reportPath = Join-Path $root '.project/local-sync-installation.json'
$humanReportPath = Join-Path $root '.project/LOCAL-SYNC-STATUS.md'
$logPath = Join-Path $root '.project/local-sync.log'
$localDisablePath = Join-Path $root '.project/local-sync.disabled'
$backgroundRunnerPath = Join-Path $root 'scripts/run-local-sync-background.ps1'

if ($Enable -and $Disable) { throw 'Нельзя одновременно включить и отключить фоновое обновление.' }

function Write-AtomicJson([string]$Path, [object]$Value) {
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    $temporary = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 10) + "`n", $utf8)
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

if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) { throw 'Не найден LOCAL-SYNC.json.' }
$configuration = [System.IO.File]::ReadAllText($configurationPath) | ConvertFrom-Json
$policyEnabled = [bool]$configuration.enabled
$interval = [int]$configuration.intervalMinutes
if ($interval -lt 1 -or $interval -gt 1440) { throw 'Интервал LOCAL-SYNC.json должен быть от 1 до 1440 минут.' }

if ($Apply -and $Disable) {
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $localDisablePath)) | Out-Null
    [System.IO.File]::WriteAllText($localDisablePath, [DateTimeOffset]::Now.ToString('o') + "`n", $utf8)
}
elseif ($Apply -and $Enable -and (Test-Path -LiteralPath $localDisablePath)) {
    Remove-Item -LiteralPath $localDisablePath -Force
}
$localEnabled = -not (Test-Path -LiteralPath $localDisablePath -PathType Leaf)
$enabled = $policyEnabled -and $localEnabled

$hash = [Convert]::ToHexString(
    [System.Security.Cryptography.SHA256]::HashData($utf8.GetBytes($root.ToLowerInvariant()))
).Substring(0, 12).ToLowerInvariant()
$taskName = "ProektnayaOsnova-$hash"
$gitHooksConfigured = $false
$scheduled = $false
$helperPath = ''
$status = if ($enabled) { 'planned' } elseif (-not $policyEnabled) { 'disabled-policy' } else { 'disabled-local' }
$message = if ($enabled) {
    "Будут включены Git-хуки и фоновая проверка каждые $interval мин."
}
elseif (-not $policyEnabled) { 'Автоматическое обновление отключено политикой проекта.' }
else { 'Фоновое обновление отключено на этом компьютере.' }

if ($Apply) {
    $insideRepository = $false
    if ($null -ne (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        & git -C $root rev-parse --show-toplevel 2>$null | Out-Null
        $insideRepository = $LASTEXITCODE -eq 0
    }
    if ($enabled -and $insideRepository) {
        & git -C $root config --local core.hooksPath .githooks
        if ($LASTEXITCODE -ne 0) { throw 'Не удалось включить локальные Git-хуки обновления контекста.' }
        if (-not $IsWindows) {
            $chmod = Get-Command chmod -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $chmod) { throw 'Не найден chmod для включения локальных Git-хуков.' }
            foreach ($hook in Get-ChildItem -LiteralPath (Join-Path $root '.githooks') -File) {
                & $chmod.Source '+x' $hook.FullName
                if ($LASTEXITCODE -ne 0) { throw "Не удалось сделать Git-хук исполняемым: $($hook.Name)" }
            }
        }
        $gitHooksConfigured = $true
    }
    elseif (-not $enabled -and $insideRepository) {
        $configuredHooks = @(& git -C $root config --local --get core.hooksPath 2>$null)
        if ($LASTEXITCODE -eq 0 -and ($configuredHooks | Select-Object -First 1) -ceq '.githooks') {
            & git -C $root config --local --unset core.hooksPath
            if ($LASTEXITCODE -notin @(0, 5)) { throw 'Не удалось отключить локальные Git-хуки обновления контекста.' }
        }
    }

    if ($IsWindows -and -not $SkipScheduledTask) {
        $currentPowerShellPath = try { (Get-Process -Id $PID).Path } catch { '' }
        $pwshPath = if (-not [string]::IsNullOrWhiteSpace($currentPowerShellPath) -and
            [System.IO.Path]::GetFileName($currentPowerShellPath) -ieq 'pwsh.exe') {
            $currentPowerShellPath
        }
        else {
            $pwsh = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $pwsh) { $pwsh.Source } else { '' }
        }
        $scheduler = Get-Command schtasks.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $enabled -and $null -ne $scheduler) {
            & $scheduler.Source /Delete /TN $taskName /F 2>$null | Out-Null
            $status = if (-not $policyEnabled) { 'disabled-policy' } else { 'disabled-local' }
        }
        elseif ($enabled -and -not [string]::IsNullOrWhiteSpace($pwshPath) -and $null -ne $scheduler) {
            if (-not (Test-Path -LiteralPath $backgroundRunnerPath -PathType Leaf)) {
                throw 'Не найден фоновый обработчик обновления.'
            }
            $localApplicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
            if ([string]::IsNullOrWhiteSpace($localApplicationData)) {
                throw 'Windows не сообщил путь локальных данных пользователя для фонового задания.'
            }
            $jobsRoot = Join-Path $localApplicationData 'ProektnayaOsnova/jobs'
            [System.IO.Directory]::CreateDirectory($jobsRoot) | Out-Null
            $helperPath = Join-Path $jobsRoot "$hash.ps1"
            $escapedRunner = $backgroundRunnerPath.Replace("'", "''")
            $escapedRoot = $root.Replace("'", "''")
            $escapedLogPath = $logPath.Replace("'", "''")
            $helperText = @(
                "`$ErrorActionPreference = 'Stop'"
                "& '$escapedRunner' -ProjectPath '$escapedRoot' -LogPath '$escapedLogPath'"
            ) -join "`r`n"
            [System.IO.File]::WriteAllText($helperPath, $helperText + "`r`n", $utf8)
            $taskCommand = ('"{0}" -WindowStyle Hidden -NoLogo -NoProfile -NonInteractive -File "{1}"' -f $pwshPath, $helperPath)
            $taskOutput = @(& $scheduler.Source /Create /TN $taskName /TR $taskCommand /SC MINUTE /MO $interval /RL LIMITED /F 2>&1)
            if ($LASTEXITCODE -eq 0) { $scheduled = $true }
            else { $message = "Git-хуки включены, но фоновое задание не создано: $($taskOutput -join ' ')" }
        }
        else { $message = 'Git-хуки включены, но Windows Task Scheduler или внутренний механизм запуска недоступен.' }
    }
    elseif ($enabled -and -not $IsWindows) {
        $message = 'Git-хуки включены. На этой системе автоматическая проверка также выполняется при запуске проекта.'
    }

    $status = if (-not $enabled) {
        if (-not $policyEnabled) { 'disabled-policy' } else { 'disabled-local' }
    } elseif ($scheduled -or (-not $IsWindows -and $gitHooksConfigured)) { 'installed' } elseif ($gitHooksConfigured) { 'partial' } else { 'pending' }
    if ($status -ceq 'installed') { $message = 'Автоматическое обновление локальной папки и контекста включено.' }
    elseif ($status -ceq 'pending') { $message = 'Папка ещё не является Git-репозиторием. Запустите START-PROJECT после клонирования.' }
}

$result = [pscustomobject][ordered]@{
    schemaVersion = 2
    status = $status
    message = $message
    enabled = $enabled
    policyEnabled = $policyEnabled
    localEnabled = $localEnabled
    applied = [bool]$Apply
    taskName = $taskName
    intervalMinutes = $interval
    gitHooksConfigured = $gitHooksConfigured
    scheduledTaskConfigured = $scheduled
    taskHelperPath = $helperPath
    logPath = $logPath
    projectPath = $root
    configuredAt = [DateTime]::UtcNow.ToString('o')
}
if ($Apply) { Write-AtomicJson $reportPath $result }
if ($Apply) {
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $logPath)) | Out-Null
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        [System.IO.File]::WriteAllText($logPath, "# Журнал фонового обновления проекта`n", $utf8)
    }
    $humanText = @(
        '# Состояние автоматического обновления'
        ''
        "**$($result.message)**"
        ''
        "- Статус установки: ``$($result.status)``"
        "- Интервал Windows: $interval мин."
        "- Журнал: ``.project/local-sync.log``"
        "- Настроено: $(([DateTimeOffset]::Parse([string]$result.configuredAt)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz'))"
        ''
        'Первая проверка общей версии выполняется при запуске проекта.'
        'Включить или отключить обновление на этом компьютере можно повторным запуском START-PROJECT.'
    ) -join "`n"
    Write-AtomicText $humanReportPath $humanText
}
if ($Json) { Write-Output ($result | ConvertTo-Json -Depth 8 -Compress) }
else { Write-Host $message }
