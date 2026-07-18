[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9][a-z0-9-]{5,79}$')][string]$ChangeId,
    [string]$BaseRef = 'origin/main',
    [string]$ProjectPath = (Join-Path $PSScriptRoot '..')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath($ProjectPath)

function Invoke-Git([string[]]$Arguments) {
    $output = @(& git -C $script:root @Arguments)
    if ($LASTEXITCODE -ne 0) {
        throw "Git завершил операцию с кодом ${LASTEXITCODE}: git $($Arguments -join ' ')"
    }
    return $output
}

$configPath = Join-Path $root 'AI-COORDINATION.json'
$statePath = Join-Path $root 'AI-INTEGRATION-STATE.json'
$config = [System.IO.File]::ReadAllText($configPath) | ConvertFrom-Json
$manifestPath = Join-Path (Join-Path $root ([string]$config.manifestDirectory)) "$ChangeId.json"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Паспорт $ChangeId не найден." }

$dirty = @(Invoke-Git @('status', '--porcelain'))
if ($dirty.Count -gt 0) {
    throw 'Сначала завершите перенос ветки и сохраните разрешённые конфликты. Перед синхронизацией рабочее дерево должно быть чистым.'
}

$branch = (Invoke-Git @('branch', '--show-current') | Select-Object -First 1).Trim()
$allowedBranch = @($config.aiBranchPrefixes | Where-Object { $branch.StartsWith([string]$_, [System.StringComparison]::Ordinal) }).Count -gt 0
if (-not $allowedBranch) { throw 'Синхронизация разрешена только в отдельной ветке нейросети.' }

$baseCommit = (Invoke-Git @('rev-parse', '--verify', "${BaseRef}^{commit}") | Select-Object -First 1).Trim().ToLowerInvariant()
& git -C $root merge-base --is-ancestor $baseCommit HEAD
if ($LASTEXITCODE -ne 0) {
    throw "Сначала перенесите ветку поверх свежей основы $BaseRef ($baseCommit) и разрешите содержательные конфликты."
}

$baseStateText = @(Invoke-Git @('show', "${baseCommit}:$([string]$config.integrationStateFile)")) -join "`n"
$baseState = $baseStateText | ConvertFrom-Json
$manifest = [System.IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
$now = [DateTime]::UtcNow.ToString('o')
$sequence = [int]$baseState.sequence + 1
$manifest.branch = $branch
$manifest.baseCommit = $baseCommit
$manifest.integrationSequence = $sequence
$manifest.synchronizedAt = $now
$newState = [ordered]@{
    schemaVersion  = 1
    sequence       = $sequence
    lastChangeId   = [string]$manifest.changeId
    lastBaseCommit = $baseCommit
    lastAgent      = [string]$manifest.agent
    updatedAt      = $now
}
$utf8 = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 10) + "`n", $utf8)
[System.IO.File]::WriteAllText($statePath, ($newState | ConvertTo-Json -Depth 10) + "`n", $utf8)

Write-Host "Паспорт $ChangeId синхронизирован с $baseCommit."
Write-Host 'Повторно проверьте содержательный результат, сохраните эти два файла и запустите check-ai-coordination.ps1.'
