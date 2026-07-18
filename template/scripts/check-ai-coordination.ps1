[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$BaseRef,
    [string]$HeadRef = 'HEAD',
    [string]$BranchName,
    [string]$ProjectPath = (Join-Path $PSScriptRoot '..')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath($ProjectPath)

function Invoke-Git([string[]]$Arguments) {
    $output = @(& git -C $script:root @Arguments)
    if ($LASTEXITCODE -ne 0) {
        throw "Git завершил операцию с кодом ${LASTEXITCODE}: git $($Arguments -join ' ')"
    }
    return $output
}

function Read-GitJson([string]$Commit, [string]$Path) {
    $text = @(Invoke-Git @('show', "${Commit}:$Path")) -join "`n"
    try { return $text | ConvertFrom-Json }
    catch { throw "$Path содержит некорректный JSON: $($_.Exception.Message)" }
}

function Test-ScopeMatch([string]$Path, [string]$Rule) {
    if ($Rule.EndsWith('/')) {
        return $Path.StartsWith($Rule, [System.StringComparison]::Ordinal)
    }
    return $Path.Equals($Rule, [System.StringComparison]::Ordinal)
}

$configPath = Join-Path $root 'AI-COORDINATION.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw 'Не найден AI-COORDINATION.json.' }
$config = [System.IO.File]::ReadAllText($configPath) | ConvertFrom-Json
if ([int]$config.schemaVersion -ne 1 -or [string]$config.integrationMode -cne 'serialized-fresh-base') {
    throw 'Неподдерживаемая конфигурация координации нейросетей.'
}

$baseCommit = (Invoke-Git @('rev-parse', '--verify', "${BaseRef}^{commit}") | Select-Object -First 1).Trim().ToLowerInvariant()
$headCommit = (Invoke-Git @('rev-parse', '--verify', "${HeadRef}^{commit}") | Select-Object -First 1).Trim().ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($BranchName)) {
    $BranchName = (Invoke-Git @('branch', '--show-current') | Select-Object -First 1).Trim()
}

