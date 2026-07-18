[CmdletBinding()]
param([switch]$AllowPlaceholders)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$errors = [System.Collections.Generic.List[string]]::new()
$datePlaceholder = '{{' + 'DATE' + '}}'
$requiredFiles = @(
    'README.md', 'AGENTS.md', 'PROJECT-BRIEF.md', 'DECISIONS.md',
    'OPEN-QUESTIONS.md', 'SOURCES.md', 'GLOSSARY.md', 'HANDOFF.md',
    'CHANGELOG.md', 'OBSIDIAN.md', 'DAILY-WORK.md', 'MIGRATIONS.md',
    'WORK-PROFILES.md', 'CONTEXT-WORKFLOW.md', 'CONTEXT-PROFILES.json',
    'AI-COORDINATION.md', 'AI-COORDINATION.json', 'AI-INTEGRATION-STATE.json',
    'REGISTRY-SCHEMA.json', 'TEMPLATE-LICENSE', 'TEMPLATE-STATE.json',
    'TEMPLATE-VERSION', 'scripts/build-context.ps1', 'scripts/check-context-health.ps1',
    'scripts/start-ai-work.ps1', 'scripts/sync-ai-work.ps1', 'scripts/check-ai-coordination.ps1',
    '.github/workflows/ai-coordination.yml', '.ai-work/README.md'
)
$requiredProperties = @('title', 'aliases', 'type', 'status', 'created', 'updated', 'tags')

function Test-PathInsideRoot([string]$Root, [string]$Candidate) {
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
    $candidateFull = [System.IO.Path]::GetFullPath($Candidate)
    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    return $candidateFull.Equals($rootFull, $comparison) -or
        $candidateFull.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, $comparison)
}

function Test-IsoDate([string]$Value) {
    if ($AllowPlaceholders -and $Value -ceq $datePlaceholder) { return $true }
    [DateTime]$parsed = [DateTime]::MinValue
    return [DateTime]::TryParseExact(
        $Value,
        'yyyy-MM-dd',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$parsed
    )
}

foreach ($file in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $file) -PathType Leaf)) {
        $errors.Add("Отсутствует обязательный файл: $file")
    }
}

$templateVersionPath = Join-Path $root 'TEMPLATE-VERSION'
$templateVersion = $null
if (Test-Path -LiteralPath $templateVersionPath -PathType Leaf) {
    $templateVersion = [System.IO.File]::ReadAllText($templateVersionPath).Trim()
    if ($templateVersion -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
        $errors.Add('TEMPLATE-VERSION: некорректная семантическая версия')
    }
}

$templateStatePath = Join-Path $root 'TEMPLATE-STATE.json'
if (Test-Path -LiteralPath $templateStatePath -PathType Leaf) {
    try {
        $templateState = [System.IO.File]::ReadAllText($templateStatePath) | ConvertFrom-Json
        if ($templateState.schemaVersion -ne 1) { $errors.Add('TEMPLATE-STATE.json: поддерживается только schemaVersion = 1') }
        if ($templateState.templateVersion -cne $templateVersion) {
            $errors.Add('TEMPLATE-STATE.json: templateVersion не совпадает с TEMPLATE-VERSION')
        }
        if ($templateState.registrySchemaVersion -ne 1) {
            $errors.Add('TEMPLATE-STATE.json: поддерживается только registrySchemaVersion = 1')
        }
        foreach ($property in @('initializedAt', 'lastUpdatedAt')) {
            if (-not (Test-IsoDate ([string]$templateState.$property))) {
                $errors.Add("TEMPLATE-STATE.json: $property должен быть календарной датой ГГГГ-ММ-ДД")
            }
        }
    }
    catch {
        $errors.Add("TEMPLATE-STATE.json: некорректный JSON или структура — $($_.Exception.Message)")
    }
}

