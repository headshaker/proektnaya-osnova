[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $root 'template'
$runId = [Guid]::NewGuid().ToString('N')
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $root ".tmp-github-protection-$runId"))
$project = Join-Path $testRoot 'project'
$mockGh = Join-Path $testRoot 'mock-gh.ps1'
$statePath = Join-Path $testRoot 'mock-state.txt'
$logPath = Join-Path $testRoot 'mock-log.txt'
$previousState = $env:PROEKTNAYA_OSNOVA_TEST_GH_STATE
$previousLog = $env:PROEKTNAYA_OSNOVA_TEST_GH_LOG
$previousAdmin = $env:PROEKTNAYA_OSNOVA_TEST_GH_ADMIN
$utf8 = [System.Text.UTF8Encoding]::new($false)

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

if (-not $testRoot.StartsWith(
        $root + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'Небезопасный путь теста защиты GitHub.'
}

try {
    [System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
    Copy-Item -LiteralPath $source -Destination $project -Recurse

    $mockSource = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Remaining)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$statePath = $env:PROEKTNAYA_OSNOVA_TEST_GH_STATE
$logPath = $env:PROEKTNAYA_OSNOVA_TEST_GH_LOG
$admin = $env:PROEKTNAYA_OSNOVA_TEST_GH_ADMIN
[System.IO.File]::AppendAllText(
    $logPath,
    (($Remaining | ConvertTo-Json -Compress) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)
if ($Remaining.Count -ge 2 -and $Remaining[0] -ceq 'auth' -and $Remaining[1] -ceq 'status') {
    return
}
if ($Remaining.Count -eq 0 -or $Remaining[0] -cne 'api') {
    throw 'Mock gh получил неизвестную команду.'
}
$endpoint = @($Remaining | Where-Object { $_ -match '^repos/' }) | Select-Object -First 1
if ($endpoint -ceq 'repos/example/project') {
    $isAdmin = $admin -cne 'false'
    Write-Output (@{
            default_branch = 'main'
            permissions = @{ admin = $isAdmin }
        } | ConvertTo-Json -Compress)
    return
}
if ($endpoint -match '^repos/example/project/rulesets\?') {
    if (Test-Path -LiteralPath $statePath) {
        Write-Output '[{"id":321,"name":"Проектная основа: единая версия","source_type":"Repository"}]'
    }
    else {
        Write-Output '[]'
    }
    return
}
$methodIndex = [Array]::IndexOf($Remaining, '--method')
$inputIndex = [Array]::IndexOf($Remaining, '--input')
if ($methodIndex -lt 0 -or $inputIndex -lt 0) {
    throw "Mock gh не распознал API-вызов: $($Remaining -join ' ')"
}
$method = $Remaining[$methodIndex + 1]
$inputPath = $Remaining[$inputIndex + 1]
[System.IO.File]::Copy($inputPath, "$statePath.payload", $true)
[System.IO.File]::WriteAllText($statePath, '321', [System.Text.UTF8Encoding]::new($false))
Write-Output (@{
        id = 321
        name = 'Проектная основа: единая версия'
        _links = @{ html = @{ href = 'https://github.example/rules/321' } }
        method = $method
    } | ConvertTo-Json -Compress -Depth 5)
'@
    [System.IO.File]::WriteAllText($mockGh, $mockSource, $utf8)

    $script = Join-Path $project 'scripts/configure-github-protection.ps1'
    $plan = & $script -Repository 'example/project'
    if ($plan.status -cne 'planned' -or $plan.payload.enforcement -cne 'active') {
        throw 'План настройки защиты GitHub не сформирован.'
    }
    $plannedTypes = @($plan.payload.rules | ForEach-Object type)
    foreach ($type in @('deletion', 'non_fast_forward', 'pull_request', 'required_status_checks')) {
        if ($plannedTypes -cnotcontains $type) { throw "В Ruleset отсутствует правило $type." }
    }

    $env:PROEKTNAYA_OSNOVA_TEST_GH_STATE = $statePath
    $env:PROEKTNAYA_OSNOVA_TEST_GH_LOG = $logPath
    $env:PROEKTNAYA_OSNOVA_TEST_GH_ADMIN = 'true'
    $created = & $script `
        -Repository 'example/project' -GhCommand $mockGh -Apply
    if ($created.status -cne 'configured' -or $created.action -cne 'created' -or $created.rulesetId -ne 321) {
        throw 'Первый запуск не создал Ruleset.'
    }

    $payload = [System.IO.File]::ReadAllText("$statePath.payload") | ConvertFrom-Json
    $statusRule = @($payload.rules | Where-Object type -eq 'required_status_checks')
    $pullRequestRule = @($payload.rules | Where-Object type -eq 'pull_request')
    $payloadInvalid = @(
        $payload.name -cne 'Проектная основа: единая версия'
        $payload.target -cne 'branch'
        $payload.enforcement -cne 'active'
        @($payload.bypass_actors).Count -ne 0
        @($payload.conditions.ref_name.include).Count -ne 1
        [string]$payload.conditions.ref_name.include[0] -cne 'refs/heads/main'
        $statusRule.Count -ne 1
        $statusRule[0].parameters.strict_required_status_checks_policy -ne $true
        [string]$statusRule[0].parameters.required_status_checks[0].context -cne 'Одна согласованная версия проекта'
        $pullRequestRule.Count -ne 1
        [int]$pullRequestRule[0].parameters.required_approving_review_count -ne 0
    ) -contains $true
    if ($payloadInvalid) { throw 'Созданный Ruleset не соответствует политике единой версии.' }

    $updated = & $script `
        -Repository 'example/project' -GhCommand $mockGh -Apply
    if ($updated.status -cne 'configured' -or $updated.action -cne 'updated' -or $updated.rulesetId -ne 321) {
        throw 'Повторный запуск не обновил существующий Ruleset.'
    }
    $log = [System.IO.File]::ReadAllText($logPath)
    if ($log -notmatch 'POST' -or $log -notmatch 'PUT') {
        throw 'Mock GitHub не получил создание и идемпотентное обновление Ruleset.'
    }

    $env:PROEKTNAYA_OSNOVA_TEST_GH_ADMIN = 'false'
    $pending = & $script `
        -Repository 'example/project' -GhCommand $mockGh -Apply -AllowPending
    if ($pending.status -cne 'pending' -or $pending.action -cne 'retry-required') {
        throw 'Недостаток административных прав не отражён как незавершённая защита.'
    }

    Assert-Throws {
        & $script -Repository 'example/project' -CanonicalBranch '../unsafe'
    } 'небезопасно' 'небезопасная каноническая ветка отклоняется'

    Write-Host 'Автоматическая настройка защиты GitHub прошла проверку.'
}
finally {
    $env:PROEKTNAYA_OSNOVA_TEST_GH_STATE = $previousState
    $env:PROEKTNAYA_OSNOVA_TEST_GH_LOG = $previousLog
    $env:PROEKTNAYA_OSNOVA_TEST_GH_ADMIN = $previousAdmin
    if (Test-Path -LiteralPath $testRoot) {
        if (-not $testRoot.StartsWith(
                $root + [System.IO.Path]::DirectorySeparatorChar,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            throw 'Небезопасное удаление папки теста защиты GitHub.'
        }
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
