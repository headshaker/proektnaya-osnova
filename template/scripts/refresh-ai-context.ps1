[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ProjectPath = (Join-Path $PSScriptRoot '..'),
    [string]$Profile = '',
    [switch]$Force,
    [switch]$Quiet,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$root = [System.IO.Path]::GetFullPath($ProjectPath).TrimEnd([char[]]@('\', '/'))
$configurationPath = Join-Path $root 'LOCAL-SYNC.json'
$statePath = Join-Path $root '.project/context/local-context-state.json'
$contextPath = Join-Path $root '.project/context/context.md'
$contextReportPath = Join-Path $root '.project/context/context-report.json'
$packagePath = Join-Path $root '.project/context/ai-package.md'
$packageReportPath = Join-Path $root '.project/context/ai-package-report.json'

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

function Get-GitValue([string[]]$Arguments) {
    $output = @(& git -C $root @Arguments)
    if ($LASTEXITCODE -ne 0) { return '' }
    return (($output | Select-Object -First 1) -as [string]).Trim()
}

foreach ($required in @(
        $configurationPath,
        (Join-Path $root 'CONTEXT-PROFILES.json'),
        (Join-Path $root 'scripts/build-context.ps1'),
        (Join-Path $root 'scripts/check-context-health.ps1'),
        (Join-Path $root 'scripts/build-ai-package.ps1')
    )) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Не найден обязательный файл обновления контекста: $required"
    }
}

$configuration = [System.IO.File]::ReadAllText($configurationPath) | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($Profile)) { $Profile = [string]$configuration.context.profile }
if ([string]::IsNullOrWhiteSpace($Profile)) { throw 'В LOCAL-SYNC.json не задан профиль контекста.' }

$tools = @()
$toolsPath = Join-Path $root 'AI-TOOLS.json'
if (Test-Path -LiteralPath $toolsPath -PathType Leaf) {
    $toolsConfiguration = [System.IO.File]::ReadAllText($toolsPath) | ConvertFrom-Json
    $tools = @($toolsConfiguration.selectedAiTools | ForEach-Object { [string]$_ })
}
$toolSignature = @($tools | Sort-Object -CaseSensitive) -join ','
$commit = Get-GitValue @('rev-parse', '--verify', 'HEAD^{commit}')
$branch = Get-GitValue @('branch', '--show-current')
$versionKey = if ([string]::IsNullOrWhiteSpace($commit)) { '' } else { "$commit|$branch|$Profile|$toolSignature" }

if (-not $Force -and -not [string]::IsNullOrWhiteSpace($versionKey) -and
    (Test-Path -LiteralPath $statePath -PathType Leaf) -and
    (Test-Path -LiteralPath $contextPath -PathType Leaf) -and
    (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
    try {
        $previous = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        if ([string]$previous.versionKey -ceq $versionKey -and [string]$previous.status -ceq 'ready') {
            $result = [pscustomobject][ordered]@{
                schemaVersion = 1
                status = 'ready'
                refreshed = $false
                commit = $commit
                branch = $branch
                profile = $Profile
                selectedAiTools = @($tools)
                packagePath = '.project/context/ai-package.md'
                refreshedAt = [string]$previous.refreshedAt
            }
            if ($Json) { Write-Output ($result | ConvertTo-Json -Depth 8 -Compress) }
            elseif (-not $Quiet) { Write-Host 'Контекст нейросетей уже соответствует текущей версии проекта.' }
            return
        }
    }
    catch { }
}

$startedAt = [DateTime]::UtcNow.ToString('o')
try {
    & (Join-Path $root 'scripts/build-context.ps1') -Profile $Profile -Check 6>$null
    & (Join-Path $root 'scripts/check-context-health.ps1') -Check 6>$null
    & (Join-Path $root 'scripts/build-ai-package.ps1') -Profile $Profile -Check 6>$null

    $contextReport = [System.IO.File]::ReadAllText($contextReportPath) | ConvertFrom-Json
    $packageReport = [System.IO.File]::ReadAllText($packageReportPath) | ConvertFrom-Json
    $state = [ordered]@{
        schemaVersion = 1
        status = 'ready'
        versionKey = $versionKey
        commit = $commit
        branch = $branch
        profile = $Profile
        selectedAiTools = @($tools)
        contextPath = '.project/context/context.md'
        contextFingerprint = [string]$contextReport.contextFingerprint
        sourceFingerprint = [string]$contextReport.sourceFingerprint
        packagePath = '.project/context/ai-package.md'
        packageFingerprint = [string]$packageReport.contextFingerprint
        startedAt = $startedAt
        refreshedAt = [DateTime]::UtcNow.ToString('o')
    }
    Write-AtomicJson $statePath $state
    $result = [pscustomobject]$state
    $result | Add-Member -NotePropertyName refreshed -NotePropertyValue $true
    if ($Json) { Write-Output ($result | ConvertTo-Json -Depth 8 -Compress) }
    elseif (-not $Quiet) { Write-Host "Контекст нейросетей обновлён для редакции $commit." }
}
catch {
    $failure = [ordered]@{
        schemaVersion = 1
        status = 'failed'
        versionKey = $versionKey
        commit = $commit
        branch = $branch
        profile = $Profile
        selectedAiTools = @($tools)
        startedAt = $startedAt
        refreshedAt = [DateTime]::UtcNow.ToString('o')
        error = $_.Exception.Message
    }
    Write-AtomicJson $statePath $failure
    throw "Не удалось обновить общий контекст нейросетей: $($_.Exception.Message)"
}
