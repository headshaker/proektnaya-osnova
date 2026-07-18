[CmdletBinding()]
param(
    [string]$OutputPath,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) { throw 'Встроенный runtime мастера собирается только в Windows.' }

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$uiRoot = Join-Path $root 'template/setup-ui'
$electronDist = Join-Path $uiRoot 'node_modules/electron/dist'
$version = [System.IO.File]::ReadAllText((Join-Path $root 'VERSION')).Trim()
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $uiRoot 'runtime'
}
elseif (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $root $OutputPath
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

$allowedParent = [System.IO.Path]::GetFullPath($uiRoot).TrimEnd([char[]]@('\', '/')) +
    [System.IO.Path]::DirectorySeparatorChar
if (-not $OutputPath.StartsWith($allowedParent, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Runtime разрешено собирать только внутри template/setup-ui.'
}
if (-not (Test-Path -LiteralPath (Join-Path $electronDist 'electron.exe') -PathType Leaf)) {
    throw 'Electron ещё не загружен. Выполните npx install-electron --no в template/setup-ui.'
}
if (Test-Path -LiteralPath $OutputPath) {
    if (-not $Force) { throw "Папка runtime уже существует: $OutputPath. Для замены укажите -Force." }
    Remove-Item -LiteralPath $OutputPath -Recurse -Force
}

Copy-Item -LiteralPath $electronDist -Destination $OutputPath -Recurse
$resources = Join-Path $OutputPath 'resources'
$defaultApplication = Join-Path $resources 'default_app.asar'
if (Test-Path -LiteralPath $defaultApplication -PathType Leaf) {
    Remove-Item -LiteralPath $defaultApplication -Force
}

$application = Join-Path $resources 'app'
[System.IO.Directory]::CreateDirectory($application) | Out-Null
foreach ($relative in @('main.js', 'preload.js', 'renderer.js', 'setup-contract.js', 'index.html', 'styles.css')) {
    $source = Join-Path $uiRoot $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Не найден файл интерфейса: $relative" }
    Copy-Item -LiteralPath $source -Destination (Join-Path $application $relative)
}

$runtimePackage = [ordered]@{
    name = 'proektnaya-osnova-setup'
    version = $version
    private = $true
    main = 'main.js'
}
[System.IO.File]::WriteAllText(
    (Join-Path $application 'package.json'),
    ($runtimePackage | ConvertTo-Json) + "`n",
    [System.Text.UTF8Encoding]::new($false)
)
[System.IO.File]::WriteAllText(
    (Join-Path $OutputPath 'RUNTIME-VERSION'),
    "Electron $(([System.IO.File]::ReadAllText((Join-Path $uiRoot 'package.json')) | ConvertFrom-Json).devDependencies.electron); app $version`n",
    [System.Text.UTF8Encoding]::new($false)
)

$electronExecutable = Join-Path $OutputPath 'electron.exe'
$applicationExecutable = Join-Path $OutputPath 'Project Setup.exe'
Move-Item -LiteralPath $electronExecutable -Destination $applicationExecutable

if (-not (Test-Path -LiteralPath $applicationExecutable -PathType Leaf)) {
    throw 'Не создан исполняемый файл визуального мастера.'
}
if (Get-ChildItem -LiteralPath $application -Recurse -Directory | Where-Object Name -eq 'node_modules') {
    throw 'В приложение ошибочно попала папка node_modules.'
}
Write-Host "Встроенный визуальный мастер собран: $applicationExecutable"
