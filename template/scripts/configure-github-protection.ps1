[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Repository = '',
    [string]$CanonicalBranch = '',
    [string]$GhCommand = 'gh',
    [switch]$Apply,
    [switch]$AllowPending
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$configPath = Join-Path $root 'AI-COORDINATION.json'
$workflowPath = Join-Path $root '.github/workflows/ai-coordination.yml'
$reportPath = Join-Path $root '.project/github-protection.json'

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw 'Не найден AI-COORDINATION.json.'
}
if (-not (Test-Path -LiteralPath $workflowPath -PathType Leaf)) {
    throw 'Не найден workflow проверки координации нейросетей.'
}

$config = [System.IO.File]::ReadAllText($configPath) | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($CanonicalBranch)) {
    $CanonicalBranch = [string]$config.canonicalBranch
}
$protection = $config.githubProtection
if ($null -eq $protection) {
    throw 'AI-COORDINATION.json не содержит настройки githubProtection.'
}

$rulesetName = [string]$protection.rulesetName
$requiredCheck = [string]$protection.requiredStatusCheck
if ($CanonicalBranch -notmatch '^[A-Za-z0-9._/-]+$' -or
    $CanonicalBranch.StartsWith('/') -or $CanonicalBranch.EndsWith('/') -or
    $CanonicalBranch -match '(^|/)\.\.(/|$)') {
    throw 'Имя канонической ветки небезопасно.'
}
if ([string]::IsNullOrWhiteSpace($rulesetName) -or [string]::IsNullOrWhiteSpace($requiredCheck)) {
    throw 'Название Ruleset и обязательной проверки не должны быть пустыми.'
}

$payload = [ordered]@{
    name = $rulesetName
    target = 'branch'
    enforcement = 'active'
    bypass_actors = @()
    conditions = [ordered]@{
        ref_name = [ordered]@{
            include = @("refs/heads/$CanonicalBranch")
            exclude = @()
        }
    }
    rules = @(
        [ordered]@{ type = 'deletion' },
        [ordered]@{ type = 'non_fast_forward' },
        [ordered]@{
            type = 'pull_request'
            parameters = [ordered]@{
                allowed_merge_methods = @('squash', 'merge', 'rebase')
                dismiss_stale_reviews_on_push = $false
                require_code_owner_review = $false
                require_last_push_approval = $false
                required_approving_review_count = 0
                required_review_thread_resolution = $true
            }
        },
        [ordered]@{
            type = 'required_status_checks'
            parameters = [ordered]@{
                do_not_enforce_on_create = $true
                required_status_checks = @(
                    [ordered]@{ context = $requiredCheck }
                )
                strict_required_status_checks_policy = $true
            }
        }
    )
}

function Write-ProtectionReport([object]$Value) {
    $directory = Split-Path -Parent $reportPath
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    [System.IO.File]::WriteAllText(
        $reportPath,
        ($Value | ConvertTo-Json -Depth 12) + "`n",
        $utf8
    )
}

function New-ProtectionResult(
    [string]$Status,
    [string]$ReasonCode,
    [string]$Message,
    [string]$Action = '',
    [Nullable[int64]]$RulesetId = $null,
    [string]$RulesetUrl = ''
) {
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        status = $Status
        reasonCode = $ReasonCode
        message = $Message
        repository = $Repository
        canonicalBranch = $CanonicalBranch
        rulesetName = $rulesetName
        requiredStatusCheck = $requiredCheck
        action = $Action
        rulesetId = $RulesetId
        rulesetUrl = $RulesetUrl
    }
}

function Resolve-LocalGitHubRepository {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) { return '' }

    $top = (& $git.Source -C $root rev-parse --show-toplevel 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$top)) { return '' }
    $topFull = [System.IO.Path]::GetFullPath(([string]$top).Trim())
    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    if (-not $topFull.TrimEnd([char[]]@('/', '\')).Equals(
            $root.TrimEnd([char[]]@('/', '\')),
            $comparison
        )) {
        return ''
    }

    $remote = (& $git.Source -C $root remote get-url origin 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$remote)) { return '' }
    $remoteText = ([string]$remote).Trim()
    $patterns = @(
        '^https://github\.com/(?<value>[^/\s]+/[^/\s]+?)(?:\.git)?/?$',
        '^git@github\.com:(?<value>[^/\s]+/[^/\s]+?)(?:\.git)?$',
        '^ssh://git@github\.com/(?<value>[^/\s]+/[^/\s]+?)(?:\.git)?/?$'
    )
    foreach ($pattern in $patterns) {
        if ($remoteText -match $pattern) { return [string]$Matches['value'] }
    }
    return ''
}

function Invoke-Gh([string[]]$Arguments) {
    $command = Get-Command $GhCommand -ErrorAction SilentlyContinue
    if ($null -eq $command) { throw 'Не найден GitHub CLI (gh).' }
    $global:LASTEXITCODE = 0
    $output = @(& $command.Source @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { [string]$_ }) -join "`n"
    if ($exitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($text)) { $text = "код завершения $exitCode" }
        throw "GitHub CLI: $text"
    }
    return $text.Trim()
}