$aiCoordinationPath = Join-Path $root 'AI-COORDINATION.json'
if (Test-Path -LiteralPath $aiCoordinationPath -PathType Leaf) {
    try {
        $aiCoordination = [System.IO.File]::ReadAllText($aiCoordinationPath) | ConvertFrom-Json
        if ([int]$aiCoordination.schemaVersion -ne 1 -or
            [string]$aiCoordination.canonicalBranch -cne 'main' -or
            [string]$aiCoordination.integrationMode -cne 'serialized-fresh-base' -or
            [string]$aiCoordination.manifestDirectory -cne '.ai-work/changes' -or
            [string]$aiCoordination.integrationStateFile -cne 'AI-INTEGRATION-STATE.json') {
            $errors.Add('AI-COORDINATION.json: неподдерживаемая схема координации')
        }
        $prefixes = @($aiCoordination.aiBranchPrefixes)
        if ($prefixes.Count -eq 0 -or @($prefixes | Group-Object -CaseSensitive | Where-Object Count -gt 1).Count -gt 0 -or
            @($prefixes | Where-Object { [string]$_ -notmatch '^[a-z][a-z0-9-]*/$' }).Count -gt 0) {
            $errors.Add('AI-COORDINATION.json: префиксы веток должны быть уникальными безопасными каталогами')
        }
        foreach ($property in @('requireSeparateWorkspace', 'requireDeclaredScope', 'requireFreshCanonicalBase', 'requireDraftPullRequest')) {
            if ($aiCoordination.$property -ne $true) { $errors.Add("AI-COORDINATION.json: $property должен быть включён") }
        }
    }
    catch {
        $errors.Add("AI-COORDINATION.json: некорректный JSON или структура — $($_.Exception.Message)")
    }
}

$aiIntegrationStatePath = Join-Path $root 'AI-INTEGRATION-STATE.json'
if (Test-Path -LiteralPath $aiIntegrationStatePath -PathType Leaf) {
    try {
        $aiIntegrationState = [System.IO.File]::ReadAllText($aiIntegrationStatePath) | ConvertFrom-Json
        if ([int]$aiIntegrationState.schemaVersion -ne 1 -or [int]$aiIntegrationState.sequence -lt 0) {
            $errors.Add('AI-INTEGRATION-STATE.json: неподдерживаемая схема или отрицательная последовательность')
        }
        if (-not (Test-IsoDate ([string]$aiIntegrationState.updatedAt).Substring(0, [Math]::Min(10, ([string]$aiIntegrationState.updatedAt).Length)))) {
            $errors.Add('AI-INTEGRATION-STATE.json: updatedAt должен начинаться с даты ГГГГ-ММ-ДД')
        }
        if ([int]$aiIntegrationState.sequence -eq 0 -and
            ($null -ne $aiIntegrationState.lastChangeId -or $null -ne $aiIntegrationState.lastBaseCommit -or $null -ne $aiIntegrationState.lastAgent)) {
            $errors.Add('AI-INTEGRATION-STATE.json: начальное состояние не должно ссылаться на изменение')
        }
    }
    catch {
        $errors.Add("AI-INTEGRATION-STATE.json: некорректный JSON или структура — $($_.Exception.Message)")
    }
}

