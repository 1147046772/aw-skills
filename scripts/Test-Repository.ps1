#requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifestPath = Join-Path $repoRoot 'manifest.json'

function Get-SkillContentHash {
    param([Parameter(Mandatory)][string]$Root)

    $physicalRoot = [System.IO.Path]::GetFullPath($Root)
    $records = [System.Collections.Generic.List[string]]::new()
    $files = Get-ChildItem -LiteralPath $physicalRoot -Recurse -File | Sort-Object {
        [System.IO.Path]::GetRelativePath($physicalRoot, $_.FullName).Replace('\', '/')
    }
    foreach ($file in $files) {
        $relative = [System.IO.Path]::GetRelativePath($physicalRoot, $file.FullName).Replace('\', '/')
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.UTF8Encoding]::new($false))
        $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
        $contentHash = [Convert]::ToHexString(
            [System.Security.Cryptography.SHA256]::HashData(
                [System.Text.UTF8Encoding]::new($false).GetBytes($normalized)
            )
        ).ToLowerInvariant()
        $records.Add("$relative|$contentHash")
    }
    $payload = ($records -join "`n") + "`n"
    return [Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData(
            [System.Text.UTF8Encoding]::new($false).GetBytes($payload)
        )
    ).ToLowerInvariant()
}

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'manifest.json is missing.'
}

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1 -or $manifest.repository -ne 'aw-skills') {
    throw 'Unsupported or invalid repository manifest.'
}
if (-not $manifest.skills -or $manifest.skills.Count -lt 1) {
    throw 'The manifest must declare at least one skill.'
}

$names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$results = [System.Collections.Generic.List[object]]::new()
foreach ($skill in $manifest.skills) {
    if ($skill.name -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw "Invalid skill name: $($skill.name)"
    }
    if (-not $names.Add([string]$skill.name)) {
        throw "Duplicate skill name: $($skill.name)"
    }
    if ($skill.version -notmatch '^\d+\.\d+\.\d+$') {
        throw "Invalid semantic version for $($skill.name): $($skill.version)"
    }

    $skillRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot ([string]$skill.path)))
    $repoPrefix = $repoRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $skillRoot.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Skill path escapes the repository: $($skill.path)"
    }
    if (-not (Test-Path -LiteralPath $skillRoot -PathType Container)) {
        throw "Skill directory is missing: $($skill.path)"
    }

    $entrypoint = [System.IO.Path]::GetFullPath((Join-Path $skillRoot ([string]$skill.entrypoint)))
    if (-not $entrypoint.StartsWith($skillRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $entrypoint -PathType Leaf)) {
        throw "Skill entrypoint is invalid: $($skill.entrypoint)"
    }

    $reparsePoints = Get-ChildItem -LiteralPath $skillRoot -Recurse -Force | Where-Object {
        $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint
    }
    if ($reparsePoints) {
        throw "Reparse points are not allowed in skill '$($skill.name)'."
    }

    $forbiddenNames = Get-ChildItem -LiteralPath $skillRoot -Recurse -File | Where-Object {
        $_.Name -match '^(\.env|id_rsa|id_ed25519)$' -or $_.Extension -in @('.pem', '.pfx', '.p12', '.key')
    }
    if ($forbiddenNames) {
        throw "Sensitive filename detected in skill '$($skill.name)': $($forbiddenNames[0].FullName)"
    }

    $secretPatterns = @(
        'BEGIN [A-Z ]*PRIVATE KEY',
        'gh[pousr]_[A-Za-z0-9_]{20,}',
        'github_pat_[A-Za-z0-9_]{20,}',
        'sk-[A-Za-z0-9_-]{20,}',
        'C:\\Users\\xyyxx(?:\\|$)',
        'C:/Users/xyyxx(?:/|$)'
    )
    foreach ($file in Get-ChildItem -LiteralPath $skillRoot -Recurse -File) {
        $content = [System.IO.File]::ReadAllText($file.FullName, [System.Text.UTF8Encoding]::new($false))
        foreach ($pattern in $secretPatterns) {
            if ($content -match $pattern) {
                throw "Sensitive content pattern detected in $($file.FullName)."
            }
        }
    }

    $actualHash = Get-SkillContentHash -Root $skillRoot
    if ($actualHash -ne [string]$skill.contentSha256) {
        throw "Content hash mismatch for '$($skill.name)'. Expected $($skill.contentSha256), got $actualHash."
    }

    $contractTest = Join-Path $skillRoot 'scripts\test-contract.ps1'
    if (Test-Path -LiteralPath $contractTest -PathType Leaf) {
        $pwshPath = (Get-Process -Id $PID).Path
        & $pwshPath -NoProfile -File $contractTest | Out-Host
        $contractExitCode = $LASTEXITCODE
        if ($contractExitCode -ne 0) {
            throw "Contract test failed for '$($skill.name)' with exit code $contractExitCode."
        }
    }

    $results.Add([ordered]@{
        name = [string]$skill.name
        version = [string]$skill.version
        contentSha256 = $actualHash
        contractTest = if (Test-Path -LiteralPath $contractTest -PathType Leaf) { 'PASS' } else { 'NOT_PRESENT' }
    })
}

[ordered]@{
    verdict = 'PASS'
    repository = $manifest.repository
    skillCount = $results.Count
    skills = $results
} | ConvertTo-Json -Depth 5