if (-not $Apply) {
    $planned = New-ProtectionResult `
        -Status 'planned' `
        -ReasonCode 'plan-only' `
        -Message 'Ruleset подготовлен, но GitHub не изменён.' `
        -Action 'plan'
    $planned | Add-Member -NotePropertyName payload -NotePropertyValue $payload
    return $planned
}

if ([string]::IsNullOrWhiteSpace($Repository)) {
    $Repository = Resolve-LocalGitHubRepository
}
if ([string]::IsNullOrWhiteSpace($Repository)) {
    $result = New-ProtectionResult `
        -Status 'not-applicable' `
        -ReasonCode 'no-github-repository' `
        -Message 'Корень проекта пока не является отдельным GitHub-репозиторием с origin.'
    Write-ProtectionReport $result
    if ($AllowPending) { return $result }
    throw $result.message
}
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw 'Репозиторий должен иметь формат owner/name.'
}

try {
    Invoke-Gh @('auth', 'status', '--hostname', 'github.com') | Out-Null

    $headers = @(
        '-H', 'Accept: application/vnd.github+json',
        '-H', 'X-GitHub-Api-Version: 2022-11-28'
    )
    $repositoryJson = Invoke-Gh (@('api') + $headers + @("repos/$Repository"))
    $repositoryInfo = $repositoryJson | ConvertFrom-Json
    if ($repositoryInfo.permissions.admin -ne $true) {
        throw 'Для автоматической защиты нужны административные права на репозиторий.'
    }
    $defaultBranch = [string]$repositoryInfo.default_branch
    if (-not [string]::IsNullOrWhiteSpace($defaultBranch) -and $defaultBranch -cne $CanonicalBranch) {
        throw "Каноническая ветка '$CanonicalBranch' не совпадает с основной веткой GitHub '$defaultBranch'."
    }

    $listJson = Invoke-Gh (@('api') + $headers + @(
            "repos/$Repository/rulesets?includes_parents=false&targets=branch"
        ))
    $rulesets = @($listJson | ConvertFrom-Json)
    $matches = @($rulesets | Where-Object {
            [string]$_.name -ceq $rulesetName -and [string]$_.source_type -ceq 'Repository'
        })
    if ($matches.Count -gt 1) {
        throw "Найдено несколько Ruleset с названием '$rulesetName'. Удалите дубликаты вручную."
    }

    $reportDirectory = Split-Path -Parent $reportPath
    [System.IO.Directory]::CreateDirectory($reportDirectory) | Out-Null
    $temporaryPayload = Join-Path $reportDirectory "github-ruleset-$PID.tmp.json"
    try {
        [System.IO.File]::WriteAllText(
            $temporaryPayload,
            ($payload | ConvertTo-Json -Depth 12) + "`n",
            $utf8
        )
        if ($matches.Count -eq 0) {
            $action = 'created'
            $responseJson = Invoke-Gh (@('api', '--method', 'POST') + $headers + @(
                    "repos/$Repository/rulesets", '--input', $temporaryPayload
                ))
        }
        else {
            $action = 'updated'
            $rulesetId = [int64]$matches[0].id
            $responseJson = Invoke-Gh (@('api', '--method', 'PUT') + $headers + @(
                    "repos/$Repository/rulesets/$rulesetId", '--input', $temporaryPayload
                ))
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPayload) {
            Remove-Item -LiteralPath $temporaryPayload -Force
        }
    }

    Write-Verbose "Ответ GitHub при настройке Ruleset: $responseJson"
    $response = $responseJson | ConvertFrom-Json
    $url = ''
    if ($null -ne $response._links -and $null -ne $response._links.html) {
        $url = [string]$response._links.html.href
    }
    $result = New-ProtectionResult `
        -Status 'configured' `
        -ReasonCode 'ruleset-active' `
        -Message 'Обязательная проверка и защита канонической ветки настроены.' `
        -Action $action `
        -RulesetId ([int64]$response.id) `
        -RulesetUrl $url
    Write-ProtectionReport $result
    Write-Host "GitHub: Ruleset '$rulesetName' $action для $Repository."
    return $result
}
catch {
    if (-not $AllowPending) { throw }
    $result = New-ProtectionResult `
        -Status 'pending' `
        -ReasonCode 'github-configuration-failed' `
        -Message $_.Exception.Message `
        -Action 'retry-required'
    Write-ProtectionReport $result
    Write-Warning "Защита GitHub пока не настроена: $($result.message)"
    return $result
}
