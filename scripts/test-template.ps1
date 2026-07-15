[CmdletBinding()]
param(
    [string]$Title = 'Проверка шаблона',
    [string]$Slug = 'template-test',
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $root 'template'
$test = [System.IO.Path]::GetFullPath((Join-Path $root '.tmp-template-test'))

if (-not $test.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Небезопасный путь тестовой папки.'
}

try {
    if (Test-Path -LiteralPath $test) {
        Remove-Item -LiteralPath $test -Recurse -Force
    }
    Copy-Item -LiteralPath $source -Destination $test -Recurse

    & (Join-Path $test 'scripts/init-project.ps1') -Title $Title -Slug $Slug -Date $Date
    & (Join-Path $test 'scripts/validate-vault.ps1')
    & (Join-Path $test 'scripts/build-project-dossier.ps1') --check

    $markers = Get-ChildItem -LiteralPath $test -Recurse -File |
        Select-String -Pattern '\{\{(PROJECT_TITLE|PROJECT_SLUG|DATE)\}\}'
    if ($markers) {
        throw 'После инициализации остались маркеры проекта.'
    }

    Write-Host 'Сквозная проверка шаблона пройдена.'
}
finally {
    if (Test-Path -LiteralPath $test) {
        if (-not $test.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar,
                [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Небезопасное удаление тестовой папки.'
        }
        Remove-Item -LiteralPath $test -Recurse -Force
    }
}

