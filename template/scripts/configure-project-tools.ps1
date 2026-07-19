[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$AiToolsCsv = '',
    [ValidateSet('enabled', 'disabled')]
    [string]$ObsidianMode = 'disabled',
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    [switch]$Apply,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
if ($env:PROJECT_SETUP_STDIO_ENCODING -ceq 'utf8') {
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
}
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$allowedTools = @('chatgpt', 'claude', 'gemini', 'qwen', 'deepseek', 'grok')

function Assert-IsoDate([string]$Value) {
    [DateTime]$parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact(
            $Value,
            'yyyy-MM-dd',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$parsed
        )) {
        throw 'Дата должна существовать и иметь формат ГГГГ-ММ-ДД.'
    }
}

function ConvertTo-AsciiJson([object]$Value, [int]$Depth = 12) {
    $json = $Value | ConvertTo-Json -Depth $Depth -Compress
    $builder = [System.Text.StringBuilder]::new($json.Length)
    foreach ($character in $json.ToCharArray()) {
        $codePoint = [int][char]$character
        if ($codePoint -ge 0x20 -and $codePoint -le 0x7e) {
            [void]$builder.Append($character)
        }
        else {
            [void]$builder.AppendFormat('\u{0:x4}', $codePoint)
        }
    }
    return $builder.ToString()
}

function Get-SelectedTools([string]$Value) {
    $requested = @($Value.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries) |
        ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if (@($requested | Group-Object -CaseSensitive | Where-Object Count -gt 1).Count -gt 0) {
        throw 'Список инструментов ИИ содержит повтор.'
    }
    foreach ($tool in $requested) {
        if ($allowedTools -cnotcontains $tool) { throw "Неизвестный инструмент ИИ: $tool." }
    }
    return @($allowedTools | Where-Object { $requested -ccontains $_ })
}

function Get-ExecutableExtensions {
    if (-not $IsWindows) { return @('') }
    $extensions = @(([Environment]::GetEnvironmentVariable('PATHEXT') -split ';') |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.ToLowerInvariant() })
    if ($extensions.Count -eq 0) { return @('.exe', '.cmd', '.bat', '.com') }
    return $extensions
}

function Get-CommandSearchPaths {
    $values = [System.Collections.Generic.List[string]]::new()
    $targets = @([System.EnvironmentVariableTarget]::Process)
    if ($IsWindows) {
        $targets += [System.EnvironmentVariableTarget]::User
        $targets += [System.EnvironmentVariableTarget]::Machine
    }
    foreach ($target in $targets) {
        try { $pathValue = [Environment]::GetEnvironmentVariable('PATH', $target) }
        catch { $pathValue = '' }
        foreach ($pathEntry in @($pathValue -split [regex]::Escape([string][IO.Path]::PathSeparator))) {
            $candidate = $pathEntry.Trim().Trim('"')
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and $values -notcontains $candidate) {
                $values.Add($candidate)
            }
        }
    }
    return @($values)
}

function Find-Executable([string]$Name, [string[]]$AdditionalPaths = @()) {
    $command = Get-Command -Name $Name -CommandType Application,ExternalScript -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) { return [string]$command.Source }

    $names = [System.Collections.Generic.List[string]]::new()
    if ([IO.Path]::GetExtension($Name)) { $names.Add($Name) }
    else {
        foreach ($extension in Get-ExecutableExtensions) { $names.Add($Name + $extension) }
    }
    foreach ($directory in @((Get-CommandSearchPaths) + $AdditionalPaths)) {
        if ([string]::IsNullOrWhiteSpace($directory)) { continue }
        foreach ($fileName in $names) {
            $candidate = Join-Path $directory $fileName
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return [System.IO.Path]::GetFullPath($candidate)
            }
        }
    }
    return ''
}

function Get-PlatformInstallHint([string]$Id) {
    $windowsHints = @{
        chatgpt = 'powershell -ExecutionPolicy ByPass -c "irm https://chatgpt.com/codex/install.ps1 | iex"'
        claude = 'irm https://claude.ai/install.ps1 | iex'
        gemini = 'npm install -g @google/gemini-cli'
        qwen = 'npm install -g @qwen-code/qwen-code@latest'
        deepseek = 'npm install -g deepseek-tui'
        grok = 'irm https://x.ai/cli/install.ps1 | iex'
    }
    $unixHints = @{
        chatgpt = 'curl -fsSL https://chatgpt.com/codex/install.sh | sh'
        claude = 'curl -fsSL https://claude.ai/install.sh | bash'
        gemini = 'npm install -g @google/gemini-cli'
        qwen = 'curl -fsSL https://qwen-code-assets.oss-cn-hangzhou.aliyuncs.com/installation/install-qwen.sh | bash'
        deepseek = 'npm install -g deepseek-tui'
        grok = 'curl -fsSL https://x.ai/cli/install.sh | bash'
    }
    return [string]$(if ($IsWindows) { $windowsHints[$Id] } else { $unixHints[$Id] })
}

