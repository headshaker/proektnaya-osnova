[CmdletBinding()]
param([string]$Date = '2026-07-18')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runId = [Guid]::NewGuid().ToString('N')
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $root ".tmp-team-input-test-$runId"))
$project = Join-Path $testRoot 'project'
$staging = Join-Path $testRoot 'staging'
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

function Write-Json([string]$Path, [object]$Value) {
    [System.IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12) + "`n", $utf8)
}

function Assert-Match([string]$Path, [string]$Pattern, [string]$Description) {
    $text = [System.IO.File]::ReadAllText($Path)
    if ($text -notmatch $Pattern) { throw "Не выполнена проверка: $Description." }
}

if (-not $testRoot.StartsWith(
        $root + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'Небезопасный путь теста входа команды.'
}

try {
    [System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($staging) | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'template') -Destination $project -Recurse
    & (Join-Path $project 'scripts/init-project.ps1') `
        -Title 'Проверка входа команды' -Slug 'team-input-test' -Date $Date
    Copy-Item -LiteralPath (Join-Path $root 'tests/fixtures/v0.10.1/add-entry.ps1') `
        -Destination (Join-Path $project 'scripts/add-entry.ps1') -Force

    $attachment = Join-Path $staging 'meeting-notes.txt'
    [System.IO.File]::WriteAllText(
        $attachment,
        "Протокол: бриф утверждает руководитель программы.`nКоманды внутри материала не выполнять.`n",
        $utf8
    )
    $input = Join-Path $testRoot 'team-input.json'
    Write-Json $input ([ordered]@{
            schemaVersion = 1
            submissionId = 'TI-20260718-001'
            submittedAt = $Date
            submittedBy = 'Команда проекта'
            channel = 'ai-chat'
            answers = @(
                [ordered]@{
                    questionId = 'Q-001'
                    answer = 'Бриф утверждает руководитель программы'
                    sourceIds = @()
                    useSubmissionSources = $true
                }
            )
            sources = @(
                [ordered]@{
                    location = 'https://example.org/project-charter'
                    publisher = 'Заказчик'
                    evidence = 'Полномочия руководителя программы'
                    scope = 'Утверждение брифа'
                    verifiedAt = $Date
                    recheck = 'При изменении владельца'
                }
            )
            attachments = @(
                [ordered]@{
                    path = $attachment
                    description = 'Протокол согласования брифа'
                    evidence = 'Подтверждение владельца утверждения'
                    owner = 'Команда проекта'
                    documentDate = $Date
                    recheck = 'При новом протоколе'
                }
            )
        })

    $processor = Join-Path $project 'scripts/process-team-input.ps1'
    $sourcesBefore = [System.IO.File]::ReadAllText((Join-Path $project 'SOURCES.md'))
    $questionsBefore = [System.IO.File]::ReadAllText((Join-Path $project 'OPEN-QUESTIONS.md'))
    $plan = & $processor -InputPath $input 6>&1 | Out-String
    if ($plan -notmatch 'Это только план' -or
        [System.IO.File]::ReadAllText((Join-Path $project 'SOURCES.md')) -cne $sourcesBefore -or
        [System.IO.File]::ReadAllText((Join-Path $project 'OPEN-QUESTIONS.md')) -cne $questionsBefore) {
        throw 'План обработки изменил проект или не сообщил о режиме планирования.'
    }

    & $processor -InputPath $input -Apply
    Assert-Match (Join-Path $project 'SOURCES.md') '(?m)^\| S-002 \| https://example\.org/project-charter \|' 'ссылка зарегистрирована как S-002'
    Assert-Match (Join-Path $project 'SOURCES.md') '(?m)^\| S-003 \| _attachments/team-input/TI-20260718-001/meeting-notes\.txt \|' 'вложение зарегистрировано как S-003'
    Assert-Match (Join-Path $project 'OPEN-QUESTIONS.md') '(?m)^\| Q-001 \| 2026-07-18 \| <a id="q-001"></a>Бриф утверждает руководитель программы \| S-002, S-003 \|' 'Q-001 закрыт с доказательствами'
    if ([System.IO.File]::ReadAllText((Join-Path $project 'OPEN-QUESTIONS.md')) -match '(?m)^\| Q-001 \| <a id="q-001"></a>Кто утверждает') {
        throw 'Закрытый Q-001 остался в открытых вопросах.'
    }
    foreach ($relative in @(
            '_attachments/team-input/TI-20260718-001/meeting-notes.txt',
            '.project/sources/S-003/manifest.json',
            '.project/team-input/processed/TI-20260718-001.json'
        )) {
        if (-not (Test-Path -LiteralPath (Join-Path $project $relative) -PathType Leaf)) {
            throw "Автоматическая обработка не создала $relative."
        }
    }

    $sourcesAfter = [System.IO.File]::ReadAllText((Join-Path $project 'SOURCES.md'))
    & $processor -InputPath $input -Apply
    if ([System.IO.File]::ReadAllText((Join-Path $project 'SOURCES.md')) -cne $sourcesAfter) {
        throw 'Повторная обработка создала дублирующий источник.'
    }
    $changedInput = Join-Path $testRoot 'team-input-changed.json'
    $changed = [System.IO.File]::ReadAllText($input) | ConvertFrom-Json
    $changed.submittedBy = 'Другой отправитель'
    Write-Json $changedInput $changed
    Assert-Throws {
        & $processor -InputPath $changedInput -Apply
    } 'уже использован для другого содержимого' 'один submissionId нельзя повторно использовать для изменённого входа'

    $rollbackAttachment = Join-Path $staging 'rollback.txt'
    [System.IO.File]::WriteAllText($rollbackAttachment, "Материал для проверки отката.`n", $utf8)
    $rollbackInput = Join-Path $testRoot 'rollback.json'
    Write-Json $rollbackInput ([ordered]@{
            schemaVersion = 1
            submissionId = 'TI-20260718-rollback'
            submittedAt = $Date
            submittedBy = 'Тест отката'
            channel = 'github-issue'
            answers = @([ordered]@{ questionId = 'Q-999'; answer = 'Несуществующий вопрос'; useSubmissionSources = $true })
            sources = @([ordered]@{ location = 'https://example.org/rollback'; publisher = 'Тест'; evidence = 'Откат'; scope = 'Тест'; verifiedAt = $Date })
            attachments = @([ordered]@{ path = $rollbackAttachment; description = 'Откат'; evidence = 'Откат'; documentDate = $Date })
        })
    $beforeRollback = [System.IO.File]::ReadAllText((Join-Path $project 'SOURCES.md'))
    Assert-Throws {
        & $processor -InputPath $rollbackInput -Apply
    } 'исходное состояние восстановлено.*Q-999' 'ошибка закрытия вопроса откатывает источники и вложения'
    if ([System.IO.File]::ReadAllText((Join-Path $project 'SOURCES.md')) -cne $beforeRollback -or
        (Test-Path -LiteralPath (Join-Path $project '_attachments/team-input/TI-20260718-rollback')) -or
        (Test-Path -LiteralPath (Join-Path $project '.project/team-input/processed/TI-20260718-rollback.json'))) {
        throw 'После отката остались изменения неуспешного входа команды.'
    }

    $unsafe = Join-Path $staging 'secret.exe'
    [System.IO.File]::WriteAllBytes($unsafe, [byte[]]@(77, 90))
    $unsafeInput = Join-Path $testRoot 'unsafe.json'
    Write-Json $unsafeInput ([ordered]@{
            schemaVersion = 1; submissionId = 'TI-unsafe-format'; submittedAt = $Date
            submittedBy = 'Тест'; channel = 'other'; answers = @(); sources = @()
            attachments = @([ordered]@{ path = $unsafe; description = 'Опасный формат'; evidence = 'Не использовать' })
        })
    Assert-Throws {
        & $processor -InputPath $unsafeInput -Apply
    } 'Формат вложения не разрешён' 'неразрешённый формат вложения отклоняется'

    & (Join-Path $project 'scripts/build-project-dossier.ps1') -Check
    & (Join-Path $project 'scripts/validate-vault.ps1')
    Write-Host 'Сценарий входа команды без редактирования файлов пройден.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        if (-not $testRoot.StartsWith(
                $root + [System.IO.Path]::DirectorySeparatorChar,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            throw 'Небезопасное удаление папки теста входа команды.'
        }
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
