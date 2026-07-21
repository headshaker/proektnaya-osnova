[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $root 'template'
$runId = [Guid]::NewGuid().ToString('N')
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $root ".tmp-migration-test-$runId"))
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

function Remove-SafePath([string]$Project, [string]$Relative) {
    $projectFull = [System.IO.Path]::GetFullPath($Project).TrimEnd([char[]]@('\', '/'))
    $path = [System.IO.Path]::GetFullPath((Join-Path $projectFull $Relative))
    if (-not $path.StartsWith(
            $projectFull + [System.IO.Path]::DirectorySeparatorChar,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Небезопасный путь тестового удаления: $Relative"
    }
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
}

function Copy-FixtureFile([string]$FixtureRoot, [string]$FixtureName, [string]$Project, [string]$Relative) {
    $sourcePath = Join-Path $FixtureRoot $FixtureName
    $destination = Join-Path $Project $Relative
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $destination -Force
}

function Set-StateVersion([string]$Project, [string]$Version) {
    $statePath = Join-Path $Project 'TEMPLATE-STATE.json'
    $state = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    $state.templateVersion = $Version
    $state.previousTemplateVersion = $null
    [System.IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 5) + "`n", $utf8)
}

function Replace-FixtureLines(
    [string]$Project,
    [string]$Relative,
    [string[]]$OldLines,
    [string[]]$NewLines = @()
) {
    $path = Join-Path $Project $Relative
    $text = [System.IO.File]::ReadAllText($path)
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $old = ($OldLines -join $newline) + $newline
    $new = if ($NewLines.Count -gt 0) { ($NewLines -join $newline) + $newline } else { '' }
    if (-not $text.Contains($old)) {
        throw "Не найден официальный фрагмент $Relative для тестовой исторической версии."
    }
    [System.IO.File]::WriteAllText($path, $text.Replace($old, $new), $utf8)
}

function Replace-FixtureRegex(
    [string]$Project,
    [string]$Relative,
    [string]$Pattern,
    [string]$Replacement = ''
) {
    $path = Join-Path $Project $Relative
    $text = [System.IO.File]::ReadAllText($path)
    $updated = [regex]::Replace($text, $Pattern, $Replacement)
    if ($updated -ceq $text) {
        throw "Не найден официальный фрагмент $Relative для тестовой исторической версии."
    }
    [System.IO.File]::WriteAllText($path, $updated, $utf8)
}

function Restore-Fixture0141([string]$Project) {
    $releaseCommit = ''
    foreach ($candidate in @(& git -C $root log --all --format=%H -- template/TEMPLATE-VERSION)) {
        $versionText = @(& git -C $root show "${candidate}:template/TEMPLATE-VERSION" 2>$null)
        if ($LASTEXITCODE -eq 0 -and ($versionText -join "`n").Trim() -ceq '0.14.1') {
            $releaseCommit = $candidate
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($releaseCommit)) {
        throw 'Не найдена официальная редакция 0.14.1 для прямой проверки миграции.'
    }

    foreach ($relative in @(
            'REGISTRY-SCHEMA.json',
            'migrations/baselines.json',
            'migrations/manifest.json',
            'scripts/install-local-sync.ps1',
            'scripts/sync-project.ps1',
            'scripts/validate-vault.ps1',
            'setup-ui/index.html',
            'setup-ui/main.js',
            'setup-ui/package-lock.json',
            'setup-ui/package.json',
            'setup-ui/preload.js',
            'setup-ui/renderer.js',
            'setup-ui/styles.css'
        )) {
        $content = @(& git -C $root show "${releaseCommit}:template/$relative" 2>$null)
        if ($LASTEXITCODE -ne 0) { throw "Не удалось восстановить официальный файл 0.14.1: $relative" }
        $destination = Join-Path $Project $relative
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        [System.IO.File]::WriteAllText($destination, ($content -join "`n").TrimEnd() + "`n", $utf8)
    }
    Remove-SafePath $Project 'scripts/run-local-sync-background.ps1'
}

function Restore-Fixture0140([string]$Project) {
    Restore-Fixture0141 $Project
    $launcher0132 = @'
@echo off
setlocal
cd /d "%~dp0"

where pwsh.exe >nul 2>nul
if errorlevel 1 goto missing_pwsh
if /i "%~1"=="--self-test" goto self_test

pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-project.ps1"
set "RESULT=%ERRORLEVEL%"
if "%RESULT%"=="0" exit /b 0

echo.
echo Project setup did not finish. See ADMIN-SETUP.md for help.
pause
exit /b %RESULT%

:self_test
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-project.ps1" -SelfTest
exit /b %ERRORLEVEL%

:missing_pwsh
echo PowerShell 7 is required to configure this project.
echo Install PowerShell 7 and run START-PROJECT.cmd again.
echo Details: ADMIN-SETUP.md
pause
exit /b 1
'@
    [System.IO.File]::WriteAllText(
        (Join-Path $Project 'START-PROJECT.cmd'),
        $launcher0132.TrimStart("`r", "`n") + "`n",
        $utf8
    )

    Replace-FixtureLines $Project 'scripts/configure-project-tools.ps1' @(
        'function Get-PlatformInstallHint([string]$Id) {',
        '    $hints = @{',
        "        chatgpt = 'Откройте официальную страницу OpenAI и выберите установку Codex для своей системы.'",
        "        claude = 'Откройте официальную страницу Anthropic и следуйте разделу установки Claude Code.'",
        "        gemini = 'Откройте официальную страницу Google и следуйте разделу установки Gemini CLI.'",
        "        qwen = 'Откройте официальную страницу Alibaba и следуйте разделу установки Qwen Code.'",
        "        deepseek = 'Откройте страницу стороннего клиента из каталога DeepSeek и сначала изучите условия и риски.'",
        "        grok = 'Откройте официальную страницу xAI и следуйте разделу установки Grok Build.'",
        '    }',
        '    return [string]$hints[$Id]',
        '}'
    ) @(
        'function Get-PlatformInstallHint([string]$Id) {',
        '    $windowsHints = @{',
        '        chatgpt = ''powershell -ExecutionPolicy ByPass -c "irm https://chatgpt.com/codex/install.ps1 | iex"''',
        '        claude = ''irm https://claude.ai/install.ps1 | iex''',
        '        gemini = ''npm install -g @google/gemini-cli''',
        '        qwen = ''npm install -g @qwen-code/qwen-code@latest''',
        '        deepseek = ''npm install -g deepseek-tui''',
        '        grok = ''irm https://x.ai/cli/install.ps1 | iex''',
        '    }',
        '    $unixHints = @{',
        '        chatgpt = ''curl -fsSL https://chatgpt.com/codex/install.sh | sh''',
        '        claude = ''curl -fsSL https://claude.ai/install.sh | bash''',
        '        gemini = ''npm install -g @google/gemini-cli''',
        '        qwen = ''curl -fsSL https://qwen-code-assets.oss-cn-hangzhou.aliyuncs.com/installation/install-qwen.sh | bash''',
        '        deepseek = ''npm install -g deepseek-tui''',
        '        grok = ''curl -fsSL https://x.ai/cli/install.sh | bash''',
        '    }',
        '    return [string]$(if ($IsWindows) { $windowsHints[$Id] } else { $unixHints[$Id] })',
        '}'
    )
    Replace-FixtureLines $Project 'scripts/configure-project-tools.ps1' @(
        'foreach ($item in $missing) {',
        '    $nextSteps.Add("Установите $($item.name) по официальной инструкции, затем повторите проверку в мастере.")',
        '}',
        'if ($obsidianSelected -and -not $obsidianInstalled) {',
        "    `$nextSteps.Add('Установите Obsidian с официального сайта, затем повторите проверку в мастере.')",
        '}'
    ) @(
        'foreach ($item in $missing) { $nextSteps.Add("$($item.name): $($item.installHint)") }',
        'if ($obsidianSelected -and -not $obsidianInstalled) { $nextSteps.Add($obsidian.installHint) }'
    )
    Replace-FixtureLines $Project 'scripts/configure-project-tools.ps1' @(
        "        Write-Host 'Осталось установить выбранные программы:'"
    ) @("        Write-Host 'Следующие ручные шаги:'")

    Replace-FixtureLines $Project 'scripts/setup-project.ps1' @(
        'foreach ($step in @($toolsResult.nextSteps)) { $unresolved.Add([string]$step) }'
    ) @('foreach ($step in @($toolsResult.nextSteps)) { $unresolved.Add("подключить инструмент: $step") }')
    Replace-FixtureLines $Project 'scripts/setup-project.ps1' @(
        "        Write-Host 'Защиту GitHub сможет завершить ИИ или технический специалист после входа администратора в GitHub.'"
    ) @(
        "        Write-Host 'После входа в gh с правами администратора выполните:'",
        "        Write-Host '  pwsh ./scripts/configure-github-protection.ps1 -Apply'"
    )

    Replace-FixtureLines $Project 'scripts/start-project.ps1' @(
        '    throw "Встроенный визуальный мастер завершился с кодом $result. Передайте ADMIN-SETUP.md техническому специалисту; запускать сценарии вручную не требуется."'
    ) @(
        '    Write-Warning "Встроенный визуальный мастер завершился с кодом $result."',
        '    Invoke-ConsoleWizard',
        '    return'
    )
    Replace-FixtureLines $Project 'scripts/start-project.ps1' @(
        "    throw 'Исходная копия не подготовлена для обычного запуска. Скачайте официальный выпуск или передайте ADMIN-SETUP.md техническому специалисту.'"
    ) @(
        "    Write-Warning 'Для визуального мастера нужны Node.js 22.12 или новее и npm.'",
        "    Write-Host 'Можно установить Node.js и повторить запуск. Сейчас доступен текстовый мастер.'",
        '    Invoke-ConsoleWizard',
        '    return'
    )
    Replace-FixtureLines $Project 'scripts/start-project.ps1' @(
        "        throw 'Не удалось подготовить визуальный мастер. Передайте ADMIN-SETUP.md техническому специалисту.'"
    ) @(
        "        Write-Warning 'Не удалось подготовить Electron. Проверьте интернет-подключение и доступ к npm.'",
        '        Invoke-ConsoleWizard',
        '        return'
    )
    Replace-FixtureLines $Project 'scripts/start-project.ps1' @(
        '    throw "Визуальный мастер завершился с кодом $result. Передайте ADMIN-SETUP.md техническому специалисту."'
    ) @(
        '    Write-Warning "Визуальный мастер завершился с кодом $result."',
        '    Invoke-ConsoleWizard'
    )

    Replace-FixtureLines $Project 'setup-ui/index.html' @(
        '      <div class="feedback">',
        '        <div class="notice" id="notice" role="status" aria-live="polite" hidden></div>',
        '        <details class="technical-error" id="technical-error" hidden>',
        '          <summary>Подробности для ИИ или технического специалиста</summary>',
        '          <p>Это диагностический журнал, а не список действий для руководителя.</p>',
        '          <pre id="technical-error-output"></pre>',
        '        </details>',
        '      </div>'
    ) @('      <div class="notice" id="notice" role="status" aria-live="polite" hidden></div>')
    Replace-FixtureLines $Project 'setup-ui/index.html' @(
        '              <small>Если программы нет, мастер откроет официальную страницу. Команды PowerShell копировать не потребуется.</small>'
    ) @(
        '              <small>Мастер не запускает установщики и не сохраняет пароли или API-ключи в проекте.</small>'
    )
    Replace-FixtureLines $Project 'setup-ui/index.html' @(
        '            <summary>Диагностика для специалиста — обычно не требуется</summary>',
        '            <p>Это журнал автоматической проверки, а не перечень задач для руководителя.</p>'
    ) @('            <summary>Показать технический результат предварительной проверки</summary>')

    Replace-FixtureLines $Project 'setup-ui/main.js' @(
        'const bundledPowerShell = app.isPackaged',
        "  ? path.resolve(process.resourcesPath, '..', 'powershell', 'pwsh.exe')",
        "  : ''",
        'const hasBundledPowerShell = Boolean(bundledPowerShell && fs.existsSync(bundledPowerShell))',
        "const powerShellExecutable = hasBundledPowerShell ? bundledPowerShell : 'pwsh'"
    )
    Replace-FixtureLines $Project 'setup-ui/main.js' @(
        '    const child = spawn(powerShellExecutable, args, {'
    ) @("    const child = spawn('pwsh', args, {")
    Replace-FixtureLines $Project 'setup-ui/main.js' @(
        "      reject(error.code === 'ENOENT'",
        '        ? new Error(app.isPackaged',
        "            ? 'В выпуске отсутствует внутренний механизм настройки. Скачайте официальный архив повторно или передайте ADMIN-SETUP.md техническому специалисту.'",
        "            : 'Исходная копия не подготовлена для обычного запуска. Техническому специалисту нужен PowerShell 7; подробности находятся в ADMIN-SETUP.md.')",
        '        : error)'
    ) @(
        "      reject(error.code === 'ENOENT'",
        "        ? new Error('Не найден PowerShell 7 (pwsh). Установите его и повторите запуск.')",
        '        : error)'
    )
    Replace-FixtureLines $Project 'setup-ui/main.js' @(
        '      electronVersion: process.versions.electron,',
        '      automationReady: hasBundledPowerShell || !app.isPackaged,',
        "      runtimeLabel: hasBundledPowerShell ? 'Автономный запуск' : 'Режим разработки'"
    ) @('      electronVersion: process.versions.electron')

    Replace-FixtureLines $Project 'setup-ui/renderer.js' @(
        "const technicalError = document.querySelector('#technical-error')",
        "const technicalErrorOutput = document.querySelector('#technical-error-output')"
    )
    Replace-FixtureRegex $Project 'setup-ui/renderer.js' '(?ms)^function clearTechnicalError \(\) \{.*?^function friendlyFailure \(operation, output = ''''\) \{.*?^\}\r?\n\r?\n'
    Replace-FixtureLines $Project 'setup-ui/renderer.js' @(
        "    guide.textContent = 'Открыть официальную страницу установки'"
    ) @("    guide.textContent = 'Открыть официальную инструкцию'")
    Replace-FixtureLines $Project 'setup-ui/renderer.js' @(
        "      const instruction = document.createElement('small')",
        '      instruction.textContent = hint',
        '      item.append(instruction)'
    ) @(
        "      const command = document.createElement('code')",
        '      command.textContent = hint',
        '      item.append(command)'
    )
    Replace-FixtureLines $Project 'setup-ui/renderer.js' @(
        '  for (const item of (result.tools || []).filter(item => item.selected && !item.installed)) {',
        '    addGuidance(item.id, item.name, item.installHint, item.credential)'
    ) @(
        '  for (const item of (result.tools || []).filter(item => item.selected)) {',
        "    addGuidance(item.id, item.name, item.installed ? '' : item.installHint, item.credential)"
    )
    Replace-FixtureLines $Project 'setup-ui/renderer.js' @(
        '    if (!result.ok) {',
        '      showTechnicalError(result.output)',
        "      throw new Error(friendlyFailure('предварительную проверку', result.output))",
        '    }',
        '    clearTechnicalError()'
    ) @('    if (!result.ok) throw new Error(result.output || `Проверка завершилась с кодом ${result.exitCode}.`)')
    Replace-FixtureLines $Project 'setup-ui/renderer.js' @(
        '    if (!result.ok) {',
        '      showTechnicalError(result.output)',
        "      throw new Error(friendlyFailure('настройку проекта', result.output))",
        '    }',
        '    clearTechnicalError()'
    ) @('    if (!result.ok) throw new Error(result.output || `Настройка завершилась с кодом ${result.exitCode}.`)')
    Replace-FixtureLines $Project 'setup-ui/renderer.js' @(
        '  document.querySelector(''#runtime-label'').textContent = defaults.runtimeLabel',
        '  document.querySelector(''#runtime-label'').title = `Визуальный движок Electron ${defaults.electronVersion}`',
        '  if (!defaults.automationReady) {',
        '    setNotice(''Этот архив собран не полностью. Не запускайте PowerShell вручную: скачайте официальный выпуск повторно или передайте ADMIN-SETUP.md техническому специалисту.'')',
        '    for (const control of form.elements) control.disabled = true',
        '    nextButton.disabled = true',
        '    return',
        '  }'
    ) @('  document.querySelector(''#runtime-label'').textContent = `Electron ${defaults.electronVersion}`')

    Replace-FixtureLines $Project 'setup-ui/styles.css' @(
        '.technical-error { margin-top: 10px; border: 1px solid #efc1ba; border-radius: 10px; background: #fff8f6; }',
        '.technical-error summary { padding: 11px 13px; color: #7b3730; font-size: 11px; font-weight: 750; cursor: pointer; }',
        '.technical-error p { margin: 0; padding: 0 13px 8px; color: var(--muted); font-size: 10px; }',
        '.technical-error pre { max-height: 130px; margin: 0; padding: 0 13px 13px; overflow: auto; white-space: pre-wrap; color: #51443f; font: 10px/1.45 Consolas, monospace; }'
    )
    Replace-FixtureLines $Project 'setup-ui/styles.css' @(
        '.install-item strong, .install-item small { display: block; }',
        '.install-item strong { font-size: 12px; }',
        '.install-item small { margin: 6px 0; color: #6c5a40; font-size: 10px; line-height: 1.45; }'
    ) @(
        '.install-item strong, .install-item code { display: block; }',
        '.install-item strong { font-size: 12px; }',
        '.install-item code { margin: 6px 0; overflow-wrap: anywhere; color: #5b4630; font: 10px/1.45 Consolas, monospace; }'
    )
    Replace-FixtureLines $Project 'setup-ui/styles.css' @(
        '.plan-details p { margin: 0; padding: 0 15px 8px; color: var(--muted); font-size: 10px; line-height: 1.4; }'
    )

    foreach ($relative in @('setup-ui/package.json', 'setup-ui/package-lock.json')) {
        Replace-FixtureRegex $Project $relative '"version": "0\.14\.1"' '"version": "0.14.0"'
    }
    foreach ($relative in @(
            'REGISTRY-SCHEMA.json',
            'migrations/baselines.json',
            'migrations/manifest.json',
            'scripts/validate-vault.ps1',
            'setup-ui/preload.js'
        )) {
        $content = @(& git -C $root show "v0.14.0:template/$relative" 2>$null)
        if ($LASTEXITCODE -ne 0) { throw "Не удалось восстановить официальный файл 0.14.0: $relative" }
        [System.IO.File]::WriteAllText(
            (Join-Path $Project $relative),
            ($content -join "`n").TrimEnd() + "`n",
            $utf8
        )
    }
}

function Restore-Fixture0132([string]$Project) {
    Restore-Fixture0140 $Project

    Replace-FixtureLines $Project 'setup-ui/index.html' @(
        '        <li class="step" data-step-indicator="5">',
        '          <span class="step-number">6</span>',
        '          <span><strong>Проверка</strong><small>План до применения</small></span>',
        '        </li>'
    )
    Replace-FixtureLines $Project 'setup-ui/index.html' @(
        '        <li class="step" data-step-indicator="4">',
        '          <span class="step-number">5</span>',
        '          <span><strong>Рабочий ритм</strong><small>Как вести проект</small></span>',
        '        </li>'
    ) @(
        '        <li class="step" data-step-indicator="4">',
        '          <span class="step-number">5</span>',
        '          <span><strong>Проверка</strong><small>План до применения</small></span>',
        '        </li>'
    )
    Replace-FixtureLines $Project 'setup-ui/index.html' @(
        '          <p class="eyebrow" id="step-eyebrow">Шаг 1 из 6</p>'
    ) @('          <p class="eyebrow" id="step-eyebrow">Шаг 1 из 5</p>')
    Replace-FixtureRegex $Project 'setup-ui/index.html' '(?ms)^        <section class="panel guidance-panel".*?^        </section>\r?\n\r?\n'
    Replace-FixtureLines $Project 'setup-ui/index.html' @(
        '        <section class="panel review-panel" data-step-panel="5" aria-labelledby="review-heading" hidden>'
    ) @('        <section class="panel review-panel" data-step-panel="4" aria-labelledby="review-heading" hidden>')
    Replace-FixtureLines $Project 'setup-ui/index.html' @(
        '            <span class="section-index">06</span>'
    ) @('            <span class="section-index">05</span>')

    Replace-FixtureRegex $Project 'setup-ui/renderer.js' 'Шаг ([1-5]) из 6' 'Шаг $1 из 5'
    Replace-FixtureLines $Project 'setup-ui/renderer.js' @(
        "  ['Шаг 5 из 5', 'Освойте рабочий ритм', 'Короткая памятка поможет управлять проектом без Git, терминала и ручного редактирования файлов.'],"
    )
    Replace-FixtureLines $Project 'setup-ui/renderer.js' @(
        "  ['Шаг 6 из 6', 'Проверьте план', 'Предварительная проверка ничего не изменила. Применение начнётся только по вашей команде.']"
    ) @(
        "  ['Шаг 5 из 5', 'Проверьте план', 'Предварительная проверка ничего не изменила. Применение начнётся только по вашей команде.']"
    )
    Replace-FixtureLines $Project 'setup-ui/renderer.js' @('    showStep(5)') @('    showStep(4)')
    Replace-FixtureRegex $Project 'setup-ui/renderer.js' "(?ms)^document\.querySelector\('\.guidance-panel'\).*?^\}\)\r?\n"
    Replace-FixtureLines $Project 'setup-ui/renderer.js' @(
        '  if (currentStep === 4) await prepareReview()'
    ) @('  if (currentStep === 3) await prepareReview()')

    Replace-FixtureRegex $Project 'setup-ui/main.js' '(?ms)^const projectGuidePaths = new Map\(\[.*?^\]\)\r?\n'
    Replace-FixtureRegex $Project 'setup-ui/main.js' "(?ms)^  ipcMain\.handle\('setup:open-project-guide'.*?^  \}\)\r?\n"
    Replace-FixtureLines $Project 'setup-ui/preload.js' @(
        "  openProjectGuide: guideId => ipcRenderer.invoke('setup:open-project-guide', guideId),"
    )

    Replace-FixtureLines $Project 'setup-ui/styles.css' @(
        '.sidebar-copy { position: relative; z-index: 1; margin-top: 42px; }'
    ) @('.sidebar-copy { position: relative; z-index: 1; margin-top: 60px; }')
    Replace-FixtureLines $Project 'setup-ui/styles.css' @(
        '.steps { position: relative; z-index: 1; display: grid; gap: 4px; margin: 30px 0 0; padding: 0; list-style: none; }',
        '.step { display: grid; grid-template-columns: 34px 1fr; gap: 12px; align-items: center; padding: 8px 12px; border-radius: 12px; color: rgba(255,255,255,.52); transition: .2s ease; }'
    ) @(
        '.steps { position: relative; z-index: 1; display: grid; gap: 6px; margin: 42px 0 0; padding: 0; list-style: none; }',
        '.step { display: grid; grid-template-columns: 34px 1fr; gap: 12px; align-items: center; padding: 10px 12px; border-radius: 12px; color: rgba(255,255,255,.52); transition: .2s ease; }'
    )
    Replace-FixtureRegex $Project 'setup-ui/styles.css' '(?ms)^\.owner-principle \{.*?^\.guide-actions \.button \{.*?\}\r?\n'
    Replace-FixtureLines $Project 'setup-ui/styles.css' @(
        '  .sidebar-copy { margin-top: 22px; }',
        '  .sidebar-copy > p:last-child { display: none; }',
        '  .steps { margin-top: 18px; }'
    ) @(
        '  .sidebar-copy { margin-top: 34px; }',
        '  .steps { margin-top: 26px; }'
    )

    foreach ($relative in @('setup-ui/package.json', 'setup-ui/package-lock.json')) {
        Replace-FixtureRegex $Project $relative '"version": "0\.14\.0"' '"version": "0.13.2"'
    }
}

function Restore-Fixture0131([string]$Project) {
    Replace-FixtureLines $Project 'scripts/configure-project-tools.ps1' @(
        'function ConvertTo-AsciiJson([object]$Value, [int]$Depth = 12) {',
        '    $json = $Value | ConvertTo-Json -Depth $Depth -Compress',
        '    $builder = [System.Text.StringBuilder]::new($json.Length)',
        '    foreach ($character in $json.ToCharArray()) {',
        '        $codePoint = [int][char]$character',
        '        if ($codePoint -ge 0x20 -and $codePoint -le 0x7e) {',
        '            [void]$builder.Append($character)',
        '        }',
        '        else {',
        "            [void]`$builder.AppendFormat('\u{0:x4}', `$codePoint)",
        '        }',
        '    }',
        '    return $builder.ToString()',
        '}',
        ''
    )
    Replace-FixtureLines $Project 'scripts/configure-project-tools.ps1' @(
        'if ($Json) { Write-Output (ConvertTo-AsciiJson $result) }'
    ) @('if ($Json) { Write-Output ($result | ConvertTo-Json -Depth 12 -Compress) }')
    Replace-FixtureLines $Project 'scripts/start-project.ps1' @(
        '    $process = Start-Process -FilePath $bundledElectron -Wait -PassThru',
        '    $result = $process.ExitCode',
        '    $process.Dispose()'
    ) @(
        '    & $bundledElectron',
        '    $result = $LASTEXITCODE'
    )
}

function New-ProjectFixture(
    [string]$Name,
    [string]$Version,
    [switch]$WithoutVersion,
    [switch]$Legacy
) {
    $project = Join-Path $testRoot $Name
    Copy-Item -LiteralPath $source -Destination $project -Recurse
    & (Join-Path $project 'scripts/init-project.ps1') `
        -Title "Миграция $Name" -Slug "migration-$Name" -Date '2026-07-01'
    Remove-SafePath $project 'scripts/check-context-health.ps1'
    foreach ($relative in @(
            '.ai-work',
            '.github/workflows/ai-coordination.yml',
            'AI-COORDINATION.json',
            'AI-COORDINATION.md',
            'AI-INTEGRATION-STATE.json',
            'scripts/check-ai-coordination.ps1',
            'scripts/configure-github-protection.ps1',
            'scripts/start-ai-work.ps1',
            'scripts/sync-ai-work.ps1'
        )) {
        $keepCoordination = $Version -in @('0.10.0', '0.10.1', '0.11.0', '0.12.0', '0.13.0', '0.13.1', '0.13.2', '0.14.0', '0.14.1')
        if (-not $keepCoordination -or
            ($Version -ceq '0.10.0' -and $relative -ceq 'scripts/configure-github-protection.ps1')) {
            Remove-SafePath $project $relative
        }
    }

    foreach ($relative in @(
            '.github/ISSUE_TEMPLATE/team-input.yml',
            '.github/workflows/team-input.yml',
            'TEAM-INPUT.json',
            'TEAM-INPUT.md',
            'scripts/process-team-input.ps1'
        )) {
        if ($Version -notin @('0.11.0', '0.12.0', '0.13.0', '0.13.1', '0.13.2', '0.14.0', '0.14.1')) { Remove-SafePath $project $relative }
    }

    foreach ($relative in @(
            '.github/copilot-instructions.md',
            'AGENTS.override.md',
            'AI-OPERATING-MODEL.md',
            'CLAUDE.md',
            'GEMINI.md',
            'PROMPTING-GUIDE.md',
            'VIRTUAL-SPECIALISTS.md',
            'scripts/link-registry-references.py'
        )) {
        if ($Version -notin @('0.8.0', '0.8.1', '0.9.0', '0.10.0', '0.10.1', '0.11.0', '0.12.0', '0.13.0', '0.13.1', '0.13.2', '0.14.0', '0.14.1')) { Remove-SafePath $project $relative }
    }

    foreach ($relative in @(
            '.github/workflows/project-health.yml',
            'AI-GOVERNANCE.md',
            'CONTROLS.md',
            'OUTCOMES.md',
            'PROJECT-CONFIG.json',
            'STATUS.md',
            'scripts/add-control.ps1',
            'scripts/build-status.ps1',
            'scripts/check-project-health.ps1'
        )) {
        if ($Version -notin @('0.8.0', '0.8.1', '0.9.0', '0.10.0', '0.10.1', '0.11.0', '0.12.0', '0.13.0', '0.13.1', '0.13.2', '0.14.0', '0.14.1')) { Remove-SafePath $project $relative }
    }

    if ($Version -notin @('0.12.0', '0.13.0', '0.13.1', '0.13.2', '0.14.0', '0.14.1')) {
        Remove-SafePath $project 'setup-ui'
        Remove-SafePath $project 'scripts/start-project.ps1'
    }

    switch ($Version) {
        '0.14.1' {
            Restore-Fixture0141 $project
            Set-StateVersion $project '0.14.1'
        }
        '0.14.0' {
            Restore-Fixture0140 $project
            Set-StateVersion $project '0.14.0'
        }
        '0.13.2' {
            Restore-Fixture0132 $project
            Set-StateVersion $project '0.13.2'
        }
        '0.13.1' {
            Restore-Fixture0132 $project
            foreach ($relative in @('setup-ui/package.json', 'setup-ui/package-lock.json')) {
                Replace-FixtureRegex $project $relative '"version": "0\.13\.2"' '"version": "0.13.1"'
            }
            Restore-Fixture0131 $project
            Set-StateVersion $project '0.13.1'
        }
        '0.13.0' {
            Restore-Fixture0132 $project
            foreach ($relative in @('setup-ui/package.json', 'setup-ui/package-lock.json')) {
                Replace-FixtureRegex $project $relative '"version": "0\.13\.2"' '"version": "0.13.0"'
            }
            Restore-Fixture0131 $project
            foreach ($relative in @('scripts/configure-project-tools.ps1', 'scripts/setup-project.ps1')) {
                Replace-FixtureLines $project $relative @(
                    "if (`$env:PROJECT_SETUP_STDIO_ENCODING -ceq 'utf8') {",
                    '    [Console]::OutputEncoding = $utf8',
                    '    $OutputEncoding = $utf8',
                    '}'
                )
            }
            Replace-FixtureLines $project 'scripts/start-project.ps1' @(
                '    $wizardSucceeded = $?',
                "    if (-not `$wizardSucceeded) { throw 'Запасной текстовый мастер завершился с ошибкой.' }"
            ) @('    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }')
            Replace-FixtureLines $project 'setup-ui/main.js' @(
                "const { StringDecoder } = require('node:string_decoder')"
            )
            Replace-FixtureLines $project 'setup-ui/main.js' @(
                "        POWERSHELL_TELEMETRY_OPTOUT: '1',",
                "        PROJECT_SETUP_STDIO_ENCODING: 'utf8'"
            ) @("        POWERSHELL_TELEMETRY_OPTOUT: '1'")
            Replace-FixtureLines $project 'setup-ui/main.js' @(
                "    const stdoutDecoder = new StringDecoder('utf8')",
                "    const stderrDecoder = new StringDecoder('utf8')",
                '    const append = (current, text) => {',
                '      if (current.length >= maximumOutput) {',
                '        if (text.length > 0) overflow = true',
                '        return current',
                '      }',
                '      const combined = current + text',
                '      if (combined.length > maximumOutput) overflow = true',
                '      return combined.slice(0, maximumOutput)',
                '    }',
                "    child.stdout.on('data', chunk => { stdout = append(stdout, stdoutDecoder.write(chunk)) })",
                "    child.stderr.on('data', chunk => { stderr = append(stderr, stderrDecoder.write(chunk)) })"
            ) @(
                '    const append = (current, chunk) => {',
                '      if (current.length >= maximumOutput) {',
                '        overflow = true',
                '        return current',
                '      }',
                "      return (current + chunk.toString('utf8')).slice(0, maximumOutput)",
                '    }',
                "    child.stdout.on('data', chunk => { stdout = append(stdout, chunk) })",
                "    child.stderr.on('data', chunk => { stderr = append(stderr, chunk) })"
            )
            Replace-FixtureLines $project 'setup-ui/main.js' @(
                '      stdout = append(stdout, stdoutDecoder.end())',
                '      stderr = append(stderr, stderrDecoder.end())'
            )
            Set-StateVersion $project '0.13.0'
        }
        '0.12.0' {
            $fixture = Join-Path $root 'tests/fixtures/v0.12.0'
            foreach ($mapping in @(
                    @('setup-main.js', 'setup-ui/main.js'),
                    @('setup-preload.js', 'setup-ui/preload.js'),
                    @('setup-renderer.js', 'setup-ui/renderer.js'),
                    @('setup-contract.js', 'setup-ui/setup-contract.js'),
                    @('setup-contract.test.js', 'setup-ui/test/setup-contract.test.js'),
                    @('setup-index.html', 'setup-ui/index.html'),
                    @('setup-styles.css', 'setup-ui/styles.css'),
                    @('setup-package.json', 'setup-ui/package.json'),
                    @('setup-package-lock.json', 'setup-ui/package-lock.json'),
                    @('setup-project.ps1', 'scripts/setup-project.ps1'),
                    @('validate-vault.ps1', 'scripts/validate-vault.ps1')
                )) {
                Copy-FixtureFile $fixture $mapping[0] $project $mapping[1]
            }
            foreach ($relative in @('AI-TOOLS.json', 'QWEN.md', 'scripts/configure-project-tools.ps1')) {
                Remove-SafePath $project $relative
            }
            Set-StateVersion $project '0.12.0'
        }
        '0.11.0' {
            $fixture = Join-Path $root 'tests/fixtures/v0.11.0'
            Copy-FixtureFile $fixture 'START-PROJECT.cmd' $project 'START-PROJECT.cmd'
            Copy-FixtureFile $fixture 'REGISTRY-SCHEMA.json' $project 'REGISTRY-SCHEMA.json'
            Copy-FixtureFile $fixture 'manifest.json' $project 'migrations/manifest.json'
            Copy-FixtureFile $fixture 'baselines.json' $project 'migrations/baselines.json'
            Copy-FixtureFile $fixture 'update-project.ps1' $project 'scripts/update-project.ps1'
            $ignorePath = Join-Path $project '.gitignore'
            $ignore = [System.IO.File]::ReadAllText($ignorePath) -replace '(?m)^setup-ui/node_modules/\s*\r?\n?', ''
            [System.IO.File]::WriteAllText($ignorePath, $ignore, $utf8)
            Set-StateVersion $project '0.11.0'
        }
        '0.10.1' {
            $fixture = Join-Path $root 'tests/fixtures/v0.10.1'
            Copy-FixtureFile $fixture 'AI-COORDINATION.json' $project 'AI-COORDINATION.json'
            Copy-FixtureFile $fixture 'REGISTRY-SCHEMA.json' $project 'REGISTRY-SCHEMA.json'
            Copy-FixtureFile $fixture 'manifest.json' $project 'migrations/manifest.json'
            Copy-FixtureFile $fixture 'baselines.json' $project 'migrations/baselines.json'
            Copy-FixtureFile $fixture 'validate-vault.ps1' $project 'scripts/validate-vault.ps1'
            Copy-FixtureFile $fixture 'copilot-instructions.md' $project '.github/copilot-instructions.md'
            Copy-FixtureFile $fixture 'AGENTS.override.md' $project 'AGENTS.override.md'
            Copy-FixtureFile $fixture 'CLAUDE.md' $project 'CLAUDE.md'
            Copy-FixtureFile $fixture 'GEMINI.md' $project 'GEMINI.md'
            Copy-FixtureFile $fixture 'add-entry.ps1' $project 'scripts/add-entry.ps1'
            Copy-FixtureFile $fixture 'project-dossier.manifest.json' $project 'scripts/project-dossier.manifest.json'
            foreach ($relative in @(
                    '.github/copilot-instructions.md', 'AGENTS.override.md', 'CLAUDE.md', 'GEMINI.md'
                )) {
                $path = Join-Path $project $relative
                $initialized = [System.IO.File]::ReadAllText($path).
                    Replace('{{PROJECT_TITLE}}', "Миграция $Name").
                    Replace('{{PROJECT_SLUG}}', "migration-$Name").
                    Replace('{{DATE}}', '2026-07-01')
                [System.IO.File]::WriteAllText($path, $initialized, $utf8)
            }
            Set-StateVersion $project '0.10.1'
        }
        '0.10.0' {
            $fixture = Join-Path $root 'tests/fixtures/v0.10.0'
            Copy-FixtureFile $fixture 'AI-COORDINATION.json' $project 'AI-COORDINATION.json'
            Copy-FixtureFile $fixture 'REGISTRY-SCHEMA.json' $project 'REGISTRY-SCHEMA.json'
            Copy-FixtureFile $fixture 'manifest.json' $project 'migrations/manifest.json'
            Copy-FixtureFile $fixture 'baselines.json' $project 'migrations/baselines.json'
            Copy-FixtureFile $fixture 'validate-vault.ps1' $project 'scripts/validate-vault.ps1'
            Set-StateVersion $project '0.10.0'
        }
        '0.9.0' {
            $fixture = Join-Path $root 'tests/fixtures/v0.9.0'
            Copy-FixtureFile $fixture 'REGISTRY-SCHEMA.json' $project 'REGISTRY-SCHEMA.json'
            Copy-FixtureFile $fixture 'manifest.json' $project 'migrations/manifest.json'
            Copy-FixtureFile $fixture 'baselines.json' $project 'migrations/baselines.json'
            Copy-FixtureFile $fixture 'validate-vault.ps1' $project 'scripts/validate-vault.ps1'
            Set-StateVersion $project '0.9.0'
        }
        '0.8.1' {
            Remove-SafePath $project 'START-PROJECT.cmd'
            Remove-SafePath $project 'scripts/setup-project.ps1'
            $fixture = Join-Path $root 'tests/fixtures/v0.8.1'
            Copy-FixtureFile $fixture 'REGISTRY-SCHEMA.json' $project 'REGISTRY-SCHEMA.json'
            Copy-FixtureFile $fixture 'manifest.json' $project 'migrations/manifest.json'
            Copy-FixtureFile $fixture 'baselines.json' $project 'migrations/baselines.json'
            Set-StateVersion $project '0.8.1'
        }
        '0.8.0' {
            Remove-SafePath $project 'HOME.md'
            Remove-SafePath $project 'ADMIN-SETUP.md'
            Remove-SafePath $project 'START-PROJECT.cmd'
            Remove-SafePath $project 'scripts/setup-project.ps1'
            $fixture = Join-Path $root 'tests/fixtures/v0.8.0'
            Copy-FixtureFile $fixture 'REGISTRY-SCHEMA.json' $project 'REGISTRY-SCHEMA.json'
            Copy-FixtureFile $fixture 'manifest.json' $project 'migrations/manifest.json'
            Copy-FixtureFile $fixture 'baselines.json' $project 'migrations/baselines.json'
            Set-StateVersion $project '0.8.0'
        }
        '0.7.0' {
            $fixture = Join-Path $root 'tests/fixtures/v0.7.0'
            Copy-FixtureFile $fixture 'REGISTRY-SCHEMA.json' $project 'REGISTRY-SCHEMA.json'
            Copy-FixtureFile $fixture 'manifest.json' $project 'migrations/manifest.json'
            Copy-FixtureFile $fixture 'baselines.json' $project 'migrations/baselines.json'
            Set-StateVersion $project '0.7.0'
        }
        '0.6.0' {
            $fixture = Join-Path $root 'tests/fixtures/v0.6.0'
            Copy-FixtureFile $fixture 'REGISTRY-SCHEMA.json' $project 'REGISTRY-SCHEMA.json'
            Copy-FixtureFile $fixture 'manifest.json' $project 'migrations/manifest.json'
            Copy-FixtureFile $fixture 'baselines.json' $project 'migrations/baselines.json'
            Set-StateVersion $project '0.6.0'
        }
        '0.5.0' {
            $fixture = Join-Path $root 'tests/fixtures/v0.5.0'
            Copy-FixtureFile $fixture 'REGISTRY-SCHEMA.json' $project 'REGISTRY-SCHEMA.json'
            Copy-FixtureFile $fixture 'manifest.json' $project 'migrations/manifest.json'
            Copy-FixtureFile $fixture 'baselines.json' $project 'migrations/baselines.json'
            Set-StateVersion $project '0.5.0'
        }
        '0.4.0' {
            foreach ($relative in @(
                    'AI-CONNECTIONS.md',
                    'INGESTION-WORKFLOW.md',
                    'SOURCE-INGESTION.json',
                    'START-HERE.md',
                    'scripts/build-ai-package.ps1',
                    'scripts/ingest-sources.ps1',
                    'scripts/source-ingestion.py'
                )) {
                Remove-SafePath $project $relative
            }
            $fixture = Join-Path $root 'tests/fixtures/v0.4.0'
            Copy-FixtureFile $fixture 'knowledge-base.yml' $project '.github/workflows/knowledge-base.yml'
            Copy-FixtureFile $fixture 'manifest.json' $project 'migrations/manifest.json'
            Copy-FixtureFile $fixture 'baselines.json' $project 'migrations/baselines.json'
            Set-StateVersion $project '0.4.0'
        }
        '0.3.0' {
            foreach ($relative in @(
                    'AI-CONNECTIONS.md',
                    'CONTEXT-PROFILES.json',
                    'CONTEXT-WORKFLOW.md',
                    'INGESTION-WORKFLOW.md',
                    'SOURCE-INGESTION.json',
                    'START-HERE.md',
                    'scripts/build-ai-package.ps1',
                    'scripts/build-context.ps1',
                    'scripts/ingest-sources.ps1',
                    'scripts/source-ingestion.py'
                )) {
                Remove-SafePath $project $relative
            }
            $fixture = Join-Path $root 'tests/fixtures/v0.3.0'
            Copy-FixtureFile $fixture 'knowledge-base.yml' $project '.github/workflows/knowledge-base.yml'
            Copy-FixtureFile $fixture 'REGISTRY-SCHEMA.json' $project 'REGISTRY-SCHEMA.json'
            Copy-FixtureFile $fixture 'manifest.json' $project 'migrations/manifest.json'
            Copy-FixtureFile $fixture 'baselines.json' $project 'migrations/baselines.json'
            Set-StateVersion $project '0.3.0'
        }
        default {
            foreach ($relative in @(
                    'AI-CONNECTIONS.md',
                    'CONTEXT-PROFILES.json',
                    'CONTEXT-WORKFLOW.md',
                    'INGESTION-WORKFLOW.md',
                    'MIGRATIONS.md',
                    'REGISTRY-SCHEMA.json',
                    'SOURCE-INGESTION.json',
                    'START-HERE.md',
                    'TEMPLATE-STATE.json',
                    'migrations',
                    'scripts/build-ai-package.ps1',
                    'scripts/build-context.ps1',
                    'scripts/ingest-sources.ps1',
                    'scripts/source-ingestion.py',
                    'scripts/update-project.ps1',
                    'scripts/validate-registries.ps1',
                    '.github/workflows/registry-compatibility.yml'
                )) {
                Remove-SafePath $project $relative
            }
        }
    }

    if ($Version -in @('0.13.0', '0.13.1', '0.13.2', '0.14.0')) {
        foreach ($relative in @('REGISTRY-SCHEMA.json', 'migrations/baselines.json', 'migrations/manifest.json')) {
            $content = @(& git -C $root show "v${Version}:template/$relative" 2>$null)
            if ($LASTEXITCODE -ne 0) { throw "Не удалось восстановить официальный файл ${Version}: $relative" }
            [System.IO.File]::WriteAllText(
                (Join-Path $project $relative),
                ($content -join "`n").TrimEnd() + "`n",
                $utf8
            )
        }
    }

    if ($Legacy) {
        foreach ($relative in @(
                'DAILY-WORK.md',
                'WORK-PROFILES.md',
                '_templates/Commit digest.md',
                'scripts/add-entry.ps1',
                'scripts/prepare-commit-digest.ps1',
                'scripts/rotate-history.ps1'
            )) {
            Remove-SafePath $project $relative
        }
        $ignorePath = Join-Path $project '.gitignore'
        $ignore = ([System.IO.File]::ReadAllText($ignorePath) -replace '(?m)^\.project/\s*\r?\n?', '')
        [System.IO.File]::WriteAllText($ignorePath, $ignore, $utf8)
    }

    $versionPath = Join-Path $project 'TEMPLATE-VERSION'
    if ($WithoutVersion) { Remove-SafePath $project 'TEMPLATE-VERSION' }
    else { [System.IO.File]::WriteAllText($versionPath, "$Version`n", $utf8) }
    return $project
}

function Assert-Version([string]$Project, [string]$Expected) {
    $actual = [System.IO.File]::ReadAllText((Join-Path $Project 'TEMPLATE-VERSION')).Trim()
    if ($actual -cne $Expected) { throw "Ожидалась версия $Expected, получена $actual." }
}

function Assert-AgentFiles([string]$Project) {
    foreach ($relative in @(
            '.github/copilot-instructions.md',
            'AGENTS.override.md',
            'AI-OPERATING-MODEL.md',
            'CLAUDE.md',
            'GEMINI.md',
            'PROMPTING-GUIDE.md',
            'VIRTUAL-SPECIALISTS.md'
        )) {
        if (-not (Test-Path -LiteralPath (Join-Path $Project $relative) -PathType Leaf)) {
            throw "Миграция не добавила агентный файл: $relative"
        }
    }
}

function Assert-ControlLoopFiles([string]$Project) {
    foreach ($relative in @(
            '.github/workflows/project-health.yml',
            'AI-GOVERNANCE.md',
            'CONTROLS.md',
            'OUTCOMES.md',
            'PROJECT-CONFIG.json',
            'STATUS.md',
            'scripts/add-control.ps1',
            'scripts/build-status.ps1',
            'scripts/check-project-health.ps1'
        )) {
        if (-not (Test-Path -LiteralPath (Join-Path $Project $relative) -PathType Leaf)) {
            throw "Миграция не добавила файл управленческого цикла: $relative"
        }
    }
    & (Join-Path $Project 'scripts/build-status.ps1') -Check
    & (Join-Path $Project 'scripts/check-project-health.ps1') -AllowPlaceholders -Date '2026-07-17'
}

function Assert-AiCoordinationFiles([string]$Project) {
    foreach ($relative in @(
            '.ai-work/README.md',
            '.ai-work/changes/.gitkeep',
            '.github/workflows/ai-coordination.yml',
            'AI-COORDINATION.json',
            'AI-COORDINATION.md',
            'AI-INTEGRATION-STATE.json',
            'scripts/check-ai-coordination.ps1',
            'scripts/configure-github-protection.ps1',
            'scripts/start-ai-work.ps1',
            'scripts/sync-ai-work.ps1'
        )) {
        if (-not (Test-Path -LiteralPath (Join-Path $Project $relative) -PathType Leaf)) {
            throw "Миграция не добавила файл координации нейросетей: $relative"
        }
    }
    $state = [System.IO.File]::ReadAllText((Join-Path $Project 'AI-INTEGRATION-STATE.json')) | ConvertFrom-Json
    if ([int]$state.sequence -ne 0 -or [string]$state.updatedAt -cne '2026-07-01') {
        throw 'Миграция создала некорректное начальное интеграционное состояние.'
    }
    Assert-TeamInputFiles $Project
}

function Assert-TeamInputFiles([string]$Project) {
    foreach ($relative in @(
            '.github/ISSUE_TEMPLATE/team-input.yml',
            '.github/workflows/team-input.yml',
            'TEAM-INPUT.json',
            'TEAM-INPUT.md',
            'scripts/process-team-input.ps1'
        )) {
        if (-not (Test-Path -LiteralPath (Join-Path $Project $relative) -PathType Leaf)) {
            throw "Миграция не добавила канал входа команды: $relative"
        }
    }
    $policy = [System.IO.File]::ReadAllText((Join-Path $Project 'TEAM-INPUT.json')) | ConvertFrom-Json
    $coordination = [System.IO.File]::ReadAllText((Join-Path $Project 'AI-COORDINATION.json')) | ConvertFrom-Json
    if ($policy.humanFileEditingAllowed -ne $false -or
        $policy.processing.processQueueAtAgentStart -ne $true -or
        $coordination.teamInput.processAtAgentStart -ne $true -or
        $coordination.teamInput.humanFileEditingAllowed -ne $false) {
        throw 'Миграция не включила безопасную автоматическую обработку входа команды.'
    }
}

if (-not $testRoot.StartsWith(
        $root + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'Небезопасный путь папки тестов миграции.'
}

try {
    [System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $updater = Join-Path $source 'scripts/update-project.ps1'

    $project0141 = New-ProjectFixture 'from-0141' '0.14.1'
    & $updater -ProjectPath $project0141 -Date '2026-07-21' -Apply -SkipLocalSyncInstallation
    Assert-Version $project0141 '0.14.2'
    $installer0141 = [System.IO.File]::ReadAllText((Join-Path $project0141 'scripts/install-local-sync.ps1'))
    $main0141 = [System.IO.File]::ReadAllText((Join-Path $project0141 'setup-ui/main.js'))
    if ($installer0141 -notmatch [regex]::Escape('-WindowStyle Hidden') -or
        $main0141 -notmatch [regex]::Escape('setup:set-local-sync') -or
        -not (Test-Path -LiteralPath (Join-Path $project0141 'scripts/run-local-sync-background.ps1') -PathType Leaf)) {
        throw 'Миграция 0.14.1 не установила скрытый запуск, журнал и визуальное управление обновлением.'
    }
    $state0141 = [System.IO.File]::ReadAllText((Join-Path $project0141 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state0141.previousTemplateVersion -cne '0.14.1' -or $state0141.templateVersion -cne '0.14.2') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.14.1 -> 0.14.2.'
    }

    $project0140 = New-ProjectFixture 'from-0140' '0.14.0'
    & $updater -ProjectPath $project0140 -Date '2026-07-21' -Apply -SkipLocalSyncInstallation
    Assert-Version $project0140 '0.14.2'
    $launcher0140 = [System.IO.File]::ReadAllText((Join-Path $project0140 'START-PROJECT.cmd'))
    $main0140 = [System.IO.File]::ReadAllText((Join-Path $project0140 'setup-ui/main.js'))
    $renderer0140 = [System.IO.File]::ReadAllText((Join-Path $project0140 'setup-ui/renderer.js'))
    if ($launcher0140 -notmatch 'bundled_ui' -or
        $main0140 -notmatch 'bundledPowerShell' -or
        $renderer0140 -notmatch 'friendlyFailure') {
        throw 'Миграция 0.14.0 не установила автономный запуск и понятную обработку ошибок.'
    }
    $state0140 = [System.IO.File]::ReadAllText((Join-Path $project0140 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state0140.previousTemplateVersion -cne '0.14.0' -or $state0140.templateVersion -cne '0.14.2') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.14.0 -> 0.14.2.'
    }

    $project0132 = New-ProjectFixture 'from-0132' '0.13.2'
    & $updater -ProjectPath $project0132 -Date '2026-07-19' -Apply -SkipLocalSyncInstallation
    Assert-Version $project0132 '0.14.2'
    $wizard0132 = [System.IO.File]::ReadAllText((Join-Path $project0132 'setup-ui/index.html'))
    $main0132 = [System.IO.File]::ReadAllText((Join-Path $project0132 'setup-ui/main.js'))
    if ([regex]::Matches($wizard0132, 'data-step-panel=').Count -ne 6 -or
        $wizard0132 -notmatch 'id="guidance-heading"' -or
        $main0132 -notmatch 'setup:open-project-guide') {
        throw 'Миграция 0.13.2 не добавила рекомендации руководителю и безопасное открытие локальных инструкций.'
    }
    $state0132 = [System.IO.File]::ReadAllText((Join-Path $project0132 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state0132.previousTemplateVersion -cne '0.13.2' -or $state0132.templateVersion -cne '0.14.2') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.13.2 -> 0.14.2.'
    }

    $project0131 = New-ProjectFixture 'from-0131' '0.13.1'
    & $updater -ProjectPath $project0131 -Date '2026-07-19' -Apply -SkipLocalSyncInstallation
    Assert-Version $project0131 '0.14.2'
    $configuredTools0131 = [System.IO.File]::ReadAllText((Join-Path $project0131 'scripts/configure-project-tools.ps1'))
    $startProject0131 = [System.IO.File]::ReadAllText((Join-Path $project0131 'scripts/start-project.ps1'))
    if ($configuredTools0131 -notmatch 'ConvertTo-AsciiJson' -or
        $startProject0131 -notmatch 'Start-Process -FilePath \$bundledElectron -Wait -PassThru') {
        throw 'Миграция 0.13.1 не установила независимый от кодировки JSON и безопасный запуск GUI.'
    }
    $state0131 = [System.IO.File]::ReadAllText((Join-Path $project0131 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state0131.previousTemplateVersion -cne '0.13.1' -or $state0131.templateVersion -cne '0.14.2') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.13.1 -> 0.14.2.'
    }

    $project0130 = New-ProjectFixture 'from-0130' '0.13.0'
    & $updater -ProjectPath $project0130 -Date '2026-07-18' -Apply -SkipLocalSyncInstallation
    Assert-Version $project0130 '0.14.2'
    $configuredTools0130 = [System.IO.File]::ReadAllText((Join-Path $project0130 'scripts/configure-project-tools.ps1'))
    $setupProject0130 = [System.IO.File]::ReadAllText((Join-Path $project0130 'scripts/setup-project.ps1'))
    $startProject0130 = [System.IO.File]::ReadAllText((Join-Path $project0130 'scripts/start-project.ps1'))
    $main0130 = [System.IO.File]::ReadAllText((Join-Path $project0130 'setup-ui/main.js'))
    if ($configuredTools0130 -notmatch 'PROJECT_SETUP_STDIO_ENCODING' -or
        $setupProject0130 -notmatch 'PROJECT_SETUP_STDIO_ENCODING' -or
        $main0130 -notmatch 'PROJECT_SETUP_STDIO_ENCODING' -or
        $main0130 -notmatch 'StringDecoder' -or
        $configuredTools0130 -notmatch 'ConvertTo-AsciiJson' -or
        $startProject0130 -notmatch 'wizardSucceeded' -or
        $startProject0130 -notmatch 'Start-Process -FilePath \$bundledElectron -Wait -PassThru') {
        throw 'Миграция 0.13.0 не установила исправления кодировки и запасного текстового мастера.'
    }
    $state0130 = [System.IO.File]::ReadAllText((Join-Path $project0130 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state0130.previousTemplateVersion -cne '0.13.0' -or $state0130.templateVersion -cne '0.14.2') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.13.0 -> 0.14.2.'
    }

    $project0120 = New-ProjectFixture 'from-0120' '0.12.0'
    & $updater -ProjectPath $project0120 -Date '2026-07-18' -Apply -SkipLocalSyncInstallation
    Assert-Version $project0120 '0.14.2'
    foreach ($relative in @(
            'AI-TOOLS.json', 'QWEN.md', 'scripts/configure-project-tools.ps1',
            'LOCAL-SYNC.json', 'LOCAL-SYNC.md', 'scripts/install-local-sync.ps1',
            'scripts/refresh-ai-context.ps1', 'scripts/sync-project.ps1', '.githooks/post-merge'
        )) {
        if (-not (Test-Path -LiteralPath (Join-Path $project0120 $relative) -PathType Leaf)) {
            throw "Миграция 0.12.0 не добавила настройку инструментов: $relative"
        }
    }
    $updatedWizard = [System.IO.File]::ReadAllText((Join-Path $project0120 'setup-ui/index.html'))
    if ($updatedWizard -notmatch 'ai-chatgpt' -or $updatedWizard -notmatch 'obsidian-enabled') {
        throw 'Миграция 0.12.0 не обновила визуальный мастер до выбора нейросетей и Obsidian.'
    }
    $syncPolicy0120 = [System.IO.File]::ReadAllText((Join-Path $project0120 'LOCAL-SYNC.json')) | ConvertFrom-Json
    $startProject0120 = [System.IO.File]::ReadAllText((Join-Path $project0120 'scripts/start-project.ps1'))
    if (-not [bool]$syncPolicy0120.enabled -or [string]$syncPolicy0120.strategy -cne 'fast-forward-only' -or
        $startProject0120 -notmatch 'sync-project\.ps1') {
        throw 'Миграция 0.12.0 не включила безопасное локальное обновление и контекст ИИ.'
    }
    $state0120 = [System.IO.File]::ReadAllText((Join-Path $project0120 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state0120.previousTemplateVersion -cne '0.12.0' -or $state0120.templateVersion -cne '0.14.2') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.12.0 -> 0.14.2.'
    }

    $project0110 = New-ProjectFixture 'from-0110' '0.11.0'
    & $updater -ProjectPath $project0110 -Date '2026-07-18' -Apply -SkipLocalSyncInstallation
    Assert-Version $project0110 '0.14.2'
    Assert-AiCoordinationFiles $project0110
    Assert-TeamInputFiles $project0110
    foreach ($relative in @(
            'START-PROJECT.cmd',
            'scripts/start-project.ps1',
            'setup-ui/package.json',
            'setup-ui/main.js',
            'setup-ui/index.html'
        )) {
        if (-not (Test-Path -LiteralPath (Join-Path $project0110 $relative) -PathType Leaf)) {
            throw "Миграция 0.11.0 не добавила визуальный мастер: $relative"
        }
    }
    $launcherBytes0110 = [System.IO.File]::ReadAllBytes((Join-Path $project0110 'START-PROJECT.cmd'))
    if (@($launcherBytes0110 | Where-Object { $_ -gt 127 }).Count -gt 0) {
        throw 'Миграция 0.11.0 не заменила повреждаемый Windows-запускатель.'
    }
    if ([System.IO.File]::ReadAllText((Join-Path $project0110 '.gitignore')) -notmatch '(?m)^setup-ui/node_modules/$') {
        throw 'Миграция 0.11.0 не исключила локальные зависимости Electron из Git.'
    }
    $state0110 = [System.IO.File]::ReadAllText((Join-Path $project0110 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state0110.previousTemplateVersion -cne '0.11.0' -or $state0110.templateVersion -cne '0.14.2') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.11.0 -> 0.14.2.'
    }

    $project0101 = New-ProjectFixture 'from-0101' '0.10.1'
    & $updater -ProjectPath $project0101 -Date '2026-07-18' -Apply -SkipLocalSyncInstallation
    Assert-Version $project0101 '0.14.2'
    Assert-AiCoordinationFiles $project0101
    Assert-TeamInputFiles $project0101
    $state0101 = [System.IO.File]::ReadAllText((Join-Path $project0101 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state0101.previousTemplateVersion -cne '0.10.1' -or $state0101.templateVersion -cne '0.14.2') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.10.1 -> 0.14.2.'
    }

    $project0100 = New-ProjectFixture 'from-0100' '0.10.0'
    & $updater -ProjectPath $project0100 -Date '2026-07-18' -Apply -SkipLocalSyncInstallation
    Assert-Version $project0100 '0.14.2'
    Assert-AiCoordinationFiles $project0100
    $coordination0100 = [System.IO.File]::ReadAllText((Join-Path $project0100 'AI-COORDINATION.json')) | ConvertFrom-Json
    if (-not [bool]$coordination0100.githubProtection.automaticSetup -or
        [string]$coordination0100.githubProtection.requiredStatusCheck -cne 'Одна согласованная версия проекта') {
        throw 'Миграция 0.10.0 не включила автоматическую защиту единой версии на GitHub.'
    }
    $state0100 = [System.IO.File]::ReadAllText((Join-Path $project0100 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state0100.previousTemplateVersion -cne '0.10.0' -or $state0100.templateVersion -cne '0.14.2') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.10.0 -> 0.14.2.'
    }

    $project090 = New-ProjectFixture 'from-090' '0.9.0'
    & $updater -ProjectPath $project090 -Date '2026-07-18' -Apply -SkipLocalSyncInstallation
    Assert-Version $project090 '0.14.2'
    Assert-AiCoordinationFiles $project090
    $state090 = [System.IO.File]::ReadAllText((Join-Path $project090 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state090.previousTemplateVersion -cne '0.9.0' -or $state090.templateVersion -cne '0.14.2') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.9.0 -> 0.14.2.'
    }

    $project081 = New-ProjectFixture 'from-081' '0.8.1'
    & $updater -ProjectPath $project081 -Date '2026-07-17' -Apply -SkipLocalSyncInstallation
    Assert-Version $project081 '0.14.2'
    Assert-AiCoordinationFiles $project081
    foreach ($relative in @('START-PROJECT.cmd', 'scripts/setup-project.ps1', 'scripts/check-context-health.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $project081 $relative) -PathType Leaf)) {
            throw "Миграция 0.8.1 не добавила новый файл выпуска: $relative"
        }
    }
    & (Join-Path $project081 'scripts/build-context.ps1') -Profile compact -IncludeId D-001,Q-001 -Check
    & (Join-Path $project081 'scripts/check-context-health.ps1') -Date '2026-07-07' -Check
    $state081 = [System.IO.File]::ReadAllText((Join-Path $project081 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state081.previousTemplateVersion -cne '0.8.1' -or $state081.templateVersion -cne '0.14.2') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.8.1 -> 0.14.2.'
    }

    $project080 = New-ProjectFixture 'from-080' '0.8.0'
    & $updater -ProjectPath $project080 -Date '2026-07-17' -Apply -SkipLocalSyncInstallation
    Assert-Version $project080 '0.14.2'
    Assert-AiCoordinationFiles $project080
    foreach ($relative in @('HOME.md', 'ADMIN-SETUP.md', 'START-PROJECT.cmd', 'scripts/setup-project.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $project080 $relative) -PathType Leaf)) {
            throw "Миграция 0.8.0 не добавила человеко-ориентированный файл или мастер: $relative"
        }
    }
    $state080 = [System.IO.File]::ReadAllText((Join-Path $project080 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state080.previousTemplateVersion -cne '0.8.0' -or $state080.templateVersion -cne '0.14.2') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.8.0 -> 0.14.2.'
    }

    $project070 = New-ProjectFixture 'from-070' '0.7.0'
    & $updater -ProjectPath $project070 -Date '2026-07-17' -Apply -SkipLocalSyncInstallation
    Assert-Version $project070 '0.14.2'
    Assert-AiCoordinationFiles $project070
    Assert-ControlLoopFiles $project070
    $state070 = [System.IO.File]::ReadAllText((Join-Path $project070 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state070.previousTemplateVersion -cne '0.7.0' -or $state070.templateVersion -cne '0.14.2') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.7.0 -> 0.14.2.'
    }

    $project060 = New-ProjectFixture 'from-060' '0.6.0'
    & $updater -ProjectPath $project060 -Date '2026-07-16' -Apply -SkipLocalSyncInstallation
    Assert-Version $project060 '0.14.2'
    Assert-AiCoordinationFiles $project060
    if (-not (Test-Path -LiteralPath (Join-Path $project060 'scripts/link-registry-references.py') -PathType Leaf)) {
        throw 'Миграция 0.6.0 не добавила преобразователь ссылок реестров.'
    }
    $state060 = [System.IO.File]::ReadAllText((Join-Path $project060 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state060.previousTemplateVersion -cne '0.6.0' -or $state060.templateVersion -cne '0.14.2') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.6.0 -> 0.14.2.'
    }
    & (Join-Path $project060 'scripts/validate-vault.ps1')

    $project050 = New-ProjectFixture 'from-050' '0.5.0'
    $agents050 = Join-Path $project050 'AGENTS.md'
    [System.IO.File]::AppendAllText($agents050, "`n<!-- USER-AGENT-RULE -->`n", $utf8)
    $plan050 = & $updater -ProjectPath $project050 -Date '2026-07-16' 6>&1 | Out-String
    if ($plan050 -notmatch 'Это только план' -or (Test-Path -LiteralPath (Join-Path $project050 'AI-OPERATING-MODEL.md'))) {
        throw 'План обновления 0.5.0 изменил проект или не сообщил о режиме планирования.'
    }
    & $updater -ProjectPath $project050 -Date '2026-07-16' -Apply -SkipLocalSyncInstallation
    Assert-Version $project050 '0.14.2'
    Assert-AiCoordinationFiles $project050
    Assert-AgentFiles $project050
    if ([System.IO.File]::ReadAllText($agents050) -notmatch 'USER-AGENT-RULE') {
        throw 'Миграция заменила пользовательский AGENTS.md.'
    }
    $state050 = [System.IO.File]::ReadAllText((Join-Path $project050 'TEMPLATE-STATE.json')) | ConvertFrom-Json
    if ($state050.previousTemplateVersion -cne '0.5.0' -or $state050.templateVersion -cne '0.14.2') {
        throw 'TEMPLATE-STATE.json не зафиксировал переход 0.5.0 -> 0.14.2.'
    }
    & (Join-Path $project050 'scripts/validate-vault.ps1')

    $project040 = New-ProjectFixture 'from-040' '0.4.0'
    & $updater -ProjectPath $project040 -Date '2026-07-16' -Apply -SkipLocalSyncInstallation
    Assert-Version $project040 '0.14.2'
    Assert-AiCoordinationFiles $project040
    Assert-AgentFiles $project040
    & (Join-Path $project040 'scripts/build-ai-package.ps1') -Profile compact -Check

    $project030 = New-ProjectFixture 'from-030' '0.3.0'
    & $updater -ProjectPath $project030 -Date '2026-07-16' -Apply -SkipLocalSyncInstallation
    Assert-Version $project030 '0.14.2'
    Assert-AiCoordinationFiles $project030
    Assert-AgentFiles $project030
    & (Join-Path $project030 'scripts/build-context.ps1') -Profile compact -IncludeId D-001,Q-001 -Check

    $project020 = New-ProjectFixture 'from-020' '0.2.0'
    $decisionsPath = Join-Path $project020 'DECISIONS.md'
    [System.IO.File]::AppendAllText($decisionsPath, "`n<!-- CANONICAL-USER-DATA -->`n", $utf8)
    & $updater -ProjectPath $project020 -Date '2026-07-16' -Apply -SkipLocalSyncInstallation
    Assert-Version $project020 '0.14.2'
    Assert-AiCoordinationFiles $project020
    Assert-AgentFiles $project020
    if ([System.IO.File]::ReadAllText($decisionsPath) -notmatch 'CANONICAL-USER-DATA') {
        throw 'Миграция изменила канонические пользовательские данные.'
    }

    $legacy = New-ProjectFixture 'from-010' '0.1.0' -WithoutVersion -Legacy
    Copy-Item -LiteralPath (Join-Path $root 'tests/fixtures/v0.1.0/knowledge-base.yml') `
        -Destination (Join-Path $legacy '.github/workflows/knowledge-base.yml') -Force
    Assert-Throws {
        & $updater -ProjectPath $legacy -Date '2026-07-16'
    } 'Укажите проверенную исходную версию' 'проект без маркера не обновляется без FromVersion'
    & $updater -ProjectPath $legacy -FromVersion '0.1.0' -Date '2026-07-16' -Apply -SkipLocalSyncInstallation
    Assert-Version $legacy '0.14.2'
    Assert-AiCoordinationFiles $legacy
    Assert-AgentFiles $legacy
    if ([System.IO.File]::ReadAllText((Join-Path $legacy '.gitignore')) -notmatch '(?m)^\.project/$') {
        throw 'Миграция старого проекта не добавила .project в .gitignore.'
    }

    $dirty = New-ProjectFixture 'dirty-git' '0.2.0'
    & git -C $dirty init -b main | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось создать тестовый Git-репозиторий.' }
    & git -C $dirty -c core.autocrlf=false add -A
    & git -C $dirty -c user.name='Migration Test' -c user.email='migration@example.invalid' commit -m 'baseline' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось создать исходный тестовый коммит.' }
    [System.IO.File]::AppendAllText((Join-Path $dirty 'DECISIONS.md'), "`n<!-- DIRTY -->`n", $utf8)
    Assert-Throws {
        & $updater -ProjectPath $dirty -Date '2026-07-16' -Apply
    } 'незакоммиченные изменения' 'обновление грязного Git-репозитория требует явного разрешения'
    Assert-Version $dirty '0.2.0'

    $conflict = New-ProjectFixture 'managed-conflict' '0.2.0'
    $managedPath = Join-Path $conflict 'scripts/build-project-dossier.ps1'
    [System.IO.File]::AppendAllText($managedPath, "`n# USER-MANAGED-CHANGE`n", $utf8)
    Assert-Throws {
        & $updater -ProjectPath $conflict -Date '2026-07-16' -Apply
    } 'Найдены конфликты управляемых файлов' 'изменённый управляемый файл блокирует обновление'
    Assert-Version $conflict '0.2.0'
    & $updater -ProjectPath $conflict -Date '2026-07-16' -Apply -ForceManagedFiles -SkipLocalSyncInstallation
    Assert-Version $conflict '0.14.2'
    $managedBackup = Get-ChildItem -LiteralPath (Join-Path $conflict '.project/backups') -Recurse -File |
        Where-Object FullName -match 'files[\\/]scripts[\\/]build-project-dossier\.ps1$' |
        Select-Object -First 1
    if ($null -eq $managedBackup -or [System.IO.File]::ReadAllText($managedBackup.FullName) -notmatch 'USER-MANAGED-CHANGE') {
        throw 'Принудительно заменённый файл не сохранён в резервной копии.'
    }

    $rollback = New-ProjectFixture 'rollback' '0.2.0'
    $sourcesPath = Join-Path $rollback 'SOURCES.md'
    [System.IO.File]::AppendAllText($sourcesPath, "`n| S-999 | Недостаточно колонок | Ошибка |`n", $utf8)
    Assert-Throws {
        & $updater -ProjectPath $rollback -Date '2026-07-16' -Apply
    } 'Обновление отменено.*восстановлены' 'ошибка проверки вызывает откат миграции'
    Assert-Version $rollback '0.2.0'
    if (Test-Path -LiteralPath (Join-Path $rollback 'AI-OPERATING-MODEL.md')) {
        throw 'После отката остался добавленный агентный файл.'
    }
    $rollbackReport = Get-ChildItem -LiteralPath (Join-Path $rollback '.project/backups') -Recurse -File -Filter 'update-report.json' |
        Select-Object -First 1
    if ($null -eq $rollbackReport -or
        ([System.IO.File]::ReadAllText($rollbackReport.FullName) | ConvertFrom-Json).result -ne 'rolled-back') {
        throw 'После отката отсутствует отчёт с результатом rolled-back.'
    }

    Assert-Throws {
        & $updater -ProjectPath $rollback -FromVersion '9.9.9' -Date '2026-07-16'
    } 'не совпадает с TEMPLATE-VERSION|не поддерживается' 'противоречащая или неподдерживаемая версия отклоняется'

    Write-Host 'Сценарии миграции проектов до 0.14.2 пройдены.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        if (-not $testRoot.StartsWith(
                $root + [System.IO.Path]::DirectorySeparatorChar,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            throw 'Небезопасное удаление папки тестов миграции.'
        }
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
