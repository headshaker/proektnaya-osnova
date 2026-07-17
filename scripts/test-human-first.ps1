[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$template = Join-Path $root 'template'

foreach ($relative in @('HOME.md', 'START-HERE.md', 'DAILY-WORK.md', 'ADMIN-SETUP.md', 'GLOSSARY.md')) {
    if (-not (Test-Path -LiteralPath (Join-Path $template $relative) -PathType Leaf)) {
        throw "Отсутствует обязательная человеко-ориентированная инструкция: $relative"
    }
}

$managerFiles = @('HOME.md', 'START-HERE.md', 'DAILY-WORK.md', 'README.md')
foreach ($relative in $managerFiles) {
    $text = [System.IO.File]::ReadAllText((Join-Path $template $relative))
    if ($text -match '(?im)^\s{4,}(pwsh|python|git|gh)\b') {
        throw "Основная страница руководителя содержит ручную команду терминала: $relative"
    }
}

$start = [System.IO.File]::ReadAllText((Join-Path $template 'START-HERE.md'))
foreach ($phrase in @(
        'Вам не нужно знать Git',
        'START-PROJECT.cmd',
        'Первая задача для ИИ',
        'Готовые команды на каждый день',
        'Объясни проблему без технических терминов'
    )) {
    if ($start -notmatch [regex]::Escape($phrase)) {
        throw "START-HERE.md не содержит обязательный элемент простого старта: $phrase"
    }
}

$homeText = [System.IO.File]::ReadAllText((Join-Path $template 'HOME.md'))
foreach ($phrase in @('Это ваш главный экран', 'Получить обзор обычным языком', 'Что остаётся решением человека')) {
    if ($homeText -notmatch [regex]::Escape($phrase)) {
        throw "HOME.md не содержит обязательный раздел: $phrase"
    }
}

$admin = [System.IO.File]::ReadAllText((Join-Path $template 'ADMIN-SETUP.md'))
if ($admin -notmatch 'Техническая инструкция' -or
    $admin -notmatch 'START-PROJECT.cmd' -or
    $admin -notmatch 'setup-project.ps1' -or
    $admin -notmatch 'pwsh ./scripts/init-project.ps1') {
    throw 'ADMIN-SETUP.md не отделяет техническую настройку от пути руководителя.'
}

$glossary = [System.IO.File]::ReadAllText((Join-Path $template 'GLOSSARY.md'))
foreach ($term in @('Репозиторий', 'Commit / коммит', 'Pull request / PR', 'Diff', 'Vault', 'Канонический документ')) {
    if ($glossary -notmatch [regex]::Escape($term)) {
        throw "GLOSSARY.md не объясняет термин: $term"
    }
}

foreach ($relative in @('AI-CONNECTIONS.md', 'CONTEXT-WORKFLOW.md', 'INGESTION-WORKFLOW.md', 'MIGRATIONS.md')) {
    $text = [System.IO.File]::ReadAllText((Join-Path $template $relative))
    if ($text -notmatch 'Техническ') {
        throw "Технический справочник не помечен для своей аудитории: $relative"
    }
}

$dossierManifest = [System.IO.File]::ReadAllText((Join-Path $template 'scripts/project-dossier.manifest.json')) | ConvertFrom-Json
$dossierDocuments = @($dossierManifest.parts.documents)
foreach ($relative in @('HOME.md', 'ADMIN-SETUP.md')) {
    if ($dossierDocuments -notcontains $relative) {
        throw "Единая книга проекта не включает человеко-ориентированный файл: $relative"
    }
}

Write-Host 'Человеко-ориентированный путь и разделение аудиторий прошли проверку.'
