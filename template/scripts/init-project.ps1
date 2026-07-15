[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][string]$Slug,
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Slug -notmatch '^[a-z0-9][a-z0-9-]*$') {
    throw 'Slug должен содержать только строчные латинские буквы, цифры и дефисы.'
}
if ($Date -notmatch '^\d{4}-\d{2}-\d{2}$') {
    throw 'Date должен иметь формат ГГГГ-ММ-ДД.'
}

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tokens = @{
    ('{{' + 'PROJECT_TITLE' + '}}') = $Title
    ('{{' + 'PROJECT_SLUG' + '}}')  = $Slug
    ('{{' + 'DATE' + '}}')          = $Date
}
$extensions = @('.md', '.json', '.yml', '.yaml')
$changed = 0

Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object {
    if ($extensions -notcontains $_.Extension.ToLowerInvariant()) {
        return
    }
    $text = [System.IO.File]::ReadAllText($_.FullName)
    $updated = $text
    foreach ($token in $tokens.Keys) {
        $updated = $updated.Replace($token, $tokens[$token])
    }
    if ($updated -cne $text) {
        [System.IO.File]::WriteAllText(
            $_.FullName,
            $updated,
            [System.Text.UTF8Encoding]::new($false)
        )
        $changed++
    }
}

Write-Host "Инициализация завершена: изменено файлов — $changed."
& (Join-Path $PSScriptRoot 'build-project-dossier.ps1')
& (Join-Path $PSScriptRoot 'build-project-dossier.ps1') -Check
& (Join-Path $PSScriptRoot 'validate-vault.ps1')
