[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][string]$Slug,
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Title)) {
    throw 'Title не должен быть пустым.'
}
if ($Title.Length -gt 200) {
    throw 'Title не должен превышать 200 символов.'
}
if ($Title -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') {
    throw 'Title не должен содержать управляющие символы или переносы строк.'
}
if ($Title -match '\{\{(PROJECT_TITLE|PROJECT_SLUG|DATE)\}\}') {
    throw 'Title не должен содержать служебные маркеры шаблона.'
}
if ($Slug -notmatch '^[a-z0-9][a-z0-9-]*$') {
    throw 'Slug должен содержать только строчные латинские буквы, цифры и дефисы.'
}
if ($Slug.Length -gt 63) {
    throw 'Slug не должен превышать 63 символа.'
}
[DateTime]$parsedDate = [DateTime]::MinValue
if (-not [DateTime]::TryParseExact(
        $Date,
        'yyyy-MM-dd',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$parsedDate
    )) {
    throw 'Date должен быть существующей календарной датой в формате ГГГГ-ММ-ДД.'
}

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$projectTitleToken = '{{' + 'PROJECT_TITLE' + '}}'
$yamlProjectTitleToken = '"' + $projectTitleToken + '"'
$yamlTitle = $Title.Replace('\', '\\').Replace('"', '\"')
$tokens = @{
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
    $updated = $text.Replace($yamlProjectTitleToken, '"' + $yamlTitle + '"')
    $updated = $updated.Replace($projectTitleToken, $Title)
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