$contextProfilesPath = Join-Path $root 'CONTEXT-PROFILES.json'
if (Test-Path -LiteralPath $contextProfilesPath -PathType Leaf) {
    try {
        $contextProfiles = [System.IO.File]::ReadAllText($contextProfilesPath) | ConvertFrom-Json
        if ($contextProfiles.schemaVersion -ne 1) {
            $errors.Add('CONTEXT-PROFILES.json: поддерживается только schemaVersion = 1')
        }
        $policy = $contextProfiles.healthPolicy
        if ([int]$policy.warningUtilizationPercent -lt 1 -or
            [int]$policy.criticalUtilizationPercent -gt 100 -or
            [int]$policy.warningUtilizationPercent -ge [int]$policy.criticalUtilizationPercent -or
            [int]$policy.minimumCompletenessScore -lt 1 -or
            [int]$policy.minimumCompletenessScore -gt 100 -or
            [int]$policy.maxHandoffAgeDays -lt 0 -or
            [int]$policy.maxStatusAgeDays -lt 0 -or
            [int]$policy.warningUtilizationIncreasePoints -lt 1) {
            $errors.Add('CONTEXT-PROFILES.json: некорректная политика здоровья контекста')
        }
        $profileNames = @($contextProfiles.profiles | ForEach-Object name)
        if ([string]::IsNullOrWhiteSpace([string]$contextProfiles.defaultProfile) -or
            $profileNames -cnotcontains [string]$contextProfiles.defaultProfile) {
            $errors.Add('CONTEXT-PROFILES.json: defaultProfile не найден среди profiles')
        }
        $duplicates = @($profileNames | Group-Object -CaseSensitive | Where-Object Count -gt 1)
        if ($duplicates.Count -gt 0) { $errors.Add('CONTEXT-PROFILES.json: имена профилей должны быть уникальны') }
        foreach ($profile in @($contextProfiles.profiles)) {
            if ([string]::IsNullOrWhiteSpace([string]$profile.name) -or
                [int]$profile.tokenBudget -lt 512 -or [int]$profile.reserveTokens -lt 0 -or
                [int]$profile.reserveTokens -ge [int]$profile.tokenBudget) {
                $errors.Add("CONTEXT-PROFILES.json: профиль '$($profile.name)' содержит некорректный бюджет")
            }
            foreach ($document in @($profile.documents)) {
                try {
                    $full = [System.IO.Path]::GetFullPath((Join-Path $root ([string]$document)))
                    if (-not (Test-PathInsideRoot $root $full) -or
                        -not (Test-Path -LiteralPath $full -PathType Leaf)) {
                        $errors.Add("CONTEXT-PROFILES.json: документ профиля отсутствует или выходит за пределы проекта -> $document")
                    }
                }
                catch {
                    $errors.Add("CONTEXT-PROFILES.json: некорректный путь документа -> $document")
                }
            }
        }
    }
    catch {
        $errors.Add("CONTEXT-PROFILES.json: некорректный JSON или структура — $($_.Exception.Message)")
    }
}

$markdown = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.md' |
    Where-Object {
        $_.Name -ne 'PROJECT.md' -and
        $_.FullName -notmatch '[\\/]_templates[\\/]' -and
        $_.FullName -notmatch '[\\/]\.project[\\/]'
    })
