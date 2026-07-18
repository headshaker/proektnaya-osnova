[CmdletBinding()]
param(
    [switch]$Console,
    [switch]$SelfTest,
    [switch]$SkipInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$setupScript = Join-Path $PSScriptRoot 'setup-project.ps1'
$uiRoot = Join-Path $root 'setup-ui'
$packagePath = Join-Path $uiRoot 'package.json'
$bundledElectron = Join-Path $uiRoot 'runtime/Project Setup.exe'
$electronLauncher = if ($IsWindows) {
    Join-Path $uiRoot 'node_modules/.bin/electron.cmd'
}
else {
    Join-Path $uiRoot 'node_modules/.bin/electron'
}

function Invoke-ConsoleWizard {
    Write-Host ''
    Write-Host 'Открывается запасной текстовый мастер настройки.'
    & $setupScript
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Get-NodeVersion([System.Management.Automation.CommandInfo]$NodeCommand) {
    $versionText = (& $NodeCommand.Source --version 2>$null | Select-Object -First 1).Trim()
    if ($versionText -notmatch '^v(?<version>\d+\.\d+\.\d+)') { return [version]'0.0.0' }
    return [version]$Matches['version']
}

foreach ($required in @($setupScript, $packagePath, (Join-Path $uiRoot 'main.js'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Не найден обязательный файл мастера: $required"
    }
}

$package = [System.IO.File]::ReadAllText($packagePath) | ConvertFrom-Json
if ([string]$package.name -cne 'proektnaya-osnova-setup' -or
    [string]::IsNullOrWhiteSpace([string]$package.devDependencies.electron)) {
    throw 'Файл setup-ui/package.json не содержит проверенную конфигурацию Electron.'
}

if ($SelfTest) {
    [pscustomobject][ordered]@{
        status = 'ok'
        projectRoot = $root
        setupScript = $setupScript
        uiRoot = $uiRoot
        electronVersion = [string]$package.devDependencies.electron
    } | ConvertTo-Json -Compress
    return
}

if ($Console) {
    Invoke-ConsoleWizard
    return
}

if ($IsWindows -and (Test-Path -LiteralPath $bundledElectron -PathType Leaf)) {
    Write-Host 'Открывается визуальный мастер настройки...'
    & $bundledElectron
    $result = $LASTEXITCODE
    if ($result -eq 0) { return }
    Write-Warning "Встроенный визуальный мастер завершился с кодом $result."
    Invoke-ConsoleWizard
    return
}

$node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue
$npm = Get-Command $(if ($IsWindows) { 'npm.cmd' } else { 'npm' }) `
    -CommandType Application -ErrorAction SilentlyContinue
$nodeVersion = if ($null -ne $node) { Get-NodeVersion $node } else { [version]'0.0.0' }

if ($null -eq $node -or $null -eq $npm -or $nodeVersion -lt [version]'22.12.0') {
    Write-Warning 'Для визуального мастера нужны Node.js 22.12 или новее и npm.'
    Write-Host 'Можно установить Node.js и повторить запуск. Сейчас доступен текстовый мастер.'
    Invoke-ConsoleWizard
    return
}

if (-not (Test-Path -LiteralPath $electronLauncher -PathType Leaf)) {
    if ($SkipInstall) {
        throw 'Electron ещё не установлен в setup-ui/node_modules.'
    }
    Write-Host 'Первый запуск: подготавливается визуальный мастер.'
    Write-Host 'Это выполняется один раз и может занять несколько минут.'
    & $npm.Source ci --ignore-scripts --no-audit --no-fund --prefix $uiRoot
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $electronLauncher -PathType Leaf)) {
        Write-Warning 'Не удалось подготовить Electron. Проверьте интернет-подключение и доступ к npm.'
        Invoke-ConsoleWizard
        return
    }
}

Write-Host 'Открывается визуальный мастер настройки...'
& $electronLauncher $uiRoot
$result = $LASTEXITCODE
if ($result -ne 0) {
    Write-Warning "Визуальный мастер завершился с кодом $result."
    Invoke-ConsoleWizard
}