$changed = @(Invoke-Git @('diff', '--name-only', '--diff-filter=ACMRTD', $baseCommit, $headCommit, '--') |
    ForEach-Object { $_.Trim().Replace('\', '/') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$manifestPrefix = ([string]$config.manifestDirectory).TrimEnd('/') + '/'
$stateFile = [string]$config.integrationStateFile
$coordinationTouched = @($changed | Where-Object { $_.StartsWith($manifestPrefix) -or $_ -ceq $stateFile }).Count -gt 0
$isAiBranch = @($config.aiBranchPrefixes | Where-Object { $BranchName.StartsWith([string]$_, [System.StringComparison]::Ordinal) }).Count -gt 0

if (-not $isAiBranch) {
    if ($coordinationTouched) { throw 'Служебные файлы координации нельзя изменять из обычной ветки.' }
    Write-Host "Ветка '$BranchName' не является веткой нейросети; специальная проверка не требуется."
    return
}
if ($BranchName -ceq [string]$config.canonicalBranch) { throw 'Нейросеть не должна работать непосредственно в канонической ветке.' }
if ($changed.Count -eq 0) { throw 'Запрос нейросети не содержит изменений.' }

& git -C $root merge-base --is-ancestor $baseCommit $headCommit
if ($LASTEXITCODE -ne 0) { throw 'Ветка не основана на проверяемой канонической редакции.' }

$manifestPaths = @($changed | Where-Object {
        $_ -match ('^' + [regex]::Escape($manifestPrefix) + '[a-z0-9][a-z0-9-]{5,79}\.json$')
    })
if ($manifestPaths.Count -ne 1) {
    throw "В одном запросе нейросети должен изменяться ровно один паспорт; найдено: $($manifestPaths.Count)."
}
if ($changed -cnotcontains $stateFile) { throw "$stateFile должен изменяться в каждом запросе нейросети." }

$manifestPath = $manifestPaths[0]
& git -C $root cat-file -e "${baseCommit}:$manifestPath" 2>$null
if ($LASTEXITCODE -eq 0) { throw 'changeId уже использовался в канонической истории; создайте новый паспорт.' }
$manifest = Read-GitJson $headCommit $manifestPath
$required = @('schemaVersion', 'changeId', 'agent', 'task', 'branch', 'baseCommit', 'integrationSequence', 'scope', 'startedAt', 'synchronizedAt', 'status')
foreach ($property in $required) {
    if ($manifest.PSObject.Properties.Name -cnotcontains $property) { throw "${manifestPath}: отсутствует свойство $property." }
}
if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.status -cne 'active') {
    throw "${manifestPath}: неподдерживаемая схема или состояние."
}
$expectedName = ([string]$manifest.changeId) + '.json'
if ([System.IO.Path]::GetFileName($manifestPath) -cne $expectedName) { throw 'Имя паспорта не совпадает с changeId.' }
if ([string]$manifest.branch -cne $BranchName) { throw "Паспорт относится к ветке '$($manifest.branch)', а проверяется '$BranchName'." }
if ([string]$manifest.baseCommit -cne $baseCommit) {
    throw "Исходная редакция устарела: паспорт указывает $($manifest.baseCommit), текущая основа — $baseCommit."
}
if ([string]::IsNullOrWhiteSpace([string]$manifest.agent) -or [string]::IsNullOrWhiteSpace([string]$manifest.task)) {
    throw 'В паспорте должны быть указаны исполнитель и задача.'
}
try {
    $startedAt = [DateTimeOffset]::Parse(
        [string]$manifest.startedAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $synchronizedAt = [DateTimeOffset]::Parse(
        [string]$manifest.synchronizedAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}
catch {
    throw 'В паспорте указаны некорректные даты запуска или синхронизации.'
}
if ($synchronizedAt -lt $startedAt) { throw 'Дата синхронизации не может предшествовать запуску работы.' }

$scope = @($manifest.scope)
if ($scope.Count -eq 0) { throw 'В паспорте не указана область изменения.' }
foreach ($ruleValue in $scope) {
    $rule = ([string]$ruleValue).Replace('\', '/').Trim()
    if ([string]::IsNullOrWhiteSpace($rule) -or $rule.StartsWith('/') -or $rule -match '^[A-Za-z]:' -or
        $rule -match '(^|/)\.\.(/|$)' -or $rule -match '[*?\[\]]' -or $rule -eq '.' -or
        $rule -eq '.git' -or $rule.StartsWith('.git/') -or $rule -eq '.ai-work' -or
        $rule.StartsWith('.ai-work/') -or $rule -eq $stateFile) {
        throw "Паспорт содержит небезопасную область: $ruleValue"
    }
}

$domainChanges = @($changed | Where-Object { $_ -cne $manifestPath -and $_ -cne $stateFile })
if ($domainChanges.Count -eq 0) { throw 'Запрос содержит только служебный паспорт, но не содержит результата задачи.' }
foreach ($path in $domainChanges) {
    $covered = @($scope | Where-Object { Test-ScopeMatch $path (([string]$_).Replace('\', '/').Trim()) }).Count -gt 0
    if (-not $covered) { throw "Файл '$path' выходит за заявленные границы задачи." }
}

$baseState = Read-GitJson $baseCommit $stateFile
$headState = Read-GitJson $headCommit $stateFile
$expectedSequence = [int]$baseState.sequence + 1
if ([int]$baseState.schemaVersion -ne 1 -or [int]$headState.schemaVersion -ne 1 -or
    [int]$headState.sequence -ne $expectedSequence -or
    [int]$manifest.integrationSequence -ne $expectedSequence -or
    [string]$headState.lastChangeId -cne [string]$manifest.changeId -or
    [string]$headState.lastBaseCommit -cne $baseCommit -or
    [string]$headState.lastAgent -cne [string]$manifest.agent -or
    [string]$headState.updatedAt -cne [string]$manifest.synchronizedAt) {
    throw "$stateFile не соответствует паспорту или следующему номеру интеграции $expectedSequence."
}

Write-Host "Координация проверена: $($manifest.changeId), основа $baseCommit, файлов результата — $($domainChanges.Count)."
