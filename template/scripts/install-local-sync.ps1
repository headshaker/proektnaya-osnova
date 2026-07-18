[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ProjectPath = (Join-Path $PSScriptRoot '..'),
    [switch]$Apply,
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

if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) { throw 'Не найден LOCAL-SYNC.json.' }
$configuration = [System.IO.File]::ReadAllText($configurationPath) | ConvertFrom-Json
$enabled = [bool]$configuration.enabled
$interval = [int]$configuration.intervalMinutes
if ($interval -lt 1 -or $interval -gt 1440) { throw 'Интервал LOCAL-SYNC.json должен быть от 1 до 1440 минут.' }

$hash = [Convert]::ToHexString(
    [System.Security.Cryptography.SHA256]::HashData($utf8.GetBytes($root.ToLowerInvariant()))
).Substring(0, 12).ToLowerInvariant()
$taskName = "ProektnayaOsnova-$hash"
$gitHooksConfigured = $false
$scheduled = $false
$helperPath = ''
$status = if ($enabled) { 'planned' } else { 'disabled' }
$message = if ($enabled) {
    "Будут включены Git-хуки и фоновая проверка каждые $interval мин."
}
else { 'Автоматическое обновление отключено политикой проекта.' }

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

    if ($IsWindows -and -not $SkipScheduledTask) {
        $pwsh = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $scheduler = Get-Command schtasks.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $enabled -and $null -ne $scheduler) {
            & $scheduler.Source /Delete /TN $taskName /F 2>$null | Out-Null
            $status = 'disabled'
            $message = 'Фоновое обновление отключено для этого компьютера.'
        }
        elseif ($enabled -and $null -ne $pwsh -and $null -ne $scheduler) {
            $syncScript = Join-Path $root 'scripts/sync-project.ps1'
            $localApplicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
            if ([string]::IsNullOrWhiteSpace($localApplicationData)) {
                throw 'Windows не сообщил путь локальных данных пользователя для фонового задания.'
            }
            $jobsRoot = Join-Path $localApplicationData 'ProektnayaOsnova/jobs'
            [System.IO.Directory]::CreateDirectory($jobsRoot) | Out-Null
            $helperPath = Join-Path $jobsRoot "$hash.ps1"
            $escapedSyncScript = $syncScript.Replace("'", "''")
            $helperText = @(
                "`$ErrorActionPreference = 'Stop'"
                "& '$escapedSyncScript' -Quiet"
            ) -join "`r`n"
            [System.IO.File]::WriteAllText($helperPath, $helperText + "`r`n", $utf8)
            $taskCommand = ('"{0}" -NoLogo -NoProfile -NonInteractive -File "{1}"' -f $pwsh.Source, $helperPath)
            $taskOutput = @(& $scheduler.Source /Create /TN $taskName /TR $taskCommand /SC MINUTE /MO $interval /RL LIMITED /F 2>&1)
            if ($LASTEXITCODE -eq 0) { $scheduled = $true }
            else { $message = "Git-хуки включены, но фоновое задание не создано: $($taskOutput -join ' ')" }
        }
        else { $message = 'Git-хуки включены, но Windows Task Scheduler или PowerShell 7 недоступен.' }
    }
    elseif ($enabled -and -not $IsWindows) {
        $message = 'Git-хуки включены. На этой системе автоматическая проверка также выполняется при запуске проекта.'
    }

    $status = if (-not $enabled) { 'disabled' } elseif ($scheduled -or (-not $IsWindows -and $gitHooksConfigured)) { 'installed' } elseif ($gitHooksConfigured) { 'partial' } else { 'pending' }
    if ($status -ceq 'installed') { $message = 'Автоматическое обновление локальной папки и контекста включено.' }
    elseif ($status -ceq 'pending') { $message = 'Папка ещё не является Git-репозиторием. Запустите START-PROJECT после клонирования.' }
}

$result = [pscustomobject][ordered]@{
    schemaVersion = 1
    status = $status
    message = $message
    enabled = $enabled
    applied = [bool]$Apply
    taskName = $taskName
    intervalMinutes = $interval
    gitHooksConfigured = $gitHooksConfigured
    scheduledTaskConfigured = $scheduled
    taskHelperPath = $helperPath
    projectPath = $root
    configuredAt = [DateTime]::UtcNow.ToString('o')
}
if ($Apply) { Write-AtomicJson $reportPath $result }
if ($Apply) {
    $humanText = @(
        '# Состояние автоматического обновления'
        ''
        "**$($result.message)**"
        ''
        "- Статус установки: ``$($result.status)``"
        "- Интервал Windows: $interval мин."
        "- Настроено: $(([DateTimeOffset]::Parse([string]$result.configuredAt)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz'))"
        ''
        'Первая проверка общей версии выполняется при запуске проекта.'
    ) -join "`n"
    try {
        $statusStream = [System.IO.File]::Open(
            $humanReportPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        try {
            $statusBytes = $utf8.GetBytes($humanText + "`n")
            $statusStream.Write($statusBytes, 0, $statusBytes.Length)
        }
        finally { $statusStream.Dispose() }
    }
    catch [System.IO.IOException] { }
}
if ($Json) { Write-Output ($result | ConvertTo-Json -Depth 8 -Compress) }
else { Write-Host $message }
