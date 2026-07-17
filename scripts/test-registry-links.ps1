[CmdletBinding()]
param([string]$Date = '2026-07-16')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $root 'template'
$runId = [Guid]::NewGuid().ToString('N')
$test = [System.IO.Path]::GetFullPath((Join-Path $root ".tmp-registry-links-test-$runId"))
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Assert-Contains([string]$Path, [string]$Pattern, [string]$Description) {
    $text = [System.IO.File]::ReadAllText($Path)
    if ($text -notmatch $Pattern) { throw "Не выполнена проверка: $Description." }
}

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

if (-not $test.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Небезопасный путь тестовой папки ссылок реестров.'
}

try {
    Copy-Item -LiteralPath $source -Destination $test -Recurse
    & (Join-Path $test 'scripts/init-project.ps1') -Title 'Проверка ссылок реестров' -Slug 'registry-links-test' -Date $Date

    $linker = Join-Path $test 'scripts/link-registry-references.py'
    & python $linker --check
    if ($LASTEXITCODE -ne 0) { throw 'Исходный шаблон содержит несформированные ссылки реестров.' }

    $addEntry = Join-Path $test 'scripts/add-entry.ps1'
    & $addEntry decision -Title 'Проверить новую запись' -Date $Date `
        -Context 'Проверка точного якоря' -Consequences 'Ссылка ведёт к строке' `
        -Basis 'Автоматический тест' -Review 'При изменении формата'
    $addControl = Join-Path $test 'scripts/add-control.ps1'
    & $addControl benefit -Title 'Проверить получение эффекта' -Date $Date `
        -Owner 'Владелец выгоды' -Metric 'Время цикла' -Baseline '10 дней' `
        -Target '5 дней' -ReviewDate '2026-12-31'
    & $addControl risk -Title 'Проверить управляющую запись' -Date $Date `
        -Owner 'Владелец риска' -Cause 'Неопределённость' -Effect 'Задержка' -Due '2026-12-31'

    $handoffPath = Join-Path $test 'HANDOFF.md'
    $handoff = [System.IO.File]::ReadAllText($handoffPath)
    $handoff += @'

## Проверка ссылок реестров

Решение D-001 связано с вопросом Q-001, допущением `A-001` и источником S-001.
Выгода B-001 зависит от ответа на риск R-001.
Новое решение D-002 также должно стать интерактивным. Несуществующий ID D-999 остаётся обычным текстом.

    pwsh ./scripts/build-context.ps1 -Profile compact -IncludeId D-001,Q-001 -Check
'@
    [System.IO.File]::WriteAllText($handoffPath, $handoff.TrimEnd() + "`n", $utf8)

    Assert-Throws {
        & python $linker --check
        if ($LASTEXITCODE -ne 0) { throw 'требуют обновления' }
    } 'требуют обновления' 'обычные упоминания известных ID обнаруживаются'

    & python $linker --write
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось сформировать интерактивные ссылки реестров.' }
    & python $linker --check
    if ($LASTEXITCODE -ne 0) { throw 'После преобразования остались несформированные ссылки реестров.' }

    Assert-Contains (Join-Path $test 'DECISIONS.md') '\| D-001 \| <a id="d-001"></a>' 'решение D-001 имеет точный якорь'
    Assert-Contains (Join-Path $test 'DECISIONS.md') '\| D-002 \| <a id="d-002"></a>' 'новое решение D-002 получило точный якорь'
    Assert-Contains (Join-Path $test 'OPEN-QUESTIONS.md') '\| Q-001 \| <a id="q-001"></a>' 'вопрос Q-001 имеет точный якорь'
    Assert-Contains (Join-Path $test 'SOURCES.md') '\| S-001 \| <a id="s-001"></a>' 'источник S-001 имеет точный якорь'
    Assert-Contains (Join-Path $test 'OUTCOMES.md') '\| B-001 \| <a id="b-001"></a>' 'выгода B-001 имеет точный якорь'
    Assert-Contains (Join-Path $test 'CONTROLS.md') '\| R-001 \| <a id="r-001"></a>Риск \|' 'риск R-001 имеет точный якорь'
    Assert-Contains $handoffPath '\[D-001\]\(\./DECISIONS\.md#d-001\)' 'ссылка на решение ведёт к точной записи'
    Assert-Contains $handoffPath '\[Q-001\]\(\./OPEN-QUESTIONS\.md#q-001\)' 'ссылка на вопрос ведёт к точной записи'
    Assert-Contains $handoffPath '\[`A-001`\]\(\./DECISIONS\.md#a-001\)' 'кодовое упоминание допущения стало ссылкой'
    Assert-Contains $handoffPath '\[S-001\]\(\./SOURCES\.md#s-001\)' 'ссылка на источник ведёт к точной записи'
    Assert-Contains $handoffPath '\[B-001\]\(\./OUTCOMES\.md#b-001\)' 'ссылка на выгоду ведёт к точной записи'
    Assert-Contains $handoffPath '\[R-001\]\(\./CONTROLS\.md#r-001\)' 'ссылка на риск ведёт к точной записи'
    Assert-Contains $handoffPath 'ID D-999 остаётся обычным текстом' 'несуществующий ID не превращается в ложную ссылку'
    Assert-Contains $handoffPath '(?m)^    pwsh ./scripts/build-context\.ps1 -Profile compact -IncludeId D-001,Q-001 -Check$' 'команда в блоке кода не изменена'

    & (Join-Path $test 'scripts/validate-registries.ps1')
    & (Join-Path $test 'scripts/validate-vault.ps1')
    Write-Host 'Проверка интерактивных ссылок реестров пройдена.'
}
finally {
    if (Test-Path -LiteralPath $test) {
        if (-not $test.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Небезопасное удаление тестовой папки ссылок реестров.'
        }
        Remove-Item -LiteralPath $test -Recurse -Force
    }
}
