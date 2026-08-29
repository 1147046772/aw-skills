#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [Parameter(Mandatory)][string]$ContractId,
    [Parameter(Mandatory)][ValidateSet('custom')][string]$Format,
    [Parameter(Mandatory)][string]$RootPath,
    [Parameter(Mandatory)][string[]]$FilePath,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }

function Get-PortableRelative([string]$Root, [string]$Path) {
    [IO.Path]::GetRelativePath($Root, [IO.Path]::GetFullPath($Path)).Replace('\','/')
}

function Assert-Under([string]$Child, [string]$Parent) {
    $childFull = [IO.Path]::GetFullPath($Child).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($childFull -ne $parentFull -and !$childFull.StartsWith($parentFull + [IO.Path]::DirectorySeparatorChar, $pathComparison)) {
        throw "Path escapes workspace: $Child"
    }
}

function Get-StringHash([string]$Value) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Value)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

$workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
$output = [IO.Path]::GetFullPath($OutputPath)
Assert-Under $output $workspace
if (Test-Path -LiteralPath $output) { throw "Refusing to overwrite: $output" }

$rootFull = [IO.Path]::GetFullPath((Join-Path $workspace ($RootPath -replace '/', [IO.Path]::DirectorySeparatorChar)))
Assert-Under $rootFull $workspace
if (!(Test-Path -LiteralPath $rootFull -PathType Leaf)) { throw "Contract root not found: $RootPath" }

$entries = @()
foreach ($declared in $FilePath) {
    $full = [IO.Path]::GetFullPath((Join-Path $workspace ($declared -replace '/', [IO.Path]::DirectorySeparatorChar)))
    Assert-Under $full $workspace
    if (!(Test-Path -LiteralPath $full -PathType Leaf)) { throw "Contract file not found: $declared" }
    $relative = Get-PortableRelative $workspace $full
    $entries += [pscustomobject]@{
        path = $relative
        sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
        role = if ($full -eq $rootFull) { 'ROOT' } else { 'REFERENCE' }
    }
}

$entries = @($entries | Sort-Object path -CaseSensitive)
if (@($entries.path | Sort-Object -Unique -CaseSensitive).Count -ne $entries.Count) { throw 'Contract file list contains duplicate paths.' }
if (@($entries | Where-Object role -eq 'ROOT').Count -ne 1) { throw 'Contract root must appear exactly once in FilePath.' }
$lines = ($entries | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join ''
$manifest = [ordered]@{
    schemaVersion = '2.0'
    contractId = $ContractId
    format = $Format
    root = Get-PortableRelative $workspace $rootFull
    files = $entries
    externalRefs = @()
    transitiveLocalRefsResolved = $true
    combinedSha256 = Get-StringHash $lines
    producer = [ordered]@{
        kind = 'CUSTOM_EXPLICIT'
        id = 'api-test.custom-explicit.v1'
        sha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$parent = Split-Path -Parent $output
if (!(Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
$temp = "$output.tmp-$([Guid]::NewGuid().ToString('N'))"
try {
    $json = $manifest | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($temp, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $output
} finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
[pscustomobject]@{ manifestPath=$output; manifestSha256=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant(); combinedSha256=$manifest.combinedSha256 } | ConvertTo-Json
