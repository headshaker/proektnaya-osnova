[CmdletBinding()]
param(
    [string]$Title = 'Проверка "Альфа"',
    [string]$Slug = 'template-test',
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $root 'template'
$runId = [Guid]::NewGuid().ToString('N')
$test = [System.IO.Path]::GetFullPath((Join-Path $root ".tmp-template-test-$runId"))
$outside = [System.IO.Path]::GetFullPath((Join-Path $root ".tmp-template-outside-$runId.md"))

function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Description) {
    try {
        & $Action 2>&1 | Out-Null
    }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "Негативная проверка '$Description' завершилась неожиданной ошибкой: $($_.Exception.Message)"
        }
        Write-Host "Негативная проверка пройдена: $Description."
        return
    }
    throw "Негативная проверка не сработала: $Description."
}

if (-not $test.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Небезопасный путь тестовой папки.'
}

try {
    if (Test-Path -LiteralPath $test) {
        Remove-Item -LiteralPath $test -Recurse -Force
    }
    Copy-Item -LiteralPath $source -Destination $test -Recurse

    & (Join-Path $test 'scripts/init-project.ps1') -Title $Title -Slug $Slug -Date $Date
    & (Join-Path $test 'scripts/validate-vault.ps1')
    & (Join-Path $test 'scripts/build-project-dossier.ps1') --check

    $markers = Get-ChildItem -LiteralPath $test -Recurse -File |
        Select-String -Pattern '\{\{(PROJECT_TITLE|PROJECT_SLUG|DATE)\}\}'
    if ($markers) {
        throw 'После инициализации остались маркеры проекта.'
    }

    $obsoleteInstruction = Get-ChildItem -LiteralPath $test -Recurse -File -Filter '*.md' |
        Select-String -SimpleMatch 'starter-kit'
    if ($obsoleteInstruction) {
        throw 'В шаблоне осталась ссылка на несуществующую папку starter-kit.'
    }

    $projectPath = Join-Path $test 'PROJECT.md'
    $projectText = [System.IO.File]::ReadAllText($projectPath)
    if ($projectText -notmatch ('(?m)^created:\s*["'']' + [regex]::Escape($Date) + '["'']\s*$')) {
        throw 'Дата создания PROJECT.md не совпадает с датой инициализации.'
    }

    $init = Join-Path $test 'scripts/init-project.ps1'
    Assert-Throws {
        & $init -Title $Title -Slug $Slug -Date '2026-99-99'
    } 'календарной датой' 'несуществующая календарная дата отклоняется'

    $readmePath = Join-Path $test 'README.md'
    $readmeOriginal = [System.IO.File]::ReadAllText($readmePath)
    [System.IO.File]::WriteAllText($outside, 'Проверочный файл', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText(
        $readmePath,
        $readmeOriginal + "`n[Опасная ссылка](../$([System.IO.Path]::GetFileName($outside)))`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    Assert-Throws {
        & (Join-Path $test 'scripts/validate-vault.ps1')
    } 'ссылка выходит за пределы проекта' 'ссылка за пределы проекта отклоняется'
    [System.IO.File]::WriteAllText($readmePath, $readmeOriginal, [System.Text.UTF8Encoding]::new($false))

    $invalidYaml = [regex]::Replace(
        $readmeOriginal,
        '(?m)^title:.*$',
        'title: "Некорректное "название""',
        1
    )
    [System.IO.File]::WriteAllText($readmePath, $invalidYaml, [System.Text.UTF8Encoding]::new($false))
    Assert-Throws {
        & (Join-Path $test 'scripts/validate-vault.ps1')
    } 'некорректная строка YAML' 'повреждённая строка YAML отклоняется'
    [System.IO.File]::WriteAllText($readmePath, $readmeOriginal, [System.Text.UTF8Encoding]::new($false))

    $manifestPath = Join-Path $test 'scripts/project-dossier.manifest.json'
    $manifestOriginal = [System.IO.File]::ReadAllText($manifestPath)
    $manifest = $manifestOriginal | ConvertFrom-Json
    $manifest.parts[0].documents[0] = '../README.md'
    [System.IO.File]::WriteAllText(
        $manifestPath,
        ($manifest | ConvertTo-Json -Depth 10),
        [System.Text.UTF8Encoding]::new($false)
    )
    Assert-Throws {
        & (Join-Path $test 'scripts/build-project-dossier.ps1')
    } 'выходит за пределы проекта' 'источник манифеста за пределами проекта отклоняется'
    [System.IO.File]::WriteAllText($manifestPath, $manifestOriginal, [System.Text.UTF8Encoding]::new($false))

    $manifest = $manifestOriginal | ConvertFrom-Json
    $manifest.output = '../PROJECT-OUTSIDE.md'
    [System.IO.File]::WriteAllText(
        $manifestPath,
        ($manifest | ConvertTo-Json -Depth 10),
        [System.Text.UTF8Encoding]::new($false)
    )
    Assert-Throws {
        & (Join-Path $test 'scripts/build-project-dossier.ps1')
    } 'выходит за пределы проекта' 'выходной файл манифеста за пределами проекта отклоняется'
    [System.IO.File]::WriteAllText($manifestPath, $manifestOriginal, [System.Text.UTF8Encoding]::new($false))

    [System.IO.File]::WriteAllText(
        $readmePath,
        $readmeOriginal + "`n<!-- Проверка устаревшей сборки -->`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    Assert-Throws {
        & (Join-Path $test 'scripts/build-project-dossier.ps1') --check
    } 'устарел' 'изменение канонического файла делает PROJECT.md устаревшим'
    [System.IO.File]::WriteAllText($readmePath, $readmeOriginal, [System.Text.UTF8Encoding]::new($false))

    $sourcesPath = Join-Path $test 'SOURCES.md'
    $sourcesOriginal = [System.IO.File]::ReadAllText($sourcesPath)
    [System.IO.File]::WriteAllText(
        $sourcesPath,
        $sourcesOriginal + "`n| S-001 | Дубликат | Тест | Тест | $Date | $Date | Тест | Тест |`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    Assert-Throws {
        & (Join-Path $test 'scripts/validate-vault.ps1')
    } 'ID S-001 встречается более одного раза' 'дублирующийся ID источника отклоняется'
    [System.IO.File]::WriteAllText($sourcesPath, $sourcesOriginal, [System.Text.UTF8Encoding]::new($false))

    Write-Host 'Сквозная проверка шаблона пройдена.'
}
finally {
    if (Test-Path -LiteralPath $test) {
        if (-not $test.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar,
                [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Небезопасное удаление тестовой папки.'
        }
        Remove-Item -LiteralPath $test -Recurse -Force
    }
    if (Test-Path -LiteralPath $outside) {
        Remove-Item -LiteralPath $outside -Force
    }
}

& (Join-Path $PSScriptRoot 'test-daily-work.ps1') -Date '2026-07-15'
& (Join-Path $PSScriptRoot 'test-context.ps1') -Date '2026-07-15'
& (Join-Path $PSScriptRoot 'test-project-control.ps1')
& (Join-Path $PSScriptRoot 'test-human-first.ps1')
& (Join-Path $PSScriptRoot 'test-setup-wizard.ps1')
