#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ProjectAdapterPath,
    [Parameter(Mandatory)] [string]$RequestPath,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string[]]$EvidencePath,
    [ValidateRange(1, 86400)] [int]$FreshForSeconds = 3600
)

$ErrorActionPreference = "Stop"
$validatorPath = Join-Path $PSScriptRoot "validate-contract.ps1"
$references = Join-Path (Split-Path -Parent $PSScriptRoot) "references"

function Get-ExactHash([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-StringHash([string]$Value) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Value)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-RelativePath([string]$Workspace, [string]$Path) {
    ([IO.Path]::GetRelativePath($Workspace, [IO.Path]::GetFullPath($Path))).Replace("\", "/")
}

function Read-Json([string]$Path, [string]$Label) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label does not exist: $Path" }
    try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { throw "$Label is invalid JSON: $($_.Exception.Message)" }
}

function Test-Schema($Value, [string]$SchemaName, [string]$Label) {
    $json = $Value | ConvertTo-Json -Depth 100
    if (!(Test-Json -Json $json -SchemaFile (Join-Path $references $SchemaName) -ErrorAction Stop)) {
        throw "$Label does not conform to $SchemaName"
    }
}

$adapterFull = [IO.Path]::GetFullPath($ProjectAdapterPath)
$requestFull = [IO.Path]::GetFullPath($RequestPath)
$global:LASTEXITCODE = 0
$preflightText = (& $validatorPath -ProjectAdapterPath $adapterFull -RequestPath $requestFull | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw "Input contract is invalid: $preflightText" }
$preflight = $preflightText | ConvertFrom-Json

$adapter = Read-Json $adapterFull "project adapter"
$request = Read-Json $requestFull "test request"
$adapterDirectory = Split-Path -Parent $adapterFull
$workspace = [IO.Path]::GetFullPath((Join-Path $adapterDirectory ([string]$adapter.roots.workspace)))
$catalogFull = [IO.Path]::GetFullPath((Join-Path $workspace ([string]$request.testPlan.catalog.path)))
$catalog = Read-Json $catalogFull "test catalog"
$outputRoot = [IO.Path]::GetFullPath((Join-Path $workspace ([string]$request.output.root)))
$receiptFull = Join-Path $outputRoot ([string]$request.output.receiptFileName)
if (Test-Path -LiteralPath $receiptFull) { throw "Refusing to overwrite test receipt: $receiptFull" }

$scenarioFacts = @{}
foreach ($entry in $catalog.scenarios) {
    $scenarioFull = [IO.Path]::GetFullPath((Join-Path $workspace ([string]$entry.path)))
    $scenarioFacts[[string]$entry.id] = [pscustomobject]@{
        entry = $entry
        scenario = Read-Json $scenarioFull "scenario '$($entry.id)'"
        hash = Get-ExactHash $scenarioFull
    }
}

$evidenceByScenario = @{}
foreach ($path in $EvidencePath) {
    $full = [IO.Path]::GetFullPath($path)
    $evidence = Read-Json $full "scenario evidence"
    Test-Schema $evidence "evidence.schema.json" "scenario evidence '$full'"
    $scenarioId = [string]$evidence.scope.scenarioId
    if ($scenarioId -notin @($request.testPlan.selectedScenarioIds)) { throw "Evidence scenario is outside the selected boundary: $scenarioId" }
    if ($evidenceByScenario.ContainsKey($scenarioId)) { throw "Duplicate evidence for scenario: $scenarioId" }
    $evidenceByScenario[$scenarioId] = [pscustomobject]@{ path = $full; value = $evidence; hash = Get-ExactHash $full }
}

$selectedIds = @($request.testPlan.selectedScenarioIds | ForEach-Object { [string]$_ })
$executedIds = @($selectedIds | Where-Object { $evidenceByScenario.ContainsKey($_) })
$excludedIds = @($preflight.excludedScenarioIds | ForEach-Object { [string]$_ })
$reasonByScenario = @($preflight.reasonByScenario)
$scenarioResults = [Collections.Generic.List[object]]::new()
$runtimeProfiles = [Collections.Generic.List[object]]::new()
$findings = [Collections.Generic.List[object]]::new()
$blockers = [Collections.Generic.List[object]]::new()
$testedPages = [Collections.Generic.HashSet[string]]::new()
$coveredImpactKeys = [Collections.Generic.HashSet[string]]::new()
$requiredImpactKeys = [Collections.Generic.HashSet[string]]::new()
$mutationSummary = [Collections.Generic.List[string]]::new()
$requiredTotal = 0
$passedTotal = 0
$failedTotal = 0
$blockedTotal = 0
$advisoryTotal = 0
$mutationCount = 0
$unresolvedMutationCount = 0
$deviceValidated = $false
$businessWritePerformed = $false
$startedTimes = [Collections.Generic.List[DateTimeOffset]]::new()
$finishedTimes = [Collections.Generic.List[DateTimeOffset]]::new()

foreach ($scenarioId in $selectedIds) {
    $fact = $scenarioFacts[$scenarioId]
    foreach ($assertion in $fact.scenario.assertions) {
        if ([string]$assertion.severity -eq "REQUIRED") {
            foreach ($key in $assertion.impactKeys) { $requiredImpactKeys.Add([string]$key) | Out-Null }
        }
    }
    if (!$evidenceByScenario.ContainsKey($scenarioId)) { continue }

    $evidenceFact = $evidenceByScenario[$scenarioId]
    $evidence = $evidenceFact.value
    $evidenceRelative = Get-RelativePath $workspace $evidenceFact.path
    $startedTimes.Add([DateTimeOffset]::Parse([string]$evidence.timing.startedAt)) | Out-Null
    $finishedTimes.Add([DateTimeOffset]::Parse([string]$evidence.timing.finishedAt)) | Out-Null
    $requiredAssertions = @($evidence.assertions | Where-Object { [string]$_.severity -eq "REQUIRED" })
    $passed = @($requiredAssertions | Where-Object { [string]$_.status -eq "PASS" }).Count
    $failed = @($requiredAssertions | Where-Object { [string]$_.status -eq "FAIL" }).Count
    $blocked = @($requiredAssertions | Where-Object { [string]$_.status -eq "BLOCKED" }).Count
    $advisory = @($evidence.assertions | Where-Object { [string]$_.severity -eq "ADVISORY" -and [string]$_.status -ne "PASS" }).Count
    $requiredTotal += $requiredAssertions.Count
    $passedTotal += $passed
    $failedTotal += $failed
    $blockedTotal += $blocked
    $advisoryTotal += $advisory

    $scenarioResults.Add([ordered]@{
        scenarioId = $scenarioId
        scenarioHash = [string]$fact.hash
        verdict = [string]$evidence.verdict
        requiredAssertionCount = $requiredAssertions.Count
        passedAssertionCount = $passed
        failedAssertionCount = $failed
        blockedAssertionCount = $blocked
        evidencePath = $evidenceRelative
        evidenceSha256 = [string]$evidenceFact.hash
        artifactCount = @($evidence.artifacts).Count
    }) | Out-Null
    $runtimeProfiles.Add([ordered]@{
        scenarioId = $scenarioId
        channel = [string]$evidence.runtime.channel
        runnerId = $evidence.runtime.runnerId
        controllerIdentity = $evidence.runtime.controllerIdentity
        devtoolsVersion = $evidence.runtime.devtoolsVersion
        protocolVersion = $evidence.runtime.protocolVersion
        sessionFingerprint = $evidence.runtime.sessionFingerprint
        commandIdentity = $evidence.runtime.commandIdentity
        deviceProfile = $evidence.runtime.deviceProfile
    }) | Out-Null

    foreach ($page in $evidence.scope.observedPages) { $testedPages.Add([string]$page) | Out-Null }
    if ($null -ne $evidence.runtime.deviceProfile -and [string]$evidence.runtime.channel -eq "device") { $deviceValidated = $true }
    foreach ($assertion in $evidence.assertions) {
        $definition = @($fact.scenario.assertions | Where-Object { [string]$_.id -eq [string]$assertion.id })[0]
        if ([string]$assertion.status -ne "BLOCKED") {
            foreach ($key in $definition.impactKeys) { $coveredImpactKeys.Add([string]$key) | Out-Null }
        }
        if ([string]$assertion.status -eq "FAIL") {
            $fingerprint = Get-StringHash "$scenarioId`t$([string]$assertion.id)`n"
            $knownDefect = if ($null -eq $request.defectLineage) { @() } else { @($request.defectLineage.defects | Where-Object { [string]$_.fingerprint -eq $fingerprint }) }
            $findings.Add([ordered]@{
                fingerprint = $fingerprint
                defectId = if ($knownDefect.Count -gt 0) { $knownDefect[0].defectId } else { $null }
                classification = if ([string]$assertion.severity -eq "REQUIRED") { "PRODUCT_DEFECT" } else { "ADVISORY" }
                scenarioId = $scenarioId
                assertionId = [string]$assertion.id
                evidencePath = $evidenceRelative
                evidenceSha256 = [string]$evidenceFact.hash
            }) | Out-Null
        }
    }
    foreach ($blocker in $evidence.blockers) {
        $blockers.Add([ordered]@{
            scenarioId = $scenarioId
            reasonClass = [string]$blocker.reasonClass
            detail = [string]$blocker.detail
            nextStep = [string]$blocker.nextStep
            evidencePath = $evidenceRelative
            evidenceSha256 = [string]$evidenceFact.hash
        }) | Out-Null
    }
    foreach ($mutation in $evidence.mutations) {
        if ([int]$mutation.attempts -eq 1 -and [string]$mutation.type -ne "none") {
            $mutationCount++
            if ([string]$mutation.resolution -eq "UNRESOLVED") { $unresolvedMutationCount++ }
            if ([string]$mutation.type -eq "business-write") { $businessWritePerformed = $true }
            $mutationSummary.Add("${scenarioId}:$([string]$mutation.type):$([string]$mutation.resolution)") | Out-Null
        }
    }
}

if ($scenarioResults.Count -eq 0) { throw "At least one scenario evidence file is required to produce a receipt" }
$untested = @($selectedIds | Where-Object { $_ -notin $executedIds })
$verdict = if ($blockers.Count -gt 0 -or $blockedTotal -gt 0 -or ($untested.Count -gt 0 -and $failedTotal -eq 0)) { "BLOCKED" } elseif ($failedTotal -gt 0) { "FAIL" } else { "PASS" }
if ($verdict -eq "BLOCKED" -and $blockers.Count -eq 0) { throw "A BLOCKED receipt requires a blocker in scenario evidence" }

$reasonClass = if ($verdict -eq "PASS") { "none" } elseif ($verdict -eq "FAIL") { "product-failure" } else {
    $classes = @($blockers | ForEach-Object { [string]$_.reasonClass })
    if ("authorization" -in $classes) { "authorization-blocked" }
    elseif ("identity" -in $classes) { "identity-mismatch" }
    elseif (@($classes | Where-Object { $_ -in @("login", "client-authorization") }).Count -gt 0) { "session-blocked" }
    elseif ("environment" -in $classes) { "environment-blocked" }
    elseif ("fixture" -in $classes) { "fixture-blocked" }
    elseif ("device" -in $classes) { "device-blocked" }
    elseif ("timeout" -in $classes) { "timeout-blocked" }
    elseif ("evidence" -in $classes) { "evidence-insufficient" }
    elseif (@($classes | Where-Object { $_ -in @("tool", "compatibility") }).Count -gt 0) { "tool-blocked" }
    else { "unknown-blocked" }
}

$receiptDefects = [Collections.Generic.List[object]]::new()
if ($null -ne $request.defectLineage) {
    foreach ($defect in $request.defectLineage.defects) {
        $currentFailing = [Collections.Generic.List[object]]::new()
        $hasBlocked = $false
        $allPass = $true
        foreach ($group in $defect.failingAssertions) {
            $failedIds = [Collections.Generic.List[string]]::new()
            $currentEvidence = if ($evidenceByScenario.ContainsKey([string]$group.scenarioId)) { $evidenceByScenario[[string]$group.scenarioId].value } else { $null }
            foreach ($assertionId in $group.assertionIds) {
                $current = if ($null -ne $currentEvidence) { @($currentEvidence.assertions | Where-Object { [string]$_.id -eq [string]$assertionId }) } else { @() }
                if ($current.Count -ne 1) { $allPass = $false; continue }
                if ([string]$current[0].status -eq "FAIL") { $failedIds.Add([string]$assertionId) | Out-Null; $allPass = $false }
                elseif ([string]$current[0].status -eq "BLOCKED") { $hasBlocked = $true; $allPass = $false }
                elseif ([string]$current[0].status -ne "PASS") { $allPass = $false }
            }
            if ($failedIds.Count -gt 0) { $currentFailing.Add([ordered]@{ scenarioId = [string]$group.scenarioId; assertionIds = @($failedIds) }) | Out-Null }
        }
        $status = if ($hasBlocked) { "BLOCKED" } elseif ($currentFailing.Count -gt 0) { "REPRODUCED" } elseif ($allPass -and [string]$request.run.mode -eq "FIX_VERIFICATION") { "FIX_VERIFIED" } elseif ($allPass) { "NOT_REPRODUCED" } else { "OPEN" }
        $receiptDefects.Add([ordered]@{
            defectId = $defect.defectId
            fingerprint = [string]$defect.fingerprint
            priorFailingAssertions = @($defect.failingAssertions)
            currentStatus = $status
            currentFailingAssertions = @($currentFailing)
        }) | Out-Null
    }
}

$knownFingerprints = if ($null -eq $request.defectLineage) { @() } else { @($request.defectLineage.defects | ForEach-Object { [string]$_.fingerprint }) }
$newProductFinding = @($findings | Where-Object { [string]$_.classification -eq "PRODUCT_DEFECT" -and [string]$_.fingerprint -notin $knownFingerprints }).Count -gt 0
$knownReproduced = @($receiptDefects | Where-Object { [string]$_.currentStatus -eq "REPRODUCED" }).Count -gt 0
if ($verdict -eq "BLOCKED") { $outcome = "BLOCKED"; $closure = "BLOCKED" }
elseif ([string]$request.run.mode -eq "FIX_VERIFICATION") {
    if ($newProductFinding) { $outcome = "REGRESSION_FOUND"; $closure = "PARTIAL" }
    elseif ($knownReproduced) { $outcome = "DEFECT_REPRODUCED"; $closure = "OPEN" }
    else { $outcome = "FIX_VERIFIED"; $closure = "CLOSED" }
} elseif ([string]$request.run.mode -eq "DEFECT_REPRODUCTION") {
    if ($newProductFinding) { $outcome = "REGRESSION_FOUND"; $closure = "PARTIAL" }
    elseif ($knownReproduced) { $outcome = "DEFECT_REPRODUCED"; $closure = "OPEN" }
    else { $outcome = "DEFECT_NOT_REPRODUCED"; $closure = "PARTIAL" }
} elseif (@($findings | Where-Object { [string]$_.classification -eq "PRODUCT_DEFECT" }).Count -gt 0) {
    $outcome = "DEFECT_FOUND"; $closure = "OPEN"
} else { $outcome = "NO_DEFECT"; $closure = "NOT_APPLICABLE" }

$hasSession = @($runtimeProfiles | Where-Object { ![string]::IsNullOrWhiteSpace([string]$_.sessionFingerprint) }).Count -gt 0
$hasLiveMutation = $mutationCount -gt 0
$resolvedFreshnessClass = if ($hasSession -and $hasLiveMutation) { "MIXED" } elseif ($hasSession) { "SESSION_BOUND" } elseif ($hasLiveMutation) { "LIVE_MUTABLE" } else { "DETERMINISTIC" }
$startedAt = @($startedTimes | Sort-Object)[0]
$finishedAt = @($finishedTimes | Sort-Object)[-1]
$issuedAt = [DateTimeOffset]::Now
$invalidationKeys = [Collections.Generic.HashSet[string]]::new()
foreach ($key in @("candidate", "request", "catalog", "environment", "impact-selection")) { $invalidationKeys.Add($key) | Out-Null }
if ($hasSession) { $invalidationKeys.Add("session") | Out-Null }
if ($hasLiveMutation) { $invalidationKeys.Add("mutation-state") | Out-Null }
$expiresAt = if ($resolvedFreshnessClass -eq "DETERMINISTIC") { $null } else { $finishedAt.AddSeconds($FreshForSeconds).ToString("o") }

$defectLineage = if ($null -eq $request.defectLineage) { $null } else {
    $source = $request.defectLineage.source
    [ordered]@{
        lineageId = [string]$request.defectLineage.lineageId
        round = [int]$request.defectLineage.round
        source = [ordered]@{
            type = [string]$source.type
            reference = if ([string]$source.type -eq "PARENT_RECEIPT") { [string]$source.receiptId } else { [string]$source.reference }
            path = [string]$source.path
            sha256 = [string]$source.sha256
        }
        defects = @($receiptDefects)
    }
}

$targetPages = @($selectedIds | ForEach-Object { $scenarioFacts[$_].scenario.targetPages.route } | Sort-Object -Unique)
$receipt = [ordered]@{
    schemaVersion = "3.2"
    receiptId = "receipt-$([string]$request.run.runId)"
    issuedAt = $issuedAt.ToString("o")
    authority = "TEST_EVIDENCE_ONLY"
    input = [ordered]@{
        requestId = [string]$request.requestId
        requestPath = Get-RelativePath $workspace $requestFull
        requestSha256 = Get-ExactHash $requestFull
        projectAdapterPath = Get-RelativePath $workspace $adapterFull
        projectAdapterSha256 = Get-ExactHash $adapterFull
        catalogPath = Get-RelativePath $workspace $catalogFull
        catalogSha256 = Get-ExactHash $catalogFull
    }
    subject = [ordered]@{
        projectId = [string]$adapter.projectId
        projectAdapterId = [string]$adapter.adapterId
        candidateRevision = [string]$request.candidate.revision
        diffHash = $request.candidate.diffHash
        sourceHash = [string]$request.candidate.sourceHash
        buildId = $request.candidate.buildId
        environment = [string]$request.environment.id
        appId = $request.environment.appId
        apiIdentity = $request.environment.apiIdentity
        environmentConfigHash = $request.environment.configHash
    }
    run = [ordered]@{ runId = [string]$request.run.runId; mode = [string]$request.run.mode; outcome = $outcome; closure = $closure }
    defectLineage = $defectLineage
    selection = [ordered]@{
        strategy = [string]$request.testPlan.strategy
        catalogScenarioCount = @($catalog.scenarios).Count
        changedImpactKeys = @($request.testPlan.changedImpactKeys)
        seedScenarioIds = @($preflight.seedScenarioIds)
        selectedScenarioIds = @($selectedIds)
        executedScenarioIds = @($executedIds)
        excludedScenarioIds = @($excludedIds)
        reasonByScenario = @($reasonByScenario)
        upstreamDepth = [int]$request.testPlan.upstreamDepth
        downstreamDepth = [int]$request.testPlan.downstreamDepth
        activeFullSuiteTriggers = @($request.testPlan.activeFullSuiteTriggers)
    }
    timing = [ordered]@{ startedAt = $startedAt.ToString("o"); finishedAt = $finishedAt.ToString("o"); durationMs = [long]($finishedAt - $startedAt).TotalMilliseconds }
    runtimeProfiles = @($runtimeProfiles)
    result = [ordered]@{
        verdict = $verdict
        requiredAssertionCount = $requiredTotal
        passedAssertionCount = $passedTotal
        failedAssertionCount = $failedTotal
        blockedAssertionCount = $blockedTotal
        advisoryNonPassCount = $advisoryTotal
        reasonClass = $reasonClass
    }
    scenarioResults = @($scenarioResults)
    findings = @($findings)
    blockers = @($blockers)
    coverage = [ordered]@{
        targetPages = @($targetPages)
        testedPages = @($testedPages | Sort-Object)
        requiredImpactKeys = @($requiredImpactKeys | Sort-Object)
        coveredImpactKeys = @($coveredImpactKeys | Sort-Object)
        uncoveredImpactKeys = @($requiredImpactKeys | Where-Object { $_ -notin @($coveredImpactKeys) } | Sort-Object)
        untested = @($untested)
        deviceValidated = $deviceValidated
        businessWritePerformed = $businessWritePerformed
    }
    mutations = [ordered]@{ count = $mutationCount; unresolvedCount = $unresolvedMutationCount; summary = @($mutationSummary | Sort-Object) }
    freshness = [ordered]@{
        class = $resolvedFreshnessClass
        observedAt = $finishedAt.ToString("o")
        expiresAt = $expiresAt
        invalidationKeys = @($invalidationKeys | Sort-Object)
    }
    producer = [ordered]@{
        skillName = "wechat-miniprogram-test"
        skillVersion = "3.2.0"
        validatorIdentity = Get-ExactHash $validatorPath
    }
}

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$temporaryReceipt = Join-Path $outputRoot (".test-receipt-" + [guid]::NewGuid().ToString("N") + ".json")
try {
    $json = $receipt | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($temporaryReceipt, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    $global:LASTEXITCODE = 0
    $validationText = (& $validatorPath -ProjectAdapterPath $adapterFull -RequestPath $requestFull -ReceiptPath $temporaryReceipt -RequireFresh | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Generated receipt is invalid: $validationText" }
    Move-Item -LiteralPath $temporaryReceipt -Destination $receiptFull
} finally {
    if (Test-Path -LiteralPath $temporaryReceipt) { Remove-Item -LiteralPath $temporaryReceipt -Force }
}

[ordered]@{
    receiptPath = $receiptFull
    receiptSha256 = Get-ExactHash $receiptFull
    verdict = $verdict
    outcome = $outcome
    closure = $closure
    selectedScenarioCount = $selectedIds.Count
    executedScenarioCount = $executedIds.Count
} | ConvertTo-Json -Depth 6
