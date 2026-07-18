[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)]
    [string]$CommitSha,
    [AllowEmptyString()]
    [string]$ExistingTagCommit = '',
    [AllowEmptyString()]
    [string]$EventTag = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$version = [System.IO.File]::ReadAllText((Join-Path $root 'VERSION')).Trim()
$tag = "v$version"

& (Join-Path $PSScriptRoot 'check-version.ps1') -Tag $tag

if ($CommitSha -notmatch '^[0-9a-fA-F]{40}$') {
    throw "CommitSha должен быть полным SHA коммита: '$CommitSha'."
}
if (-not [string]::IsNullOrWhiteSpace($EventTag) -and $EventTag -cne $tag) {
    throw "Тег события '$EventTag' не соответствует ожидаемому тегу '$tag'."
}

$commit = $CommitSha.ToLowerInvariant()
$existing = $ExistingTagCommit.Trim().ToLowerInvariant()
if (-not [string]::IsNullOrWhiteSpace($existing) -and $existing -notmatch '^[0-9a-f]{40}$') {
    throw "ExistingTagCommit должен быть пустым или полным SHA коммита: '$ExistingTagCommit'."
}

$tagAction = if ([string]::IsNullOrWhiteSpace($existing)) {
    'create'
}
elseif ($existing -ceq $commit) {
    'reuse'
}
else {
    throw "Тег $tag уже указывает на $existing, а текущий коммит — $commit. Повышайте VERSION при каждом новом выпуске; существующий тег не будет переписан."
}

[ordered]@{
    schemaVersion = 1
    version = $version
    tag = $tag
    commitSha = $commit
    existingTagCommit = if ([string]::IsNullOrWhiteSpace($existing)) { $null } else { $existing }
    tagAction = $tagAction
} | ConvertTo-Json -Compress
