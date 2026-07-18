[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Agent,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Task,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string[]]$Scope,
    [string]$ChangeId,
    [string]$BranchName,
    [string]$BaseRef,
    [string]$ProjectPath = (Join-Path $PSScriptRoot '..')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Git([string[]]$Arguments) {
    $output = @(& git -C $script:root @Arguments)
    if ($LASTEXITCODE -ne 0) {
        throw "Git завершил операцию с кодом ${LASTEXITCODE}: git $($Arguments -join ' ')"
    }
    return $output
}

function Test-GitRef([string]$Ref) {
    & git -C $script:root show-ref --verify --quiet $Ref
    return $LASTEXITCODE -eq 0
}

function ConvertTo-Slug([string]$Value) {
    $slug = $Value.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    $slug = $slug.Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) { return 'ai' }
    if ($slug.Length -gt 24) { $slug = $slug.Substring(0, 24).TrimEnd('-') }
    return $slug
}

function Test-SafeScope([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $normalized = $Path.Replace('\', '/').Trim()
    if ($normalized.StartsWith('/') -or $normalized -match '^[A-Za-z]:' -or
        $normalized -match '(^|/)\.\.(/|$)' -or $normalized -match '[*?\[\]]' -or
        $normalized -eq '.' -or $normalized -eq '.git' -or $normalized.StartsWith('.git/') -or
        $normalized -eq '.ai-work' -or $normalized.StartsWith('.ai-work/') -or
        $normalized -eq 'AI-INTEGRATION-STATE.json') {
        return $false
    }
    return $true
}

$root = [System.IO.Path]::GetFullPath($ProjectPath)
$configPath = Join-Path $root 'AI-COORDINATION.json'
$statePath = Join-Path $root 'AI-INTEGRATION-STATE.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw 'В проекте отсутствуют AI-COORDINATION.json или AI-INTEGRATION-STATE.json.'
}

$repoRoot = (Invoke-Git @('rev-parse', '--show-toplevel') | Select-Object -First 1).Trim()
if ([System.IO.Path]::GetFullPath($repoRoot) -cne $root -and
    -not $IsWindows) {
    throw 'Сценарий нужно запускать из корня отдельного рабочего дерева проекта.'
}
if ($IsWindows -and [System.IO.Path]::GetFullPath($repoRoot) -ine $root) {
    throw 'Сценарий нужно запускать из корня отдельного рабочего дерева проекта.'
}

$dirty = @(Invoke-Git @('status', '--porcelain'))
if ($dirty.Count -gt 0) {
    throw 'До регистрации работы рабочее дерево должно быть чистым. Сохраните или отмените текущие изменения.'
}

$config = [System.IO.File]::ReadAllText($configPath) | ConvertFrom-Json
$canonicalBranch = [string]$config.canonicalBranch
if ([string]::IsNullOrWhiteSpace($BaseRef)) {
    $remoteRef = "refs/remotes/origin/$canonicalBranch"
    $localRef = "refs/heads/$canonicalBranch"
    if (Test-GitRef $remoteRef) { $BaseRef = "origin/$canonicalBranch" }
    elseif (Test-GitRef $localRef) { $BaseRef = $canonicalBranch }
    else { throw "Не найдена каноническая ветка $canonicalBranch. Сначала получите её из GitHub." }
}

$baseCommit = (Invoke-Git @('rev-parse', '--verify', "${BaseRef}^{commit}") | Select-Object -First 1).Trim().ToLowerInvariant()
$headCommit = (Invoke-Git @('rev-parse', '--verify', 'HEAD^{commit}') | Select-Object -First 1).Trim().ToLowerInvariant()
$currentBranch = (Invoke-Git @('branch', '--show-current') | Select-Object -First 1).Trim()
if ([string]::IsNullOrWhiteSpace($currentBranch)) { throw 'Работа из detached HEAD запрещена.' }

$agentSlug = ConvertTo-Slug $Agent
if ([string]::IsNullOrWhiteSpace($ChangeId)) {
    $ChangeId = "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$agentSlug-$([Guid]::NewGuid().ToString('N').Substring(0, 6))"
}
if ($ChangeId -notmatch '^[a-z0-9][a-z0-9-]{5,79}$') {
    throw 'ChangeId должен содержать 6–80 строчных латинских букв, цифр и дефисов.'
}
if ([string]::IsNullOrWhiteSpace($BranchName)) {
    $BranchName = "ai/$agentSlug/$ChangeId"
}
$allowedBranch = @($config.aiBranchPrefixes | Where-Object { $BranchName.StartsWith([string]$_, [System.StringComparison]::Ordinal) }).Count -gt 0
if (-not $allowedBranch) {
    throw "Ветка нейросети должна начинаться с одного из префиксов: $(@($config.aiBranchPrefixes) -join ', ')."
}

if ($currentBranch -ceq $canonicalBranch) {
    Invoke-Git @('switch', '-c', $BranchName, $BaseRef) | Out-Null
    $currentBranch = $BranchName
    $headCommit = $baseCommit
}
elseif ($currentBranch -cne $BranchName) {
    if ($PSBoundParameters.ContainsKey('BranchName')) {
        throw "Текущая ветка '$currentBranch' не совпадает с указанной '$BranchName'."
    }
    $BranchName = $currentBranch
    $allowedCurrent = @($config.aiBranchPrefixes | Where-Object { $BranchName.StartsWith([string]$_, [System.StringComparison]::Ordinal) }).Count -gt 0
    if (-not $allowedCurrent) { throw 'Текущая ветка не помечена как отдельная ветка нейросети.' }
}

if ($headCommit -cne $baseCommit) {
    throw "Новая работа должна начинаться точно от $BaseRef ($baseCommit). Обновите каноническую ветку или используйте отдельное чистое рабочее дерево."
}

$normalizedScope = [System.Collections.Generic.List[string]]::new()
foreach ($item in $Scope) {
    $path = $item.Replace('\', '/').Trim()
    if (-not (Test-SafeScope $path)) { throw "Недопустимая область изменения: $item" }
    if (-not $normalizedScope.Contains($path)) { $normalizedScope.Add($path) }
}
if ($normalizedScope.Count -eq 0) { throw 'Укажите хотя бы один файл или каталог в Scope.' }

$manifestDirectory = Join-Path $root ([string]$config.manifestDirectory)
[System.IO.Directory]::CreateDirectory($manifestDirectory) | Out-Null
$manifestPath = Join-Path $manifestDirectory "$ChangeId.json"
if (Test-Path -LiteralPath $manifestPath) { throw "Паспорт $ChangeId уже существует." }

$state = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
$sequence = [int]$state.sequence + 1
$now = [DateTime]::UtcNow.ToString('o')
$manifest = [ordered]@{
    schemaVersion       = 1
    changeId            = $ChangeId
    agent               = $Agent.Trim()
    task                = $Task.Trim()
    branch              = $BranchName
    baseCommit          = $baseCommit
    integrationSequence = $sequence
    scope               = @($normalizedScope)
    startedAt           = $now
    synchronizedAt      = $now
    status              = 'active'
}
$newState = [ordered]@{
    schemaVersion  = 1
    sequence       = $sequence
    lastChangeId   = $ChangeId
    lastBaseCommit = $baseCommit
    lastAgent      = $Agent.Trim()
    updatedAt      = $now
}
$utf8 = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 10) + "`n", $utf8)
[System.IO.File]::WriteAllText($statePath, ($newState | ConvertTo-Json -Depth 10) + "`n", $utf8)

Write-Host "Работа зарегистрирована: $ChangeId"
Write-Host "Ветка: $BranchName"
Write-Host "Исходная редакция: $baseCommit"
Write-Host "Область: $($normalizedScope -join ', ')"
Write-Host 'Добавьте паспорт и AI-INTEGRATION-STATE.json в тот же запрос изменений, что и содержательный результат.'
