[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,
    [switch]$Apply,
    [switch]$SkipIngestion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$projectState = Join-Path $root '.project'
$processedRoot = Join-Path $projectState 'team-input/processed'
$attachmentsRoot = [System.IO.Path]::GetFullPath((Join-Path $root '_attachments'))
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Get-Optional([object]$Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Assert-IsoDate([string]$Value, [string]$Name) {
    [DateTime]$parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact(
            $Value,
            'yyyy-MM-dd',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$parsed
        )) {
        throw "$Name должен быть существующей датой ГГГГ-ММ-ДД."
    }
}

function Assert-Text([string]$Value, [string]$Name, [int]$Maximum = 1000) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Name не должен быть пустым." }
    if ($Value.Length -gt $Maximum) { throw "$Name не должен превышать $Maximum символов." }
    if ($Value -match '[\|\r\n\x00-\x08\x0B\x0C\x0E-\x1F]') {
        throw "$Name не должен содержать вертикальную черту, переносы строк или управляющие символы."
    }
}

function Test-PathInside([string]$Parent, [string]$Candidate) {
    $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd([char[]]@('\', '/'))
    $candidateFull = [System.IO.Path]::GetFullPath($Candidate)
    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    return $candidateFull.StartsWith(
        $parentFull + [System.IO.Path]::DirectorySeparatorChar,
        $comparison
    )
}

function Get-SafeAttachmentName([string]$Path) {
    $name = [System.IO.Path]::GetFileName($Path)
    if ([string]::IsNullOrWhiteSpace($name)) { throw "Не удалось определить имя вложения: $Path" }
    $safe = [regex]::Replace($name, '[^\p{L}\p{Nd}._-]+', '_').Trim('_', '.')
    if ([string]::IsNullOrWhiteSpace($safe)) { throw "Имя вложения не содержит безопасных символов: $name" }
    return $safe
}

function Get-UniqueDestination([string]$Directory, [string]$Name) {
    $candidate = Join-Path $Directory $Name
    if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $extension = [System.IO.Path]::GetExtension($Name)
    foreach ($number in 2..999) {
        $candidate = Join-Path $Directory ("{0}-{1}{2}" -f $base, $number, $extension)
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    throw "Не удалось подобрать уникальное имя для вложения: $Name"
}

function Add-TableRow([string]$Text, [string]$Heading, [string]$Row) {
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Text.Replace("`r`n", "`n") -split "`n")) { $lines.Add($line) }
    $headingIndex = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index].Trim() -ceq "## $Heading") { $headingIndex = $index; break }
    }
    if ($headingIndex -lt 0) { throw "Не найден раздел '## $Heading'." }
    $separatorIndex = -1
    for ($index = $headingIndex + 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^##\s+') { break }
        if ($lines[$index] -match '^\|\s*:?-{3,}') { $separatorIndex = $index; break }
    }
    if ($separatorIndex -lt 0) { throw "В разделе '$Heading' не найдена таблица." }
    $insertAt = $separatorIndex + 1
    while ($insertAt -lt $lines.Count -and $lines[$insertAt] -match '^\|') { $insertAt++ }
    $lines.Insert($insertAt, $Row)
    return ($lines -join "`n").TrimEnd() + "`n"
}

function Close-QuestionText(
    [string]$Text,
    [string]$QuestionId,
    [string]$Answer,
    [string]$AnswerDate,
    [string]$Related
) {
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Text.Replace("`r`n", "`n") -split "`n")) { $lines.Add($line) }
    $closedHeading = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index].Trim() -ceq '## Закрытые вопросы') { $closedHeading = $index; break }
    }
    if ($closedHeading -lt 0) { throw "Не найден раздел '## Закрытые вопросы'." }
    $escaped = [regex]::Escape($QuestionId)
    $matchingIndexes = @()
    for ($index = 0; $index -lt $closedHeading; $index++) {
        if ($lines[$index] -match "^\|\s*$escaped\s*\|") { $matchingIndexes += $index }
    }
    if ($matchingIndexes.Count -eq 0) { throw "Открытый вопрос $QuestionId не найден или уже закрыт." }
    if ($matchingIndexes.Count -gt 1) { throw "Открытый вопрос $QuestionId встречается более одного раза." }
    $lines.RemoveAt([int]$matchingIndexes[0])
    $withoutOpen = ($lines -join "`n").TrimEnd() + "`n"
    $anchor = $QuestionId.ToLowerInvariant()
    return Add-TableRow $withoutOpen 'Закрытые вопросы' `
        "| $QuestionId | $AnswerDate | <a id=`"$anchor`"></a>$Answer | $Related |"
}

