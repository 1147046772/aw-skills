#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
    [string]$Name = 'wechat-miniprogram-test',

    [Parameter(Mandatory = $false)]
    [string]$DestinationRoot = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\skills')
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifest = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'manifest.json') | ConvertFrom-Json
$skill = @($manifest.skills | Where-Object { $_.name -eq $Name })
if ($skill.Count -ne 1) {
    throw "Skill '$Name' is not uniquely declared in manifest.json."
}

$source = [System.IO.Path]::GetFullPath((Join-Path $repoRoot ([string]$skill[0].path)))
$repoPrefix = $repoRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
if (-not $source.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
    -not (Test-Path -LiteralPath (Join-Path $source 'SKILL.md') -PathType Leaf)) {
    throw "Skill source is invalid: $source"
}
if (Get-ChildItem -LiteralPath $source -Recurse -Force | Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint }) {
    throw "Skill '$Name' contains a reparse point and cannot be installed."
}

& (Join-Path $PSScriptRoot 'Test-Repository.ps1') | Out-Host

$destinationRootPath = [System.IO.Path]::GetFullPath($DestinationRoot)
New-Item -ItemType Directory -Path $destinationRootPath -Force | Out-Null
$destination = Join-Path $destinationRootPath $Name
if (Test-Path -LiteralPath $destination) {
    throw "Destination already exists: $destination. Review and remove or back up the old version explicitly before installing."
}

$temporary = Join-Path $destinationRootPath ('.$Name.install.' + [Guid]::NewGuid().ToString('N'))
try {
    Copy-Item -LiteralPath $source -Destination $temporary -Recurse
    Move-Item -LiteralPath $temporary -Destination $destination
}
finally {
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Recurse -Force
    }
}

[ordered]@{
    installed = $true
    name = $Name
    version = [string]$skill[0].version
    destination = $destination
} | ConvertTo-Json
