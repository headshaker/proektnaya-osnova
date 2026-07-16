[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$SourceId,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script = Join-Path $PSScriptRoot 'source-ingestion.py'
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
    throw 'Не найден scripts/source-ingestion.py.'
}

function Get-PythonCommand {
    foreach ($candidate in @('python', 'python3', 'py')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return [pscustomobject]@{
                Path = $command.Source
                Prefix = if ($candidate -eq 'py') { @('-3') } else { @() }
            }
        }
    }
    throw 'Не найден Python 3.10 или новее.'
}

$python = Get-PythonCommand
$ids = @($SourceId |
    ForEach-Object { $_ -split ',' } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_.Trim().ToUpperInvariant() } |
    Select-Object -Unique)

foreach ($id in $ids) {
    if ($id -notmatch '^S-\d+$') { throw "Некорректный ID источника: $id" }
    $arguments = @($python.Prefix) + @($script, 'ingest', '--source-id', $id)
    if ($Force) { $arguments += '--force' }
    $output = @(& $python.Path @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Не удалось обработать ${id}: $($output -join [Environment]::NewLine)"
    }
    $result = ($output -join "`n") | ConvertFrom-Json
    $mode = if ($result.cacheHit) { 'кэш актуален' } else { 'кэш создан' }
    Write-Host ("{0}: {1}; фрагментов — {2}; полный объём — ~{3} токенов." -f `
            $id, $mode, $result.chunkCount, $result.fullEstimatedTokens)
}
