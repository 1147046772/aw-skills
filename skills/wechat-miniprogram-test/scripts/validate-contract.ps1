#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ProjectAdapterPath,
    [Parameter(Mandatory)] [string]$RequestPath,
    [string]$ReceiptPath = "",
    [switch]$RequireFresh,
    [DateTimeOffset]$AsOf = [DateTimeOffset]::Now
)

$ErrorActionPreference = "Stop"
$errors = [Collections.Generic.List[string]]::new()
$references = Join-Path (Split-Path -Parent $PSScriptRoot) "references"
$allowedTokens = @("{workspace}", "{requestPath}", "{scenarioPath}", "{evidencePath}", "{artifactRoot}")
$permissionNames = @(
    "devtoolsLifecycle", "runtimeRead", "networkAccess", "screenshot",
    "manualObservation", "loginAction", "accountSwitch", "businessWrite",
    "testDataMutation", "deviceStateChange"
)

function Add-ContractError([string]$Message) {
    $errors.Add($Message) | Out-Null
}

function Read-ContractJson([string]$Path, [string]$Label) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-ContractError "$Label does not exist: $Path"
        return $null
    }
    try {
        return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    } catch {
        Add-ContractError "$Label is not valid JSON: $($_.Exception.Message)"
        return $null
    }
}

function Test-ContractSchema($Value, [string]$SchemaName, [string]$Label) {
    if ($null -eq $Value) { return $false }
    try {
        $json = $Value | ConvertTo-Json -Depth 100
        $valid = Test-Json -Json $json -SchemaFile (Join-Path $references $SchemaName) -ErrorAction Stop
        if (!$valid) { Add-ContractError "$Label does not conform to $SchemaName" }
        return [bool]$valid
    } catch {
        Add-ContractError "$Label does not conform to ${SchemaName}: $($_.Exception.Message)"
        return $false
    }
}

function Get-ExactHash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-PhysicalPathChain([string]$Workspace, [string]$Candidate, [string]$Label) {
    if (!(Test-Path -LiteralPath $Workspace -PathType Container)) { return $true }
    $workspaceFull = [IO.Path]::GetFullPath($Workspace)
    $candidateFull = [IO.Path]::GetFullPath($Candidate)
    $prefix = $workspaceFull.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($candidateFull -ne $workspaceFull -and !$candidateFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        Add-ContractError "$Label escapes the physical workspace: $Candidate"
        return $false
    }

    $currentPath = $workspaceFull
    $segments = @()
    $relative = [IO.Path]::GetRelativePath($workspaceFull, $candidateFull)
    if ($relative -ne ".") { $segments = @($relative -split '[\\/]') }
    foreach ($segment in @(".") + $segments) {
        if ($segment -ne ".") { $currentPath = Join-Path $currentPath $segment }
        if (!(Test-Path -LiteralPath $currentPath)) { break }
        $item = Get-Item -LiteralPath $currentPath -Force
        $linkType = $item.PSObject.Properties["LinkType"]
        $hasLinkType = $null -ne $linkType -and ![string]::IsNullOrWhiteSpace([string]$linkType.Value)
        $isReparsePoint = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        if ($hasLinkType -or $isReparsePoint) {
            Add-ContractError "$Label contains a symbolic link or reparse point: $($item.FullName)"
            return $false
        }
    }
    return $true
}

function Resolve-WorkspacePath([string]$Workspace, [string]$RelativePath, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        Add-ContractError "$Label is empty"
        return $null
    }
    if ([IO.Path]::IsPathRooted($RelativePath)) {
        Add-ContractError "$Label must be workspace-relative: $RelativePath"
        return $null
    }
    try {
        $full = [IO.Path]::GetFullPath((Join-Path $Workspace $RelativePath))
        $prefix = $Workspace.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if ($full -ne $Workspace -and !$full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            Add-ContractError "$Label escapes the workspace: $RelativePath"
            return $null
        }
        if (!(Test-PhysicalPathChain $Workspace $full $Label)) { return $null }
        return $full
    } catch {
        Add-ContractError "$Label is invalid: $RelativePath"
        return $null
    }
}

function Test-SetEqual($Left, $Right) {
    return @((Compare-Object @($Left | Sort-Object -Unique) @($Right | Sort-Object -Unique))).Count -eq 0
}

