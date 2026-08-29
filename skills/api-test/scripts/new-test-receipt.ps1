#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectAdapterPath,
    [Parameter(Mandatory)][string]$RequestPath,
    [Parameter(Mandatory)][string[]]$EvidencePath,
    [int]$FreshForSeconds = 3600
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path $PSScriptRoot -Parent
$validator = Join-Path $PSScriptRoot 'validate-contract.ps1'
$references = Join-Path $skillRoot 'references'

function Read-Json([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100 }
function Get-Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Relative([string]$Root, [string]$Path) { [IO.Path]::GetRelativePath($Root, [IO.Path]::GetFullPath($Path)).Replace('\','/') }

& $validator -ProjectAdapterPath $ProjectAdapterPath -RequestPath $RequestPath -EvidencePath $EvidencePath | Out-Null
if (!$?) { throw 'Input or evidence contract is invalid.' }

$adapterFull = [IO.Path]::GetFullPath($ProjectAdapterPath)
$requestFull = [IO.Path]::GetFullPath($RequestPath)
$adapter = Read-Json $adapterFull
$request = Read-Json $requestFull
if ([string]$adapter.evidenceMode -eq 'PROJECT_NATIVE_PARENT') { throw 'Project owns the canonical parent summary; map child evidence instead of generating a second receipt.' }
$workspace = [IO.Path]::GetFullPath((Join-Path (Split-Path $adapterFull -Parent) ([string]$adapter.roots.workspace)))
$catalogFull = [IO.Path]::GetFullPath((Join-Path $workspace ([string]$request.testPlan.catalog.path)))
$catalog = Read-Json $catalogFull
$outputRoot = [IO.Path]::GetFullPath((Join-Path $workspace ([string]$request.output.root)))
$receiptFull = Join-Path $outputRoot ([string]$request.output.receiptFileName)
if (Test-Path -LiteralPath $receiptFull) { throw "Refusing to overwrite receipt: $receiptFull" }

$scenarioById = @{}
foreach ($entry in $catalog.scenarios) { $scenarioById[[string]$entry.id] = Read-Json ([IO.Path]::GetFullPath((Join-Path $workspace ([string]$entry.path)))) }
$evidenceById = @{}
foreach ($path in $EvidencePath) { $ev = Read-Json $path; $evidenceById[[string]$ev.scope.scenarioId] = @{ value=$ev; path=[IO.Path]::GetFullPath($path); hash=(Get-Hash $path) } }

$selected = @($request.testPlan.selectedScenarioIds)
if (@($selected | Where-Object { !$evidenceById.ContainsKey([string]$_) }).Count -gt 0) { throw 'Every selected scenario must have one PASS, FAIL, or BLOCKED evidence file.' }

$required = 0; $passed = 0; $failed = 0; $blocked = 0; $advisory = 0
$findings = @(); $blockers = @(); $scenarioResults = @(); $runtimeProfiles = @()
$targetOperations = @(); $testedOperations = @(); $requiredImpact = @(); $coveredImpact = @(); $mutationSummary = @(); $mutationCount = 0; $unresolved = 0
$started = @(); $finished = @(); $hasRuntime = $false; $hasMutation = $false

foreach ($sid in $selected) {
    $fact = $evidenceById[[string]$sid]
    $ev = $fact.value
    $scenario = $scenarioById[[string]$sid]
    $started += [DateTimeOffset]::Parse([string]$ev.timing.startedAt)
    $finished += [DateTimeOffset]::Parse([string]$ev.timing.finishedAt)
    $hasRuntime = $hasRuntime -or @($ev.requests).Count -gt 0 -or $null -ne $ev.runtime.authProfileFingerprint
    $targetOperations += @($scenario.operations | ForEach-Object { [string]$_.id })
    $testedOperations += @($ev.scope.observedOperations)
    foreach ($a in $scenario.assertions) { if ([string]$a.severity -eq 'REQUIRED') { $requiredImpact += @($a.impactKeys) } }
    foreach ($a in $ev.assertions) {
        if ([string]$a.severity -eq 'REQUIRED') {
            $required++
            if ([string]$a.status -eq 'PASS') { $passed++; $coveredImpact += @($a.impactKeys) }
            elseif ([string]$a.status -eq 'FAIL') { $failed++; $coveredImpact += @($a.impactKeys) }
            else { $blocked++ }
        } elseif ([string]$a.status -ne 'PASS') { $advisory++ }
        if ([string]$a.status -eq 'FAIL') {
            $findings += [ordered]@{ scenarioId=[string]$sid; assertionId=[string]$a.id; classification=if ([string]$a.severity -eq 'REQUIRED') {'PRODUCT_DEFECT'} else {'ADVISORY'}; fingerprint=[string]$a.findingFingerprint; evidenceHash=[string]$fact.hash }
        }
    }
    foreach ($b in $ev.blockers) { $blockers += [ordered]@{ scenarioId=[string]$sid; code=[string]$b.code; reason=[string]$b.reason; nextStep=[string]$b.nextStep } }
    foreach ($m in $ev.mutations) {
        $mutationCount++; $hasMutation = $true
        if ([string]$m.resolution -eq 'UNRESOLVED') { $unresolved++ }
        $mutationSummary += "$sid/$($m.id):$($m.resolution)"
    }
    $req = @($ev.assertions | Where-Object { [string]$_.severity -eq 'REQUIRED' })
    $scenarioResults += [ordered]@{
        scenarioId=[string]$sid; scenarioHash=[string]$ev.scope.scenarioHash; evidencePath=Relative $workspace $fact.path; evidenceHash=[string]$fact.hash; verdict=[string]$ev.verdict
        requiredAssertionCount=$req.Count; passedAssertionCount=@($req | Where-Object status -eq 'PASS').Count; failedAssertionCount=@($req | Where-Object status -eq 'FAIL').Count; blockedAssertionCount=@($req | Where-Object status -eq 'BLOCKED').Count; artifactCount=@($ev.artifacts).Count
    }
    $runtimeProfiles += [ordered]@{ scenarioId=[string]$sid; runnerId=[string]$ev.runtime.runnerId; protocol=[string]$ev.runtime.protocol; serviceIdentityHash=[string]$ev.runtime.serviceIdentityHash; authProfileFingerprint=$ev.runtime.authProfileFingerprint }
}

$verdict = if ($blockers.Count -gt 0 -or $unresolved -gt 0 -or @($scenarioResults | Where-Object verdict -eq 'BLOCKED').Count -gt 0) {'BLOCKED'} elseif ($failed -gt 0) {'FAIL'} else {'PASS'}
$outcome = if ($verdict -eq 'BLOCKED') {'BLOCKED'} elseif ($verdict -eq 'FAIL') { if ([string]$request.run.mode -eq 'FIX_VERIFICATION') {'REGRESSION_FOUND'} else {'DEFECT_FOUND'} } elseif ([string]$request.run.mode -eq 'FIX_VERIFICATION') {'FIX_VERIFIED'} else {'NO_DEFECT'}
$closure = if ($verdict -eq 'BLOCKED') {'BLOCKED'} elseif ($verdict -eq 'FAIL') {'OPEN'} elseif ([string]$request.run.mode -eq 'FIX_VERIFICATION') {'CLOSED'} else {'NOT_APPLICABLE'}
$freshClass = if ($hasRuntime -and $hasMutation) {'MIXED'} elseif ($hasMutation) {'LIVE_MUTABLE'} elseif ($hasRuntime) {'RUNTIME_BOUND'} else {'DETERMINISTIC'}
$issued = [DateTimeOffset]::UtcNow
$expires = if ($freshClass -eq 'DETERMINISTIC') { $null } else { $issued.AddSeconds($FreshForSeconds).ToString('o') }
$keys = @('candidate','adapter','catalog','scenario','environment','service-runtime','contract','artifact')
if ($null -ne $request.environment.authProfileFingerprint) { $keys += 'auth-profile' }
if ($hasMutation) { $keys += 'mutation-state' }
if ($null -ne $expires) { $keys += 'time' }

$receipt = [ordered]@{
    schemaVersion='2.0'; receiptId="receipt-$($request.runId)"; issuedAt=$issued.ToString('o'); authority='TEST_EVIDENCE_ONLY'
    input=[ordered]@{ requestPath=Relative $workspace $requestFull; requestSha256=Get-Hash $requestFull; projectAdapterPath=Relative $workspace $adapterFull; projectAdapterSha256=Get-Hash $adapterFull; catalogPath=Relative $workspace $catalogFull; catalogSha256=Get-Hash $catalogFull }
    subject=[ordered]@{ projectId=[string]$adapter.projectId; candidateSourceHash=[string]$request.candidate.sourceHash; revision=[string]$request.candidate.revision; buildId=[string]$request.candidate.buildId; environment=[string]$request.environment.name; destinationId=[string]$request.environment.destinationId; destinationFingerprint=[string]$request.environment.destinationFingerprint; serviceId=[string]$request.environment.serviceId; serviceIdentityHash=[string]$request.environment.serviceIdentityHash; contractId=[string]$request.environment.contractId; contractManifestHash=[string]$request.environment.contractManifestHash; contractCombinedSha256=[string]$request.environment.contractCombinedSha256; operationIndexHash=[string]$request.environment.operationIndexHash; authProfileFingerprint=$request.environment.authProfileFingerprint; attestationHash=[string]$request.currentAttestation.sha256 }
    run=[ordered]@{ mode=[string]$request.run.mode; outcome=$outcome; closure=$closure }
    selection=[ordered]@{ strategy=[string]$request.testPlan.strategy; selectedScenarioIds=$selected; executedScenarioIds=$selected; excludedScenarioIds=@($catalog.scenarios | ForEach-Object { [string]$_.id } | Where-Object { $_ -notin $selected }) }
    timing=[ordered]@{ startedAt=($started | Sort-Object | Select-Object -First 1).ToString('o'); finishedAt=($finished | Sort-Object | Select-Object -Last 1).ToString('o'); durationMs=[long]((($finished | Sort-Object | Select-Object -Last 1)-($started | Sort-Object | Select-Object -First 1)).TotalMilliseconds) }
    runtimeProfiles=$runtimeProfiles
    result=[ordered]@{ verdict=$verdict; requiredAssertionCount=$required; passedAssertionCount=$passed; failedAssertionCount=$failed; blockedAssertionCount=$blocked; advisoryNonPassCount=$advisory; reasonClass=if($verdict -eq 'PASS'){'none'}elseif($verdict -eq 'FAIL'){'product-failure'}else{'blocked'} }
    scenarioResults=$scenarioResults; findings=$findings; blockers=$blockers
    coverage=[ordered]@{ requiredImpactKeys=@($requiredImpact | Sort-Object -Unique); coveredImpactKeys=@($coveredImpact | Sort-Object -Unique); uncoveredImpactKeys=@($requiredImpact | Where-Object { $_ -notin $coveredImpact } | Sort-Object -Unique); targetOperations=@($targetOperations | Sort-Object -Unique); testedOperations=@($testedOperations | Sort-Object -Unique); untestedScenarioIds=@() }
    mutations=[ordered]@{ count=$mutationCount; unresolvedCount=$unresolved; summary=$mutationSummary }
    freshness=[ordered]@{ class=$freshClass; freshForSeconds=if($freshClass -eq 'DETERMINISTIC'){0}else{$FreshForSeconds}; expiresAt=$expires; invalidationKeys=@($keys | Sort-Object -Unique) }
    producer=[ordered]@{ skillName='api-test'; generatorIdentity=Get-Hash $PSCommandPath; validatorIdentity=Get-Hash $validator }
}

$json = $receipt | ConvertTo-Json -Depth 100
if (!(Test-Json -Json $json -SchemaFile (Join-Path $references 'test-receipt.schema.json') -ErrorAction Stop)) { throw 'Generated receipt does not conform to schema.' }
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$temp = "$receiptFull.tmp"
try {
    [IO.File]::WriteAllText($temp, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $receiptFull
} finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }

[pscustomobject]@{ receiptPath=$receiptFull; receiptSha256=Get-Hash $receiptFull; verdict=$verdict } | ConvertTo-Json