function Set-UpdatedDate([string]$Text, [string]$Date) {
    $pattern = [regex]::new('(?m)^updated:\s*.*$')
    if (-not $pattern.IsMatch($Text)) { throw 'В реестре отсутствует свойство updated.' }
    return $pattern.Replace($Text, "updated: `"$Date`"", 1)
}

function Write-AtomicUtf8([string]$Path, [string]$Text) {
    $temporary = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($temporary, $Text, $utf8)
        [System.IO.File]::Move($temporary, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-RegistryLock([string]$Path) {
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        try {
            return [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        }
        catch [System.IO.IOException] { Start-Sleep -Milliseconds 100 }
    }
    throw 'Не удалось получить блокировку реестров за 5 секунд.'
}

$inputFull = [System.IO.Path]::GetFullPath($InputPath)
if (-not (Test-Path -LiteralPath $inputFull -PathType Leaf)) { throw "Не найден вход команды: $inputFull" }
$inputItem = Get-Item -LiteralPath $inputFull -Force
if (($inputItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Файл входа команды не должен быть ссылкой или точкой повторного анализа.'
}
if ($inputItem.Length -gt 1048576) { throw 'JSON входа команды не должен превышать 1 МБ.' }

try { $submission = [System.IO.File]::ReadAllText($inputFull) | ConvertFrom-Json -Depth 20 }
catch { throw "Некорректный JSON входа команды: $($_.Exception.Message)" }

if ([int](Get-Optional $submission 'schemaVersion' 0) -ne 1) { throw 'Поддерживается только schemaVersion = 1.' }
$submissionId = [string](Get-Optional $submission 'submissionId' '')
if ($submissionId -notmatch '^TI-[A-Za-z0-9][A-Za-z0-9._-]{2,63}$') {
    throw 'submissionId должен начинаться с TI- и содержать только буквы, цифры, точку, дефис или подчёркивание.'
}
$submittedAt = [string](Get-Optional $submission 'submittedAt' '')
Assert-IsoDate $submittedAt 'submittedAt'
$submittedBy = [string](Get-Optional $submission 'submittedBy' '')
Assert-Text $submittedBy 'submittedBy' 200
$channel = [string](Get-Optional $submission 'channel' 'other')
if ($channel -notin @('ai-chat', 'github-issue', 'meeting', 'email', 'other')) {
    throw 'channel должен быть ai-chat, github-issue, meeting, email или other.'
}

$answers = @((Get-Optional $submission 'answers' @()))
$sources = @((Get-Optional $submission 'sources' @()))
$attachments = @((Get-Optional $submission 'attachments' @()))
if ($answers.Count + $sources.Count + $attachments.Count -eq 0) {
    throw 'Вход команды не содержит ответов, источников или вложений.'
}

$configuration = [System.IO.File]::ReadAllText((Join-Path $root 'SOURCE-INGESTION.json')) | ConvertFrom-Json
$allowedExtensions = @($configuration.allowedExtensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
$maximumAttachmentBytes = [int64]$configuration.maxInputBytes
$inputDirectory = Split-Path -Parent $inputFull
$attachmentPlans = [System.Collections.Generic.List[object]]::new()

foreach ($attachment in $attachments) {
    $pathValue = [string](Get-Optional $attachment 'path' '')
    Assert-Text $pathValue 'attachments.path' 1000
    $sourcePath = if ([System.IO.Path]::IsPathRooted($pathValue)) {
        [System.IO.Path]::GetFullPath($pathValue)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $inputDirectory $pathValue))
    }
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Не найдено вложение: $sourcePath" }
    $item = Get-Item -LiteralPath $sourcePath -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Вложение не должно быть ссылкой или точкой повторного анализа: $sourcePath"
    }
    if ($item.Length -gt $maximumAttachmentBytes) {
        throw "Вложение превышает разрешённый размер $maximumAttachmentBytes байт: $sourcePath"
    }
    $extension = [System.IO.Path]::GetExtension($sourcePath).ToLowerInvariant()
    if ($allowedExtensions -notcontains $extension) { throw "Формат вложения не разрешён: $extension" }
    $description = [string](Get-Optional $attachment 'description' $item.Name)
    $evidence = [string](Get-Optional $attachment 'evidence' $description)
    $owner = [string](Get-Optional $attachment 'owner' $submittedBy)
    $documentDate = [string](Get-Optional $attachment 'documentDate' $submittedAt)
    $recheck = [string](Get-Optional $attachment 'recheck' 'При изменении файла')
    foreach ($pair in @{
            description = $description; evidence = $evidence; owner = $owner; recheck = $recheck
        }.GetEnumerator()) {
        Assert-Text ([string]$pair.Value) ("attachments." + $pair.Key) 1000
    }
    Assert-IsoDate $documentDate 'attachments.documentDate'
    $attachmentPlans.Add([pscustomobject]@{
            sourcePath = $sourcePath
            safeName = Get-SafeAttachmentName $sourcePath
            description = $description
            evidence = $evidence
            owner = $owner
            documentDate = $documentDate
            recheck = $recheck
        })
}

foreach ($source in $sources) {
    $location = [string](Get-Optional $source 'location' '')
    $publisher = [string](Get-Optional $source 'publisher' 'Не указан')
    $evidence = [string](Get-Optional $source 'evidence' 'Требует проверки ИИ')
    $scope = [string](Get-Optional $source 'scope' 'В пределах указанного материала')
    $verifiedAt = [string](Get-Optional $source 'verifiedAt' $submittedAt)
    $recheck = [string](Get-Optional $source 'recheck' 'При изменении подтверждаемого тезиса')
    foreach ($pair in @{
            location = $location; publisher = $publisher; evidence = $evidence; scope = $scope; recheck = $recheck
        }.GetEnumerator()) {
        Assert-Text ([string]$pair.Value) ("sources." + $pair.Key) 1000
    }
    [Uri]$uri = $null
    if (-not [Uri]::TryCreate($location, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https')) {
        throw "sources.location должен быть абсолютным HTTP(S)-адресом: $location"
    }
    Assert-IsoDate $verifiedAt 'sources.verifiedAt'
}

foreach ($answer in $answers) {
    $questionId = ([string](Get-Optional $answer 'questionId' '')).ToUpperInvariant()
    $answerText = [string](Get-Optional $answer 'answer' '')
    if ($questionId -notmatch '^Q-\d+$') { throw "Некорректный questionId: $questionId" }
    Assert-Text $answerText "answer $questionId" 1000
    foreach ($sourceId in @((Get-Optional $answer 'sourceIds' @()))) {
        if ([string]$sourceId -notmatch '^S-\d+$') { throw "Некорректная ссылка на источник: $sourceId" }
    }
}

Write-Host "План обработки $submissionId"
Write-Host "  Ответы на вопросы: $($answers.Count)"
Write-Host "  Ссылки-источники: $($sources.Count)"
Write-Host "  Вложения: $($attachments.Count)"
if (-not $Apply) {
    Write-Host 'Это только план. Для применения добавьте -Apply.'
    return
}

[System.IO.Directory]::CreateDirectory($projectState) | Out-Null
[System.IO.Directory]::CreateDirectory($processedRoot) | Out-Null
$inputBytes = [System.IO.File]::ReadAllBytes($inputFull)
$inputSha = [Convert]::ToHexString(
    [System.Security.Cryptography.SHA256]::HashData($inputBytes)
).ToLowerInvariant()
$reportPath = Join-Path $processedRoot "$submissionId.json"
if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
    $existingReport = [System.IO.File]::ReadAllText($reportPath) | ConvertFrom-Json
    if ([string]$existingReport.inputSha256 -cne $inputSha) {
        throw "Идентификатор $submissionId уже использован для другого содержимого. Создайте новый submissionId."
    }
    Write-Host "Вход $submissionId уже обработан; повторных изменений нет."
    return
}

$lockPath = Join-Path $projectState 'team-input.lock'
$lock = $null
$destinationRoot = [System.IO.Path]::GetFullPath((Join-Path $attachmentsRoot "team-input/$submissionId"))
if (-not (Test-PathInside $attachmentsRoot $destinationRoot)) { throw 'Небезопасный путь каталога вложений.' }
$sourceIds = [System.Collections.Generic.List[string]]::new()
$attachmentIds = [System.Collections.Generic.List[string]]::new()
$copiedAttachments = [System.Collections.Generic.List[string]]::new()
$backupPaths = @(
    (Join-Path $root 'SOURCES.md'),
    (Join-Path $root 'OPEN-QUESTIONS.md'),
    (Join-Path $root 'PROJECT.md'),
    (Join-Path $root 'STATUS.md')
)
$backups = @{}
foreach ($path in $backupPaths) { $backups[$path] = [System.IO.File]::ReadAllText($path) }

try {
    for ($attempt = 0; $attempt -lt 50 -and $null -eq $lock; $attempt++) {
        try {
            $lock = [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        }
        catch [System.IO.IOException] { Start-Sleep -Milliseconds 100 }
    }
    if ($null -eq $lock) { throw 'Не удалось получить блокировку входа команды за 5 секунд.' }

    $addEntry = Join-Path $PSScriptRoot 'add-entry.ps1'
    foreach ($source in $sources) {
        $output = @(& $addEntry source -Title ([string]$source.location) -Date $submittedAt `
            -SourceClass external -Publisher ([string](Get-Optional $source 'publisher' 'Не указан')) `
            -Evidence ([string](Get-Optional $source 'evidence' 'Требует проверки ИИ')) `
            -Scope ([string](Get-Optional $source 'scope' 'В пределах указанного материала')) `
            -Verified ([string](Get-Optional $source 'verifiedAt' $submittedAt)) `
            -Recheck ([string](Get-Optional $source 'recheck' 'При изменении подтверждаемого тезиса')) 6>&1)
        $match = [regex]::Match(($output | Out-String), 'S-\d+')
        if (-not $match.Success) { throw 'Добавление ссылки не вернуло ID источника.' }
        $sourceIds.Add($match.Value)
    }

    if ($attachmentPlans.Count -gt 0) { [System.IO.Directory]::CreateDirectory($destinationRoot) | Out-Null }
    foreach ($attachment in $attachmentPlans) {
        $destination = Get-UniqueDestination $destinationRoot ([string]$attachment.safeName)
        if (-not (Test-PathInside $attachmentsRoot $destination)) { throw 'Небезопасный путь назначения вложения.' }
        Copy-Item -LiteralPath $attachment.sourcePath -Destination $destination
        $copiedAttachments.Add($destination)
        $relative = [System.IO.Path]::GetRelativePath($root, $destination).Replace('\', '/')
        $output = @(& $addEntry source -Title $relative -Date $submittedAt `
            -SourceClass project -SourceType 'Вложение команды' `
            -Evidence ([string]$attachment.evidence) -DocumentDate ([string]$attachment.documentDate) `
            -Verified $submittedAt -Owner ([string]$attachment.owner) -Recheck ([string]$attachment.recheck) 6>&1)
        $match = [regex]::Match(($output | Out-String), 'S-\d+')
        if (-not $match.Success) { throw 'Добавление вложения не вернуло ID источника.' }
        $sourceIds.Add($match.Value)
        $attachmentIds.Add($match.Value)
    }

    $sourcesText = [System.IO.File]::ReadAllText((Join-Path $root 'SOURCES.md'))
    $questionsPath = Join-Path $root 'OPEN-QUESTIONS.md'
    $registryLock = Get-RegistryLock (Join-Path $projectState 'add-entry.lock')
    try {
        $questionsText = [System.IO.File]::ReadAllText($questionsPath)
        foreach ($answer in $answers) {
            $questionId = ([string]$answer.questionId).ToUpperInvariant()
            $references = [System.Collections.Generic.List[string]]::new()
            foreach ($sourceId in @((Get-Optional $answer 'sourceIds' @()))) {
                $normalizedId = ([string]$sourceId).ToUpperInvariant()
                if ($sourcesText -notmatch "(?m)^\|\s*$([regex]::Escape($normalizedId))\s*\|") {
                    throw "Источник $normalizedId для ответа $questionId не найден."
                }
                if (-not $references.Contains($normalizedId)) { $references.Add($normalizedId) }
            }
            $useSubmissionSources = [bool](Get-Optional $answer 'useSubmissionSources' $true)
            if ($useSubmissionSources) {
                foreach ($sourceId in $sourceIds) {
                    if (-not $references.Contains($sourceId)) { $references.Add($sourceId) }
                }
            }
            $related = if ($references.Count -gt 0) {
                $references -join ', '
            }
            else {
                "Прямой ответ команды: $submittedBy"
            }
            $questionsText = Close-QuestionText $questionsText $questionId ([string]$answer.answer) $submittedAt $related
        }
        if ($answers.Count -gt 0) {
            $questionsText = Set-UpdatedDate $questionsText $submittedAt
            Write-AtomicUtf8 $questionsPath $questionsText
        }
    }
    finally {
        $registryLock.Dispose()
    }

    if (-not $SkipIngestion -and $attachmentIds.Count -gt 0) {
        & (Join-Path $PSScriptRoot 'ingest-sources.ps1') -SourceId @($attachmentIds)
    }

    & (Join-Path $PSScriptRoot 'build-status.ps1')
    & (Join-Path $PSScriptRoot 'build-project-dossier.ps1')
    & (Join-Path $PSScriptRoot 'validate-vault.ps1')

    $report = [ordered]@{
        schemaVersion = 1
        submissionId = $submissionId
        status = 'processed'
        submittedAt = $submittedAt
        submittedBy = $submittedBy
        channel = $channel
        inputSha256 = $inputSha
        questionIds = @($answers | ForEach-Object { ([string]$_.questionId).ToUpperInvariant() })
        sourceIds = @($sourceIds)
        attachmentPaths = @($copiedAttachments | ForEach-Object {
                [System.IO.Path]::GetRelativePath($root, $_).Replace('\', '/')
            })
        ingestion = if ($SkipIngestion) { 'skipped-explicitly' } else { 'completed' }
        processedAt = (Get-Date).ToUniversalTime().ToString('O')
    }
    [System.IO.File]::WriteAllText(
        $reportPath,
        ($report | ConvertTo-Json -Depth 8) + "`n",
        $utf8
    )
    Write-Host "Вход $submissionId обработан: вопросов — $($answers.Count), источников — $($sourceIds.Count), вложений — $($attachments.Count)."
    Write-Host "Отчёт: $([System.IO.Path]::GetRelativePath($root, $reportPath).Replace('\', '/'))"
}
catch {
    $failure = $_
    foreach ($path in $backups.Keys) {
        [System.IO.File]::WriteAllText($path, [string]$backups[$path], $utf8)
    }
    if (Test-Path -LiteralPath $destinationRoot) {
        if (-not (Test-PathInside $attachmentsRoot $destinationRoot)) { throw 'Небезопасный откат вложений.' }
        Remove-Item -LiteralPath $destinationRoot -Recurse -Force
    }
    foreach ($sourceId in $attachmentIds) {
        $cache = [System.IO.Path]::GetFullPath((Join-Path $projectState "sources/$sourceId"))
        if ((Test-PathInside $projectState $cache) -and (Test-Path -LiteralPath $cache)) {
            Remove-Item -LiteralPath $cache -Recurse -Force
        }
    }
    $failureLocation = if ($failure.InvocationInfo.ScriptLineNumber -gt 0) {
        " [$([System.IO.Path]::GetFileName($failure.InvocationInfo.ScriptName)):$($failure.InvocationInfo.ScriptLineNumber)]"
    }
    else { '' }
    throw "Обработка входа команды отменена; исходное состояние восстановлено.$failureLocation $($failure.Exception.Message)"
}
finally {
    if ($null -ne $lock) { $lock.Dispose() }
}
