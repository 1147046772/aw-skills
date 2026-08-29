#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9._-]*$')][string]$ContractId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9._-]*$')][string]$ServiceId,
    [Parameter(Mandatory)][string]$RootPath,
    [Parameter(Mandatory)][string]$ManifestOutputPath,
    [Parameter(Mandatory)][string]$OperationIndexOutputPath
)

$ErrorActionPreference = 'Stop'
$pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$httpMethods = @('get','head','options','post','put','patch','delete')

function Get-StringHash([string]$Value) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Value)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}
function Assert-Under([string]$Child, [string]$Parent, [string]$Label) {
    $childFull = [IO.Path]::GetFullPath($Child).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (!$childFull.Equals($parentFull, $pathComparison) -and !$childFull.StartsWith($parentFull + [IO.Path]::DirectorySeparatorChar, $pathComparison)) {
        throw "$Label escapes workspace: $Child"
    }
}
function Resolve-ExistingFile([string]$Path, [string]$Workspace, [string]$Label) {
    $lexical = [IO.Path]::GetFullPath($Path)
    Assert-Under $lexical $Workspace $Label
    if (!(Test-Path -LiteralPath $lexical -PathType Leaf)) { throw "$Label not found: $Path" }
    $physical = (Resolve-Path -LiteralPath $lexical).ProviderPath
    Assert-Under $physical $Workspace "$Label physical path"
    $physical
}
function Get-PortableRelative([string]$Root, [string]$Path) {
    [IO.Path]::GetRelativePath($Root, [IO.Path]::GetFullPath($Path)).Replace('\','/')
}
function Read-JsonMap([string]$Path) {
    try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 100 }
    catch { throw "OpenAPI JSON parse failed: $Path ($($_.Exception.Message))" }
}
function Get-Refs($Node) {
    $refs = [Collections.Generic.List[string]]::new()
    function Visit($Value) {
        if ($Value -is [Collections.IDictionary]) {
            foreach ($key in $Value.Keys) {
                if ([string]$key -ceq '$ref') {
                    if ($Value[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value[$key])) { throw 'Every $ref must be a non-empty string.' }
                    $refs.Add([string]$Value[$key])
                } else { Visit $Value[$key] }
            }
        } elseif ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
            foreach ($item in $Value) { Visit $item }
        }
    }
    Visit $Node
    @($refs)
}
function Assert-JsonPointer($Document, [string]$Fragment, [string]$RefText) {
    if ([string]::IsNullOrEmpty($Fragment)) { return }
    $decoded = [Uri]::UnescapeDataString($Fragment)
    if (!$decoded.StartsWith('/')) { throw "Unsupported non-JSON-Pointer fragment in local ref: $RefText" }
    $cursor = $Document
    foreach ($raw in $decoded.Substring(1).Split('/')) {
        $part = $raw.Replace('~1','/').Replace('~0','~')
        if ($cursor -is [Collections.IDictionary]) {
            if (!$cursor.Contains($part)) { throw "Unresolved JSON Pointer in local ref: $RefText" }
            $cursor = $cursor[$part]
        } elseif ($cursor -is [Collections.IList] -and $part -match '^(0|[1-9][0-9]*)$' -and [int]$part -lt $cursor.Count) {
            $cursor = $cursor[[int]$part]
        } else { throw "Unresolved JSON Pointer in local ref: $RefText" }
    }
}
function Resolve-Ref([string]$CurrentFile, [string]$RefText, [string]$Workspace) {
    if ($RefText -match '^[A-Za-z][A-Za-z0-9+.-]*:' -or $RefText.StartsWith('//')) { throw "External ref is forbidden: $RefText" }
    $parts = $RefText.Split('#',2)
    $filePart = [Uri]::UnescapeDataString($parts[0])
    $fragment = if ($parts.Count -eq 2) { $parts[1] } else { '' }
    if ([string]::IsNullOrEmpty($filePart)) { $target = $CurrentFile }
    else {
        if ([IO.Path]::IsPathRooted($filePart)) { throw "Absolute ref is forbidden: $RefText" }
        $target = Join-Path (Split-Path -Parent $CurrentFile) ($filePart -replace '/', [IO.Path]::DirectorySeparatorChar)
    }
    $resolved = Resolve-ExistingFile $target $Workspace "OpenAPI ref '$RefText'"
    if ([IO.Path]::GetExtension($resolved) -cne '.json') { throw "Only JSON OpenAPI refs are supported: $RefText" }
    [pscustomobject]@{ Path=$resolved; Fragment=$fragment }
}
function Write-AtomicJson($Value, [string]$Path) {
    if (Test-Path -LiteralPath $Path) { throw "Refusing to overwrite: $Path" }
    $parent = Split-Path -Parent $Path
    if (!(Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
    $temp = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        $json = $Value | ConvertTo-Json -Depth 100
        [IO.File]::WriteAllText($temp, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $Path
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

$workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
if (!(Test-Path -LiteralPath $workspace -PathType Container)) { throw "Workspace not found: $workspace" }
$workspace = (Resolve-Path -LiteralPath $workspace).ProviderPath
if ([IO.Path]::GetExtension($RootPath) -cne '.json') { throw 'The stable OpenAPI compiler supports JSON only; YAML is BLOCKED until a pinned parser is declared.' }
$rootCandidate = if ([IO.Path]::IsPathRooted($RootPath)) { $RootPath } else { Join-Path $workspace ($RootPath -replace '/', [IO.Path]::DirectorySeparatorChar) }
$root = Resolve-ExistingFile $rootCandidate $workspace 'OpenAPI root'
$manifestOut = [IO.Path]::GetFullPath($ManifestOutputPath)
$indexOut = [IO.Path]::GetFullPath($OperationIndexOutputPath)
Assert-Under $manifestOut $workspace 'Manifest output'
Assert-Under $indexOut $workspace 'Operation index output'
if ($manifestOut -ceq $indexOut) { throw 'Manifest and Operation index outputs must differ.' }
if (Test-Path -LiteralPath $manifestOut) { throw "Refusing to overwrite: $manifestOut" }
if (Test-Path -LiteralPath $indexOut) { throw "Refusing to overwrite: $indexOut" }

$documents = @{}
$queue = [Collections.Generic.Queue[string]]::new()
$queue.Enqueue($root)
while ($queue.Count -gt 0) {
    $current = $queue.Dequeue()
    if ($documents.ContainsKey($current)) { continue }
    $doc = Read-JsonMap $current
    $documents[$current] = $doc
    foreach ($refText in Get-Refs $doc) {
        $resolved = Resolve-Ref $current $refText $workspace
        $targetDoc = if ($documents.ContainsKey($resolved.Path)) { $documents[$resolved.Path] } else { Read-JsonMap $resolved.Path }
        Assert-JsonPointer $targetDoc $resolved.Fragment $refText
        if (!$documents.ContainsKey($resolved.Path)) { $queue.Enqueue($resolved.Path) }
    }
}

$rootDoc = $documents[$root]
if (!$rootDoc.Contains('openapi') -or [string]$rootDoc['openapi'] -notmatch '^3\.(0|1)\.') { throw 'OpenAPI root must declare OpenAPI 3.0.x or 3.1.x.' }
if (!$rootDoc.Contains('paths') -or $rootDoc['paths'] -isnot [Collections.IDictionary]) { throw 'OpenAPI root must contain a paths object.' }

$operations = [Collections.Generic.List[object]]::new()
$operationIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($pathKey in @($rootDoc['paths'].Keys | Sort-Object -CaseSensitive)) {
    $pathItem = $rootDoc['paths'][$pathKey]
    if ($pathItem -isnot [Collections.IDictionary]) { throw "OpenAPI path item must be an object: $pathKey" }
    if ($pathItem.Contains('$ref')) { throw "Referenced path items are not supported by the stable compiler: $pathKey" }
    foreach ($method in $httpMethods) {
        if (!$pathItem.Contains($method)) { continue }
        $operation = $pathItem[$method]
        if ($operation -isnot [Collections.IDictionary]) { throw "OpenAPI operation must be an object: $method $pathKey" }
        if (!$operation.Contains('operationId') -or [string]::IsNullOrWhiteSpace([string]$operation['operationId'])) { throw "operationId is required: $method $pathKey" }
        $operationId = [string]$operation['operationId']
        if (!$operationIds.Add($operationId)) { throw "Duplicate operationId: $operationId" }
        $external = $false
        if ($operation.Contains('x-api-test-external')) {
            if ($operation['x-api-test-external'] -isnot [bool]) { throw "x-api-test-external must be boolean: $operationId" }
            $external = [bool]$operation['x-api-test-external']
        }
        $traceability = @()
        if ($operation.Contains('x-api-test-traceability')) {
            $declared = $operation['x-api-test-traceability']
            if ($declared -is [string]) { $traceability = @([string]$declared) }
            elseif ($declared -is [Collections.IEnumerable]) { $traceability = @($declared | ForEach-Object { if ($_ -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$_)) { throw "Invalid x-api-test-traceability: $operationId" }; [string]$_ }) }
            else { throw "Invalid x-api-test-traceability: $operationId" }
        }
        $operations.Add([ordered]@{
            id=$operationId
            method=$method.ToUpperInvariant()
            pathOrOperation=[string]$pathKey
            effect=if ($method -in @('get','head','options')) { 'READ' } else { 'WRITE' }
            external=$external
            traceabilityKeys=@($traceability | Sort-Object -Unique -CaseSensitive)
        })
    }
}
if ($operations.Count -eq 0) { throw 'OpenAPI contract contains no supported operations.' }

$entries = @($documents.Keys | ForEach-Object {
    [ordered]@{
        path=Get-PortableRelative $workspace $_
        sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()
        role=if (([string]$_).Equals([string]$root,$pathComparison)) { 'ROOT' } else { 'REFERENCE' }
    }
} | Sort-Object { [string]$_['path'] } -CaseSensitive)
$lines = ($entries | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join ''
$compilerHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
$producer = [ordered]@{ kind='OPENAPI_JSON_COMPILER'; id='api-test.openapi-json.v1'; sha256=$compilerHash }
$manifest = [ordered]@{
    schemaVersion='2.0'; contractId=$ContractId; format='openapi'; root=Get-PortableRelative $workspace $root
    files=$entries; externalRefs=@(); transitiveLocalRefsResolved=$true; combinedSha256=Get-StringHash $lines; producer=$producer
}
$index = [ordered]@{
    schemaVersion='2.0'; contractId=$ContractId; serviceId=$ServiceId; contractCombinedSha256=$manifest.combinedSha256
    operations=@($operations | Sort-Object { [string]$_['id'] } -CaseSensitive); producer=$producer
}

Write-AtomicJson $manifest $manifestOut
try { Write-AtomicJson $index $indexOut }
catch { if (Test-Path -LiteralPath $manifestOut) { Remove-Item -LiteralPath $manifestOut -Force }; throw }
[pscustomobject]@{
    manifestPath=$manifestOut; manifestSha256=(Get-FileHash -LiteralPath $manifestOut -Algorithm SHA256).Hash.ToLowerInvariant()
    operationIndexPath=$indexOut; operationIndexSha256=(Get-FileHash -LiteralPath $indexOut -Algorithm SHA256).Hash.ToLowerInvariant()
    combinedSha256=$manifest.combinedSha256; operationCount=$operations.Count; fileCount=$entries.Count
} | ConvertTo-Json
