[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,
    [string]$FromVersion,
    [string]$ProjectTitle,
    [string]$ProjectSlug,
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    [switch]$Apply,
    [switch]$ForceManagedFiles,
    [switch]$AllowDirty,
    [switch]$SkipLocalSyncInstallation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$projectRoot = [System.IO.Path]::GetFullPath($ProjectPath)
$manifestPath = Join-Path $sourceRoot 'migrations/manifest.json'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$dateToken = '{{' + 'DATE' + '}}'
$slugToken = '{{' + 'PROJECT_SLUG' + '}}'
$titleToken = '{{' + 'PROJECT_TITLE' + '}}'

function Get-IsoDate([string]$Value, [string]$Name) {
    [DateTime]$parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact(
            $Value,
            'yyyy-MM-dd',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$parsed
        )) {
        throw "$Name должен быть существующей календарной датой в формате ГГГГ-ММ-ДД."
    }
    return $parsed
}

function Get-SafePath([string]$Root, [string]$Relative, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [System.IO.Path]::IsPathRooted($Relative)) {
        throw "$Label содержит недопустимый путь: $Relative"
    }
    $normalized = $Relative.Replace('\', '/')
    if ($normalized -match '(^|/)\.\.(/|$)') { throw "$Label выходит за пределы проекта: $Relative" }
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $rootFull $Relative))
    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    if (-not $candidate.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, $comparison)) {
        throw "$Label выходит за пределы проекта: $Relative"
    }

    $current = $rootFull
    foreach ($segment in ($normalized -split '/')) {
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Label проходит через ссылку или точку повторного анализа: $Relative"
            }
        }
    }
    return $candidate
}

function Get-NormalizedText([string]$Text) {
    return (($Text -replace "`r`n", "`n") -replace "`r", "`n").TrimEnd() + "`n"
}