function Write-JsonFile([string]$Path, [object]$Value) {
    $directory = Split-Path -Parent $Path
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = "$Path.setup-$PID.tmp"
    try {
        [System.IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 12) + "`n", $utf8)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Write-JsonFileIfMissing([string]$Path, [object]$Value) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Write-JsonFile $Path $Value }
}

Assert-IsoDate $Date
$selected = @(Get-SelectedTools $AiToolsCsv)
$toolCatalog = [ordered]@{
    chatgpt = [ordered]@{
        name = 'ChatGPT / OpenAI Codex'; command = 'codex';
        guideUrl = 'https://developers.openai.com/codex/cli'; instructionFile = 'AGENTS.md';
        credential = 'При первом запуске выберите вход через ChatGPT.'; thirdPartyClient = $false
    }
    claude = [ordered]@{
        name = 'Claude Code'; command = 'claude';
        guideUrl = 'https://code.claude.com/docs/en/terminal-guide'; instructionFile = 'CLAUDE.md';
        credential = 'При первом запуске войдите в аккаунт Anthropic.'; thirdPartyClient = $false
    }
    gemini = [ordered]@{
        name = 'Gemini CLI'; command = 'gemini';
        guideUrl = 'https://google-gemini.github.io/gemini-cli/docs/get-started/deployment.html'; instructionFile = 'GEMINI.md';
        credential = 'При первом запуске войдите в Google или укажите разрешённый API-ключ.'; thirdPartyClient = $false
    }
    qwen = [ordered]@{
        name = 'Qwen Code'; command = 'qwen';
        guideUrl = 'https://qwenlm.github.io/qwen-code-docs/en/'; instructionFile = 'QWEN.md';
        credential = 'При первом запуске выберите Alibaba Cloud Coding Plan или разрешённый API-провайдер.'; thirdPartyClient = $false
    }
    deepseek = [ordered]@{
        name = 'DeepSeek'; command = 'deepseek';
        guideUrl = 'https://github.com/deepseek-ai/awesome-deepseek-agent/blob/main/docs/deepseek-tui.md'; instructionFile = 'AGENTS.md';
        credential = 'Клиент DeepSeek-TUI является сторонней интеграцией из каталога DeepSeek; требуется DEEPSEEK_API_KEY.'; thirdPartyClient = $true
    }
    grok = [ordered]@{
        name = 'Grok Build'; command = 'grok';
        guideUrl = 'https://docs.x.ai/build/overview'; instructionFile = 'AGENTS.md';
        credential = 'При первом запуске войдите через браузер или задайте XAI_API_KEY.'; thirdPartyClient = $false
    }
}

$toolResults = [System.Collections.Generic.List[object]]::new()
foreach ($id in $allowedTools) {
    $entry = $toolCatalog[$id]
    $isSelected = $selected -ccontains $id
    $commandPath = if ($isSelected) { Find-Executable ([string]$entry.command) } else { '' }
    $installed = $isSelected -and -not [string]::IsNullOrWhiteSpace($commandPath)
    $toolResults.Add([pscustomobject][ordered]@{
        id = $id
        name = [string]$entry.name
        selected = $isSelected
        installed = $installed
        status = if (-not $isSelected) { 'not-selected' } elseif ($installed) { 'installed' } else { 'missing' }
        command = [string]$entry.command
        commandPath = $commandPath
        guideUrl = [string]$entry.guideUrl
        installHint = Get-PlatformInstallHint $id
        instructionFile = [string]$entry.instructionFile
        credential = [string]$entry.credential
        thirdPartyClient = [bool]$entry.thirdPartyClient
    })
}

$obsidianSelected = $ObsidianMode -ceq 'enabled'
$obsidianAdditional = [System.Collections.Generic.List[string]]::new()
if ($IsWindows) {
    foreach ($candidate in @(
            (Join-Path ([string]$env:LOCALAPPDATA) 'Programs/Obsidian'),
            (Join-Path ([string]$env:LOCALAPPDATA) 'Obsidian'),
            (Join-Path ([string]$env:ProgramFiles) 'Obsidian'),
            (Join-Path ([string]$env:USERPROFILE) 'scoop/apps/obsidian/current')
        )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { $obsidianAdditional.Add($candidate) }
    }
}
elseif ($IsMacOS) { $obsidianAdditional.Add('/Applications/Obsidian.app/Contents/MacOS') }
else { $obsidianAdditional.Add('/snap/bin') }
$obsidianPath = if ($obsidianSelected) { Find-Executable 'obsidian' @($obsidianAdditional) } else { '' }
$obsidianInstalled = $obsidianSelected -and -not [string]::IsNullOrWhiteSpace($obsidianPath)
$obsidian = [pscustomobject][ordered]@{
    selected = $obsidianSelected
    installed = $obsidianInstalled
    status = if (-not $obsidianSelected) { 'not-selected' } elseif ($obsidianInstalled) { 'installed' } else { 'missing' }
    commandPath = $obsidianPath
    guideUrl = 'https://obsidian.md/help/install'
    installHint = 'Скачайте Obsidian с https://obsidian.md/download и установите обычным способом.'
}