$incomingLinks = @{}
$outgoingLinks = @{}
foreach ($file in $markdown) {
    $relative = [System.IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
    $incomingLinks[$relative] = 0
    $outgoingLinks[$relative] = 0
}

foreach ($file in $markdown) {
    $relative = [System.IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
    $text = [System.IO.File]::ReadAllText($file.FullName)
    if (-not $AllowPlaceholders -and $text -match '\{\{(PROJECT_TITLE|PROJECT_SLUG|DATE)\}\}') {
        $errors.Add("${relative}: остались маркеры инициализации")
    }
    $lines = @(($text -replace "`r`n", "`n") -split "`n")
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') {
        $errors.Add("${relative}: отсутствует YAML-заголовок")
        continue
    }
    $end = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') { $end = $i; break }
    }
    if ($end -lt 0) { $errors.Add("${relative}: YAML-заголовок не закрыт"); continue }
    $fields = @{}
    for ($i = 1; $i -lt $end; $i++) {
        if ($lines[$i] -match '^([A-Za-z0-9_-]+):\s*(.*?)\s*$') {
            $field = $Matches[1]
            if ($fields.ContainsKey($field)) {
                $errors.Add("${relative}: свойство $field встречается более одного раза")
            }
            else {
                $fields[$field] = $Matches[2].Trim()
            }
        }
    }
    foreach ($property in $requiredProperties) {
        if (-not $fields.ContainsKey($property)) {
            $errors.Add("${relative}: отсутствует свойство $property")
        }
    }
    if ($fields.ContainsKey('title')) {
        $title = $fields['title']
        if ([string]::IsNullOrWhiteSpace($title)) {
            $errors.Add("${relative}: свойство title не должно быть пустым")
        }
        elseif ($title.StartsWith('"') -and
            $title -notmatch '^"(?:[^"\\]|\\["\\/bfnrt]|\\u[0-9A-Fa-f]{4})*"$') {
            $errors.Add("${relative}: некорректная строка YAML в свойстве title")
        }
        elseif ($title.StartsWith("'") -and $title -notmatch "^'(?:[^']|'')*'$") {
            $errors.Add("${relative}: некорректная строка YAML в свойстве title")
        }
    }
    foreach ($property in @('created', 'updated')) {
        if (-not $fields.ContainsKey($property)) { continue }
        $date = $fields[$property]
        if ($date.StartsWith('"')) {
            if ($date -notmatch '^"(?<value>[^"]*)"$') {
                $errors.Add("${relative}: некорректная строка YAML в свойстве $property")
                continue
            }
            $date = $Matches['value']
        }
        elseif ($date.StartsWith("'")) {
            if ($date -notmatch "^'(?<value>[^']*)'$") {
                $errors.Add("${relative}: некорректная строка YAML в свойстве $property")
                continue
            }
            $date = $Matches['value']
        }
        if (-not (Test-IsoDate $date)) {
            $errors.Add("${relative}: свойство $property должно быть календарной датой ГГГГ-ММ-ДД")
        }
    }
    foreach ($match in [regex]::Matches($text, '\[[^\]]+\]\((?<target>[^)]+)\)')) {
        $target = $match.Groups['target'].Value.Split('#')[0]
        if ([string]::IsNullOrWhiteSpace($target) -or $target -match '^(https?://|mailto:|#)') { continue }
        try {
            $decoded = [System.Uri]::UnescapeDataString($target)
            $full = [System.IO.Path]::GetFullPath((Join-Path $file.DirectoryName $decoded))
            if (-not (Test-PathInsideRoot $root $full)) {
                $errors.Add("${relative}: ссылка выходит за пределы проекта -> $target")
            }
            elseif (-not (Test-Path -LiteralPath $full)) {
                $errors.Add("${relative}: битая ссылка -> $target")
            }
            elseif ((Test-Path -LiteralPath $full -PathType Leaf) -and
                [System.IO.Path]::GetExtension($full) -ieq '.md') {
                $targetRelative = [System.IO.Path]::GetRelativePath($root, $full).Replace('\', '/')
                if ($targetRelative -cne $relative -and $incomingLinks.ContainsKey($targetRelative)) {
                    $outgoingLinks[$relative]++
                    $incomingLinks[$targetRelative]++
                }
            }
        }
        catch {
            $errors.Add("${relative}: некорректная ссылка -> $target")
        }
    }
}

foreach ($relative in $outgoingLinks.Keys | Sort-Object) {
    if ($relative -notmatch '^(?:docs|_inbox)/') { continue }
    if ($outgoingLinks[$relative] -eq 0) {
        $errors.Add("${relative}: у новой заметки нет исходящей локальной ссылки")
    }
    if ($incomingLinks[$relative] -eq 0) {
        $errors.Add("${relative}: у новой заметки нет входящей локальной ссылки")
    }
}

foreach ($entry in @(
    @{ File = 'DECISIONS.md'; Pattern = '^\|\s*(?<id>[DA]-\d+)\s*\|' },
    @{ File = 'OPEN-QUESTIONS.md'; Pattern = '^\|\s*(?<id>Q-\d+)\s*\|' },
    @{ File = 'SOURCES.md'; Pattern = '^\|\s*(?<id>S-\d+)\s*\|' }
)) {
    $seen = @{}
    $path = Join-Path $root $entry.File
    if (-not (Test-Path -LiteralPath $path)) { continue }
    foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -match $entry.Pattern) {
            $id = $Matches['id']
            if ($seen.ContainsKey($id)) { $errors.Add("$($entry.File): ID $id встречается более одного раза") }
            $seen[$id] = $true
        }
    }
}

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "Проверка не пройдена: ошибок — $($errors.Count). $($errors -join '; ')"
}
& (Join-Path $PSScriptRoot 'validate-registries.ps1') -ProjectPath $root
Write-Host "Проверка пройдена: файлов — $($markdown.Count), ошибок нет."