function Get-TextHash([string]$Text) {
    $bytes = $utf8.GetBytes((Get-NormalizedText $Text))
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-FileHashNormalized([string]$Path) {
    return Get-TextHash ([System.IO.File]::ReadAllText($Path))
}

function ConvertFrom-SimpleYamlScalar([string]$Value) {
    $trimmed = $Value.Trim()
    if ($trimmed.StartsWith('"')) {
        return [System.Text.Json.JsonSerializer]::Deserialize[string]($trimmed)
    }
    if ($trimmed.StartsWith("'") -and $trimmed.EndsWith("'")) {
        return $trimmed.Substring(1, $trimmed.Length - 2).Replace("''", "'")
    }
    return $trimmed
}

function Get-ProjectMetadata([string]$Root) {
    $readmePath = Join-Path $Root 'README.md'
    if (-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) {
        throw 'В обновляемом проекте отсутствует README.md.'
    }
    $text = [System.IO.File]::ReadAllText($readmePath)
    $titleMatch = [regex]::Match($text, '(?m)^title:\s*(?<value>.+?)\s*$')
    $createdMatch = [regex]::Match($text, '(?m)^created:\s*["'']?(?<value>\d{4}-\d{2}-\d{2})["'']?\s*$')
    if (-not $titleMatch.Success -or -not $createdMatch.Success) {
        throw 'README.md не содержит распознаваемые поля title и created.'
    }
    [void](Get-IsoDate $createdMatch.Groups['value'].Value 'README.md: created')

    $detectedSlug = $null
    $tagsMatch = [regex]::Match($text, '(?ms)^tags:\s*\n(?<value>(?:\s+-[^\n]*(?:\n|$))+?)^(?=\S|---)')
    if ($tagsMatch.Success) {
        foreach ($line in ($tagsMatch.Groups['value'].Value -split "`n")) {
            if ($line -notmatch '^\s+-\s*(?<value>.+?)\s*$') { continue }
            $candidate = (ConvertFrom-SimpleYamlScalar $Matches['value']).Trim()
            if ($candidate -and $candidate -notmatch '^(?:project|governance)/') {
                $detectedSlug = $candidate
                break
            }
        }
    }
    return [pscustomobject]@{
        Title = ConvertFrom-SimpleYamlScalar $titleMatch.Groups['value'].Value
        Created = $createdMatch.Groups['value'].Value
        Slug = $detectedSlug
    }
}

function Render-Template([string]$Text, [string]$Title, [string]$Slug, [string]$CreatedDate) {
    return $Text.Replace($titleToken, $Title).Replace($slugToken, $Slug).Replace($dateToken, $CreatedDate)
}

function Write-AtomicUtf8([string]$Path, [string]$Text) {
    $directory = Split-Path -Parent $Path
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($temporary, (Get-NormalizedText $Text), $utf8)
        [System.IO.File]::Move($temporary, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Assert-CleanGitProject([string]$Root) {
    if ($AllowDirty) { return }
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) { return }
    $top = @(& git -C $Root rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or $top.Count -eq 0) { return }
    $topFull = [System.IO.Path]::GetFullPath($top[0].Trim())
    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    if (-not $topFull.Equals($Root.TrimEnd([char[]]@('\', '/')), $comparison)) { return }
    $status = @(& git -C $Root status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось проверить состояние Git обновляемого проекта.' }
    if ($status.Count -gt 0) {
        throw 'Обновляемый Git-репозиторий содержит незакоммиченные изменения. Зафиксируйте их или явно укажите -AllowDirty.'
    }
}

if (-not (Test-Path -LiteralPath $projectRoot -PathType Container)) {
    throw "ProjectPath не существует или не является папкой: $ProjectPath"
}
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Не найден манифест миграций: $manifestPath"
}
[void](Get-IsoDate $Date 'Date')

$manifest = [System.IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1) { throw 'Поддерживается только schemaVersion = 1 манифеста миграций.' }
$targetVersion = [string]$manifest.targetVersion
$baselinePath = Get-SafePath $sourceRoot ([string]$manifest.baselineFile) 'baselineFile'
$baselines = [System.IO.File]::ReadAllText($baselinePath) | ConvertFrom-Json
if ($baselines.schemaVersion -ne 1 -or $baselines.hashAlgorithm -ne 'SHA256-normalized-text-v1') {
    throw 'Файл исторических SHA-256 имеет неподдерживаемый формат.'
}

$versionPath = Join-Path $projectRoot 'TEMPLATE-VERSION'
$detectedVersion = if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
    [System.IO.File]::ReadAllText($versionPath).Trim()
}
else { $null }
if (-not [string]::IsNullOrWhiteSpace($FromVersion) -and
    -not [string]::IsNullOrWhiteSpace($detectedVersion) -and
    $FromVersion -cne $detectedVersion) {
    throw "FromVersion ($FromVersion) не совпадает с TEMPLATE-VERSION ($detectedVersion)."
}
$currentVersion = if (-not [string]::IsNullOrWhiteSpace($detectedVersion)) { $detectedVersion } else { $FromVersion }
if ([string]::IsNullOrWhiteSpace($currentVersion)) {
    throw 'TEMPLATE-VERSION отсутствует. Укажите проверенную исходную версию через -FromVersion.'
}
if ($currentVersion -cne $targetVersion -and @($manifest.supportedFromVersions) -notcontains $currentVersion) {
    throw "Обновление с версии $currentVersion до $targetVersion не поддерживается."
}

$metadata = Get-ProjectMetadata $projectRoot
if ([string]::IsNullOrWhiteSpace($ProjectTitle)) { $ProjectTitle = $metadata.Title }
if ([string]::IsNullOrWhiteSpace($ProjectSlug)) { $ProjectSlug = $metadata.Slug }
if ([string]::IsNullOrWhiteSpace($ProjectTitle)) { throw 'Не удалось определить название проекта. Укажите -ProjectTitle.' }
if ([string]::IsNullOrWhiteSpace($ProjectSlug)) { throw 'Не удалось определить slug проекта. Укажите -ProjectSlug.' }
if ($ProjectSlug -notmatch '^[a-z0-9][a-z0-9-]*$') { throw 'ProjectSlug должен содержать только строчные латинские буквы, цифры и дефисы.' }

if ($currentVersion -ceq $targetVersion) {
    Write-Host "Проект уже использует шаблон $targetVersion. Изменения не требуются."
    if ($Apply) {
        & (Join-Path $projectRoot 'scripts/validate-registries.ps1') -ProjectPath $projectRoot
        & (Join-Path $projectRoot 'scripts/validate-vault.ps1')
        & (Join-Path $projectRoot 'scripts/build-project-dossier.ps1') -Check
    }
    return
}

$baselineProperty = $baselines.versions.PSObject.Properties[$currentVersion]
if ($null -eq $baselineProperty) { throw "Для версии $currentVersion отсутствуют исторические SHA-256." }
$baseline = $baselineProperty.Value
$plan = [System.Collections.Generic.List[object]]::new()
$changes = [System.Collections.Generic.List[object]]::new()
$conflicts = [System.Collections.Generic.List[object]]::new()

foreach ($relative in @($manifest.managedFiles)) {
    $source = Get-SafePath $sourceRoot $relative 'Управляемый исходный файл'
    $destination = Get-SafePath $projectRoot $relative 'Управляемый файл проекта'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "В выпуске отсутствует управляемый файл: $relative" }
    $sourceText = Render-Template ([System.IO.File]::ReadAllText($source)) $ProjectTitle $ProjectSlug $metadata.Created
    $sourceHash = Get-TextHash $sourceText
    if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        $entry = [pscustomobject]@{ Path = $relative; Action = 'add'; Reason = 'файл отсутствует'; Text = $sourceText }
        $plan.Add($entry); $changes.Add($entry)
        continue
    }
    $currentHash = Get-FileHashNormalized $destination
    if ($currentHash -ceq $sourceHash) {
        $plan.Add([pscustomobject]@{ Path = $relative; Action = 'skip'; Reason = 'уже актуален'; Text = $null })
        continue
    }
    $expectedProperty = $baseline.PSObject.Properties[$relative]
    $expectedHash = if ($null -ne $expectedProperty) { [string]$expectedProperty.Value } else { $null }
    if (-not [string]::IsNullOrWhiteSpace($expectedHash) -and $currentHash -ceq $expectedHash) {
        $entry = [pscustomobject]@{ Path = $relative; Action = 'replace'; Reason = "официальный файл $currentVersion"; Text = $sourceText }
        $plan.Add($entry); $changes.Add($entry)
    }
    elseif ($ForceManagedFiles) {
        $entry = [pscustomobject]@{ Path = $relative; Action = 'replace-forced'; Reason = 'явно разрешена замена изменённого файла'; Text = $sourceText }
        $plan.Add($entry); $changes.Add($entry)
    }
    else {
        $entry = [pscustomobject]@{ Path = $relative; Action = 'conflict'; Reason = 'файл отличается от выпуска и исторического SHA-256'; Text = $null }
        $plan.Add($entry); $conflicts.Add($entry)
    }
}

foreach ($relative in @($manifest.additiveFiles)) {
    $source = Get-SafePath $sourceRoot $relative 'Добавляемый исходный файл'
    $destination = Get-SafePath $projectRoot $relative 'Добавляемый файл проекта'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "В выпуске отсутствует добавляемый файл: $relative" }
    $sourceText = Render-Template ([System.IO.File]::ReadAllText($source)) $ProjectTitle $ProjectSlug $metadata.Created
    if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        $entry = [pscustomobject]@{ Path = $relative; Action = 'add'; Reason = 'новый файл'; Text = $sourceText }
        $plan.Add($entry); $changes.Add($entry)
    }
    elseif ((Get-FileHashNormalized $destination) -ceq (Get-TextHash $sourceText)) {
        $plan.Add([pscustomobject]@{ Path = $relative; Action = 'skip'; Reason = 'уже актуален'; Text = $null })
    }
    else {
        $plan.Add([pscustomobject]@{ Path = $relative; Action = 'preserve'; Reason = 'существующий пользовательский файл сохранён'; Text = $null })
    }
}

$gitignorePath = Get-SafePath $projectRoot '.gitignore' '.gitignore'
$gitignoreText = if (Test-Path -LiteralPath $gitignorePath -PathType Leaf) {
    [System.IO.File]::ReadAllText($gitignorePath)
}
else { '' }
$missingIgnoreLines = @(
    @('.project/', 'setup-ui/node_modules/', 'setup-ui/runtime/') |
        Where-Object { $gitignoreText -notmatch ('(?m)^' + [regex]::Escape($_) + '\s*$') }
)
if ($missingIgnoreLines.Count -gt 0) {
    $mergedIgnore = (Get-NormalizedText $gitignoreText).TrimEnd() + "`n" + ($missingIgnoreLines -join "`n") + "`n"
    $entry = [pscustomobject]@{ Path = '.gitignore'; Action = 'merge'; Reason = 'добавить локальные служебные папки в исключения'; Text = $mergedIgnore }
    $plan.Add($entry); $changes.Add($entry)
}
else {
    $plan.Add([pscustomobject]@{ Path = '.gitignore'; Action = 'skip'; Reason = 'локальные служебные папки уже исключены'; Text = $null })
}

$state = [ordered]@{
    schemaVersion = 1
    templateVersion = $targetVersion
    registrySchemaVersion = 1
    initializedAt = $metadata.Created
    lastUpdatedAt = $Date
    previousTemplateVersion = $currentVersion
}
$stateText = $state | ConvertTo-Json -Depth 5
foreach ($special in @(
        @{ Path = 'TEMPLATE-STATE.json'; Text = $stateText },
        @{ Path = 'TEMPLATE-VERSION'; Text = $targetVersion }
    )) {
    $destination = Get-SafePath $projectRoot $special.Path 'Служебный файл версии'
    $action = if (Test-Path -LiteralPath $destination -PathType Leaf) { 'replace' } else { 'add' }
    $entry = [pscustomobject]@{ Path = $special.Path; Action = $action; Reason = 'зафиксировать состояние обновления'; Text = $special.Text }
    $plan.Add($entry); $changes.Add($entry)
}
$projectFile = Get-SafePath $projectRoot 'PROJECT.md' 'Производная единая книга'
$projectEntry = [pscustomobject]@{ Path = 'PROJECT.md'; Action = 'regenerate'; Reason = 'пересобрать производное представление'; Text = $null }
$plan.Add($projectEntry); $changes.Add($projectEntry)

Write-Host "План обновления: $currentVersion -> $targetVersion"
foreach ($entry in $plan) {
    Write-Host ('[{0}] {1} — {2}' -f $entry.Action.ToUpperInvariant(), $entry.Path, $entry.Reason)
}
if ($conflicts.Count -gt 0) {
    throw "Найдены конфликты управляемых файлов: $($conflicts.Path -join ', '). Сравните их вручную или явно укажите -ForceManagedFiles."
}
if (-not $Apply) {
    Write-Host 'Это только план. Для применения повторите команду с -Apply.'
    return
}

Assert-CleanGitProject $projectRoot
$backupId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$backupRoot = Get-SafePath $projectRoot ".project/backups/$backupId" 'Папка резервной копии'
$backupFiles = Join-Path $backupRoot 'files'
[System.IO.Directory]::CreateDirectory($backupFiles) | Out-Null
$records = [System.Collections.Generic.List[object]]::new()
$reportPath = Join-Path $backupRoot 'update-report.json'
$result = 'running'
$failure = $null

try {
    foreach ($entry in $changes) {
        $destination = Get-SafePath $projectRoot $entry.Path 'Файл операции'
        $hadOriginal = Test-Path -LiteralPath $destination -PathType Leaf
        $backup = $null
        if ($hadOriginal) {
            $backup = Get-SafePath $backupFiles $entry.Path 'Резервная копия файла'
            [System.IO.Directory]::CreateDirectory((Split-Path -Parent $backup)) | Out-Null
            Copy-Item -LiteralPath $destination -Destination $backup -Force
        }
        $records.Add([pscustomobject]@{
                Path = $entry.Path
                Action = $entry.Action
                HadOriginal = $hadOriginal
                Backup = $backup
            })
    }

    foreach ($entry in $changes | Where-Object Action -ne 'regenerate') {
        $destination = Get-SafePath $projectRoot $entry.Path 'Файл операции'
        Write-AtomicUtf8 $destination ([string]$entry.Text)
    }

    & (Join-Path $projectRoot 'scripts/build-project-dossier.ps1')
    & (Join-Path $projectRoot 'scripts/validate-registries.ps1') -ProjectPath $projectRoot
    & (Join-Path $projectRoot 'scripts/validate-vault.ps1')
    & (Join-Path $projectRoot 'scripts/build-project-dossier.ps1') -Check
    $result = 'success'
}
catch {
    $failure = $_.Exception.Message
    for ($index = $records.Count - 1; $index -ge 0; $index--) {
        $record = $records[$index]
        $destination = Get-SafePath $projectRoot $record.Path 'Откат файла'
        if ($record.HadOriginal) {
            [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
            Copy-Item -LiteralPath $record.Backup -Destination $destination -Force
        }
        elseif (Test-Path -LiteralPath $destination -PathType Leaf) {
            Remove-Item -LiteralPath $destination -Force
        }
    }
    $result = 'rolled-back'
}
finally {
    $report = [ordered]@{
        schemaVersion = 1
        result = $result
        fromVersion = $currentVersion
        targetVersion = $targetVersion
        date = $Date
        backup = [System.IO.Path]::GetRelativePath($projectRoot, $backupRoot).Replace('\', '/')
        error = $failure
        operations = @($records | ForEach-Object {
                [ordered]@{ path = $_.Path; action = $_.Action; hadOriginal = $_.HadOriginal }
            })
    }
    [System.IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 8) + "`n", $utf8)
}

if ($result -ne 'success') {
    throw "Обновление отменено и применённые файлы восстановлены. Причина: $failure. Отчёт: $reportPath"
}
Write-Host "Обновление завершено: $currentVersion -> $targetVersion."
Write-Host "Резервная копия и отчёт: $backupRoot"
if (-not $SkipLocalSyncInstallation -and
    (Test-Path -LiteralPath (Join-Path $projectRoot 'scripts/install-local-sync.ps1') -PathType Leaf)) {
    try {
        $syncInstallationText = (& (Join-Path $projectRoot 'scripts/install-local-sync.ps1') `
            -ProjectPath $projectRoot -Apply -Json | Out-String).Trim()
        $syncInstallation = $syncInstallationText | ConvertFrom-Json
        if ([string]$syncInstallation.status -in @('installed', 'disabled')) {
            Write-Host ([string]$syncInstallation.message)
        }
        else {
            Write-Warning ([string]$syncInstallation.message)
        }
    }
    catch {
        Write-Warning "Проект обновлён, но локальную фоновую проверку нужно повторить: $($_.Exception.Message)"
    }
}
