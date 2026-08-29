#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectAdapterPath,
    [Parameter(Mandatory)][string]$RequestPath,
    [Parameter(Mandatory)][string[]]$EvidencePath,
    [Parameter(Mandatory)][string]$CurrentAttestationPath
)

$ErrorActionPreference = 'Stop'
$validator = Join-Path $PSScriptRoot 'validate-contract.ps1'
$references = Join-Path (Split-Path $PSScriptRoot -Parent) 'references'
function Read-Json([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100 }
function Get-Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Relative([string]$Root, [string]$Path) { [IO.Path]::GetRelativePath($Root, [IO.Path]::GetFullPath($Path)).Replace('\','/') }

& $validator -ProjectAdapterPath $ProjectAdapterPath -RequestPath $RequestPath -EvidencePath $EvidencePath -CurrentAttestationPath $CurrentAttestationPath -RequireCurrentIdentity | Out-Null
$adapter = Read-Json $ProjectAdapterPath
if ([string]$adapter.evidenceMode -ne 'PROJECT_NATIVE_PARENT') { throw 'Native leaf summary requires evidenceMode=PROJECT_NATIVE_PARENT.' }
$request = Read-Json $RequestPath
$attestation = Read-Json $CurrentAttestationPath
$workspace = [IO.Path]::GetFullPath((Join-Path (Split-Path ([IO.Path]::GetFullPath($ProjectAdapterPath)) -Parent) ([string]$adapter.roots.workspace)))
$catalog = Read-Json ([IO.Path]::GetFullPath((Join-Path $workspace ([string]$request.testPlan.catalog.path))))
$outputRoot = [IO.Path]::GetFullPath((Join-Path $workspace ([string]$request.output.root)))
$summaryPath = Join-Path $outputRoot ([string]$request.output.leafSummaryFileName)
if (Test-Path -LiteralPath $summaryPath) { throw "Refusing to overwrite leaf summary: $summaryPath" }

$evidenceRows=@(); $findings=@(); $blockers=@(); $required=0; $passed=0; $failed=0; $blocked=0; $mutations=0; $unresolved=0
foreach($path in $EvidencePath) {
    $ev=Read-Json $path
    $evidenceRows += [ordered]@{ scenarioId=[string]$ev.scope.scenarioId; path=Relative $workspace $path; sha256=Get-Hash $path; verdict=[string]$ev.verdict }
    foreach($a in $ev.assertions) {
        if([string]$a.severity -eq 'REQUIRED') { $required++; if([string]$a.status -eq 'PASS'){$passed++}elseif([string]$a.status -eq 'FAIL'){$failed++}else{$blocked++} }
        if([string]$a.status -eq 'FAIL') { $findings += "$($ev.scope.scenarioId)/$($a.id)/$($a.findingFingerprint)" }
    }
    foreach($b in $ev.blockers) { $blockers += "$($ev.scope.scenarioId)/$($b.code): $($b.reason)" }
    foreach($m in $ev.mutations) { $mutations++; if([string]$m.resolution -eq 'UNRESOLVED'){$unresolved++} }
}
$executed=@($evidenceRows | ForEach-Object { [string]$_.scenarioId })
$selected=@($request.testPlan.selectedScenarioIds)
$excluded=@($catalog.scenarios | ForEach-Object { [string]$_.id } | Where-Object { $_ -notin $selected })
$verdict=if($blockers.Count -gt 0 -or $unresolved -gt 0 -or $blocked -gt 0){'BLOCKED'}elseif($failed -gt 0){'FAIL'}else{'PASS'}
$issued=[DateTimeOffset]::UtcNow
$summary=[ordered]@{
    schemaVersion='2.0'; summaryId="api-leaf-$($request.runId)"; issuedAt=$issued.ToString('o'); authority='TEST_LEAF_EVIDENCE_ONLY'
    request=[ordered]@{ path=Relative $workspace $RequestPath; sha256=Get-Hash $RequestPath; authorizationRef=[string]$request.authorizationRef }
    subject=[ordered]@{ projectId=[string]$adapter.projectId; revision=[string]$request.candidate.revision; sourceHash=[string]$request.candidate.sourceHash; diffHash=[string]$request.candidate.diffHash; buildId=[string]$request.candidate.buildId; serviceId=[string]$request.environment.serviceId; serviceIdentityHash=[string]$request.environment.serviceIdentityHash; destinationId=[string]$request.environment.destinationId; destinationFingerprint=[string]$request.environment.destinationFingerprint; contractId=[string]$request.environment.contractId; contractCombinedSha256=[string]$request.environment.contractCombinedSha256; operationIndexHash=[string]$request.environment.operationIndexHash; authProfileFingerprint=$request.environment.authProfileFingerprint; attestationHash=Get-Hash $CurrentAttestationPath }
    selection=[ordered]@{ selected=$selected; executed=$executed; excluded=$excluded }
    result=[ordered]@{ verdict=$verdict; requiredAssertions=$required; passedAssertions=$passed; failedAssertions=$failed; blockedAssertions=$blocked }
    evidence=$evidenceRows; findings=$findings; blockers=$blockers
    mutations=[ordered]@{ count=$mutations; unresolvedCount=$unresolved }
    freshness=[ordered]@{ attestedAt=[string]$attestation.observedAt; attestationHash=Get-Hash $CurrentAttestationPath; currentIdentityRequired=$true }
    producer=[ordered]@{ skillName='api-test'; generatorIdentity=Get-Hash $PSCommandPath; validatorIdentity=Get-Hash $validator }
}
$json=$summary | ConvertTo-Json -Depth 100
if(!(Test-Json -Json $json -SchemaFile (Join-Path $references 'native-leaf-summary.schema.json') -ErrorAction Stop)){ throw 'Generated native leaf summary does not conform to schema.' }
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$temp="$summaryPath.tmp-$([Guid]::NewGuid().ToString('N'))"
try {
    [IO.File]::WriteAllText($temp, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $summaryPath
} finally { if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force} }
[pscustomobject]@{ summaryPath=$summaryPath; summarySha256=Get-Hash $summaryPath; verdict=$verdict } | ConvertTo-Json
