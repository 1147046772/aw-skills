#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectAdapterPath,
    [Parameter(Mandatory)][string]$RequestPath,
    [string[]]$EvidencePath = @(),
    [string]$ReceiptPath,
    [string]$NativeLeafSummaryPath,
    [string]$CurrentAttestationPath,
    [switch]$RequireUnexpired,
    [switch]$RequireCurrentIdentity,
    [DateTimeOffset]$AsOf = [DateTimeOffset]::UtcNow
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path $PSScriptRoot -Parent
$references = Join-Path $skillRoot 'references'
$errors = [Collections.Generic.List[string]]::new()
$pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }

function Add-Error([string]$Message) { $errors.Add($Message) }
function Read-Json([string]$Path, [string]$Label) {
    try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100 }
    catch { Add-Error "$Label is unreadable JSON: $($_.Exception.Message)"; $null }
}
function Test-Schema($Value, [string]$SchemaName, [string]$Label) {
    if ($null -eq $Value) { return $false }
    try {
        $json = $Value | ConvertTo-Json -Depth 100
        if (!(Test-Json -Json $json -SchemaFile (Join-Path $references $SchemaName) -ErrorAction Stop)) { Add-Error "$Label does not conform to $SchemaName"; return $false }
        $true
    } catch { Add-Error "$Label schema error: $($_.Exception.Message)"; $false }
}
function Get-Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-StringHash([string]$Value) {
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($Value)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}
function Set-Equal($Left, $Right) {
    $a=@($Left | ForEach-Object { [string]$_ } | Sort-Object -Unique -CaseSensitive)
    $b=@($Right | ForEach-Object { [string]$_ } | Sort-Object -Unique -CaseSensitive)
    if($a.Count -ne $b.Count){ return $false }
    for($i=0;$i -lt $a.Count;$i++){ if($a[$i] -cne $b[$i]){ return $false } }
    $true
}
function Is-Under([string]$Child,[string]$Parent) {
    $c=[IO.Path]::GetFullPath($Child).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $p=[IO.Path]::GetFullPath($Parent).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $c.Equals($p,$pathComparison) -or $c.StartsWith($p+[IO.Path]::DirectorySeparatorChar,$pathComparison)
}
function Resolve-Portable([string]$Base,[string]$Relative,[string]$Label,[switch]$AllowMissing) {
    if([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative)){ Add-Error "$Label must be a relative path"; return $null }
    $parts=@($Relative -split '[/\\]+' | Where-Object { $_ -ne '' })
    if(@($parts | Where-Object { $_ -eq '..' }).Count -gt 0){ Add-Error "$Label contains parent traversal"; return $null }
    $current=[IO.Path]::GetFullPath($Base)
    foreach($part in $parts){
        if($part -eq '.'){ continue }
        $current=Join-Path $current $part
        if(Test-Path -LiteralPath $current){
            $item=Get-Item -LiteralPath $current -Force
            if($null -ne $item.LinkType -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){ Add-Error "$Label crosses a link or reparse point"; return $null }
        }
    }
    $full=[IO.Path]::GetFullPath($current)
    if(!(Is-Under $full $Base)){ Add-Error "$Label escapes workspace"; return $null }
    if(!$AllowMissing -and !(Test-Path -LiteralPath $full)){ Add-Error "$Label does not exist: $Relative"; return $null }
    $full
}
function Resolve-WorkspaceRoot([string]$AdapterDirectory,[string]$Relative) {
    if([string]::IsNullOrWhiteSpace($Relative) -or $Relative -notmatch '^(?:\.|\.\.(?:[/\\]\.\.){0,3})$'){
        Add-Error 'adapter workspace must be dot or a bounded ancestor-only path'; return $null
    }
    $full=[IO.Path]::GetFullPath((Join-Path $AdapterDirectory $Relative))
    $root=[IO.Path]::GetPathRoot($full).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    if($full.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar).Equals($root,$pathComparison)){
        Add-Error 'adapter workspace cannot be a filesystem root'; return $null
    }
    if(!(Test-Path -LiteralPath $full -PathType Container) -or !(Is-Under $AdapterDirectory $full)){
        Add-Error 'adapter workspace does not contain the adapter directory'; return $null
    }
    $relativeAdapter=[IO.Path]::GetRelativePath($full,$AdapterDirectory).Replace('\','/')
    if($null -eq (Resolve-Portable $full $relativeAdapter 'adapter workspace path chain')){ return $null }
    $full
}
function Test-UniqueIds($Values,[string]$Label){
    $ids=@($Values | ForEach-Object { [string]$_.id })
    if($ids.Count -ne @($ids | Sort-Object -Unique -CaseSensitive).Count){ Add-Error "$Label IDs are not unique" }
}
function Test-RunnerTemplate($Runner,[string]$Workspace){
    $allowed=@('{workspace}','{requestPath}','{scenarioPath}','{evidencePath}','{artifactRoot}')
    foreach($arg in @($Runner.argvTemplate)){
        $text=[string]$arg
        if(($text.Contains('{') -or $text.Contains('}')) -and $text -cnotin $allowed){ Add-Error "runner '$($Runner.id)' contains an unknown or embedded token: $text" }
    }
    $exe=[IO.Path]::GetFileNameWithoutExtension([string]$Runner.argvTemplate[0]).ToLowerInvariant()
    $tail=@($Runner.argvTemplate | Select-Object -Skip 1 | ForEach-Object { ([string]$_).ToLowerInvariant() })
    if(($exe -in @('pwsh','powershell') -and @($tail | Where-Object { $_ -in @('-command','-c') }).Count -gt 0) -or
       ($exe -eq 'cmd' -and @($tail | Where-Object { $_ -in @('/c','/k') }).Count -gt 0) -or
       ($exe -in @('sh','bash','zsh') -and @($tail | Where-Object { $_ -eq '-c' }).Count -gt 0)){
        Add-Error "runner '$($Runner.id)' uses a shell command mode"
    }
    $null=Resolve-Portable $Workspace ([string]$Runner.cwd) "runner '$($Runner.id)' cwd"
}
function Test-DestinationObservation($Observed,$Destination,[string]$Label){
    if($null -eq $Observed -or $null -eq $Destination){ return }
    foreach($pair in @(
        @('observedScheme',$Destination.scheme),@('observedHost',$Destination.host),@('observedPort',$Destination.port),@('observedBasePath',$Destination.basePath),
        @('finalObservedScheme',$Destination.scheme),@('finalObservedHost',$Destination.host),@('finalObservedPort',$Destination.port),@('finalObservedBasePath',$Destination.basePath),
        @('networkScope',$Destination.networkScope),@('observationProviderId',$Destination.observation.providerId),@('observationCommandHash',$Destination.observation.commandHash)
    )){ if([string]$Observed.($pair[0]) -cne [string]$pair[1]){ Add-Error "$Label $($pair[0]) does not match the approved destination" } }
    if([bool]$Observed.proxyUsed -or @($Observed.redirectChain).Count -ne 0){ Add-Error "$Label used a proxy or redirect" }
    if([string]$Destination.scheme -eq 'http' -and $null -ne $Observed.tlsPeerFingerprint){ Add-Error "$Label reports a TLS peer for an HTTP destination" }
}
function Test-OpenApiPointer($Document,[string]$Fragment,[string]$RefText){
    if([string]::IsNullOrEmpty($Fragment)){return}
    $decoded=[Uri]::UnescapeDataString($Fragment)
    if(!$decoded.StartsWith('/')){Add-Error "OpenAPI ref uses an unsupported fragment: $RefText";return}
    $cursor=$Document
    foreach($raw in $decoded.Substring(1).Split('/')){
        $part=$raw.Replace('~1','/').Replace('~0','~')
        if($cursor -is [Collections.IDictionary] -and $cursor.Contains($part)){$cursor=$cursor[$part]}
        elseif($cursor -is [Collections.IList] -and $part -match '^(0|[1-9][0-9]*)$' -and [int]$part -lt $cursor.Count){$cursor=$cursor[[int]$part]}
        else{Add-Error "OpenAPI ref has an unresolved JSON Pointer: $RefText";return}
    }
}
function Get-OpenApiTruth([string]$RootFile,[string]$Workspace){
    $docs=@{}; $queue=[Collections.Generic.Queue[string]]::new(); $queue.Enqueue($RootFile)
    while($queue.Count -gt 0){
        $current=$queue.Dequeue(); if($docs.ContainsKey($current)){continue}
        try{$doc=Get-Content -LiteralPath $current -Raw|ConvertFrom-Json -AsHashtable -Depth 100}catch{Add-Error "OpenAPI JSON is unreadable: $current";return $null}
        $docs[$current]=$doc
        $refs=[Collections.Generic.List[string]]::new()
        function Visit-OpenApiNode($node){
            if($node -is [Collections.IDictionary]){foreach($k in $node.Keys){if([string]$k -ceq '$ref'){$refs.Add([string]$node[$k])}else{Visit-OpenApiNode $node[$k]}}}
            elseif($node -is [Collections.IEnumerable] -and $node -isnot [string]){foreach($item in $node){Visit-OpenApiNode $item}}
        }
        Visit-OpenApiNode $doc
        foreach($refText in $refs){
            if($refText -match '^[A-Za-z][A-Za-z0-9+.-]*:' -or $refText.StartsWith('//')){Add-Error "OpenAPI external ref is forbidden: $refText";continue}
            $refParts=$refText.Split('#',2);$filePart=[Uri]::UnescapeDataString($refParts[0]);$fragment=if($refParts.Count -eq 2){$refParts[1]}else{''}
            if([string]::IsNullOrEmpty($filePart)){$physical=$current}else{
                if([IO.Path]::IsPathRooted($filePart)){Add-Error "OpenAPI absolute ref is forbidden: $refText";continue}
                $candidate=[IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $current) ($filePart -replace '/',[IO.Path]::DirectorySeparatorChar)))
                if(!(Is-Under $candidate $Workspace) -or !(Test-Path -LiteralPath $candidate -PathType Leaf)){Add-Error "OpenAPI ref is missing or escapes workspace: $refText";continue}
                $physical=(Resolve-Path -LiteralPath $candidate).ProviderPath
                if(!(Is-Under $physical $Workspace)){Add-Error "OpenAPI ref physically escapes workspace: $refText";continue}
                if([IO.Path]::GetExtension($physical) -cne '.json'){Add-Error "OpenAPI non-JSON ref is unsupported: $refText";continue}
            }
            try{$targetDoc=if($docs.ContainsKey($physical)){$docs[$physical]}else{Get-Content -LiteralPath $physical -Raw|ConvertFrom-Json -AsHashtable -Depth 100}}catch{Add-Error "OpenAPI referenced JSON is unreadable: $refText";continue}
            Test-OpenApiPointer $targetDoc $fragment $refText
            if(!$docs.ContainsKey($physical)){$queue.Enqueue($physical)}
        }
    }
    $root=$docs[$RootFile]
    if($null -eq $root -or !$root.Contains('openapi') -or [string]$root['openapi'] -notmatch '^3\.(0|1)\.' -or !$root.Contains('paths')){Add-Error 'OpenAPI root is not supported 3.0/3.1 JSON';return $null}
    $ops=@();$ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($path in $root['paths'].Keys){
        $item=$root['paths'][$path]
        if($item.Contains('$ref')){Add-Error "OpenAPI referenced path item is unsupported: $path";continue}
        foreach($method in @('get','head','options','post','put','patch','delete')){
            if(!$item.Contains($method)){continue}
            $op=$item[$method];$id=[string]$op['operationId']
            if([string]::IsNullOrWhiteSpace($id)){Add-Error "OpenAPI operationId is missing: $method $path";continue}
            if(!$ids.Add($id)){Add-Error "OpenAPI operationId is duplicated: $id";continue}
            $external=$false;if($op.Contains('x-api-test-external')){$external=[bool]$op['x-api-test-external']}
            $trace=@();if($op.Contains('x-api-test-traceability')){$v=$op['x-api-test-traceability'];if($v -is [string]){$trace=@([string]$v)}else{$trace=@($v|ForEach-Object{[string]$_})}}
            $ops+=@{id=$id;method=$method.ToUpperInvariant();pathOrOperation=[string]$path;effect=if($method -in @('get','head','options')){'READ'}else{'WRITE'};external=$external;traceabilityKeys=@($trace|Sort-Object -Unique -CaseSensitive)}
        }
    }
    [pscustomobject]@{Files=@($docs.Keys|ForEach-Object{[IO.Path]::GetRelativePath($Workspace,$_).Replace('\','/')}|Sort-Object -Unique -CaseSensitive);Operations=$ops}
}
function Get-OperationSignatures($Operations){@($Operations|ForEach-Object{"$($_.id)|$($_.method)|$($_.pathOrOperation)|$($_.effect)|$(([bool]$_.external).ToString().ToLowerInvariant())|$(@($_.traceabilityKeys|Sort-Object -Unique -CaseSensitive)-join ',')"}|Sort-Object -CaseSensitive)}
function Get-DestinationFingerprint($Destination) {
    $line='{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}' -f $Destination.id,$Destination.serviceId,$Destination.scheme,$Destination.host,$Destination.port,$Destination.basePath,$Destination.environmentClass,$Destination.networkScope,([bool]$Destination.allowRedirects).ToString().ToLowerInvariant(),([bool]$Destination.external).ToString().ToLowerInvariant(),([bool]$Destination.production).ToString().ToLowerInvariant()
    Get-StringHash ($line+"`n")
}
function Has-SecretMaterial([string]$Path) {
    $text=Get-Content -LiteralPath $Path -Raw
    $text -match '(?i)authorization\s*[:=]\s*(bearer|basic)|cookie\s*[:=]|password\s*[:=]|secret\s*[:=]|token\s*[:=]\s*[A-Za-z0-9._-]{12,}'
}
function Compare-Attestation($Attestation,$Request,[string]$Label,$InitialAttestation) {
    if($null -eq $Attestation){ return }
    if([string]$Attestation.candidate.revision -ne [string]$Request.candidate.revision -or [string]$Attestation.candidate.sourceHash -ne [string]$Request.candidate.sourceHash -or [string]$Attestation.candidate.diffHash -ne [string]$Request.candidate.diffHash -or [string]$Attestation.candidate.buildId -ne [string]$Request.candidate.buildId){ Add-Error "$Label candidate identity drifted" }
    if([string]$Attestation.destination.id -ne [string]$Request.environment.destinationId -or [string]$Attestation.destination.serviceId -ne [string]$Request.environment.serviceId -or [string]$Attestation.destination.fingerprint -ne [string]$Request.environment.destinationFingerprint){ Add-Error "$Label destination identity drifted" }
    Test-DestinationObservation $Attestation.destination $script:destination $Label
    if([string]$Attestation.service.serviceId -ne [string]$Request.environment.serviceId -or [string]$Attestation.service.identityHash -ne [string]$Request.environment.serviceIdentityHash){ Add-Error "$Label service identity drifted" }
    if([string]$Attestation.contract.contractId -ne [string]$Request.environment.contractId -or [string]$Attestation.contract.manifestHash -ne [string]$Request.environment.contractManifestHash -or [string]$Attestation.contract.combinedSha256 -ne [string]$Request.environment.contractCombinedSha256 -or [string]$Attestation.contract.operationIndexHash -ne [string]$Request.environment.operationIndexHash){ Add-Error "$Label contract identity drifted" }
    if([string]$Attestation.authProfileFingerprint -ne [string]$Request.environment.authProfileFingerprint){ Add-Error "$Label authentication profile drifted" }
    if([string]$Attestation.runtime.kind -eq 'container' -and [string]$Attestation.runtime.imageId -ne [string]$Attestation.runtime.containerImageId){ Add-Error "$Label image/container identity mismatch" }
    if($null -ne $InitialAttestation -and [string]$Attestation.mutationStateHash -ne [string]$InitialAttestation.mutationStateHash){ Add-Error "$Label mutation state drifted" }
}

$adapterFull=[IO.Path]::GetFullPath($ProjectAdapterPath)
$requestFull=[IO.Path]::GetFullPath($RequestPath)
$adapter=Read-Json $adapterFull 'project adapter'
$request=Read-Json $requestFull 'test request'
$null=Test-Schema $adapter 'project.schema.json' 'project adapter'
$null=Test-Schema $request 'test-request.schema.json' 'test request'
if($null -eq $adapter -or $null -eq $request){ throw ($errors -join [Environment]::NewLine) }

$adapterDir=Split-Path $adapterFull -Parent
$workspace=Resolve-WorkspaceRoot $adapterDir ([string]$adapter.roots.workspace)
if($null -eq $workspace){ throw ($errors -join [Environment]::NewLine) }
if(!(Is-Under $adapterFull $workspace) -or !(Is-Under $requestFull $workspace)){ Add-Error 'adapter or request is outside workspace' }
$adapterHash=Get-Hash $adapterFull
$requestHash=Get-Hash $requestFull
if([string]$request.projectAdapter.sha256 -ne $adapterHash -or [string]$request.projectAdapter.adapterId -ne [string]$adapter.adapterId -or [string]$request.projectAdapter.adapterVersion -ne [string]$adapter.adapterVersion){ Add-Error 'request adapter identity mismatch' }
Test-UniqueIds $adapter.runners 'runner'
foreach($declaredRunner in $adapter.runners){ Test-RunnerTemplate $declaredRunner $workspace }

$destinationIds=@($adapter.destinations | ForEach-Object { [string]$_.id })
if($destinationIds.Count -ne @($destinationIds | Sort-Object -Unique -CaseSensitive).Count){ Add-Error 'destination IDs are not unique' }
$destination=@($adapter.destinations | Where-Object { [string]$_.id -eq [string]$request.environment.destinationId })
if($destination.Count -ne 1){ Add-Error 'request destination is not uniquely declared by adapter' } else {
    $destination=$destination[0]
    $fingerprint=Get-DestinationFingerprint $destination
    if($fingerprint -ne [string]$request.environment.destinationFingerprint){ Add-Error 'request destination fingerprint mismatch' }
    if([string]$destination.serviceId -ne [string]$request.environment.serviceId -or [string]$destination.environmentClass -ne [string]$request.environment.class){ Add-Error 'request destination service or environment class mismatch' }
    if([bool]$destination.production -ne ([string]$request.environment.class -eq 'production')){ Add-Error 'destination production classification mismatch' }
    if(([bool]$destination.external) -and ![bool]$request.authorization.externalCall){ Add-Error 'external destination is not authorized' }
    if(([bool]$destination.production) -and ![bool]$request.authorization.productionAccess){ Add-Error 'production destination is not authorized' }
}

$contractIds=@($adapter.contracts | ForEach-Object { [string]$_.id })
if($contractIds.Count -ne @($contractIds | Sort-Object -Unique -CaseSensitive).Count){ Add-Error 'contract IDs are not unique' }
$contract=@($adapter.contracts | Where-Object { [string]$_.id -eq [string]$request.environment.contractId })
$operationByKey=@{}; $allOperationIds=@(); $manifest=$null; $index=$null; $openApiTruth=$null
if($contract.Count -ne 1){ Add-Error 'request contract is not uniquely declared by adapter' } else {
    $contract=$contract[0]
    if([string]$contract.format -in @('graphql','grpc','websocket')){Add-Error "BLOCKED_UNSUPPORTED contract format in stable release: $($contract.format)"}
    if([string]$contract.serviceId -ne [string]$request.environment.serviceId){ Add-Error 'contract service does not match request service' }
    $manifestPath=Resolve-Portable $workspace ([string]$contract.manifest.path) 'contract manifest'
    $indexPath=Resolve-Portable $workspace ([string]$contract.operationIndex.path) 'operation index'
    if($manifestPath){
        if((Get-Hash $manifestPath) -ne [string]$contract.manifest.sha256 -or [string]$request.environment.contractManifestHash -ne [string]$contract.manifest.sha256){ Add-Error 'contract manifest hash mismatch' }
        $manifest=Read-Json $manifestPath 'contract manifest'; $null=Test-Schema $manifest 'contract-manifest.schema.json' 'contract manifest'
        if($manifest){
            if([string]$manifest.contractId -ne [string]$contract.id -or [string]$manifest.format -ne [string]$contract.format){ Add-Error 'contract manifest identity mismatch' }
            $manifestPaths=@($manifest.files | ForEach-Object { [string]$_.path })
            if($manifestPaths.Count -ne @($manifestPaths | Sort-Object -Unique -CaseSensitive).Count){ Add-Error 'contract manifest contains duplicate paths' }
            $rootEntries=@($manifest.files | Where-Object role -eq 'ROOT')
            if($rootEntries.Count -ne 1 -or ($rootEntries.Count -eq 1 -and [string]$rootEntries[0].path -cne [string]$manifest.root)){ Add-Error 'contract manifest root entry is not exact' }
            $lines=''
            foreach($entry in @($manifest.files | Sort-Object path -CaseSensitive)){
                $file=Resolve-Portable $workspace ([string]$entry.path) "contract file '$($entry.path)'"
                if($file -and (Get-Hash $file) -ne [string]$entry.sha256){ Add-Error "contract file hash mismatch: $($entry.path)" }
                $lines += "$($entry.path)`t$($entry.sha256)`n"
            }
            $actualCombinedSha256 = Get-StringHash $lines
            if($actualCombinedSha256 -ne [string]$manifest.combinedSha256 -or [string]$manifest.combinedSha256 -ne [string]$request.environment.contractCombinedSha256){
                Add-Error "contract combined hash mismatch (actual=$actualCombinedSha256 manifest=$($manifest.combinedSha256) request=$($request.environment.contractCombinedSha256))"
            }
            if([string]$contract.format -eq 'openapi'){
                if([string]$manifest.producer.kind -ne 'OPENAPI_JSON_COMPILER'){ Add-Error 'OpenAPI manifest is not compiler-produced' }
                $rootFile=Resolve-Portable $workspace ([string]$manifest.root) 'OpenAPI root'
                if($rootFile){$openApiTruth=Get-OpenApiTruth $rootFile $workspace;if($openApiTruth -and !(Set-Equal @($openApiTruth.Files) $manifestPaths)){Add-Error 'OpenAPI transitive local-reference file set does not match manifest'}}
            }
        }
    }
    if($indexPath){
        if((Get-Hash $indexPath) -ne [string]$contract.operationIndex.sha256 -or [string]$request.environment.operationIndexHash -ne [string]$contract.operationIndex.sha256){ Add-Error 'operation index hash mismatch' }
        $index=Read-Json $indexPath 'operation index'; $null=Test-Schema $index 'operation-index.schema.json' 'operation index'
        if($index){
            if([string]$index.contractId -ne [string]$contract.id -or [string]$index.serviceId -ne [string]$contract.serviceId -or [string]$index.contractCombinedSha256 -ne [string]$request.environment.contractCombinedSha256){ Add-Error 'operation index identity mismatch' }
            if([string]$contract.format -eq 'openapi' -and ([string]$index.producer.kind -ne 'OPENAPI_JSON_COMPILER' -or [string]$index.producer.id -cne [string]$manifest.producer.id -or [string]$index.producer.sha256 -cne [string]$manifest.producer.sha256)){ Add-Error 'OpenAPI manifest and Operation index producer identity mismatch' }
            foreach($op in $index.operations){
                $key="$($contract.id)|$($op.id)"
                if($operationByKey.ContainsKey($key)){ Add-Error "duplicate operation ID: $($op.id)" } else { $operationByKey[$key]=$op; $allOperationIds += [string]$op.id }
                $derived=if([string]$op.method -in @('GET','HEAD','OPTIONS','QUERY')){'READ'}elseif([string]$op.method -in @('POST','PUT','PATCH','DELETE','MUTATION')){'WRITE'}else{$null}
                if($null -ne $derived -and [string]$op.effect -ne $derived){ Add-Error "operation effect contradicts method: $($op.id)" }
            }
            if([string]$contract.format -eq 'openapi' -and $openApiTruth -and !(Set-Equal (Get-OperationSignatures $index.operations) (Get-OperationSignatures $openApiTruth.Operations))){ Add-Error 'Operation index does not exactly match OpenAPI contract truth' }
        }
    }
    if($null -ne $contract.traceability){
        $tracePath=Resolve-Portable $workspace ([string]$contract.traceability.path) 'traceability contract'
        if($tracePath){
            if((Get-Hash $tracePath) -ne [string]$contract.traceability.sha256){ Add-Error 'traceability hash mismatch' }
            $trace=Read-Json $tracePath 'traceability contract'; $null=Test-Schema $trace 'traceability.schema.json' 'traceability contract'
            if($trace){
                if([string]$trace.contractId -ne [string]$contract.id -or [string]$trace.serviceId -ne [string]$contract.serviceId){ Add-Error 'traceability identity mismatch' }
                foreach($mapping in $trace.mappings){ foreach($oid in $mapping.apiOperationIds){ if([string]$oid -notin $allOperationIds){ Add-Error "traceability references unknown operation: $oid" } } }
                if($index){
                    $declaredTracePairs=@($trace.mappings|ForEach-Object{$business=[string]$_.businessOperationId;@($_.apiOperationIds)|ForEach-Object{"$business|$([string]$_)"}})
                    $indexedTracePairs=@($index.operations|ForEach-Object{$operationId=[string]$_.id;@($_.traceabilityKeys)|ForEach-Object{"$([string]$_)|$operationId"}})
                    if(!(Set-Equal $declaredTracePairs $indexedTracePairs)){Add-Error 'Operation index traceability does not exactly match traceability contract'}
                }
            }
        }
    } elseif($index -and @($index.operations|ForEach-Object{$_.traceabilityKeys}|Where-Object{!([string]::IsNullOrWhiteSpace([string]$_))}).Count -gt 0){
        Add-Error 'Operation index declares traceability keys but adapter has no traceability contract'
    }
}

$initialAttestationPath=Resolve-Portable $workspace ([string]$request.currentAttestation.path) 'request attestation'
$initialAttestation=$null
if($initialAttestationPath){
    if((Get-Hash $initialAttestationPath) -ne [string]$request.currentAttestation.sha256){ Add-Error 'request attestation hash mismatch' }
    $initialAttestation=Read-Json $initialAttestationPath 'request attestation'; $null=Test-Schema $initialAttestation 'current-attestation.schema.json' 'request attestation'
    Compare-Attestation $initialAttestation $request 'request attestation' $null
}
if($RequireCurrentIdentity -and [string]::IsNullOrWhiteSpace($CurrentAttestationPath)){ Add-Error 'RequireCurrentIdentity requires CurrentAttestationPath' }
if(![string]::IsNullOrWhiteSpace($CurrentAttestationPath)){
    $currentFull=[IO.Path]::GetFullPath($CurrentAttestationPath)
    if(!(Is-Under $currentFull $workspace)){ Add-Error 'current attestation is outside workspace' } else {
        $current=Read-Json $currentFull 'current attestation'; $null=Test-Schema $current 'current-attestation.schema.json' 'current attestation'
        Compare-Attestation $current $request 'current attestation' $initialAttestation
    }
}

$catalogPath=Resolve-Portable $workspace ([string]$request.testPlan.catalog.path) 'catalog'
$catalog=$null; $scenarioById=@{}; $scenarioPathById=@{}; $catalogIds=@()
if($catalogPath){
    if((Get-Hash $catalogPath) -ne [string]$request.testPlan.catalog.sha256){ Add-Error 'catalog hash mismatch' }
    $catalog=Read-Json $catalogPath 'catalog'; $null=Test-Schema $catalog 'test-catalog.schema.json' 'catalog'
    if($catalog){
        $catalogIds=@($catalog.scenarios | ForEach-Object { [string]$_.id })
        if($catalogIds.Count -ne @($catalogIds | Sort-Object -Unique -CaseSensitive).Count){ Add-Error 'catalog scenario IDs are not unique' }
        foreach($relation in $catalog.relations){if([string]$relation.from -notin $catalogIds -or [string]$relation.to -notin $catalogIds){Add-Error "catalog relation references an unknown scenario: $($relation.from)->$($relation.to)"}}
        foreach($entry in $catalog.scenarios){
            $scenarioPath=Resolve-Portable $workspace ([string]$entry.path) "scenario '$($entry.id)'"
            if(!$scenarioPath){ continue }
            if((Get-Hash $scenarioPath) -ne [string]$entry.sha256){ Add-Error "scenario hash mismatch: $($entry.id)" }
            $scenario=Read-Json $scenarioPath "scenario '$($entry.id)'"; $null=Test-Schema $scenario 'scenario.schema.json' "scenario '$($entry.id)'"
            if(!$scenario){ continue }
            if([string]$scenario.id -ne [string]$entry.id){ Add-Error "scenario ID mismatch: $($entry.id)" }
            $scenarioById[[string]$entry.id]=$scenario; $scenarioPathById[[string]$entry.id]=$scenarioPath
            $runner=@($adapter.runners | Where-Object { [string]$_.id -eq [string]$scenario.runtime.runnerId })
            if($runner.Count -ne 1){ Add-Error "scenario runner is not uniquely declared: $($entry.id)" } else {
                if([string]$scenario.protocol -notin @($runner[0].protocols) -or [string]$scenario.testType -notin @($runner[0].testTypes)){ Add-Error "runner is incompatible: $($entry.id)" }
                if(@($scenario.runtime.capabilities | Where-Object { [string]$_ -notin @($runner[0].capabilities) }).Count -gt 0){ Add-Error "runner lacks a required scenario capability: $($entry.id)" }
            }
            Test-UniqueIds $scenario.preconditions "scenario '$($entry.id)' precondition"
            Test-UniqueIds $scenario.steps "scenario '$($entry.id)' step"
            Test-UniqueIds $scenario.assertions "scenario '$($entry.id)' assertion"
            Test-UniqueIds $scenario.stopConditions "scenario '$($entry.id)' stop condition"
            $scenarioOperationIds=@($scenario.operations | ForEach-Object { [string]$_.id })
            if($scenarioOperationIds.Count -ne @($scenarioOperationIds | Sort-Object -Unique -CaseSensitive).Count){ Add-Error "scenario operation IDs are not unique: $($entry.id)" }
            $opForScenario=@{}
            foreach($declared in $scenario.operations){
                $key="$($declared.contractId)|$($declared.id)"
                if(!$operationByKey.ContainsKey($key)){ Add-Error "scenario references unknown operation: $($entry.id)/$($declared.id)"; continue }
                $indexed=$operationByKey[$key]; $opForScenario[[string]$declared.id]=$indexed
                if([string]$declared.contractId -ne [string]$request.environment.contractId -or [string]$declared.serviceId -ne [string]$request.environment.serviceId -or [string]$declared.method -ne [string]$indexed.method -or [string]$declared.pathOrOperation -cne [string]$indexed.pathOrOperation){ Add-Error "scenario operation does not exactly match index: $($entry.id)/$($declared.id)" }
            }
            $usedPermissions=@{businessWrite=$false;testDataMutation=$false;externalCall=$false;accountOrCredentialChange=$false}
            foreach($step in $scenario.steps){
                $action=[string]$step.action; $mutation=[string]$step.mutationClass
                if($action -in @('request','poll')){
                    if($null -eq $step.operationId -or !$opForScenario.ContainsKey([string]$step.operationId)){ Add-Error "step references unknown operation: $($entry.id)/$($step.id)"; continue }
                    $op=$opForScenario[[string]$step.operationId]; $external=[bool]$op.external -or ($destination.Count -eq 1 -and [bool]$destination.external)
                    if($action -eq 'poll' -and [string]$op.effect -ne 'READ'){ Add-Error "poll must use a read operation: $($entry.id)/$($step.id)" }
                    if([string]$op.effect -eq 'READ' -and $mutation -ne 'none'){ Add-Error "read operation is mislabeled as mutation: $($entry.id)/$($step.id)" }
                    if([string]$op.effect -eq 'WRITE' -and $mutation -eq 'none'){ Add-Error "write operation is mislabeled as none: $($entry.id)/$($step.id)" }
                    if($external -and $mutation -ne 'external-call'){ Add-Error "external operation must declare external-call: $($entry.id)/$($step.id)" }
                    if(!$external -and $mutation -eq 'external-call'){ Add-Error "internal operation cannot declare external-call: $($entry.id)/$($step.id)" }
                } elseif($action -eq 'assert' -and ($null -ne $step.operationId -or $mutation -ne 'none')){ Add-Error "assert step cannot dispatch or mutate: $($entry.id)/$($step.id)" }
                switch($mutation){ 'business-write'{$usedPermissions.businessWrite=$true}; 'test-data'{$usedPermissions.testDataMutation=$true}; 'external-call'{$usedPermissions.externalCall=$true}; 'account-or-credential'{$usedPermissions.accountOrCredentialChange=$true} }
            }
            foreach($permission in $usedPermissions.Keys){
                if($usedPermissions[$permission] -and (![bool]$scenario.permissions.$permission -or ![bool]$request.authorization.$permission)){ Add-Error "mutation permission is missing: $($entry.id)/$permission" }
                if(!$usedPermissions[$permission] -and [bool]$scenario.permissions.$permission){ Add-Error "scenario declares unused mutation permission: $($entry.id)/$permission" }
            }
            $hasMutation=@($usedPermissions.Values | Where-Object { $_ }).Count -gt 0
            if($hasMutation -and $runner.Count -eq 1 -and [string]$runner[0].mutationClass -eq 'NONE'){ Add-Error "mutation scenario uses a read-only runner: $($entry.id)" }
            if($hasMutation -and $null -eq $scenario.writePolicy){ Add-Error "mutation scenario lacks write policy: $($entry.id)" }
            if(($usedPermissions.businessWrite -or $usedPermissions.testDataMutation) -and ([string]$scenario.fixture.mode -eq 'none' -or ![bool]$scenario.fixture.ownsData)){ Add-Error "data mutation lacks owned fixture: $($entry.id)" }
            foreach($permission in @('businessWrite','testDataMutation','externalCall','productionAccess','accountOrCredentialChange')){ if([bool]$scenario.permissions.$permission -and ![bool]$request.authorization.$permission){ Add-Error "scenario permission exceeds request: $($entry.id)/$permission" } }
        }
        $catalogOps=@($scenarioById.Values | ForEach-Object { $_.operations } | ForEach-Object { [string]$_.id } | Sort-Object -Unique -CaseSensitive)
        $expectedOps=if([string]$catalog.coveragePolicy.mode -eq 'ALL_CONTRACT_OPERATIONS'){@($allOperationIds | Sort-Object -Unique -CaseSensitive)}else{@($catalog.coveragePolicy.activeOperationIds)}
        if(!(Set-Equal $catalogOps $expectedOps)){ Add-Error 'catalog operation coverage does not match coverage policy' }
    }
}

if(@($request.testPlan.fullSuiteTriggers).Count -gt 0 -and [string]$request.testPlan.strategy -ne 'FULL'){ Add-Error 'full-suite trigger requires FULL strategy' }
$expectedSelected=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
if([string]$request.testPlan.strategy -eq 'FULL'){ foreach($id in $catalogIds){$null=$expectedSelected.Add($id)} } else {
    $changed=@($request.testPlan.changedImpactKeys)
    foreach($id in $catalogIds){ if(@($scenarioById[$id].impact.keys | Where-Object { [string]$_ -in $changed }).Count -gt 0){$null=$expectedSelected.Add($id)} }
    if($expectedSelected.Count -eq 0){ Add-Error 'IMPACT selection has no seed scenario' }
    for($depth=0;$depth -lt [int]$request.testPlan.upstreamDepth;$depth++){ foreach($rel in $catalog.relations){ if($expectedSelected.Contains([string]$rel.to) -and @($rel.impactKeys | Where-Object { [string]$_ -in $changed }).Count -gt 0){$null=$expectedSelected.Add([string]$rel.from)} } }
    for($depth=0;$depth -lt [int]$request.testPlan.downstreamDepth;$depth++){ foreach($rel in $catalog.relations){ if($expectedSelected.Contains([string]$rel.from) -and @($rel.impactKeys | Where-Object { [string]$_ -in $changed }).Count -gt 0){$null=$expectedSelected.Add([string]$rel.to)} } }
}
if(!(Set-Equal @($expectedSelected) @($request.testPlan.selectedScenarioIds))){ Add-Error 'selected scenarios do not equal computed boundary' }

$evidenceRoot=Resolve-Portable $workspace ([string]$adapter.evidenceRoot) 'adapter evidence root' -AllowMissing
$outputRoot=Resolve-Portable $workspace ([string]$request.output.root) 'output root' -AllowMissing
if($evidenceRoot -and $outputRoot -and !(Is-Under $outputRoot $evidenceRoot)){ Add-Error 'output root is outside adapter evidence root' }
if($outputRoot -and !(Is-Under $requestFull $outputRoot)){ Add-Error 'test request is outside its output root' }
$evidenceByScenario=@{}
foreach($ep in $EvidencePath){
    $full=[IO.Path]::GetFullPath($ep)
    if($outputRoot -and !(Is-Under $full $outputRoot)){ Add-Error 'evidence is outside output root'; continue }
    $ev=Read-Json $full 'scenario evidence'; $null=Test-Schema $ev 'evidence.schema.json' 'scenario evidence'
    if(!$ev){continue}; if(Has-SecretMaterial $full){ Add-Error 'scenario evidence contains secret-like material' }
    $sid=[string]$ev.scope.scenarioId
    $expectedEvidence=if($outputRoot){[IO.Path]::GetFullPath((Join-Path (Join-Path $outputRoot $sid) ([string]$request.output.evidenceFileName)))}else{$null}
    if($null -eq $expectedEvidence -or !$full.Equals($expectedEvidence,$pathComparison)){ Add-Error "evidence path is not canonical: $sid" }
    if($evidenceByScenario.ContainsKey($sid)){ Add-Error "duplicate evidence: $sid" }else{$evidenceByScenario[$sid]=@{value=$ev;path=$full}}
    if($sid -notin @($request.testPlan.selectedScenarioIds) -or !$scenarioById.ContainsKey($sid)){ Add-Error "evidence outside selected boundary: $sid"; continue }
    if([string]$ev.requestId -ne [string]$request.requestId -or [string]$ev.scope.requestHash -ne $requestHash){ Add-Error "evidence request identity mismatch: $sid" }
    if([string]$ev.scope.projectAdapterHash -ne $adapterHash -or [string]$ev.scope.catalogHash -ne (Get-Hash $catalogPath) -or [string]$ev.scope.scenarioHash -ne (Get-Hash $scenarioPathById[$sid])){ Add-Error "evidence input hash mismatch: $sid" }
    foreach($pair in @(@('candidateSourceHash',$request.candidate.sourceHash),@('serviceIdentityHash',$request.environment.serviceIdentityHash),@('destinationFingerprint',$request.environment.destinationFingerprint),@('contractManifestHash',$request.environment.contractManifestHash),@('contractCombinedSha256',$request.environment.contractCombinedSha256),@('operationIndexHash',$request.environment.operationIndexHash),@('attestationHash',$request.currentAttestation.sha256))){ if([string]$ev.scope.($pair[0]) -ne [string]$pair[1]){ Add-Error "evidence $($pair[0]) mismatch: $sid" } }
    if([string]$ev.runtime.destinationId -ne [string]$request.environment.destinationId -or [string]$ev.runtime.destinationFingerprint -ne [string]$request.environment.destinationFingerprint -or [string]$ev.runtime.finalDestinationFingerprint -ne [string]$request.environment.destinationFingerprint -or [bool]$ev.runtime.redirected){ Add-Error "runtime destination mismatch or redirect: $sid" }
    Test-DestinationObservation $ev.runtime $destination "evidence runtime '$sid'"
    if($initialAttestation -and ([string]$ev.runtime.observationProviderId -cne [string]$initialAttestation.destination.observationProviderId -or [string]$ev.runtime.observationCommandHash -cne [string]$initialAttestation.destination.observationCommandHash -or !(Set-Equal @($ev.runtime.resolvedAddresses) @($initialAttestation.destination.resolvedAddresses)))){ Add-Error "evidence destination observation differs from attestation: $sid" }
    if([string]$ev.runtime.attestationHash -ne [string]$request.currentAttestation.sha256 -or [string]$ev.runtime.serviceIdentityHash -ne [string]$request.environment.serviceIdentityHash -or [string]$ev.runtime.authProfileFingerprint -ne [string]$request.environment.authProfileFingerprint){ Add-Error "runtime identity mismatch: $sid" }
    if($null -ne $ev.runtime.imageRef -and ([string]$ev.runtime.imageId -ne [string]$ev.runtime.containerImageId -or $null -eq $ev.runtime.containerId)){ Add-Error "Docker runtime identity is incomplete or mismatched: $sid" }
    $scenario=$scenarioById[$sid]; $allowed=@($scenario.operations | ForEach-Object { [string]$_.id })
    if(@($ev.scope.observedOperations | Where-Object { [string]$_ -notin $allowed }).Count -gt 0){ Add-Error "evidence observed undeclared operation: $sid" }
    foreach($fact in $ev.requests){
        $declared=@($scenario.operations | Where-Object { [string]$_.id -eq [string]$fact.operationId })
        if($declared.Count -ne 1){ Add-Error "request observed undeclared operation: $sid/$($fact.id)"; continue }
        $indexed=$operationByKey["$($declared[0].contractId)|$($declared[0].id)"]
        if([string]$fact.method -ne [string]$indexed.method){ Add-Error "request method mismatch: $sid/$($fact.id)" }
        if([string]$indexed.effect -eq 'WRITE' -and [int]$fact.attempt -ne 1){ Add-Error "write operation attempted more than once: $sid/$($fact.id)" }
        if([string]$indexed.effect -eq 'READ' -and [int]$fact.attempt -gt (1+[int]$request.execution.readRetryLimit)){ Add-Error "read retry limit exceeded: $sid/$($fact.id)" }
    }
    if(!(Set-Equal @($ev.assertions | ForEach-Object { [string]$_.id }) @($scenario.assertions | ForEach-Object { [string]$_.id }))){ Add-Error "evidence assertion set mismatch: $sid" }
    foreach($a in $ev.assertions){
        $declared=@($scenario.assertions | Where-Object { [string]$_.id -eq [string]$a.id }); if($declared.Count -ne 1){continue}
        if([string]$a.kind -ne [string]$declared[0].kind -or [string]$a.severity -ne [string]$declared[0].severity -or !(Set-Equal @($a.impactKeys) @($declared[0].impactKeys))){ Add-Error "evidence assertion contract mismatch: $sid/$($a.id)" }
        if([string]$a.status -eq 'FAIL'){ $expected=Get-StringHash "$sid`t$($a.id)`n"; if([string]$a.findingFingerprint -ne $expected){ Add-Error "finding fingerprint mismatch: $sid/$($a.id)" } } elseif($null -ne $a.findingFingerprint){ Add-Error "non-failing assertion carries fingerprint: $sid/$($a.id)" }
    }
    foreach($artifact in $ev.artifacts){ $artifactFull=Resolve-Portable $workspace ([string]$artifact.path) "artifact '$sid/$($artifact.id)'"; if($artifactFull -and $outputRoot -and !(Is-Under $artifactFull $outputRoot)){Add-Error "artifact outside output root: $sid/$($artifact.id)"}elseif($artifactFull -and ((Get-Hash $artifactFull) -ne [string]$artifact.sha256 -or (Get-Item -LiteralPath $artifactFull).Length -ne [long]$artifact.sizeBytes)){Add-Error "artifact identity mismatch: $sid/$($artifact.id)"} }
}

if($ReceiptPath){
    if([string]$adapter.evidenceMode -ne 'GENERIC_CANONICAL'){ Add-Error 'PROJECT_NATIVE_PARENT cannot consume a generic receipt' }
    $receiptFull=[IO.Path]::GetFullPath($ReceiptPath)
    $expectedReceipt=if($outputRoot){[IO.Path]::GetFullPath((Join-Path $outputRoot ([string]$request.output.receiptFileName)))}else{$null}
    if($null -eq $expectedReceipt -or !$receiptFull.Equals($expectedReceipt,$pathComparison)){ Add-Error 'test receipt path does not match the request output contract' }
    $receipt=Read-Json $receiptFull 'test receipt'; $null=Test-Schema $receipt 'test-receipt.schema.json' 'test receipt'
    if($receipt){
        if([string]$receipt.input.requestSha256 -ne $requestHash -or [string]$receipt.input.projectAdapterSha256 -ne $adapterHash -or [string]$receipt.input.catalogSha256 -ne (Get-Hash $catalogPath)){ Add-Error 'receipt input identity mismatch' }
        foreach($pair in @(@('candidateSourceHash',$request.candidate.sourceHash),@('serviceIdentityHash',$request.environment.serviceIdentityHash),@('destinationFingerprint',$request.environment.destinationFingerprint),@('contractManifestHash',$request.environment.contractManifestHash),@('contractCombinedSha256',$request.environment.contractCombinedSha256),@('operationIndexHash',$request.environment.operationIndexHash),@('attestationHash',$request.currentAttestation.sha256))){ if([string]$receipt.subject.($pair[0]) -ne [string]$pair[1]){ Add-Error "receipt $($pair[0]) mismatch" } }
        if(!(Set-Equal @($receipt.selection.selectedScenarioIds) @($request.testPlan.selectedScenarioIds)) -or !(Set-Equal @($receipt.selection.executedScenarioIds) @($evidenceByScenario.Keys))){ Add-Error 'receipt selected or executed boundary mismatch' }
        $required=0;$passed=0;$failed=0;$blocked=0;$advisory=0;$unresolved=0;$blockerCount=0;$mutationCount=0;$hasRuntime=$false;$hasMutation=$false
        $scenarioSignatures=@();$findingSignatures=@();$blockerSignatures=@();$mutationSummary=@();$runtimeSignatures=@();$requiredImpact=@();$coveredImpact=@();$targetOperations=@();$testedOperations=@();$started=@();$finished=@()
        foreach($sid in @($request.testPlan.selectedScenarioIds)){
            if(!$evidenceByScenario.ContainsKey([string]$sid)){continue};$fact=$evidenceByScenario[[string]$sid];$ev=$fact.value;$scenario=$scenarioById[[string]$sid]
            $started+=[DateTimeOffset]::Parse([string]$ev.timing.startedAt);$finished+=[DateTimeOffset]::Parse([string]$ev.timing.finishedAt)
            $hasRuntime=$hasRuntime -or @($ev.requests).Count -gt 0 -or $null -ne $ev.runtime.authProfileFingerprint
            $targetOperations+=@($scenario.operations|ForEach-Object{[string]$_.id});$testedOperations+=@($ev.scope.observedOperations)
            foreach($declaredAssertion in $scenario.assertions){if([string]$declaredAssertion.severity -eq 'REQUIRED'){$requiredImpact+=@($declaredAssertion.impactKeys)}}
            foreach($a in $ev.assertions){
                if([string]$a.severity -eq 'REQUIRED'){$required++;if([string]$a.status -eq 'PASS'){$passed++;$coveredImpact+=@($a.impactKeys)}elseif([string]$a.status -eq 'FAIL'){$failed++;$coveredImpact+=@($a.impactKeys)}else{$blocked++}}
                elseif([string]$a.status -ne 'PASS'){$advisory++}
                if([string]$a.status -eq 'FAIL'){$findingSignatures+="$sid|$($a.id)|$(if([string]$a.severity -eq 'REQUIRED'){'PRODUCT_DEFECT'}else{'ADVISORY'})|$($a.findingFingerprint)|$(Get-Hash $fact.path)"}
            }
            foreach($b in $ev.blockers){$blockerCount++;$blockerSignatures+="$sid|$($b.code)|$($b.reason)|$($b.nextStep)"}
            foreach($m in $ev.mutations){$mutationCount++;$hasMutation=$true;if([string]$m.resolution -eq 'UNRESOLVED'){$unresolved++};$mutationSummary+="$sid/$($m.id):$($m.resolution)"}
            $reqAssertions=@($ev.assertions|Where-Object{[string]$_.severity -eq 'REQUIRED'})
            $relativeEvidence=[IO.Path]::GetRelativePath($workspace,$fact.path).Replace('\','/')
            $scenarioSignatures+="$sid|$($ev.scope.scenarioHash)|$relativeEvidence|$(Get-Hash $fact.path)|$($ev.verdict)|$($reqAssertions.Count)|$(@($reqAssertions|Where-Object status -eq 'PASS').Count)|$(@($reqAssertions|Where-Object status -eq 'FAIL').Count)|$(@($reqAssertions|Where-Object status -eq 'BLOCKED').Count)|$(@($ev.artifacts).Count)"
            $runtimeSignatures+="$sid|$($ev.runtime.runnerId)|$($ev.runtime.protocol)|$($ev.runtime.serviceIdentityHash)|$($ev.runtime.authProfileFingerprint)"
        }
        $expectedVerdict=if($blocked -gt 0 -or $unresolved -gt 0 -or $blockerCount -gt 0){'BLOCKED'}elseif($failed -gt 0){'FAIL'}else{'PASS'}
        $expectedOutcome=if($expectedVerdict -eq 'BLOCKED'){'BLOCKED'}elseif($expectedVerdict -eq 'FAIL'){if([string]$request.run.mode -eq 'FIX_VERIFICATION'){'REGRESSION_FOUND'}elseif([string]$request.run.mode -eq 'DEFECT_REPRODUCTION'){'DEFECT_REPRODUCED'}else{'DEFECT_FOUND'}}elseif([string]$request.run.mode -eq 'FIX_VERIFICATION'){'FIX_VERIFIED'}else{'NO_DEFECT'}
        $expectedClosure=if($expectedVerdict -eq 'BLOCKED'){'BLOCKED'}elseif($expectedVerdict -eq 'FAIL'){'OPEN'}elseif([string]$request.run.mode -eq 'FIX_VERIFICATION'){'CLOSED'}else{'NOT_APPLICABLE'}
        if([string]$receipt.result.verdict -ne $expectedVerdict -or [int]$receipt.result.requiredAssertionCount -ne $required -or [int]$receipt.result.passedAssertionCount -ne $passed -or [int]$receipt.result.failedAssertionCount -ne $failed -or [int]$receipt.result.blockedAssertionCount -ne $blocked -or [int]$receipt.result.advisoryNonPassCount -ne $advisory -or [string]$receipt.result.reasonClass -ne $(if($expectedVerdict -eq 'PASS'){'none'}elseif($expectedVerdict -eq 'FAIL'){'product-failure'}else{'blocked'})){ Add-Error 'receipt aggregate result mismatch' }
        if([string]$receipt.run.outcome -ne $expectedOutcome -or [string]$receipt.run.closure -ne $expectedClosure){Add-Error 'receipt outcome or closure mismatch'}
        $actualScenario=@($receipt.scenarioResults|ForEach-Object{"$($_.scenarioId)|$($_.scenarioHash)|$($_.evidencePath)|$($_.evidenceHash)|$($_.verdict)|$($_.requiredAssertionCount)|$($_.passedAssertionCount)|$($_.failedAssertionCount)|$($_.blockedAssertionCount)|$($_.artifactCount)"})
        $actualFindings=@($receipt.findings|ForEach-Object{"$($_.scenarioId)|$($_.assertionId)|$($_.classification)|$($_.fingerprint)|$($_.evidenceHash)"})
        $actualBlockers=@($receipt.blockers|ForEach-Object{"$($_.scenarioId)|$($_.code)|$($_.reason)|$($_.nextStep)"})
        $actualRuntime=@($receipt.runtimeProfiles|ForEach-Object{"$($_.scenarioId)|$($_.runnerId)|$($_.protocol)|$($_.serviceIdentityHash)|$($_.authProfileFingerprint)"})
        if(!(Set-Equal $actualScenario $scenarioSignatures) -or !(Set-Equal $actualFindings $findingSignatures) -or !(Set-Equal $actualBlockers $blockerSignatures) -or !(Set-Equal $actualRuntime $runtimeSignatures)){Add-Error 'receipt scenario, finding, blocker, or runtime aggregate mismatch'}
        $requiredImpact=@($requiredImpact|Sort-Object -Unique -CaseSensitive);$coveredImpact=@($coveredImpact|Sort-Object -Unique -CaseSensitive);$uncoveredImpact=@($requiredImpact|Where-Object{[string]$_ -notin $coveredImpact}|Sort-Object -Unique -CaseSensitive)
        if(!(Set-Equal @($receipt.coverage.requiredImpactKeys) $requiredImpact) -or !(Set-Equal @($receipt.coverage.coveredImpactKeys) $coveredImpact) -or !(Set-Equal @($receipt.coverage.uncoveredImpactKeys) $uncoveredImpact) -or !(Set-Equal @($receipt.coverage.targetOperations) @($targetOperations|Sort-Object -Unique -CaseSensitive)) -or !(Set-Equal @($receipt.coverage.testedOperations) @($testedOperations|Sort-Object -Unique -CaseSensitive)) -or @($receipt.coverage.untestedScenarioIds).Count -ne 0){Add-Error 'receipt coverage aggregate mismatch'}
        if([int]$receipt.mutations.count -ne $mutationCount -or [int]$receipt.mutations.unresolvedCount -ne $unresolved -or !(Set-Equal @($receipt.mutations.summary) $mutationSummary)){Add-Error 'receipt mutation aggregate mismatch'}
        if($started.Count -gt 0){$expectedStart=($started|Sort-Object|Select-Object -First 1);$expectedFinish=($finished|Sort-Object|Select-Object -Last 1);if([DateTimeOffset]::Parse([string]$receipt.timing.startedAt) -ne $expectedStart -or [DateTimeOffset]::Parse([string]$receipt.timing.finishedAt) -ne $expectedFinish -or [long]$receipt.timing.durationMs -ne [long](($expectedFinish-$expectedStart).TotalMilliseconds)){Add-Error 'receipt timing aggregate mismatch'}}
        $expectedFreshClass=if($hasRuntime -and $hasMutation){'MIXED'}elseif($hasMutation){'LIVE_MUTABLE'}elseif($hasRuntime){'RUNTIME_BOUND'}else{'DETERMINISTIC'}
        $expectedKeys=@('candidate','adapter','catalog','scenario','environment','service-runtime','contract','artifact');if($null -ne $request.environment.authProfileFingerprint){$expectedKeys+='auth-profile'};if($hasMutation){$expectedKeys+='mutation-state'};if($expectedFreshClass -ne 'DETERMINISTIC'){$expectedKeys+='time'}
        if([string]$receipt.freshness.class -ne $expectedFreshClass -or !(Set-Equal @($receipt.freshness.invalidationKeys) $expectedKeys)){Add-Error 'receipt freshness classification mismatch'}
        if($expectedFreshClass -eq 'DETERMINISTIC'){if([int]$receipt.freshness.freshForSeconds -ne 0 -or $null -ne $receipt.freshness.expiresAt){Add-Error 'deterministic receipt has an expiry'}}else{if([int]$receipt.freshness.freshForSeconds -le 0 -or $null -eq $receipt.freshness.expiresAt -or [DateTimeOffset]::Parse([string]$receipt.freshness.expiresAt) -ne [DateTimeOffset]::Parse([string]$receipt.issuedAt).AddSeconds([int]$receipt.freshness.freshForSeconds)){Add-Error 'runtime-bound receipt expiry is inconsistent'}}
        if($RequireUnexpired -and $null -ne $receipt.freshness.expiresAt -and $AsOf -ge [DateTimeOffset]::Parse([string]$receipt.freshness.expiresAt)){ Add-Error 'receipt freshness expired' }
    }
}
if($NativeLeafSummaryPath){
    if([string]$adapter.evidenceMode -ne 'PROJECT_NATIVE_PARENT'){ Add-Error 'native leaf summary requires PROJECT_NATIVE_PARENT' }
    $leafFull=[IO.Path]::GetFullPath($NativeLeafSummaryPath)
    $expectedLeaf=if($outputRoot){[IO.Path]::GetFullPath((Join-Path $outputRoot ([string]$request.output.leafSummaryFileName)))}else{$null}
    if($null -eq $expectedLeaf -or !$leafFull.Equals($expectedLeaf,$pathComparison)){ Add-Error 'native leaf summary path does not match the request output contract' }
    $leaf=Read-Json $leafFull 'native leaf summary'; $null=Test-Schema $leaf 'native-leaf-summary.schema.json' 'native leaf summary'
    if($leaf){
        $expectedExcluded=@($catalogIds | Where-Object { $_ -notin @($request.testPlan.selectedScenarioIds) })
        if([string]$leaf.request.sha256 -ne $requestHash -or !(Set-Equal @($leaf.selection.selected) @($request.testPlan.selectedScenarioIds)) -or !(Set-Equal @($leaf.selection.executed) @($evidenceByScenario.Keys)) -or !(Set-Equal @($leaf.selection.excluded) $expectedExcluded)){ Add-Error 'native leaf summary input or selection mismatch' }
        foreach($pair in @(@('sourceHash',$request.candidate.sourceHash),@('diffHash',$request.candidate.diffHash),@('serviceIdentityHash',$request.environment.serviceIdentityHash),@('destinationFingerprint',$request.environment.destinationFingerprint),@('contractCombinedSha256',$request.environment.contractCombinedSha256),@('operationIndexHash',$request.environment.operationIndexHash))){ if([string]$leaf.subject.($pair[0]) -ne [string]$pair[1]){ Add-Error "native leaf $($pair[0]) mismatch" } }
        if(![string]::IsNullOrWhiteSpace($CurrentAttestationPath) -and ([string]$leaf.subject.attestationHash -ne (Get-Hash ([IO.Path]::GetFullPath($CurrentAttestationPath))) -or [string]$leaf.freshness.attestationHash -ne [string]$leaf.subject.attestationHash)){ Add-Error 'native leaf current attestation mismatch' }
        $leafEvidence=@();$leafFindings=@();$leafBlockers=@();$leafRequired=0;$leafPassed=0;$leafFailed=0;$leafBlocked=0;$leafMutations=0;$leafUnresolved=0
        foreach($sid in @($request.testPlan.selectedScenarioIds)){if(!$evidenceByScenario.ContainsKey([string]$sid)){continue};$fact=$evidenceByScenario[[string]$sid];$ev=$fact.value;$leafEvidence+="$sid|$([IO.Path]::GetRelativePath($workspace,$fact.path).Replace('\','/'))|$(Get-Hash $fact.path)|$($ev.verdict)";foreach($a in $ev.assertions){if([string]$a.severity -eq 'REQUIRED'){$leafRequired++;if([string]$a.status -eq 'PASS'){$leafPassed++}elseif([string]$a.status -eq 'FAIL'){$leafFailed++}else{$leafBlocked++}};if([string]$a.status -eq 'FAIL'){$leafFindings+="$sid/$($a.id)/$($a.findingFingerprint)"}};foreach($b in $ev.blockers){$leafBlockers+="$sid/$($b.code): $($b.reason)"};foreach($m in $ev.mutations){$leafMutations++;if([string]$m.resolution -eq 'UNRESOLVED'){$leafUnresolved++}}}
        $actualLeafEvidence=@($leaf.evidence|ForEach-Object{"$($_.scenarioId)|$($_.path)|$($_.sha256)|$($_.verdict)"})
        $expectedLeafVerdict=if($leafBlockers.Count -gt 0 -or $leafUnresolved -gt 0 -or $leafBlocked -gt 0){'BLOCKED'}elseif($leafFailed -gt 0){'FAIL'}else{'PASS'}
        if(!(Set-Equal $actualLeafEvidence $leafEvidence) -or !(Set-Equal @($leaf.findings) $leafFindings) -or !(Set-Equal @($leaf.blockers) $leafBlockers)){Add-Error 'native leaf evidence, findings, or blockers aggregate mismatch'}
        if([string]$leaf.result.verdict -ne $expectedLeafVerdict -or [int]$leaf.result.requiredAssertions -ne $leafRequired -or [int]$leaf.result.passedAssertions -ne $leafPassed -or [int]$leaf.result.failedAssertions -ne $leafFailed -or [int]$leaf.result.blockedAssertions -ne $leafBlocked -or [int]$leaf.mutations.count -ne $leafMutations -or [int]$leaf.mutations.unresolvedCount -ne $leafUnresolved){Add-Error 'native leaf result or mutation aggregate mismatch'}
    }
}

if(($ReceiptPath -or $NativeLeafSummaryPath) -and @($request.testPlan.selectedScenarioIds | Where-Object { !$evidenceByScenario.ContainsKey([string]$_) }).Count -gt 0){ Add-Error 'every selected scenario requires evidence for summary generation' }
if($errors.Count -gt 0){ throw ($errors -join [Environment]::NewLine) }
[pscustomobject]@{valid=$true;workspace=$workspace;requestHash=$requestHash;selectedScenarioIds=@($request.testPlan.selectedScenarioIds);evidenceCount=$EvidencePath.Count;currentIdentityChecked=[bool]$RequireCurrentIdentity}|ConvertTo-Json -Depth 10
