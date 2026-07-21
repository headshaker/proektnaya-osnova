[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ProjectPath = (Join-Path $PSScriptRoot '..'),
    [string]$LogPath,
    [int]$MaximumLogBytes = 524288
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$root = [System.IO.Path]::GetFullPath($ProjectPath).TrimEnd([char[]]@('\', '/'))
$syncScript = Join-Path $root 'scripts/sync-project.ps1'
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $root '.project/local-sync.log'
}
$LogPath = [System.IO.Path]::GetFullPath($LogPath)

function Compress-LogIfNeeded {
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return }
    $item = Get-Item -LiteralPath $LogPath
    if ($item.Length -le $MaximumLogBytes) { return }

    $keepBytes = [Math]::Max(65536, [Math]::Floor($MaximumLogBytes / 2))
    $stream = [System.IO.File]::Open($LogPath, 'Open', 'Read', 'ReadWrite')
    try {
        $start = [Math]::Max(0, $stream.Length - $keepBytes)
        $stream.Seek($start, [System.IO.SeekOrigin]::Begin) | Out-Null
        $buffer = [byte[]]::new($stream.Length - $start)
        $read = $stream.Read($buffer, 0, $buffer.Length)
    }
    finally { $stream.Dispose() }

    $tail = $utf8.GetString($buffer, 0, $read)
    $firstLineBreak = $tail.IndexOf("`n")
    if ($firstLineBreak -ge 0) { $tail = $tail.Substring($firstLineBreak + 1) }
    [System.IO.File]::WriteAllText(
        $LogPath,
        "# Более ранние записи журнала автоматически удалены.`n$tail",
        $utf8
    )
}

function Write-Log([string]$Level, [string]$Message) {
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $LogPath)) | Out-Null
    Compress-LogIfNeeded
    $safeMessage = (($Message -replace '[\r\n]+', ' ') -replace '\s{2,}', ' ').Trim()
    if ($safeMessage.Length -gt 2000) { $safeMessage = $safeMessage.Substring(0, 2000) + '…' }
    $line = '{0} [{1}] {2}' -f [DateTimeOffset]::Now.ToString('o'), $Level, $safeMessage
    [System.IO.File]::AppendAllText($LogPath, $line + "`n", $utf8)
}

try {
    if (-not (Test-Path -LiteralPath $syncScript -PathType Leaf)) {
        throw "Не найден сценарий синхронизации: $syncScript"
    }

    $output = (& $syncScript -ProjectPath $root -Quiet -Json 2>&1 | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($output)) {
        Write-Log 'INFO' 'Проверка пропущена: другая синхронизация уже выполняется.'
        return
    }

    $result = $null
    foreach ($line in @($output -split '[\r\n]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        try {
            $candidate = $line | ConvertFrom-Json
            if ($null -ne $candidate.PSObject.Properties['status']) { $result = $candidate }
        }
        catch { }
    }
    if ($null -eq $result) { throw "Синхронизация вернула непонятный результат: $output" }

    $warningStatuses = @(
        'offline', 'local-changes', 'diverged', 'local-ahead', 'agent-branch-stale',
        'context-failed', 'git-missing', 'not-a-repository', 'detached-head', 'remote-branch-missing'
    )
    $level = if ([string]$result.status -in $warningStatuses) { 'WARN' } else { 'INFO' }
    Write-Log $level ("status={0}; {1}" -f [string]$result.status, [string]$result.message)
}
catch {
    try { Write-Log 'ERROR' $_.Exception.Message }
    catch { }
    throw
}
