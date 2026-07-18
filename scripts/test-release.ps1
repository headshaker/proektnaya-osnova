[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runId = [Guid]::NewGuid().ToString('N')
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $root ".tmp-release-test-$runId"))
$output = Join-Path $testRoot 'proektnaya-osnova-template.zip'
$checksumPath = $output + '.sha256'
$extractPath = Join-Path $testRoot 'extracted'

if (-not $testRoot.StartsWith(
        $root + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'Небезопасный путь теста выпускного пакета.'
}

try {
    & (Join-Path $PSScriptRoot 'check-version.ps1')
    & (Join-Path $PSScriptRoot 'export-template.ps1') -OutputPath $output

    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
        throw 'Не создан файл SHA-256.'
    }
    $checksumLine = [System.IO.File]::ReadAllText($checksumPath).Trim()
    if ($checksumLine -notmatch '^(?<hash>[0-9A-Fa-f]{64})  (?<name>.+)$') {
        throw 'Файл SHA-256 имеет некорректный формат.'
    }
    if ($Matches['name'] -cne [System.IO.Path]::GetFileName($output)) {
        throw 'В файле SHA-256 указано неверное имя архива.'
    }
    $actualHash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
    if ($actualHash -cne $Matches['hash'].ToUpperInvariant()) {
        throw 'SHA-256 выпускного архива не совпадает.'
    }
    $hashBefore = $actualHash

    $blocked = $false
    try {
        & (Join-Path $PSScriptRoot 'export-template.ps1') -OutputPath $output 2>&1 | Out-Null
    }
    catch {
        $blocked = $_.Exception.Message -match 'укажите -Force'
    }
    if (-not $blocked) { throw 'Существующий выпуск был заменён без -Force.' }

    & (Join-Path $PSScriptRoot 'export-template.ps1') -OutputPath $output -Force
    $checksumLine = [System.IO.File]::ReadAllText($checksumPath).Trim()
    if ($checksumLine -notmatch '^(?<hash>[0-9A-Fa-f]{64})  (?<name>.+)$') {
        throw 'Файл SHA-256 после -Force имеет некорректный формат.'
    }
    $actualHash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
    if ($actualHash -cne $Matches['hash'].ToUpperInvariant()) {
        throw 'SHA-256 после -Force не совпадает.'
    }
    if ($actualHash -cne $hashBefore) {
        throw 'Повторная сборка тех же исходных файлов дала другой SHA-256.'
    }

    $archive = [System.IO.Compression.ZipFile]::OpenRead($output)
    try {
        $entries = @($archive.Entries)
        if ($entries.Count -eq 0) { throw 'Выпускной архив пуст.' }

        $duplicates = $entries | Group-Object FullName | Where-Object Count -gt 1
        if ($duplicates) { throw 'В выпускном архиве есть повторяющиеся пути.' }

        foreach ($entry in $entries) {
            if ([System.IO.Path]::IsPathRooted($entry.FullName) -or
                $entry.FullName -match '(^|[\/])\.\.([\/]|$)' -or
                $entry.FullName -match '^[A-Za-z]:') {
                throw "Небезопасный путь в архиве: $($entry.FullName)"
            }
            $mode = (([int64]$entry.ExternalAttributes -shr 16) -band 0xF000)
            if ($mode -eq 0xA000) { throw "Символьная ссылка в архиве: $($entry.FullName)" }
        }

        $required = @(
            'README.md',
            'START-PROJECT.cmd',
            'HOME.md',
            'START-HERE.md',
            'ADMIN-SETUP.md',
            'STATUS.md',
            'PROJECT-CONFIG.json',
            'OUTCOMES.md',
            'CONTROLS.md',
            'AI-OPERATING-MODEL.md',
            'AI-GOVERNANCE.md',
            'VIRTUAL-SPECIALISTS.md',
            'PROMPTING-GUIDE.md',
            'AI-CONNECTIONS.md',
            'AI-COORDINATION.md',
            'AI-COORDINATION.json',
            'AI-INTEGRATION-STATE.json',
            'OBSIDIAN.md',
            'AGENTS.md',
            'AGENTS.override.md',
            'CLAUDE.md',
            'GEMINI.md',
            '.github/copilot-instructions.md',
            '.ai-work/README.md',
            '.ai-work/changes/.gitkeep',
            'INGESTION-WORKFLOW.md',
            'SOURCE-INGESTION.json',
            'TEMPLATE-LICENSE',
            'TEMPLATE-VERSION',
            'DAILY-WORK.md',
            'CONTEXT-PROFILES.json',
            'CONTEXT-WORKFLOW.md',
            'MIGRATIONS.md',
            'REGISTRY-SCHEMA.json',
            'TEMPLATE-STATE.json',
            'WORK-PROFILES.md',
            'migrations/baselines.json',
            'migrations/manifest.json',
            'scripts/add-entry.ps1',
            'scripts/add-control.ps1',
            'scripts/build-ai-package.ps1',
            'scripts/build-context.ps1',
            'scripts/build-status.ps1',
            'scripts/check-context-health.ps1',
            'scripts/check-ai-coordination.ps1',
            'scripts/check-project-health.ps1',
            'scripts/ingest-sources.ps1',
            'scripts/source-ingestion.py',
            'scripts/link-registry-references.py',
            'scripts/init-project.ps1',
            'scripts/setup-project.ps1',
            'scripts/start-ai-work.ps1',
            'scripts/sync-ai-work.ps1',
            'scripts/prepare-commit-digest.ps1',
            'scripts/rotate-history.ps1',
            'scripts/update-project.ps1',
            'scripts/validate-registries.ps1',
            '.github/workflows/knowledge-base.yml',
            '.github/workflows/ai-coordination.yml',
            '.github/workflows/project-health.yml',
            '.github/workflows/registry-compatibility.yml'
        )
        foreach ($path in $required) {
            if ($entries.FullName -notcontains $path) {
                throw "В выпускном архиве отсутствует обязательный файл: $path"
            }
        }

        $versionEntry = $entries | Where-Object FullName -eq 'TEMPLATE-VERSION'
        $reader = [System.IO.StreamReader]::new($versionEntry.Open())
        try { $archiveVersion = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
        $expectedVersion = [System.IO.File]::ReadAllText((Join-Path $root 'VERSION')).Trim()
        if ($archiveVersion -cne $expectedVersion) {
            throw "Версия архива ($archiveVersion) не совпадает с VERSION ($expectedVersion)."
        }
    }
    finally {
        $archive.Dispose()
    }

    [System.IO.Compression.ZipFile]::ExtractToDirectory($output, $extractPath)
    & (Join-Path $extractPath 'scripts/init-project.ps1') -Title 'Проверка выпускного архива' -Slug 'release-package-test' -Date '2000-02-29'
    & (Join-Path $PSScriptRoot 'test-agent-guides.ps1') -Date '2026-07-16'
    & (Join-Path $PSScriptRoot 'test-ai-coordination.ps1')
    & (Join-Path $PSScriptRoot 'test-human-first.ps1')
    & (Join-Path $PSScriptRoot 'test-setup-wizard.ps1')
    & (Join-Path $PSScriptRoot 'test-ingestion.ps1') -Date '2026-07-16'
    & (Join-Path $PSScriptRoot 'test-migrations.ps1')

    Write-Host 'Выпускной архив, агентные инструкции и SHA-256 прошли проверку.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        if (-not $testRoot.StartsWith(
                $root + [System.IO.Path]::DirectorySeparatorChar,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            throw 'Небезопасное удаление тестовой папки выпуска.'
        }
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
