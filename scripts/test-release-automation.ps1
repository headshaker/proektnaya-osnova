[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$planner = Join-Path $PSScriptRoot 'plan-release.ps1'
$workflowPath = Join-Path $root '.github/workflows/release.yml'
$checkWorkflowPath = Join-Path $root '.github/workflows/template-check.yml'
$version = [System.IO.File]::ReadAllText((Join-Path $root 'VERSION')).Trim()
$commitA = 'a' * 40
$commitB = 'b' * 40

function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Description) {
    try { & $Action 2>&1 | Out-Null }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "Негативная проверка '$Description' завершилась неожиданной ошибкой: $($_.Exception.Message)"
        }
        Write-Host "Негативная проверка пройдена: $Description."
        return
    }
    throw "Негативная проверка не сработала: $Description."
}

$createPlan = (& $planner -CommitSha $commitA | Select-Object -Last 1) | ConvertFrom-Json
if ($createPlan.version -cne $version -or $createPlan.tag -cne "v$version" -or
    $createPlan.commitSha -cne $commitA -or $createPlan.tagAction -cne 'create') {
    throw 'План не предложил создать отсутствующий тег текущей версии.'
}

$reusePlan = (& $planner -CommitSha $commitA -ExistingTagCommit $commitA -EventTag "v$version" |
    Select-Object -Last 1) | ConvertFrom-Json
if ($reusePlan.tagAction -cne 'reuse' -or $reusePlan.existingTagCommit -cne $commitA) {
    throw 'План не распознал согласованный существующий тег.'
}

Assert-Throws {
    & $planner -CommitSha $commitA -ExistingTagCommit $commitB
} 'Повышайте VERSION' 'изменение после выпуска без новой версии блокируется'

Assert-Throws {
    & $planner -CommitSha $commitA -EventTag 'v999.0.0'
} 'не соответствует ожидаемому тегу' 'чужой тег не публикует текущую версию'

$workflow = [System.IO.File]::ReadAllText($workflowPath)
foreach ($required in @(
        'branches:',
        '- main',
        'fetch-depth: 0',
        './scripts/plan-release.ps1',
        'gh release create',
        '--target $env:TARGET_SHA',
        'gh release upload',
        'tagName,isDraft,isPrerelease,assets,url'
    )) {
    if ($workflow.IndexOf($required, [System.StringComparison]::Ordinal) -lt 0) {
        throw "Workflow автоматического выпуска не содержит обязательный фрагмент: $required"
    }
}

$checkWorkflow = [System.IO.File]::ReadAllText($checkWorkflowPath)
foreach ($required in @(
        'release-readiness:',
        "if: github.event_name == 'pull_request'",
        'Не допустить повторного использования версии',
        './scripts/plan-release.ps1'
    )) {
    if ($checkWorkflow.IndexOf($required, [System.StringComparison]::Ordinal) -lt 0) {
        throw "Проверка pull request не содержит обязательный фрагмент: $required"
    }
}

Write-Host 'Автоматическая синхронизация версии, тега и GitHub Release прошла проверку.'