$missing = @($toolResults | Where-Object { $_.selected -and -not $_.installed })
$ready = $missing.Count -eq 0 -and (-not $obsidianSelected -or $obsidianInstalled)
$nextSteps = [System.Collections.Generic.List[string]]::new()
foreach ($item in $missing) { $nextSteps.Add("$($item.name): $($item.installHint)") }
if ($obsidianSelected -and -not $obsidianInstalled) { $nextSteps.Add($obsidian.installHint) }

if ($Apply) {
    $adapters = [ordered]@{}
    foreach ($id in $selected) {
        $entry = $toolCatalog[$id]
        $adapters[$id] = [ordered]@{
            command = [string]$entry.command
            instructionFile = [string]$entry.instructionFile
            guideUrl = [string]$entry.guideUrl
            thirdPartyClient = [bool]$entry.thirdPartyClient
        }
    }
    $configuration = [ordered]@{
        schemaVersion = 1
        selectedAiTools = @($selected)
        instructionContract = 'AGENTS.md'
        coordination = [ordered]@{
            mode = 'separate-worktree-per-agent'
            guide = 'AI-COORDINATION.md'
        }
        context = [ordered]@{
            packagePath = '.project/context/ai-package.md'
            statePath = '.project/context/local-context-state.json'
            syncPolicy = 'LOCAL-SYNC.json'
            refreshScript = 'scripts/refresh-ai-context.ps1'
            refreshBeforeSession = $true
        }
        adapters = $adapters
        obsidian = [ordered]@{
            enabled = $obsidianSelected
            configurationFolder = '.obsidian'
            homeDocument = 'HOME.md'
        }
        secretsStoredInRepository = $false
        configuredAt = $Date
    }
    Write-JsonFile (Join-Path $root 'AI-TOOLS.json') $configuration

    if ($obsidianSelected) {
        $obsidianRoot = Join-Path $root '.obsidian'
        Write-JsonFileIfMissing (Join-Path $obsidianRoot 'app.json') ([ordered]@{
                newFileLocation = 'folder'
                newFileFolderPath = '_inbox'
                attachmentFolderPath = '_attachments'
                newLinkFormat = 'relative'
                useMarkdownLinks = $true
                alwaysUpdateLinks = $true
                promptDelete = $true
            })
        Write-JsonFileIfMissing (Join-Path $obsidianRoot 'templates.json') ([ordered]@{
                folder = '_templates'
                dateFormat = 'YYYY-MM-DD'
                timeFormat = 'HH:mm'
            })
        Write-JsonFileIfMissing (Join-Path $obsidianRoot 'core-plugins.json') @(
            'file-explorer',
            'global-search',
            'backlink',
            'outgoing-link',
            'properties',
            'graph',
            'canvas',
            'bookmarks',
            'templates',
            'workspaces'
        )
    }
}

$result = [pscustomobject][ordered]@{
    schemaVersion = 1
    ready = $ready
    applied = [bool]$Apply
    selectedAiTools = @($selected)
    tools = @($toolResults)
    obsidian = $obsidian
    nextSteps = @($nextSteps)
    secretsStored = $false
}

if ($Apply) {
    $reportDirectory = Join-Path $root '.project'
    [System.IO.Directory]::CreateDirectory($reportDirectory) | Out-Null
    Write-JsonFile (Join-Path $reportDirectory 'setup-tools-report.json') $result
}

if ($Json) { Write-Output (ConvertTo-AsciiJson $result) }
else {
    Write-Host "Выбрано инструментов ИИ: $($selected.Count)."
    foreach ($item in @($toolResults | Where-Object selected)) {
        Write-Host ("  {0}: {1}" -f $item.name, $(if ($item.installed) { 'установлен' } else { 'требуется установка' }))
    }
    if ($obsidianSelected) {
        Write-Host ("  Obsidian: {0}" -f $(if ($obsidianInstalled) { 'установлен' } else { 'требуется установка' }))
    }
    if ($nextSteps.Count -gt 0) {
        Write-Host 'Следующие ручные шаги:'
        foreach ($step in $nextSteps) { Write-Host "  - $step" }
    }
}
