[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runId = [Guid]::NewGuid().ToString('N')
$test = [System.IO.Path]::GetFullPath((Join-Path $root ".tmp-ai-coordination-test-$runId"))
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Invoke-TestGit([string[]]$Arguments, [switch]$AllowFailure) {
    $output = @(& git -C $test @Arguments)
    $code = $LASTEXITCODE
    if (-not $AllowFailure -and $code -ne 0) {
        throw "Git fixture failed with code ${code}: git $($Arguments -join ' ')"
    }
    return [pscustomobject]@{ Code = $code; Output = $output }
}

function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Description) {
    try { & $Action 2>&1 | Out-Null }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "Проверка '$Description' дала неожиданную ошибку: $($_.Exception.Message)"
        }
        Write-Host "Негативная проверка пройдена: $Description."
        return
    }
    throw "Негативная проверка не сработала: $Description."
}

function Add-Line([string]$RelativePath, [string]$Line) {
    $path = Join-Path $test $RelativePath
    $text = [System.IO.File]::ReadAllText($path)
    [System.IO.File]::WriteAllText($path, $text + "`n$Line`n", $utf8)
}

function Save-TestCommit([string]$Message) {
    Invoke-TestGit @('add', '--all') | Out-Null
    Invoke-TestGit @('commit', '-m', $Message) | Out-Null
}

if (-not $test.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Небезопасный путь теста координации нейросетей.'
}

try {
    Copy-Item -LiteralPath (Join-Path $root 'template') -Destination $test -Recurse
    & (Join-Path $test 'scripts/init-project.ps1') -Title 'Параллельная проверка ИИ' -Slug 'multi-ai-test' -Date '2026-07-18'

    Invoke-TestGit @('init', '-b', 'main') | Out-Null
    Invoke-TestGit @('config', 'user.name', 'AI coordination test') | Out-Null
    Invoke-TestGit @('config', 'user.email', 'ai-coordination@example.invalid') | Out-Null
    Save-TestCommit 'Initial project state'
    $initialBase = (Invoke-TestGit @('rev-parse', 'main')).Output[0].Trim()

    $start = Join-Path $test 'scripts/start-ai-work.ps1'
    $check = Join-Path $test 'scripts/check-ai-coordination.ps1'
    $sync = Join-Path $test 'scripts/sync-ai-work.ps1'

    & $start -Agent 'Codex' -Task 'Уточнить продукт' -Scope 'docs/01-product.md' `
        -ChangeId 'codex-product-001' -BranchName 'ai/codex/codex-product-001' -BaseRef main -ProjectPath $test
    Add-Line 'docs/01-product.md' 'Проверочный результат Codex.'
    Save-TestCommit 'Codex product update'
    & $check -BaseRef $initialBase -HeadRef HEAD -BranchName 'ai/codex/codex-product-001' -ProjectPath $test

    Invoke-TestGit @('switch', 'main') | Out-Null
    & $start -Agent 'Claude' -Task 'Уточнить архитектуру' -Scope 'docs/02-architecture.md' `
        -ChangeId 'claude-architecture-001' -BranchName 'ai/claude/claude-architecture-001' -BaseRef main -ProjectPath $test
    Add-Line 'docs/02-architecture.md' 'Проверочный результат Claude.'
    Save-TestCommit 'Claude architecture update'
    & $check -BaseRef $initialBase -HeadRef HEAD -BranchName 'ai/claude/claude-architecture-001' -ProjectPath $test

    Invoke-TestGit @('switch', 'main') | Out-Null
    Invoke-TestGit @('merge', '--no-ff', 'ai/codex/codex-product-001', '-m', 'Integrate Codex') | Out-Null
    $newBase = (Invoke-TestGit @('rev-parse', 'main')).Output[0].Trim()
    Assert-Throws {
        & $check -BaseRef $newBase -HeadRef 'ai/claude/claude-architecture-001' `
            -BranchName 'ai/claude/claude-architecture-001' -ProjectPath $test
    } 'устарела|не основана' 'вторая параллельная работа устаревает после первого объединения'

    Invoke-TestGit @('switch', 'ai/claude/claude-architecture-001') | Out-Null
    $merge = Invoke-TestGit @('merge', 'main', '--no-edit') -AllowFailure
    if ($merge.Code -eq 0) { throw 'Общий интеграционный счётчик не создал ожидаемый конфликт параллельных работ.' }
    $mainState = (Invoke-TestGit @('show', 'main:AI-INTEGRATION-STATE.json')).Output -join "`n"
    [System.IO.File]::WriteAllText((Join-Path $test 'AI-INTEGRATION-STATE.json'), $mainState + "`n", $utf8)
    Invoke-TestGit @('add', 'AI-INTEGRATION-STATE.json') | Out-Null
    Invoke-TestGit @('commit', '--no-edit') | Out-Null

    & $sync -ChangeId 'claude-architecture-001' -BaseRef main -ProjectPath $test
    Save-TestCommit 'Synchronize Claude after Codex'
    & $check -BaseRef $newBase -HeadRef HEAD -BranchName 'ai/claude/claude-architecture-001' -ProjectPath $test

    Add-Line 'docs/04-governance-risks.md' 'Незапланированное изменение.'
    Save-TestCommit 'Out of scope update'
    Assert-Throws {
        & $check -BaseRef $newBase -HeadRef HEAD -BranchName 'ai/claude/claude-architecture-001' -ProjectPath $test
    } 'выходит за заявленные границы' 'изменение вне заявленной области отклоняется'

    Invoke-TestGit @('switch', 'main') | Out-Null
    Invoke-TestGit @('switch', '-c', 'ai/gemini/no-passport') | Out-Null
    Add-Line 'docs/03-delivery.md' 'Изменение без паспорта.'
    Save-TestCommit 'Missing AI manifest'
    Assert-Throws {
        & $check -BaseRef main -HeadRef HEAD -BranchName 'ai/gemini/no-passport' -ProjectPath $test
    } 'ровно один паспорт' 'ветка нейросети без паспорта отклоняется'

    Invoke-TestGit @('switch', 'main') | Out-Null
    Invoke-TestGit @('switch', '-c', 'human/editorial') | Out-Null
    Add-Line 'GLOSSARY.md' 'Редакторское изменение человека.'
    Save-TestCommit 'Human editorial update'
    & $check -BaseRef main -HeadRef HEAD -BranchName 'human/editorial' -ProjectPath $test

    Write-Host 'Параллельная работа, намеренный интеграционный конфликт, синхронизация и границы задач проверены.'
}
finally {
    if (Test-Path -LiteralPath $test) {
        if (-not $test.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar,
                [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Небезопасное удаление тестовой папки координации.'
        }
        Remove-Item -LiteralPath $test -Recurse -Force
    }
}
