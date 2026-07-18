[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $root 'template'
$runId = [Guid]::NewGuid().ToString('N')
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $root ".tmp-setup-wizard-$runId"))

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

function New-WizardFixture([string]$Name) {
    $path = Join-Path $testRoot $Name
    Copy-Item -LiteralPath $source -Destination $path -Recurse
    return $path
}

if (-not $testRoot.StartsWith(
        $root + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'Небезопасный путь теста мастера настройки.'
}

try {
    [System.IO.Directory]::CreateDirectory($testRoot) | Out-Null

    $launcherPath = Join-Path $source 'START-PROJECT.cmd'
    $launcherBytes = [System.IO.File]::ReadAllBytes($launcherPath)
    if (@($launcherBytes | Where-Object { $_ -gt 127 }).Count -gt 0) {
        throw 'Windows-запускатель должен содержать только ASCII.'
    }
    $launcherText = [System.IO.File]::ReadAllText($launcherPath)
    foreach ($fragment in @('scripts\start-project.ps1', 'goto missing_pwsh', '--self-test')) {
        if ($launcherText -notmatch [regex]::Escape($fragment)) {
            throw "Windows-запускатель не содержит обязательный безопасный фрагмент: $fragment"
        }
    }

    $uiRoot = Join-Path $source 'setup-ui'
    $package = [System.IO.File]::ReadAllText((Join-Path $uiRoot 'package.json')) | ConvertFrom-Json
    $lock = [System.IO.File]::ReadAllText((Join-Path $uiRoot 'package-lock.json')) | ConvertFrom-Json -AsHashtable -Depth 100
    $electronVersion = [string]$package.devDependencies.electron
    if ($electronVersion -notmatch '^\d+\.\d+\.\d+$' -or
        [string]$lock['packages']['']['devDependencies']['electron'] -cne $electronVersion) {
        throw 'Electron должен быть зафиксирован точной версией в package.json и package-lock.json.'
    }
    foreach ($securityPattern in @(
            'contextIsolation: true',
            'nodeIntegration: false',
            'sandbox: true',
            'shell: false',
            "scheme = 'project-setup'"
        )) {
        if ([System.IO.File]::ReadAllText((Join-Path $uiRoot 'main.js')) -notmatch [regex]::Escape($securityPattern)) {
            throw "Electron-мастер не содержит обязательную настройку безопасности: $securityPattern"
        }
    }
    $wizardHtml = [System.IO.File]::ReadAllText((Join-Path $uiRoot 'index.html'))
    if ([regex]::Matches($wizardHtml, 'data-step-panel=').Count -ne 5 -or
        [regex]::Matches($wizardHtml, 'name="aiTools"').Count -ne 6 -or
        $wizardHtml -notmatch 'id="obsidian-enabled"' -or
        $wizardHtml -notmatch 'id="local-sync-enabled"' -or
        $wizardHtml -notmatch 'id="inspect-tools-button"') {
        throw 'Electron-мастер не содержит пять шагов, шесть нейросетей или настройку Obsidian.'
    }
    $mainText = [System.IO.File]::ReadAllText((Join-Path $uiRoot 'main.js'))
    $preloadText = [System.IO.File]::ReadAllText((Join-Path $uiRoot 'preload.js'))
    foreach ($pattern in @('setup:inspect-tools', 'setup:open-guide', 'setup:open-obsidian')) {
        if ($mainText -notmatch [regex]::Escape($pattern)) {
            throw "Electron-мастер не содержит изолированный обработчик: $pattern"
        }
    }
    foreach ($pattern in @("PROJECT_SETUP_STDIO_ENCODING: 'utf8'", "new StringDecoder('utf8')")) {
        if ($mainText -notmatch [regex]::Escape($pattern)) {
            throw "Electron-мастер не фиксирует безопасное декодирование PowerShell: $pattern"
        }
    }
    foreach ($scriptName in @('configure-project-tools.ps1', 'setup-project.ps1')) {
        $scriptText = [System.IO.File]::ReadAllText((Join-Path $source "scripts/$scriptName"))
        foreach ($pattern in @('PROJECT_SETUP_STDIO_ENCODING', '[Console]::OutputEncoding = $utf8')) {
            if ($scriptText -notmatch [regex]::Escape($pattern)) {
                throw "$scriptName не фиксирует UTF-8 для Electron-мастера: $pattern"
            }
        }
    }
    foreach ($pattern in @('inspectTools:', 'openGuide:', 'openObsidian:')) {
        if ($preloadText -notmatch [regex]::Escape($pattern)) {
            throw "Preload не содержит безопасный метод: $pattern"
        }
    }
    & node --check (Join-Path $uiRoot 'main.js')
    if ($LASTEXITCODE -ne 0) { throw 'main.js не прошёл синтаксическую проверку Node.js.' }
    & node --check (Join-Path $uiRoot 'preload.js')
    if ($LASTEXITCODE -ne 0) { throw 'preload.js не прошёл синтаксическую проверку Node.js.' }
    & node --check (Join-Path $uiRoot 'renderer.js')
    if ($LASTEXITCODE -ne 0) { throw 'renderer.js не прошёл синтаксическую проверку Node.js.' }
    & node --test (Join-Path $uiRoot 'test/setup-contract.test.js')
    if ($LASTEXITCODE -ne 0) { throw 'Контракт Electron-мастера не прошёл тесты.' }

    $encodingProbe = @'
const { spawnSync } = require('node:child_process')
const script = process.argv[1].replaceAll("'", "''")
const command = "[Console]::OutputEncoding=[Text.Encoding]::GetEncoding(866); & '" + script + "' -AiToolsCsv 'chatgpt,claude,qwen' -ObsidianMode disabled -Date '2026-07-18' -Json"
const result = spawnSync('pwsh', ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', command], {
  encoding: null,
  env: { ...process.env, PROJECT_SETUP_STDIO_ENCODING: 'utf8' }
})
if (result.status !== 0) throw new Error(result.stderr.toString('utf8'))
const text = new TextDecoder('utf-8', { fatal: true }).decode(result.stdout)
const value = JSON.parse(text)
const credentials = value.tools.filter(tool => tool.selected).map(tool => tool.credential)
if (!credentials.includes('При первом запуске выберите вход через ChatGPT.') ||
    !credentials.includes('При первом запуске войдите в аккаунт Anthropic.') ||
    !credentials.some(value => value.includes('Alibaba Cloud Coding Plan'))) {
  throw new Error('PowerShell вернул повреждённую кириллицу.')
}
'@
    & node -e $encodingProbe (Join-Path $source 'scripts/configure-project-tools.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Electron-мастер не защитил кириллицу от системной кодировки CP866.' }

    & (Join-Path $source 'scripts/start-project.ps1') -SelfTest | Out-Null
    $consoleFixture = New-WizardFixture 'console-fallback'
    [System.IO.File]::WriteAllText(
        (Join-Path $consoleFixture 'scripts/setup-project.ps1'),
        "[CmdletBinding()]`nparam()`nWrite-Output 'console-fallback-ok'`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    $powerShellExecutable = (Get-Process -Id $PID).Path
    $consoleOutput = @(& $powerShellExecutable -NoLogo -NoProfile -NonInteractive -File `
            (Join-Path $consoleFixture 'scripts/start-project.ps1') -Console 2>&1)
    $consoleExitCode = $LASTEXITCODE
    if ($consoleExitCode -ne 0 -or ($consoleOutput -join "`n") -notmatch 'console-fallback-ok') {
        throw "Запасной текстовый мастер неверно обрабатывает успешный PowerShell-сценарий: $($consoleOutput -join ' ')"
    }
    if ($IsWindows) {
        & cmd.exe /d /c (Join-Path $source 'START-PROJECT.cmd') --self-test | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'START-PROJECT.cmd не прошёл реальный запуск через cmd.exe.' }
    }

    $planProject = New-WizardFixture 'plan-only'
    & (Join-Path $planProject 'scripts/setup-project.ps1') `
        -Title 'План настройки' -AiToolsCsv 'chatgpt,claude' -ObsidianMode enabled `
        -NonInteractive -Date '2026-07-17'
    $planReadme = [System.IO.File]::ReadAllText((Join-Path $planProject 'README.md'))
    $planChanged = @(
        $planReadme -notmatch '\{\{PROJECT_TITLE\}\}'
        Test-Path -LiteralPath (Join-Path $planProject '.project/setup-report.json')
        Test-Path -LiteralPath (Join-Path $planProject '.obsidian')
    ) -contains $true
    if ($planChanged) {
        throw 'Режим плана изменил файлы проекта.'
    }

    $project = New-WizardFixture 'configured'
    & (Join-Path $project 'scripts/setup-project.ps1') `
        -Title 'Проект Ёлка 2026' `
        -ManagementProfile regulated `
        -DeliveryApproach adaptive `
        -WorkSystemType jira `
        -WorkSystemUrl 'https://jira.example.org/project/ELKA' `
        -DataClassification confidential `
        -ScheduleToleranceDays 5 `
        -CostVariancePercent 10 `
        -ScopeChangeRequiresApprovalValue false `
        -LocalSyncMode disabled -SkipLocalSyncScheduling -NonInteractive -Apply -Date '2026-07-17'

    $config = [System.IO.File]::ReadAllText((Join-Path $project 'PROJECT-CONFIG.json')) | ConvertFrom-Json
    $configInvalid = @(
        $config.projectSlug -cne 'proekt-elka-2026'
        $config.managementProfile -cne 'regulated'
        $config.deliveryApproach -cne 'adaptive'
        $config.workSystem.type -cne 'jira'
        $config.workSystem.url -cne 'https://jira.example.org/project/ELKA'
        $config.dataClassification -cne 'confidential'
        $config.aiGovernanceLevel -cne 'high'
        $config.tolerances.scheduleDays -ne 5
        $config.tolerances.costVariancePercent -ne 10
        $config.tolerances.scopeChangeRequiresApproval -ne $false
    ) -contains $true
    if ($configInvalid) {
        throw 'Мастер неверно сохранил выбранные параметры.'
    }

    $report = [System.IO.File]::ReadAllText((Join-Path $project '.project/setup-report.json')) | ConvertFrom-Json
    $reportInvalid = @(
        $report.result -cne 'success'
        $report.projectSlug -cne 'proekt-elka-2026'
        @($report.unresolvedDecisions).Count -ne 0
        [string]$report.githubProtection.status -cne 'not-applicable'
        [string]$report.githubProtection.requiredStatusCheck -cne 'Одна согласованная версия проекта'
        [string]$report.localSync.status -cne 'disabled'
        $report.nextDocument -cne 'HOME.md'
    ) -contains $true
    if ($reportInvalid) {
        throw 'Отчёт мастера не подтверждает завершённую настройку.'
    }
    $toolsConfiguration = [System.IO.File]::ReadAllText((Join-Path $project 'AI-TOOLS.json')) | ConvertFrom-Json
    if (@($toolsConfiguration.selectedAiTools).Count -ne 0 -or
        $toolsConfiguration.obsidian.enabled -ne $false -or
        $toolsConfiguration.secretsStoredInRepository -ne $false) {
        throw 'Мастер неверно сохранил пустой безопасный выбор инструментов.'
    }

    $toolsProject = New-WizardFixture 'tools-configured'
    [System.IO.Directory]::CreateDirectory((Join-Path $toolsProject '.obsidian')) | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $toolsProject '.obsidian/app.json'),
        '{"newFileLocation":"folder","newFileFolderPath":"_inbox","attachmentFolderPath":"_attachments","newLinkFormat":"relative","useMarkdownLinks":true,"customSettingPreserved":true}',
        [System.Text.UTF8Encoding]::new($false)
    )
    & (Join-Path $toolsProject 'scripts/setup-project.ps1') `
        -Title 'Мульти ИИ и база знаний' `
        -AiToolsCsv 'chatgpt,claude,gemini,qwen,deepseek,grok' `
        -ObsidianMode enabled -GitHubProtectionMode disabled `
        -WorkSystemType repository -DataClassification internal `
        -ScheduleToleranceDays 3 -CostVariancePercent 5 `
        -LocalSyncMode disabled -SkipLocalSyncScheduling -NonInteractive -Apply -Date '2026-07-17'

    $toolsConfiguration = [System.IO.File]::ReadAllText((Join-Path $toolsProject 'AI-TOOLS.json')) | ConvertFrom-Json
    $toolsReport = [System.IO.File]::ReadAllText((Join-Path $toolsProject '.project/setup-tools-report.json')) | ConvertFrom-Json
    $selectedTools = @($toolsConfiguration.selectedAiTools)
    $adapterNames = @($toolsConfiguration.adapters.PSObject.Properties | ForEach-Object { $_.Name })
    if ($selectedTools.Count -ne 6 -or $adapterNames.Count -ne 6 -or
        [string]$toolsConfiguration.instructionContract -cne 'AGENTS.md' -or
        [string]$toolsConfiguration.coordination.mode -cne 'separate-worktree-per-agent' -or
        [string]$toolsConfiguration.context.packagePath -cne '.project/context/ai-package.md' -or
        $toolsConfiguration.context.refreshBeforeSession -ne $true -or
        $toolsConfiguration.secretsStoredInRepository -ne $false -or
        @($toolsReport.tools).Count -ne 6 -or
        $toolsReport.obsidian.selected -ne $true) {
        throw 'Мастер неверно настроил несколько нейросетей и Obsidian.'
    }
    foreach ($file in @('.obsidian/app.json', '.obsidian/templates.json', '.obsidian/core-plugins.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $toolsProject $file) -PathType Leaf)) {
            throw "Мастер не создал безопасную настройку Obsidian: $file"
        }
    }
    $obsidianApp = [System.IO.File]::ReadAllText((Join-Path $toolsProject '.obsidian/app.json')) | ConvertFrom-Json
    if ([string]$obsidianApp.attachmentFolderPath -cne '_attachments' -or
        [string]$obsidianApp.newLinkFormat -cne 'relative' -or
        $obsidianApp.useMarkdownLinks -ne $true -or
        $obsidianApp.customSettingPreserved -ne $true) {
        throw 'Настройки Obsidian не обеспечивают переносимые Markdown-ссылки и отдельную папку вложений.'
    }
    & (Join-Path $toolsProject 'scripts/validate-vault.ps1')

    & (Join-Path $project 'scripts/build-status.ps1') -Check
    & (Join-Path $project 'scripts/check-project-health.ps1') -Date '2026-07-17'
    & (Join-Path $project 'scripts/build-project-dossier.ps1') -Check
    & (Join-Path $project 'scripts/validate-vault.ps1')

    Assert-Throws {
        & (Join-Path $project 'scripts/setup-project.ps1') `
            -Title 'Повтор' -NonInteractive -Apply -Date '2026-07-17'
    } 'уже инициализирован' 'повторная инициализация отклоняется'

    $invalidUrl = New-WizardFixture 'invalid-url'
    Assert-Throws {
        & (Join-Path $invalidUrl 'scripts/setup-project.ps1') `
            -Title 'Плохой адрес' -WorkSystemType jira -WorkSystemUrl 'http://unsafe.example' `
            -NonInteractive -Apply -Date '2026-07-17'
    } 'начинаться с https://' 'небезопасный адрес рабочей системы отклоняется'
    if ([System.IO.File]::ReadAllText((Join-Path $invalidUrl 'README.md')) -notmatch '\{\{PROJECT_TITLE\}\}') {
        throw 'Ошибка проверки адреса частично инициализировала проект.'
    }

    $invalidTolerance = New-WizardFixture 'invalid-tolerance'
    Assert-Throws {
        & (Join-Path $invalidTolerance 'scripts/setup-project.ps1') `
            -Title 'Плохой допуск' -ScheduleToleranceDays -1 `
            -NonInteractive -Apply -Date '2026-07-17'
    } 'не может быть отрицательным' 'отрицательный допуск отклоняется'

    $invalidTool = New-WizardFixture 'invalid-tool'
    Assert-Throws {
        & (Join-Path $invalidTool 'scripts/setup-project.ps1') `
            -Title 'Неизвестный ИИ' -AiToolsCsv 'chatgpt,unknown-ai' `
            -NonInteractive -Apply -Date '2026-07-17'
    } 'Неизвестный инструмент ИИ' 'неизвестный инструмент ИИ отклоняется до изменения проекта'
    if ([System.IO.File]::ReadAllText((Join-Path $invalidTool 'README.md')) -notmatch '\{\{PROJECT_TITLE\}\}') {
        throw 'Ошибка проверки инструмента частично инициализировала проект.'
    }

    Write-Host 'Мастер первоначальной настройки прошёл проверку.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        if (-not $testRoot.StartsWith(
                $root + [System.IO.Path]::DirectorySeparatorChar,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            throw 'Небезопасное удаление папки теста мастера.'
        }
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