function Test-IsUnder([string]$Child, [string]$Parent) {
    $parentPrefix = $Parent.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    return $Child -eq $Parent -or $Child.StartsWith($parentPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-StringHash([string]$Value) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Value)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Test-AnyOverlap($Left, $Right) {
    return @($Left | Where-Object { [string]$_ -in @($Right | ForEach-Object { [string]$_ }) }).Count -gt 0
}

$script:selectionReasons = @{}
function Add-SelectionReason([string]$ScenarioId, [string]$Reason) {
    if (!$script:selectionReasons.ContainsKey($ScenarioId)) {
        $script:selectionReasons[$ScenarioId] = [Collections.Generic.HashSet[string]]::new()
    }
    $script:selectionReasons[$ScenarioId].Add($Reason) | Out-Null
}

$adapterFull = [IO.Path]::GetFullPath($ProjectAdapterPath)
$requestFull = [IO.Path]::GetFullPath($RequestPath)
$adapter = Read-ContractJson $adapterFull "project adapter"
$request = Read-ContractJson $requestFull "test request"
$adapterValid = Test-ContractSchema $adapter "project.schema.json" "project adapter"
$requestValid = Test-ContractSchema $request "test-request.schema.json" "test request"

if ($null -eq $adapter -or $null -eq $request) {
    [ordered]@{ valid = $false; errors = @($errors) } | ConvertTo-Json -Depth 8
    exit 2
}

$adapterDirectory = Split-Path -Parent $adapterFull
$workspace = $null
if ([IO.Path]::IsPathRooted([string]$adapter.roots.workspace)) {
    Add-ContractError "adapter roots.workspace must be adapter-relative"
} else {
    try { $workspace = [IO.Path]::GetFullPath((Join-Path $adapterDirectory ([string]$adapter.roots.workspace))) }
    catch { Add-ContractError "adapter roots.workspace is invalid: $($_.Exception.Message)" }
}
if ($null -eq $workspace -or !(Test-Path -LiteralPath $workspace -PathType Container)) {
    Add-ContractError "resolved workspace does not exist"
} else {
    $null = Test-PhysicalPathChain $workspace $workspace "adapter roots.workspace"
}

$adapterHash = Get-ExactHash $adapterFull
$requestHash = Get-ExactHash $requestFull
if ([string]$request.projectAdapter.sha256 -ne $adapterHash) { Add-ContractError "project adapter hash mismatch" }
if ([string]$request.projectAdapter.adapterId -ne [string]$adapter.adapterId) { Add-ContractError "project adapter ID mismatch" }
if ([string]$request.projectAdapter.adapterVersion -ne [string]$adapter.adapterVersion) { Add-ContractError "project adapter version mismatch" }

$scenarioRoot = $null
$evidenceRoot = $null
$outputRoot = $null
if ($null -ne $workspace) {
    if (!(Test-IsUnder $adapterFull $workspace)) { Add-ContractError "project adapter is outside the resolved workspace" }
    elseif (!(Test-PhysicalPathChain $workspace $adapterFull "project adapter")) { $adapterValid = $false }
    if (!(Test-IsUnder $requestFull $workspace)) { Add-ContractError "test request is outside the resolved workspace" }
    elseif (!(Test-PhysicalPathChain $workspace $requestFull "test request")) { $requestValid = $false }
    $embeddedAdapter = Resolve-WorkspacePath $workspace ([string]$request.projectAdapter.path) "request projectAdapter.path"
    if ($null -ne $embeddedAdapter -and $embeddedAdapter -ne $adapterFull) { Add-ContractError "request projectAdapter.path does not resolve to the supplied adapter" }
    foreach ($pathFact in @(
        @{ name = "roots.source"; value = $adapter.roots.source; kind = "Container" },
        @{ name = "roots.devtoolsProject"; value = $adapter.roots.devtoolsProject; kind = "Container" },
        @{ name = "files.projectConfig"; value = $adapter.files.projectConfig; kind = "Leaf" },
        @{ name = "files.scenarioRoot"; value = $adapter.files.scenarioRoot; kind = "Container" },
        @{ name = "candidateIdentity.definitionRef"; value = $adapter.candidateIdentity.definitionRef; kind = "Leaf" }
    )) {
        $resolved = Resolve-WorkspacePath $workspace ([string]$pathFact.value) ([string]$pathFact.name)
        if ($null -ne $resolved -and !(Test-Path -LiteralPath $resolved -PathType $pathFact.kind)) { Add-ContractError "$($pathFact.name) does not exist" }
        if ($pathFact.name -eq "files.scenarioRoot") { $scenarioRoot = $resolved }
    }
    if ($null -ne $adapter.files.packageManifest) {
        $packagePath = Resolve-WorkspacePath $workspace ([string]$adapter.files.packageManifest) "files.packageManifest"
        if ($null -ne $packagePath -and !(Test-Path -LiteralPath $packagePath -PathType Leaf)) { Add-ContractError "files.packageManifest does not exist" }
    }
    $evidenceRoot = Resolve-WorkspacePath $workspace ([string]$adapter.evidenceRoot) "adapter evidenceRoot"
    $outputRoot = Resolve-WorkspacePath $workspace ([string]$request.output.root) "request output.root"
    if ($null -ne $evidenceRoot -and $null -ne $outputRoot -and !(Test-IsUnder $outputRoot $evidenceRoot)) { Add-ContractError "request output.root is outside adapter evidenceRoot" }
}

$runnerIds = @($adapter.runners | ForEach-Object { [string]$_.id })
if ($runnerIds.Count -ne @($runnerIds | Sort-Object -Unique).Count) { Add-ContractError "runner IDs are not unique" }
foreach ($runner in $adapter.runners) {
    foreach ($argument in $runner.argvTemplate) {
        $value = [string]$argument
        if ($value -match '[{}]' -and $value -notin $allowedTokens) { Add-ContractError "runner '$($runner.id)' contains an unknown or interpolated token: $value" }
    }
    if ($null -ne $workspace) {
        $runnerCwd = Resolve-WorkspacePath $workspace ([string]$runner.cwd) "runner '$($runner.id)' cwd"
        if ($null -ne $runnerCwd -and !(Test-Path -LiteralPath $runnerCwd -PathType Container)) { Add-ContractError "runner '$($runner.id)' cwd does not exist" }
    }
}

$catalog = $null
$catalogFull = $null
$catalogHash = $null
$catalogValid = $false
$scenarioFacts = [Collections.Generic.List[object]]::new()
if ($null -ne $workspace) {
    $catalogFull = Resolve-WorkspacePath $workspace ([string]$request.testPlan.catalog.path) "test catalog path"
    if ($null -ne $catalogFull) {
        $catalog = Read-ContractJson $catalogFull "test catalog"
        $catalogValid = Test-ContractSchema $catalog "test-catalog.schema.json" "test catalog"
        if ($null -ne $catalog) {
            $catalogHash = Get-ExactHash $catalogFull
            if ([string]$request.testPlan.catalog.sha256 -ne $catalogHash) { Add-ContractError "test catalog hash mismatch" }
            if ([string]$request.testPlan.catalog.catalogId -ne [string]$catalog.catalogId) { Add-ContractError "test catalog ID mismatch" }
            if ([string]$request.testPlan.catalog.catalogVersion -ne [string]$catalog.catalogVersion) { Add-ContractError "test catalog version mismatch" }
        }
    }
}

if ($null -ne $catalog) {
    $catalogIds = @($catalog.scenarios | ForEach-Object { [string]$_.id })
    if ($catalogIds.Count -ne @($catalogIds | Sort-Object -Unique).Count) { Add-ContractError "catalog scenario IDs are not unique" }
    foreach ($entry in $catalog.scenarios) {
        $scenarioFull = Resolve-WorkspacePath $workspace ([string]$entry.path) "catalog scenario '$($entry.id)' path"
        if ($null -eq $scenarioFull) { continue }
        if ($null -ne $scenarioRoot -and !(Test-IsUnder $scenarioFull $scenarioRoot)) { Add-ContractError "catalog scenario escapes scenario root: $($entry.id)" }
        $scenario = Read-ContractJson $scenarioFull "catalog scenario '$($entry.id)'"
        $null = Test-ContractSchema $scenario "scenario.schema.json" "catalog scenario '$($entry.id)'"
        if ($null -eq $scenario) { continue }
        $scenarioHash = Get-ExactHash $scenarioFull
        if ([string]$entry.sha256 -ne $scenarioHash) { Add-ContractError "catalog scenario hash mismatch: $($entry.id)" }
        if ([string]$entry.id -ne [string]$scenario.id) { Add-ContractError "catalog scenario ID mismatch: $($entry.id)" }
        $assertionIds = @($scenario.assertions | ForEach-Object { [string]$_.id })
        if ($assertionIds.Count -ne @($assertionIds | Sort-Object -Unique).Count) { Add-ContractError "scenario assertion IDs are not unique: $($entry.id)" }
        foreach ($assertion in $scenario.assertions) {
            if (@($assertion.impactKeys | Where-Object { [string]$_ -notin @($scenario.impact.keys) }).Count -gt 0) { Add-ContractError "assertion impact keys escape scenario impact: $($entry.id)/$($assertion.id)" }
        }
        if ([string]$scenario.runtime.channel -notin @($adapter.supportedChannels)) { Add-ContractError "scenario channel is not supported: $($entry.id)" }
        if ($null -ne $scenario.runtime.runnerId) {
            $runnerMatches = @($adapter.runners | Where-Object { [string]$_.id -ceq [string]$scenario.runtime.runnerId })
            if ($runnerMatches.Count -ne 1) {
                Add-ContractError "scenario runner does not resolve exactly once: $($entry.id)"
            } else {
                $runner = $runnerMatches[0]
                if ([string]$scenario.testType -notin @($runner.testTypes)) { Add-ContractError "scenario test type is not supported by its runner: $($entry.id)" }
                if ([string]$scenario.runtime.channel -ne [string]$runner.channel) { Add-ContractError "scenario runner channel mismatch: $($entry.id)" }
                $missingRunnerTools = @($scenario.runtime.requiredTools | Where-Object { [string]$_ -notin @($runner.capabilities) })
                if ($missingRunnerTools.Count -gt 0) { Add-ContractError "scenario runner lacks capabilities: $($entry.id)" }
            }
        } elseif ([string]$scenario.runtime.channel -notin @("wechatide-mcp", "human", "device")) {
            Add-ContractError "scenario requires a runner: $($entry.id)"
        }
        $missingAdapterTools = @($scenario.runtime.requiredTools | Where-Object { [string]$_ -notin @($adapter.capabilities) })
        if ($missingAdapterTools.Count -gt 0) { Add-ContractError "adapter lacks scenario capabilities: $($entry.id)" }
        $scenarioFacts.Add([pscustomobject]@{ entry = $entry; scenario = $scenario; path = $scenarioFull; hash = $scenarioHash }) | Out-Null
    }

    $relationIds = [Collections.Generic.HashSet[string]]::new()
    foreach ($relation in $catalog.relations) {
        $fromId = [string]$relation.upstreamScenarioId
        $toId = [string]$relation.downstreamScenarioId
        if ($fromId -eq $toId) { Add-ContractError "catalog relation cannot self-reference: $fromId" }
        if ($fromId -notin $catalogIds -or $toId -notin $catalogIds) { Add-ContractError "catalog relation endpoint does not exist: $fromId->$toId"; continue }
        $relationId = "$fromId`t$toId`t$(@($relation.impactKeys | Sort-Object) -join ',')"
        if (!$relationIds.Add($relationId)) { Add-ContractError "duplicate catalog relation: $fromId->$toId" }
        $fromFact = @($scenarioFacts | Where-Object { [string]$_.entry.id -eq $fromId })
        $toFact = @($scenarioFacts | Where-Object { [string]$_.entry.id -eq $toId })
        if ($fromFact.Count -eq 1 -and $toFact.Count -eq 1) {
            $shared = @($fromFact[0].scenario.impact.keys | Where-Object { [string]$_ -in @($toFact[0].scenario.impact.keys) })
            if (@($relation.impactKeys | Where-Object { [string]$_ -notin $shared }).Count -gt 0) { Add-ContractError "catalog relation keys are not shared by both scenarios: $fromId->$toId" }
        }
    }
}

$catalogIds = @($scenarioFacts | ForEach-Object { [string]$_.entry.id })
$selectedIds = @($request.testPlan.selectedScenarioIds | ForEach-Object { [string]$_ })
if (@($selectedIds | Where-Object { $_ -notin $catalogIds }).Count -gt 0) { Add-ContractError "selected scenario does not exist in catalog" }

$runMode = [string]$request.run.mode
$defectLineage = $request.defectLineage
$defects = if ($null -eq $defectLineage) { @() } else { @($defectLineage.defects) }
$defectScenarioIds = [Collections.Generic.HashSet[string]]::new()
$defectImpactKeys = [Collections.Generic.HashSet[string]]::new()
$defectFingerprints = @($defects | ForEach-Object { [string]$_.fingerprint })
if ($defectFingerprints.Count -ne @($defectFingerprints | Sort-Object -Unique).Count) { Add-ContractError "request defect fingerprints are not unique" }
foreach ($defect in $defects) {
    foreach ($group in $defect.failingAssertions) {
        $scenarioId = [string]$group.scenarioId
        $defectScenarioIds.Add($scenarioId) | Out-Null
        $fact = @($scenarioFacts | Where-Object { [string]$_.entry.id -eq $scenarioId })
        if ($fact.Count -ne 1) { Add-ContractError "defect scenario does not exist in catalog: $scenarioId"; continue }
        foreach ($assertionId in $group.assertionIds) {
            $assertion = @($fact[0].scenario.assertions | Where-Object { [string]$_.id -eq [string]$assertionId })
            if ($assertion.Count -ne 1) { Add-ContractError "defect assertion does not exist: $scenarioId/$assertionId"; continue }
            $expectedFingerprint = Get-StringHash "$scenarioId`t$assertionId`n"
            if ([string]$defect.fingerprint -ne $expectedFingerprint) { Add-ContractError "defect fingerprint mismatch: $scenarioId/$assertionId" }
            foreach ($key in $assertion[0].impactKeys) { $defectImpactKeys.Add([string]$key) | Out-Null }
        }
    }
}

$affectedKeys = [Collections.Generic.HashSet[string]]::new()
foreach ($key in $request.testPlan.changedImpactKeys) { $affectedKeys.Add([string]$key) | Out-Null }
foreach ($key in $defectImpactKeys) { $affectedKeys.Add([string]$key) | Out-Null }

$seedIds = [Collections.Generic.HashSet[string]]::new()
$expectedIds = [Collections.Generic.HashSet[string]]::new()
if ([string]$request.testPlan.strategy -eq "FULL") {
    foreach ($id in $catalogIds) { $seedIds.Add($id) | Out-Null; $expectedIds.Add($id) | Out-Null; Add-SelectionReason $id "full-suite" }
} else {
    if (@($request.testPlan.activeFullSuiteTriggers).Count -gt 0) { Add-ContractError "IMPACT selection cannot run with an active full-suite trigger" }
    foreach ($fact in $scenarioFacts) {
        $id = [string]$fact.entry.id
        $isDefect = $defectScenarioIds.Contains($id)
        $matchesChanged = Test-AnyOverlap @($fact.scenario.impact.keys) @($request.testPlan.changedImpactKeys)
        $matchesDefect = Test-AnyOverlap @($fact.scenario.impact.keys) @($defectImpactKeys)
        $includeAsSeed = if ($runMode -eq "DEFECT_REPRODUCTION") { $isDefect } else { $isDefect -or $matchesChanged -or $matchesDefect }
        if ($includeAsSeed) {
            $seedIds.Add($id) | Out-Null
            $expectedIds.Add($id) | Out-Null
            if ($isDefect) { Add-SelectionReason $id "defect-reproducer" }
            if ($matchesChanged) { Add-SelectionReason $id "changed-impact" }
            if ($runMode -ne "DEFECT_REPRODUCTION" -and $matchesDefect -and !$isDefect) { Add-SelectionReason $id "shared-impact" }
        }
    }
    if ($seedIds.Count -eq 0) { Add-ContractError "IMPACT selection has no resolvable seed" }

    $frontier = @($seedIds)
    for ($depth = 1; $depth -le [int]$request.testPlan.upstreamDepth; $depth++) {
        $next = [Collections.Generic.HashSet[string]]::new()
        foreach ($relation in $catalog.relations) {
            if ([string]$relation.downstreamScenarioId -in $frontier -and (Test-AnyOverlap @($relation.impactKeys) @($affectedKeys))) {
                $id = [string]$relation.upstreamScenarioId
                if ($expectedIds.Add($id)) { $next.Add($id) | Out-Null }
                Add-SelectionReason $id "upstream"
            }
        }
        $frontier = @($next)
    }

    $frontier = @($seedIds)
    for ($depth = 1; $depth -le [int]$request.testPlan.downstreamDepth; $depth++) {
        $next = [Collections.Generic.HashSet[string]]::new()
        foreach ($relation in $catalog.relations) {
            if ([string]$relation.upstreamScenarioId -in $frontier -and (Test-AnyOverlap @($relation.impactKeys) @($affectedKeys))) {
                $id = [string]$relation.downstreamScenarioId
                if ($expectedIds.Add($id)) { $next.Add($id) | Out-Null }
                Add-SelectionReason $id "downstream"
            }
        }
        $frontier = @($next)
    }
}

if (!(Test-SetEqual $selectedIds @($expectedIds))) { Add-ContractError "selected scenarios do not equal the computed impact closure" }
$excludedIds = @($catalogIds | Where-Object { $_ -notin $selectedIds } | Sort-Object -Unique)
foreach ($id in $selectedIds) {
    $fact = @($scenarioFacts | Where-Object { [string]$_.entry.id -eq $id })
    if ($fact.Count -eq 1) {
        foreach ($permission in $permissionNames) {
            if ([bool]$fact[0].scenario.permissions.$permission -and ![bool]$request.authorization.$permission) { Add-ContractError "selected scenario exceeds request authorization: $id/$permission" }
        }
    }
}

$parentReceipt = $null
$lineageSourcePath = $null
if ($null -ne $defectLineage) {
    $lineageSourcePath = Resolve-WorkspacePath $workspace ([string]$defectLineage.source.path) "defect lineage source path"
    if ($null -ne $lineageSourcePath) {
        if (!(Test-Path -LiteralPath $lineageSourcePath -PathType Leaf)) {
            Add-ContractError "defect lineage source does not exist"
        } elseif ((Get-ExactHash $lineageSourcePath) -ne [string]$defectLineage.source.sha256) {
            Add-ContractError "defect lineage source hash mismatch"
        }
    }
    if ([string]$defectLineage.source.type -eq "PARENT_RECEIPT" -and $null -ne $lineageSourcePath) {
        $parentReceipt = Read-ContractJson $lineageSourcePath "parent test receipt"
        $null = Test-ContractSchema $parentReceipt "test-receipt.schema.json" "parent test receipt"
        if ($null -ne $parentReceipt) {
            if ([string]$parentReceipt.receiptId -ne [string]$defectLineage.source.receiptId) { Add-ContractError "parent receipt ID mismatch" }
            if ($null -eq $parentReceipt.defectLineage) {
                if ([int]$defectLineage.round -ne 1) { Add-ContractError "a parent without defect lineage can seed only lineage round 1" }
            } else {
                if ([string]$parentReceipt.defectLineage.lineageId -ne [string]$defectLineage.lineageId) { Add-ContractError "parent receipt lineage mismatch" }
                if ([int]$parentReceipt.defectLineage.round -ne ([int]$defectLineage.round - 1)) { Add-ContractError "parent receipt round is not the immediate predecessor" }
            }
        }
    }
}

if ($runMode -eq "FIX_VERIFICATION" -and $null -ne $parentReceipt) {
    $identityChanged =
        [string]$parentReceipt.subject.sourceHash -ne [string]$request.candidate.sourceHash -or
        [string]$parentReceipt.subject.buildId -ne [string]$request.candidate.buildId -or
        [string]$parentReceipt.subject.apiIdentity -ne [string]$request.environment.apiIdentity -or
        [string]$parentReceipt.subject.environmentConfigHash -ne [string]$request.environment.configHash
    if (!$identityChanged) { Add-ContractError "FIX_VERIFICATION candidate identity did not change from the parent receipt" }
}

if ($null -ne $parentReceipt) {
    foreach ($defect in $defects) {
        $knownFingerprint = [string]$defect.fingerprint
        $parentKnown = @($parentReceipt.findings | Where-Object { [string]$_.fingerprint -eq $knownFingerprint }).Count -gt 0 -or @($parentReceipt.defectLineage.defects | Where-Object { [string]$_.fingerprint -eq $knownFingerprint }).Count -gt 0
        if (!$parentKnown) { Add-ContractError "defect fingerprint is absent from the parent receipt: $knownFingerprint" }
        foreach ($group in $defect.failingAssertions) {
            $parentResult = @($parentReceipt.scenarioResults | Where-Object { [string]$_.scenarioId -eq [string]$group.scenarioId })
            if ($parentResult.Count -ne 1) { Add-ContractError "parent receipt lacks defect scenario evidence: $($group.scenarioId)"; continue }
            $parentEvidencePath = Resolve-WorkspacePath $workspace ([string]$parentResult[0].evidencePath) "parent defect evidence path"
            if ($null -eq $parentEvidencePath) { continue }
            $parentEvidence = Read-ContractJson $parentEvidencePath "parent defect evidence"
            if ($null -eq $parentEvidence) { continue }
            if ((Get-ExactHash $parentEvidencePath) -ne [string]$parentResult[0].evidenceSha256) { Add-ContractError "parent defect evidence hash mismatch: $($group.scenarioId)" }
            foreach ($assertionId in $group.assertionIds) {
                $prior = @($parentEvidence.assertions | Where-Object { [string]$_.id -eq [string]$assertionId -and [string]$_.status -eq "FAIL" })
                if ($prior.Count -ne 1) { Add-ContractError "parent evidence does not contain the declared failing assertion: $($group.scenarioId)/$assertionId"; continue }
                if ([string]$prior[0].findingFingerprint -ne $knownFingerprint) { Add-ContractError "parent failing assertion fingerprint mismatch: $($group.scenarioId)/$assertionId" }
            }
        }
    }
}

$receiptValidated = $false
if (![string]::IsNullOrWhiteSpace($ReceiptPath)) {
    $receiptFull = [IO.Path]::GetFullPath($ReceiptPath)
    $receipt = Read-ContractJson $receiptFull "test receipt"
    $receiptValidated = Test-ContractSchema $receipt "test-receipt.schema.json" "test receipt"
    if ($null -ne $receipt -and $null -ne $workspace) {
        if ($null -ne $outputRoot -and !(Test-IsUnder $receiptFull $outputRoot)) { Add-ContractError "test receipt is outside request output.root" }
        foreach ($inputPath in @(
            @{ label = "request"; value = $receipt.input.requestPath; expected = $requestFull },
            @{ label = "adapter"; value = $receipt.input.projectAdapterPath; expected = $adapterFull },
            @{ label = "catalog"; value = $receipt.input.catalogPath; expected = $catalogFull }
        )) {
            $resolved = Resolve-WorkspacePath $workspace ([string]$inputPath.value) "receipt $($inputPath.label) path"
            if ($null -ne $resolved -and $resolved -ne $inputPath.expected) { Add-ContractError "receipt $($inputPath.label) path mismatch" }
        }
        if ([string]$receipt.input.requestId -ne [string]$request.requestId) { Add-ContractError "receipt request ID mismatch" }
        if ([string]$receipt.input.requestSha256 -ne $requestHash) { Add-ContractError "receipt request hash mismatch" }
        if ([string]$receipt.input.projectAdapterSha256 -ne $adapterHash) { Add-ContractError "receipt adapter hash mismatch" }
        if ([string]$receipt.input.catalogSha256 -ne $catalogHash) { Add-ContractError "receipt catalog hash mismatch" }
        if ([string]$receipt.subject.projectId -ne [string]$adapter.projectId) { Add-ContractError "receipt project ID mismatch" }
        if ([string]$receipt.subject.projectAdapterId -ne [string]$adapter.adapterId) { Add-ContractError "receipt adapter ID mismatch" }
        foreach ($pair in @(
            @{ label = "candidateRevision"; actual = $receipt.subject.candidateRevision; expected = $request.candidate.revision },
            @{ label = "diffHash"; actual = $receipt.subject.diffHash; expected = $request.candidate.diffHash },
            @{ label = "sourceHash"; actual = $receipt.subject.sourceHash; expected = $request.candidate.sourceHash },
            @{ label = "buildId"; actual = $receipt.subject.buildId; expected = $request.candidate.buildId },
            @{ label = "environment"; actual = $receipt.subject.environment; expected = $request.environment.id },
            @{ label = "appId"; actual = $receipt.subject.appId; expected = $request.environment.appId },
            @{ label = "apiIdentity"; actual = $receipt.subject.apiIdentity; expected = $request.environment.apiIdentity },
            @{ label = "environmentConfigHash"; actual = $receipt.subject.environmentConfigHash; expected = $request.environment.configHash }
        )) {
            if ([string]$pair.actual -ne [string]$pair.expected) { Add-ContractError "receipt $($pair.label) mismatch" }
        }
        foreach ($runPair in @(
            @{ label = "runId"; actual = $receipt.run.runId; expected = $request.run.runId },
            @{ label = "mode"; actual = $receipt.run.mode; expected = $request.run.mode }
        )) {
            if ([string]$runPair.actual -ne [string]$runPair.expected) { Add-ContractError "receipt $($runPair.label) mismatch" }
        }
        try {
            $requestedAt = [DateTimeOffset]::Parse([string]$request.requestedAt)
            $receiptStartedAt = [DateTimeOffset]::Parse([string]$receipt.timing.startedAt)
            $receiptFinishedAt = [DateTimeOffset]::Parse([string]$receipt.timing.finishedAt)
            $issuedAt = [DateTimeOffset]::Parse([string]$receipt.issuedAt)
            $observedAt = [DateTimeOffset]::Parse([string]$receipt.freshness.observedAt)
            if ($receiptStartedAt -lt $requestedAt) { Add-ContractError "receipt started before the request was issued" }
            if ($receiptFinishedAt -lt $receiptStartedAt) { Add-ContractError "receipt finished before it started" }
            if ([Math]::Abs((($receiptFinishedAt - $receiptStartedAt).TotalMilliseconds) - [double]$receipt.timing.durationMs) -gt 1) { Add-ContractError "receipt duration does not match timing" }
            if ($issuedAt -lt $receiptFinishedAt) { Add-ContractError "receipt was issued before execution finished" }
            if ($observedAt -lt $receiptFinishedAt) { Add-ContractError "receipt freshness was observed before execution finished" }
            if ($null -ne $receipt.freshness.expiresAt) {
                $expiresAt = [DateTimeOffset]::Parse([string]$receipt.freshness.expiresAt)
                if ($expiresAt -le $observedAt) { Add-ContractError "receipt freshness expiry is not after observation" }
                if ([string]$receipt.freshness.class -eq "DETERMINISTIC") { Add-ContractError "deterministic receipt must not have an expiry" }
            } elseif ([string]$receipt.freshness.class -ne "DETERMINISTIC") {
                Add-ContractError "non-deterministic receipt requires freshness expiry"
            }
        } catch {
            Add-ContractError "receipt timing or freshness is invalid: $($_.Exception.Message)"
        }
        $requiredInvalidationKeys = @("candidate", "request", "catalog", "environment")
        foreach ($key in $requiredInvalidationKeys) {
            if ([string]$key -notin @($receipt.freshness.invalidationKeys)) { Add-ContractError "receipt freshness omits invalidation key: $key" }
        }
        $hasSessionRuntime = @($receipt.runtimeProfiles | Where-Object { ![string]::IsNullOrWhiteSpace([string]$_.sessionFingerprint) }).Count -gt 0
        if ($hasSessionRuntime -and "session" -notin @($receipt.freshness.invalidationKeys)) { Add-ContractError "session-backed receipt omits the session invalidation key" }
        if ($null -eq $defectLineage) {
            if ($null -ne $receipt.defectLineage) { Add-ContractError "receipt has undeclared defect lineage" }
        } elseif ($null -eq $receipt.defectLineage) {
            Add-ContractError "receipt omits declared defect lineage"
        } else {
            $sourceReference = if ([string]$defectLineage.source.type -eq "PARENT_RECEIPT") { [string]$defectLineage.source.receiptId } else { [string]$defectLineage.source.reference }
            foreach ($lineagePair in @(
                @{ label = "lineageId"; actual = $receipt.defectLineage.lineageId; expected = $defectLineage.lineageId },
                @{ label = "round"; actual = $receipt.defectLineage.round; expected = $defectLineage.round },
                @{ label = "source.type"; actual = $receipt.defectLineage.source.type; expected = $defectLineage.source.type },
                @{ label = "source.reference"; actual = $receipt.defectLineage.source.reference; expected = $sourceReference },
                @{ label = "source.path"; actual = $receipt.defectLineage.source.path; expected = $defectLineage.source.path },
                @{ label = "source.sha256"; actual = $receipt.defectLineage.source.sha256; expected = $defectLineage.source.sha256 }
            )) {
                if ([string]$lineagePair.actual -ne [string]$lineagePair.expected) { Add-ContractError "receipt defect $($lineagePair.label) mismatch" }
            }
        }

        if ([string]$receipt.selection.strategy -ne [string]$request.testPlan.strategy) { Add-ContractError "receipt selection strategy mismatch" }
        if ([int]$receipt.selection.catalogScenarioCount -ne $catalogIds.Count) { Add-ContractError "receipt catalog scenario count mismatch" }
        if (!(Test-SetEqual @($receipt.selection.changedImpactKeys) @($request.testPlan.changedImpactKeys))) { Add-ContractError "receipt changed-impact keys mismatch" }
        if (!(Test-SetEqual @($receipt.selection.seedScenarioIds) @($seedIds))) { Add-ContractError "receipt seed scenarios mismatch" }
        if (!(Test-SetEqual @($receipt.selection.selectedScenarioIds) $selectedIds)) { Add-ContractError "receipt selected scenarios mismatch" }
        if (@($receipt.selection.executedScenarioIds | Where-Object { [string]$_ -notin $selectedIds }).Count -gt 0) { Add-ContractError "receipt executed scenario is outside the selected boundary" }
        if ($receipt.result.verdict -eq "PASS" -and !(Test-SetEqual @($receipt.selection.executedScenarioIds) $selectedIds)) { Add-ContractError "PASS receipt does not close selected scenarios" }
        if (!(Test-SetEqual @($receipt.selection.excludedScenarioIds) $excludedIds)) { Add-ContractError "receipt excluded scenarios mismatch" }
        if ([int]$receipt.selection.upstreamDepth -ne [int]$request.testPlan.upstreamDepth -or [int]$receipt.selection.downstreamDepth -ne [int]$request.testPlan.downstreamDepth) { Add-ContractError "receipt graph depth mismatch" }
        if (!(Test-SetEqual @($receipt.selection.activeFullSuiteTriggers) @($request.testPlan.activeFullSuiteTriggers))) { Add-ContractError "receipt full-suite triggers mismatch" }
        $reasonIds = @($receipt.selection.reasonByScenario | ForEach-Object { [string]$_.scenarioId })
        if ($reasonIds.Count -ne @($reasonIds | Sort-Object -Unique).Count) { Add-ContractError "receipt selection-reason scenario IDs are not unique" }
        if (!(Test-SetEqual $reasonIds $selectedIds)) { Add-ContractError "receipt selection-reason scenario set mismatch" }
        foreach ($reasonFact in $receipt.selection.reasonByScenario) {
            $expectedReasons = if ($script:selectionReasons.ContainsKey([string]$reasonFact.scenarioId)) { @($script:selectionReasons[[string]$reasonFact.scenarioId]) } else { @() }
            if (!(Test-SetEqual @($reasonFact.reasons) $expectedReasons)) { Add-ContractError "receipt selection reasons mismatch: $($reasonFact.scenarioId)" }
        }

        $requiredTotal = 0
        $passedTotal = 0
        $failedTotal = 0
        $blockedTotal = 0
        $advisoryTotal = 0
        $executedPages = [Collections.Generic.HashSet[string]]::new()
        $coveredImpactKeys = [Collections.Generic.HashSet[string]]::new()
        $expectedFindings = [Collections.Generic.List[object]]::new()
        $expectedBlockers = [Collections.Generic.List[object]]::new()
        $expectedMutationSummary = [Collections.Generic.List[string]]::new()
        $expectedMutationCount = 0
        $expectedUnresolvedMutationCount = 0
        $expectedDeviceValidated = $false
        $expectedBusinessWritePerformed = $false
        $evidenceByScenario = @{}
        foreach ($scenarioResult in $receipt.scenarioResults) {
            $scenarioId = [string]$scenarioResult.scenarioId
            $fact = @($scenarioFacts | Where-Object { [string]$_.entry.id -eq $scenarioId })
            if ($fact.Count -ne 1 -or $scenarioId -notin $selectedIds) { Add-ContractError "receipt scenario result is not selected: $scenarioId"; continue }
            if ([string]$scenarioResult.scenarioHash -ne [string]$fact[0].hash) { Add-ContractError "receipt scenario hash mismatch: $scenarioId" }
            $expectedReasons = @($script:selectionReasons[$scenarioId])
            $evidenceFull = Resolve-WorkspacePath $workspace ([string]$scenarioResult.evidencePath) "scenario evidence path"
            if ($null -eq $evidenceFull) { continue }
            if ($null -ne $outputRoot -and !(Test-IsUnder $evidenceFull $outputRoot)) { Add-ContractError "scenario evidence is outside request output.root: $scenarioId" }
            $evidence = Read-ContractJson $evidenceFull "scenario evidence '$scenarioId'"
            $null = Test-ContractSchema $evidence "evidence.schema.json" "scenario evidence '$scenarioId'"
            if ($null -eq $evidence) { continue }
            $unresolvedEvidenceMutations = @($evidence.mutations | Where-Object { [string]$_.resolution -eq "UNRESOLVED" })
            if ($unresolvedEvidenceMutations.Count -gt 0 -and [string]$evidence.verdict -ne "BLOCKED") { Add-ContractError "unresolved mutation requires BLOCKED evidence: $scenarioId" }
            if ($unresolvedEvidenceMutations.Count -gt 0 -and @($evidence.blockers).Count -eq 0) { Add-ContractError "unresolved mutation requires a blocker: $scenarioId" }
            $evidenceByScenario[$scenarioId] = $evidence
            $evidenceHash = Get-ExactHash $evidenceFull
            if ($evidenceHash -ne [string]$scenarioResult.evidenceSha256) { Add-ContractError "scenario evidence hash mismatch: $scenarioId" }
            try {
                $evidenceStartedAt = [DateTimeOffset]::Parse([string]$evidence.timing.startedAt)
                $evidenceFinishedAt = [DateTimeOffset]::Parse([string]$evidence.timing.finishedAt)
                if ($evidenceFinishedAt -lt $evidenceStartedAt) { Add-ContractError "evidence finished before it started: $scenarioId" }
                if ([Math]::Abs((($evidenceFinishedAt - $evidenceStartedAt).TotalMilliseconds) - [double]$evidence.timing.durationMs) -gt 1) { Add-ContractError "evidence duration does not match timing: $scenarioId" }
                if ($evidenceStartedAt -lt $requestedAt -or $evidenceStartedAt -lt $receiptStartedAt -or $evidenceFinishedAt -gt $receiptFinishedAt) { Add-ContractError "evidence timing is outside the receipt run: $scenarioId" }
            } catch {
                Add-ContractError "evidence timing is invalid: $scenarioId/$($_.Exception.Message)"
            }
            foreach ($scopePair in @(
                @{ label = "projectAdapterHash"; actual = $evidence.scope.projectAdapterHash; expected = $adapterHash },
                @{ label = "requestHash"; actual = $evidence.scope.requestHash; expected = $requestHash },
                @{ label = "sourceHash"; actual = $evidence.scope.sourceHash; expected = $request.candidate.sourceHash },
                @{ label = "buildId"; actual = $evidence.scope.buildId; expected = $request.candidate.buildId },
                @{ label = "environment"; actual = $evidence.scope.environment; expected = $request.environment.id },
                @{ label = "appId"; actual = $evidence.scope.appId; expected = $request.environment.appId },
                @{ label = "apiIdentity"; actual = $evidence.scope.apiIdentity; expected = $request.environment.apiIdentity },
                @{ label = "environmentConfigHash"; actual = $evidence.scope.environmentConfigHash; expected = $request.environment.configHash },
                @{ label = "runId"; actual = $evidence.scope.runId; expected = $request.run.runId },
                @{ label = "runMode"; actual = $evidence.scope.runMode; expected = $request.run.mode },
                @{ label = "defectLineageId"; actual = $evidence.scope.defectLineageId; expected = $defectLineage.lineageId },
                @{ label = "defectRound"; actual = $evidence.scope.defectRound; expected = $defectLineage.round },
                @{ label = "scenarioHash"; actual = $evidence.scope.scenarioHash; expected = $fact[0].hash },
                @{ label = "scenarioId"; actual = $evidence.scope.scenarioId; expected = $scenarioId }
            )) {
                if ([string]$scopePair.actual -ne [string]$scopePair.expected) { Add-ContractError "evidence $($scopePair.label) mismatch: $scenarioId" }
            }
            if (!(Test-SetEqual @($evidence.scope.selectionReasons) $expectedReasons)) { Add-ContractError "evidence selection reasons mismatch: $scenarioId" }
            $runtimeProfile = @($receipt.runtimeProfiles | Where-Object { [string]$_.scenarioId -eq $scenarioId })
            if ($runtimeProfile.Count -ne 1) {
                Add-ContractError "receipt runtime profile does not resolve exactly once: $scenarioId"
            } else {
                foreach ($runtimePair in @(
                    @{ label = "channel"; actual = $runtimeProfile[0].channel; expected = $evidence.runtime.channel },
                    @{ label = "runnerId"; actual = $runtimeProfile[0].runnerId; expected = $evidence.runtime.runnerId },
                    @{ label = "controllerIdentity"; actual = $runtimeProfile[0].controllerIdentity; expected = $evidence.runtime.controllerIdentity },
                    @{ label = "devtoolsVersion"; actual = $runtimeProfile[0].devtoolsVersion; expected = $evidence.runtime.devtoolsVersion },
                    @{ label = "protocolVersion"; actual = $runtimeProfile[0].protocolVersion; expected = $evidence.runtime.protocolVersion },
                    @{ label = "sessionFingerprint"; actual = $runtimeProfile[0].sessionFingerprint; expected = $evidence.runtime.sessionFingerprint },
                    @{ label = "commandIdentity"; actual = $runtimeProfile[0].commandIdentity; expected = $evidence.runtime.commandIdentity }
                )) {
                    if ([string]$runtimePair.actual -ne [string]$runtimePair.expected) { Add-ContractError "receipt runtime $($runtimePair.label) mismatch: $scenarioId" }
                }
                $profileDevice = $runtimeProfile[0].deviceProfile | ConvertTo-Json -Depth 20 -Compress
                $evidenceDevice = $evidence.runtime.deviceProfile | ConvertTo-Json -Depth 20 -Compress
                if ($profileDevice -ne $evidenceDevice) { Add-ContractError "receipt runtime device profile mismatch: $scenarioId" }
            }
            if (!(Test-SetEqual @($evidence.assertions.id) @($fact[0].scenario.assertions.id))) { Add-ContractError "evidence assertion set mismatch: $scenarioId" }
            foreach ($assertion in $evidence.assertions) {
                $definition = @($fact[0].scenario.assertions | Where-Object { [string]$_.id -eq [string]$assertion.id })
                if ($definition.Count -ne 1) { continue }
                foreach ($assertionPair in @(
                    @{ label = "kind"; actual = $assertion.kind; expected = $definition[0].kind },
                    @{ label = "operator"; actual = $assertion.operator; expected = $definition[0].operator },
                    @{ label = "sourceOfTruth"; actual = $assertion.sourceOfTruth; expected = $definition[0].sourceOfTruth },
                    @{ label = "severity"; actual = $assertion.severity; expected = $definition[0].severity }
                )) {
                    if ([string]$assertionPair.actual -ne [string]$assertionPair.expected) { Add-ContractError "evidence assertion $($assertionPair.label) mismatch: $scenarioId/$($assertion.id)" }
                }
                if ([string]$assertion.status -eq "FAIL") {
                    $fingerprint = Get-StringHash "$scenarioId`t$([string]$assertion.id)`n"
                    if ([string]$assertion.findingFingerprint -ne $fingerprint) { Add-ContractError "finding fingerprint mismatch: $scenarioId/$($assertion.id)" }
                    $matchingDefect = @($defects | Where-Object { [string]$_.fingerprint -eq $fingerprint })
                    $defectId = if ($matchingDefect.Count -gt 0) { $matchingDefect[0].defectId } else { $null }
                    $classification = if ([string]$assertion.severity -eq "REQUIRED") { "PRODUCT_DEFECT" } else { "ADVISORY" }
                    $expectedFindings.Add([pscustomobject]@{ fingerprint = $fingerprint; defectId = $defectId; classification = $classification; scenarioId = $scenarioId; assertionId = [string]$assertion.id; evidencePath = [string]$scenarioResult.evidencePath; evidenceSha256 = $evidenceHash }) | Out-Null
                }
                if ([string]$assertion.status -ne "BLOCKED") {
                    foreach ($impactKey in $definition[0].impactKeys) { $coveredImpactKeys.Add([string]$impactKey) | Out-Null }
                }
            }
            $requiredAssertions = @($evidence.assertions | Where-Object { $_.severity -eq "REQUIRED" })
            $advisoryFindings = @($evidence.assertions | Where-Object { $_.severity -eq "ADVISORY" -and $_.status -ne "PASS" })
            $passed = @($requiredAssertions | Where-Object { $_.status -eq "PASS" }).Count
            $failed = @($requiredAssertions | Where-Object { $_.status -eq "FAIL" }).Count
            $blocked = @($requiredAssertions | Where-Object { $_.status -eq "BLOCKED" }).Count
            if ($scenarioResult.requiredAssertionCount -ne $requiredAssertions.Count -or $scenarioResult.passedAssertionCount -ne $passed -or $scenarioResult.failedAssertionCount -ne $failed -or $scenarioResult.blockedAssertionCount -ne $blocked) { Add-ContractError "scenario assertion counts mismatch: $scenarioId" }
            if ([string]$scenarioResult.verdict -ne [string]$evidence.verdict) { Add-ContractError "scenario verdict mismatch: $scenarioId" }
            if ($scenarioResult.artifactCount -ne @($evidence.artifacts).Count) { Add-ContractError "scenario artifact count mismatch: $scenarioId" }
            foreach ($artifact in $evidence.artifacts) {
                $artifactFull = Resolve-WorkspacePath $workspace ([string]$artifact.path) "artifact '$($artifact.id)' path"
                if ($null -eq $artifactFull -or !(Test-Path -LiteralPath $artifactFull -PathType Leaf)) { Add-ContractError "artifact does not exist: $($artifact.id)"; continue }
                if ($null -ne $outputRoot -and !(Test-IsUnder $artifactFull $outputRoot)) { Add-ContractError "artifact is outside request output.root: $($artifact.id)" }
                $item = Get-Item -LiteralPath $artifactFull
                if ((Get-ExactHash $artifactFull) -ne [string]$artifact.sha256) { Add-ContractError "artifact hash mismatch: $($artifact.id)" }
                if ($item.Length -ne [long]$artifact.sizeBytes) { Add-ContractError "artifact size mismatch: $($artifact.id)" }
                try {
                    $declaredModifiedAt = [DateTimeOffset]::Parse([string]$artifact.modifiedAt)
                    $actualModifiedAt = [DateTimeOffset]$item.LastWriteTimeUtc
                    if ([Math]::Abs(($declaredModifiedAt - $actualModifiedAt).TotalSeconds) -gt 2) { Add-ContractError "artifact modifiedAt mismatch: $($artifact.id)" }
                    $scenarioStartedAt = [DateTimeOffset]::Parse([string]$evidence.timing.startedAt)
                    $scenarioFinishedAt = [DateTimeOffset]::Parse([string]$evidence.timing.finishedAt)
                    if ($declaredModifiedAt -lt $scenarioStartedAt.AddSeconds(-5) -or $declaredModifiedAt -gt $scenarioFinishedAt.AddSeconds(5)) { Add-ContractError "artifact modifiedAt is outside scenario timing: $($artifact.id)" }
                } catch {
                    Add-ContractError "artifact modifiedAt is invalid: $($artifact.id)"
                }
            }
            $allowedPages = @($fact[0].scenario.targetPages.route | ForEach-Object { [string]$_ })
            foreach ($page in $evidence.scope.observedPages) {
                if ([string]$page -notin $allowedPages) { Add-ContractError "evidence observed an undeclared page: $scenarioId/$page" }
                $executedPages.Add([string]$page) | Out-Null
            }
            foreach ($blocker in $evidence.blockers) {
                $expectedBlockers.Add([pscustomobject]@{
                    scenarioId = $scenarioId
                    reasonClass = [string]$blocker.reasonClass
                    detail = [string]$blocker.detail
                    nextStep = [string]$blocker.nextStep
                    evidencePath = [string]$scenarioResult.evidencePath
                    evidenceSha256 = $evidenceHash
                }) | Out-Null
            }
            $scenarioBusinessWrites = @($evidence.mutations | Where-Object { [string]$_.type -eq "business-write" -and [int]$_.attempts -eq 1 }).Count
            if ([bool]$evidence.scope.businessWrite -ne ($scenarioBusinessWrites -gt 0)) { Add-ContractError "evidence businessWrite flag does not match mutations: $scenarioId" }
            if ($scenarioBusinessWrites -gt 0) { $expectedBusinessWritePerformed = $true }
            if ($null -ne $evidence.runtime.deviceProfile -and [string]$evidence.runtime.channel -eq "device") { $expectedDeviceValidated = $true }
            foreach ($mutation in $evidence.mutations) {
                if ([int]$mutation.attempts -eq 1 -and [string]$mutation.type -ne "none") {
                    $expectedMutationCount++
                    if ([string]$mutation.resolution -eq "UNRESOLVED") { $expectedUnresolvedMutationCount++ }
                    $expectedMutationSummary.Add("${scenarioId}:$([string]$mutation.type):$([string]$mutation.resolution)") | Out-Null
                }
            }
            $requiredTotal += $requiredAssertions.Count
            $passedTotal += $passed
            $failedTotal += $failed
            $blockedTotal += $blocked
            $advisoryTotal += $advisoryFindings.Count
        }

        $scenarioResultIds = @($receipt.scenarioResults | ForEach-Object { [string]$_.scenarioId })
        if ($scenarioResultIds.Count -ne @($scenarioResultIds | Sort-Object -Unique).Count) { Add-ContractError "receipt scenario-result IDs are not unique" }
        if (!(Test-SetEqual @($receipt.selection.executedScenarioIds) $scenarioResultIds)) { Add-ContractError "receipt executed scenarios and scenario results differ" }
        $runtimeProfileIds = @($receipt.runtimeProfiles | ForEach-Object { [string]$_.scenarioId })
        if ($runtimeProfileIds.Count -ne @($runtimeProfileIds | Sort-Object -Unique).Count) { Add-ContractError "receipt runtime-profile scenario IDs are not unique" }
        if (!(Test-SetEqual $runtimeProfileIds $scenarioResultIds)) { Add-ContractError "receipt runtime profiles and scenario results differ" }
        if ($receipt.result.requiredAssertionCount -ne $requiredTotal -or $receipt.result.passedAssertionCount -ne $passedTotal -or $receipt.result.failedAssertionCount -ne $failedTotal -or $receipt.result.blockedAssertionCount -ne $blockedTotal -or $receipt.result.advisoryNonPassCount -ne $advisoryTotal) { Add-ContractError "aggregate assertion counts mismatch" }

        $expectedFindingKeys = @($expectedFindings | ForEach-Object { "$($_.fingerprint)`t$($_.scenarioId)`t$($_.assertionId)`t$($_.classification)`t$($_.evidencePath)`t$($_.evidenceSha256)`t$($_.defectId)" })
        $receiptFindingKeys = @($receipt.findings | ForEach-Object { "$($_.fingerprint)`t$($_.scenarioId)`t$($_.assertionId)`t$($_.classification)`t$($_.evidencePath)`t$($_.evidenceSha256)`t$($_.defectId)" })
        if ($receiptFindingKeys.Count -ne @($receiptFindingKeys | Sort-Object -Unique).Count) { Add-ContractError "receipt findings are not unique" }
        if (!(Test-SetEqual $receiptFindingKeys $expectedFindingKeys)) { Add-ContractError "receipt findings do not exactly match evidence" }
        if ($receipt.findings.Count -ne $expectedFindings.Count) { Add-ContractError "receipt finding count mismatch" }
        foreach ($finding in $receipt.findings) {
            $match = @($expectedFindings | Where-Object {
                [string]$_.fingerprint -eq [string]$finding.fingerprint -and
                [string]$_.scenarioId -eq [string]$finding.scenarioId -and
                [string]$_.assertionId -eq [string]$finding.assertionId -and
                [string]$_.classification -eq [string]$finding.classification -and
                [string]$_.evidencePath -eq [string]$finding.evidencePath -and
                [string]$_.evidenceSha256 -eq [string]$finding.evidenceSha256
            })
            if ($match.Count -ne 1 -or [string]$match[0].defectId -ne [string]$finding.defectId) { Add-ContractError "receipt finding does not match evidence: $($finding.scenarioId)/$($finding.assertionId)" }
        }

        $expectedBlockerKeys = @($expectedBlockers | ForEach-Object { "$($_.scenarioId)`t$($_.reasonClass)`t$($_.detail)`t$($_.nextStep)`t$($_.evidencePath)`t$($_.evidenceSha256)" })
        $receiptBlockerKeys = @($receipt.blockers | ForEach-Object { "$($_.scenarioId)`t$($_.reasonClass)`t$($_.detail)`t$($_.nextStep)`t$($_.evidencePath)`t$($_.evidenceSha256)" })
        if ($receiptBlockerKeys.Count -ne @($receiptBlockerKeys | Sort-Object -Unique).Count) { Add-ContractError "receipt blockers are not unique" }
        if (!(Test-SetEqual $receiptBlockerKeys $expectedBlockerKeys) -or $receipt.blockers.Count -ne $expectedBlockers.Count) { Add-ContractError "receipt blockers do not exactly match evidence" }

        $targetPages = @($scenarioFacts | Where-Object { [string]$_.entry.id -in $selectedIds } | ForEach-Object { $_.scenario.targetPages.route } | Sort-Object -Unique)
        $requiredImpactKeys = @($scenarioFacts | Where-Object { [string]$_.entry.id -in $selectedIds } | ForEach-Object {
            $_.scenario.assertions | Where-Object { [string]$_.severity -eq "REQUIRED" } | ForEach-Object { $_.impactKeys }
        } | Sort-Object -Unique)
        $uncoveredImpactKeys = @($requiredImpactKeys | Where-Object { [string]$_ -notin @($coveredImpactKeys) } | Sort-Object -Unique)
        $untestedIds = @($selectedIds | Where-Object { [string]$_ -notin @($receipt.selection.executedScenarioIds) } | Sort-Object -Unique)
        if (!(Test-SetEqual @($receipt.coverage.targetPages) $targetPages)) { Add-ContractError "receipt target-page coverage mismatch" }
        if (!(Test-SetEqual @($receipt.coverage.testedPages) @($executedPages))) { Add-ContractError "receipt tested-page coverage mismatch" }
        if (!(Test-SetEqual @($receipt.coverage.requiredImpactKeys) $requiredImpactKeys)) { Add-ContractError "receipt required-impact coverage mismatch" }
        if (!(Test-SetEqual @($receipt.coverage.coveredImpactKeys) @($coveredImpactKeys))) { Add-ContractError "receipt covered-impact keys mismatch" }
        if (!(Test-SetEqual @($receipt.coverage.uncoveredImpactKeys) $uncoveredImpactKeys)) { Add-ContractError "receipt uncovered-impact keys mismatch" }
        if (!(Test-SetEqual @($receipt.coverage.untested) $untestedIds)) { Add-ContractError "receipt untested scenarios mismatch" }
        if ([bool]$receipt.coverage.deviceValidated -ne $expectedDeviceValidated) { Add-ContractError "receipt device coverage mismatch" }
        if ([bool]$receipt.coverage.businessWritePerformed -ne $expectedBusinessWritePerformed) { Add-ContractError "receipt business-write coverage mismatch" }
        if ([int]$receipt.mutations.count -ne $expectedMutationCount -or [int]$receipt.mutations.unresolvedCount -ne $expectedUnresolvedMutationCount) { Add-ContractError "receipt mutation counts mismatch" }
        if (!(Test-SetEqual @($receipt.mutations.summary) @($expectedMutationSummary))) { Add-ContractError "receipt mutation summary mismatch" }
        $expectedFreshnessClass = if ($hasSessionRuntime -and $expectedMutationCount -gt 0) { "MIXED" } elseif ($hasSessionRuntime) { "SESSION_BOUND" } elseif ($expectedMutationCount -gt 0) { "LIVE_MUTABLE" } else { "DETERMINISTIC" }
        if ([string]$receipt.freshness.class -ne $expectedFreshnessClass) { Add-ContractError "receipt freshness class does not match runtime facts" }
        if ($expectedMutationCount -gt 0 -and "mutation-state" -notin @($receipt.freshness.invalidationKeys)) { Add-ContractError "mutable receipt omits the mutation-state invalidation key" }

        $expectedVerdict = if ($expectedBlockers.Count -gt 0 -or $blockedTotal -gt 0 -or ($untestedIds.Count -gt 0 -and $failedTotal -eq 0)) { "BLOCKED" } elseif ($failedTotal -gt 0) { "FAIL" } else { "PASS" }
        if ([string]$receipt.result.verdict -ne $expectedVerdict) { Add-ContractError "receipt verdict does not match scenario evidence" }

        $expectedDefectFacts = [Collections.Generic.List[object]]::new()
        foreach ($defect in $defects) {
            $currentFailing = [Collections.Generic.List[object]]::new()
            $hasBlocked = $false
            $allPass = $true
            foreach ($group in $defect.failingAssertions) {
                $failedIds = [Collections.Generic.List[string]]::new()
                $evidence = $evidenceByScenario[[string]$group.scenarioId]
                foreach ($assertionId in $group.assertionIds) {
                    $current = if ($null -ne $evidence) { @($evidence.assertions | Where-Object { [string]$_.id -eq [string]$assertionId }) } else { @() }
                    if ($current.Count -ne 1) { $allPass = $false; continue }
                    if ([string]$current[0].status -eq "FAIL") { $failedIds.Add([string]$assertionId) | Out-Null; $allPass = $false }
                    elseif ([string]$current[0].status -eq "BLOCKED") { $hasBlocked = $true; $allPass = $false }
                    elseif ([string]$current[0].status -ne "PASS") { $allPass = $false }
                }
                if ($failedIds.Count -gt 0) { $currentFailing.Add([pscustomobject]@{ scenarioId = [string]$group.scenarioId; assertionIds = @($failedIds) }) | Out-Null }
            }
            $status = if ($hasBlocked) { "BLOCKED" } elseif ($currentFailing.Count -gt 0) { "REPRODUCED" } elseif ($allPass -and $runMode -eq "FIX_VERIFICATION") { "FIX_VERIFIED" } elseif ($allPass) { "NOT_REPRODUCED" } else { "OPEN" }
            $expectedDefectFacts.Add([pscustomobject]@{ defect = $defect; status = $status; currentFailing = @($currentFailing) }) | Out-Null
        }
        $receiptDefects = if ($null -eq $receipt.defectLineage) { @() } else { @($receipt.defectLineage.defects) }
        if ($receiptDefects.Count -ne $expectedDefectFacts.Count) { Add-ContractError "receipt defect count mismatch" }
        $receiptDefectFingerprints = @($receiptDefects | ForEach-Object { [string]$_.fingerprint })
        if ($receiptDefectFingerprints.Count -ne @($receiptDefectFingerprints | Sort-Object -Unique).Count) { Add-ContractError "receipt defect fingerprints are not unique" }
        foreach ($receiptDefect in $receiptDefects) {
            $expected = @($expectedDefectFacts | Where-Object { [string]$_.defect.fingerprint -eq [string]$receiptDefect.fingerprint })
            if ($expected.Count -ne 1) { Add-ContractError "receipt defect does not resolve: $($receiptDefect.fingerprint)"; continue }
            if ([string]$receiptDefect.defectId -ne [string]$expected[0].defect.defectId) { Add-ContractError "receipt defect ID mismatch" }
            if (!(Test-SetEqual @($receiptDefect.priorFailingAssertions | ForEach-Object { "$($_.scenarioId):$(@($_.assertionIds | Sort-Object) -join ',')" }) @($expected[0].defect.failingAssertions | ForEach-Object { "$($_.scenarioId):$(@($_.assertionIds | Sort-Object) -join ',')" }))) { Add-ContractError "receipt prior failing assertions mismatch" }
            if ([string]$receiptDefect.currentStatus -ne [string]$expected[0].status) { Add-ContractError "receipt defect current status mismatch" }
            if (!(Test-SetEqual @($receiptDefect.currentFailingAssertions | ForEach-Object { "$($_.scenarioId):$(@($_.assertionIds | Sort-Object) -join ',')" }) @($expected[0].currentFailing | ForEach-Object { "$($_.scenarioId):$(@($_.assertionIds | Sort-Object) -join ',')" }))) { Add-ContractError "receipt current failing assertions mismatch" }
        }

        $knownFingerprints = @($defects | ForEach-Object { [string]$_.fingerprint })
        $newProductFindings = @($expectedFindings | Where-Object { $_.classification -eq "PRODUCT_DEFECT" -and [string]$_.fingerprint -notin $knownFingerprints })
        $knownReproduced = @($expectedDefectFacts | Where-Object { $_.status -eq "REPRODUCED" }).Count -gt 0
        if ([string]$receipt.result.verdict -eq "BLOCKED") {
            $expectedOutcome = "BLOCKED"; $expectedClosure = "BLOCKED"
        } elseif ($runMode -eq "FIX_VERIFICATION") {
            if ($newProductFindings.Count -gt 0) { $expectedOutcome = "REGRESSION_FOUND"; $expectedClosure = "PARTIAL" }
            elseif ($knownReproduced) { $expectedOutcome = "DEFECT_REPRODUCED"; $expectedClosure = "OPEN" }
            elseif ([string]$receipt.result.verdict -eq "PASS") { $expectedOutcome = "FIX_VERIFIED"; $expectedClosure = "CLOSED" }
            else { $expectedOutcome = "BLOCKED"; $expectedClosure = "BLOCKED" }
        } elseif ($runMode -eq "DEFECT_REPRODUCTION") {
            if ($newProductFindings.Count -gt 0) { $expectedOutcome = "REGRESSION_FOUND"; $expectedClosure = "PARTIAL" }
            elseif ($knownReproduced) { $expectedOutcome = "DEFECT_REPRODUCED"; $expectedClosure = "OPEN" }
            else { $expectedOutcome = "DEFECT_NOT_REPRODUCED"; $expectedClosure = "PARTIAL" }
        } elseif (@($expectedFindings | Where-Object { $_.classification -eq "PRODUCT_DEFECT" }).Count -gt 0) {
            $expectedOutcome = "DEFECT_FOUND"; $expectedClosure = "OPEN"
        } else {
            $expectedOutcome = "NO_DEFECT"; $expectedClosure = "NOT_APPLICABLE"
        }
        if ([string]$receipt.run.outcome -ne $expectedOutcome -or [string]$receipt.run.closure -ne $expectedClosure) { Add-ContractError "receipt run outcome/closure mismatch" }

        if ($RequireFresh -and $null -ne $receipt.freshness.expiresAt -and $AsOf -ge [DateTimeOffset]::Parse([string]$receipt.freshness.expiresAt)) { Add-ContractError "receipt freshness expired" }
    }
}

$result = [ordered]@{
    valid = $errors.Count -eq 0
    adapterSchemaValid = $adapterValid
    requestSchemaValid = $requestValid
    catalogSchemaValid = $catalogValid
    receiptValidated = $receiptValidated
    adapterHash = $adapterHash
    requestHash = $requestHash
    catalogHash = $catalogHash
    catalogScenarioCount = $scenarioFacts.Count
    selectedScenarioCount = $selectedIds.Count
    selectionStrategy = [string]$request.testPlan.strategy
    seedScenarioIds = @($seedIds | Sort-Object)
    selectedScenarioIds = @($selectedIds)
    excludedScenarioIds = @($excludedIds)
    reasonByScenario = @($selectedIds | ForEach-Object {
        $reasonList = if ($script:selectionReasons.ContainsKey([string]$_)) { @($script:selectionReasons[[string]$_] | Sort-Object) } else { @() }
        [ordered]@{
            scenarioId = [string]$_
            reasons = [object[]]$reasonList
        }
    })
    errors = @($errors)
}
$result | ConvertTo-Json -Depth 10
if ($errors.Count -gt 0) { exit 2 }
exit 0
