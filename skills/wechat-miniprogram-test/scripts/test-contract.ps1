#requires -Version 7.4

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$skillRoot = Split-Path -Parent $PSScriptRoot
$validator = Join-Path $PSScriptRoot "validate-contract.ps1"
$builder = Join-Path $PSScriptRoot "new-test-receipt.ps1"
$evidenceSchema = Join-Path $skillRoot "references/evidence.schema.json"
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$workspace = Join-Path $tempBase ("wechat-skill-contract-" + [guid]::NewGuid().ToString("N"))
$results = [ordered]@{}
$diagnostics = [ordered]@{}

function Write-Json([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    if (!(Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $json = $Value | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

function Get-Hash([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-StringHash([string]$Value) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Value)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Copy-Json($Value) {
    $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
}

try {
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    $scenarioRoot = Join-Path $workspace ".wechat-test/scenarios"
    $evidenceRoot = Join-Path $workspace ".local/evidence"
    New-Item -ItemType Directory -Force -Path $scenarioRoot, $evidenceRoot | Out-Null

    Write-Json (Join-Path $workspace "project.config.json") ([ordered]@{ appid = "test-app-id" })
    Write-Json (Join-Path $workspace "package.json") ([ordered]@{ name = "wechat-skill-contract-test"; private = $true })
    Write-Json (Join-Path $workspace "source-identity.json") ([ordered]@{ method = "test-fixture"; version = 1 })

    $scenarioPath = Join-Path $scenarioRoot "home.json"
    $scenario = [ordered]@{
        schemaVersion = "4.0"
        scenarioVersion = "1.0.0"
        id = "home-runtime"
        title = "Home runtime contract"
        priority = "P0"
        tags = @("contract-test")
        testType = "ui"
        impact = [ordered]@{ keys = @("page:pages/home/index"); risk = "local" }
        targetPages = @([ordered]@{ route = "pages/home/index"; entryMode = "relaunch"; parameterKeys = @() })
        session = [ordered]@{ mode = "none"; expectedRole = $null; expectedScope = $null }
        runtime = [ordered]@{ channel = "wechatide-mcp"; runnerId = $null; requiredTools = @("runtime-read") }
        preconditions = @()
        fixture = $null
        permissions = [ordered]@{
            pages = @("pages/home/index")
            navigation = $true
            elementRead = $true
            devtoolsLifecycle = $false
            runtimeRead = $true
            networkAccess = $false
            screenshot = $false
            manualObservation = $false
            loginAction = $false
            accountSwitch = $false
            businessWrite = $false
            testDataMutation = $false
            deviceStateChange = $false
        }
        writePolicy = $null
        steps = @([ordered]@{
            id = "open-home"
            action = "relaunch"
            target = [ordered]@{ kind = "page"; value = "pages/home/index" }
            inputRef = $null
            wait = [ordered]@{ condition = "page"; expected = "pages/home/index"; timeoutMs = 5000 }
            mutationClass = "none"
            idempotencyStrategy = $null
        })
        assertions = @([ordered]@{
            id = "home-active"
            title = "Home page is active"
            kind = "page"
            target = [ordered]@{ kind = "page"; value = "pages/home/index" }
            operator = "equals"
            expected = "pages/home/index"
            sourceOfTruth = "runtime"
            severity = "REQUIRED"
            impactKeys = @("page:pages/home/index")
            evidenceTypes = @("runtime-state")
        })
        evidencePolicy = [ordered]@{ screenshots = "none"; console = "none"; network = "none"; trace = $false; video = $false; redactFields = @() }
        stopConditions = @([ordered]@{ id = "contract-blocked"; condition = "required runtime unavailable"; classification = "BLOCKED"; detail = "record blocker and stop" })
        timeBudgetSeconds = 30
    }
    Write-Json $scenarioPath $scenario

    $catalogPath = Join-Path $workspace ".wechat-test/catalog.json"
    $catalog = [ordered]@{
        schemaVersion = "1.0"
        catalogId = "contract-test-catalog"
        catalogVersion = "1.0.0"
        scenarios = @([ordered]@{ id = "home-runtime"; path = ".wechat-test/scenarios/home.json"; sha256 = Get-Hash $scenarioPath })
        relations = @()
    }
    Write-Json $catalogPath $catalog

    $adapterPath = Join-Path $workspace "project-adapter.json"
    $adapter = [ordered]@{
        schemaVersion = "2.0"
        adapterVersion = "1.0.0"
        adapterId = "contract-test-adapter"
        projectId = "contract-test-project"
        framework = "native-wechat"
        roots = [ordered]@{ workspace = "."; source = "."; devtoolsProject = "." }
        files = [ordered]@{ projectConfig = "project.config.json"; packageManifest = "package.json"; scenarioRoot = ".wechat-test/scenarios" }
        candidateIdentity = [ordered]@{ method = "filesystem-manifest-sha256"; definitionRef = "source-identity.json"; command = $null }
        runners = @()
        supportedChannels = @("wechatide-mcp")
        capabilities = @("runtime-read")
        evidenceRoot = ".local/evidence"
        secretEnvKeys = @()
    }
    Write-Json $adapterPath $adapter

    $runRoot = Join-Path $evidenceRoot "pass-run"
    $requestPath = Join-Path $runRoot "test-request.json"
    $now = [DateTimeOffset]::Now
    $request = [ordered]@{
        schemaVersion = "3.1"
        requestId = "contract-pass-request"
        requestedAt = $now.AddSeconds(-10).ToString("o")
        authorizationRef = "contract-test-authorization"
        projectAdapter = [ordered]@{ path = "project-adapter.json"; sha256 = Get-Hash $adapterPath; adapterId = "contract-test-adapter"; adapterVersion = "1.0.0" }
        candidate = [ordered]@{
            revision = "contract-candidate"
            diffHash = $null
            sourceHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            buildId = "contract-build"
        }
        environment = [ordered]@{
            id = "contract-environment"
            appId = "test-app-id"
            apiIdentity = "contract-api"
            configHash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        }
        run = [ordered]@{ runId = "contract-pass-run"; mode = "BASELINE" }
        defectLineage = $null
        testPlan = [ordered]@{
            catalog = [ordered]@{ path = ".wechat-test/catalog.json"; sha256 = Get-Hash $catalogPath; catalogId = "contract-test-catalog"; catalogVersion = "1.0.0" }
            strategy = "FULL"
            changedImpactKeys = @()
            upstreamDepth = 0
            downstreamDepth = 0
            activeFullSuiteTriggers = @()
            selectedScenarioIds = @("home-runtime")
        }
        authorization = [ordered]@{
            devtoolsLifecycle = $false
            runtimeRead = $true
            networkAccess = $false
            screenshot = $false
            manualObservation = $false
            loginAction = $false
            accountSwitch = $false
            businessWrite = $false
            testDataMutation = $false
            deviceStateChange = $false
        }
        execution = [ordered]@{ totalBudgetSeconds = 60; failFast = $true; maxParallelScenarios = 1; isolatedRuntimePerScenario = $false; readRetryLimit = 0; writeRetryLimit = 0 }
        output = [ordered]@{ root = ".local/evidence/pass-run"; evidenceFileName = "evidence.json"; receiptFileName = "test-receipt.json"; overwrite = $false }
    }
    Write-Json $requestPath $request

    $evidencePath = Join-Path $runRoot "home-runtime/evidence.json"
    $requestHash = Get-Hash $requestPath
    $evidence = [ordered]@{
        schemaVersion = "3.2"
        evidenceId = "contract-pass-evidence"
        requestId = "contract-pass-request"
        verdict = "PASS"
        timing = [ordered]@{ startedAt = $now.AddSeconds(-5).ToString("o"); finishedAt = $now.ToString("o"); durationMs = 5000 }
        scope = [ordered]@{
            projectId = "contract-test-project"
            projectAdapterId = "contract-test-adapter"
            projectAdapterHash = Get-Hash $adapterPath
            requestHash = $requestHash
            environment = "contract-environment"
            appId = "test-app-id"
            apiIdentity = "contract-api"
            environmentConfigHash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            candidateRevision = "contract-candidate"
            diffHash = $null
            sourceHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            buildId = "contract-build"
            runId = "contract-pass-run"
            runMode = "BASELINE"
            defectLineageId = $null
            defectRound = $null
            scenarioId = "home-runtime"
            scenarioVersion = "1.0.0"
            scenarioHash = Get-Hash $scenarioPath
            selectionReasons = @("full-suite")
            observedPages = @("pages/home/index")
            businessWrite = $false
        }
        preflight = [ordered]@{ preflightId = "contract-preflight"; reused = $false; identityMatched = $true; requiredToolsAvailable = $true }
        runtime = [ordered]@{
            channel = "wechatide-mcp"
            runnerId = $null
            controllerIdentity = "contract-controller"
            devtoolsVersion = "contract-devtools"
            protocolVersion = "contract-protocol"
            sessionFingerprint = "contract-session"
            commandIdentity = $null
            deviceProfile = $null
        }
        session = [ordered]@{ devtoolsLoggedIn = $true; clientAuthorized = $true; businessSessionMode = "none"; businessSessionPresent = $null }
        preconditions = @()
        steps = @([ordered]@{
            id = "open-home"
            action = "relaunch"
            target = "pages/home/index"
            status = "PASS"
            startedAt = $now.AddSeconds(-4).ToString("o")
            finishedAt = $now.AddSeconds(-1).ToString("o")
            mutationClass = "none"
            evidenceRefs = @()
        })
        assertions = @([ordered]@{
            id = "home-active"
            kind = "page"
            operator = "equals"
            sourceOfTruth = "runtime"
            severity = "REQUIRED"
            status = "PASS"
            expected = "pages/home/index"
            actual = "pages/home/index"
            findingFingerprint = $null
            defectIds = @()
            evidenceRefs = @()
        })
        artifacts = @()
        diagnostics = [ordered]@{ baselineEstablished = $true; freshConsoleErrors = @(); freshNetworkFailures = @() }
        interactions = @()
        mutations = @()
        excluded = @()
        blockers = @()
    }
    Write-Json $evidencePath $evidence

    $inputResult = & $validator -ProjectAdapterPath $adapterPath -RequestPath $requestPath | ConvertFrom-Json
    $results.ValidInputAccepted = [bool]$inputResult.valid

    $null = & $builder -ProjectAdapterPath $adapterPath -RequestPath $requestPath -EvidencePath $evidencePath -FreshForSeconds 600
    $receiptPath = Join-Path $runRoot "test-receipt.json"
    $receiptResult = & $validator -ProjectAdapterPath $adapterPath -RequestPath $requestPath -ReceiptPath $receiptPath -RequireFresh | ConvertFrom-Json
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    $results.ValidPassReceipt = [bool]$receiptResult.valid -and [string]$receipt.result.verdict -eq "PASS"
    $diagnostics.PassReceiptErrors = @($receiptResult.errors)
    $results.SessionFreshnessDerived = [string]$receipt.freshness.class -eq "SESSION_BOUND" -and $null -ne $receipt.freshness.expiresAt

    $failRoot = Join-Path $evidenceRoot "fail-run"
    $failRequestPath = Join-Path $failRoot "test-request.json"
    $failRequest = Copy-Json $request
    $failRequest.requestId = "contract-fail-request"
    $failRequest.run.runId = "contract-fail-run"
    $failRequest.output.root = ".local/evidence/fail-run"
    Write-Json $failRequestPath $failRequest
    $failEvidencePath = Join-Path $failRoot "home-runtime/evidence.json"
    $failEvidence = Copy-Json $evidence
    $failEvidence.evidenceId = "contract-fail-evidence"
    $failEvidence.requestId = "contract-fail-request"
    $failEvidence.verdict = "FAIL"
    $failEvidence.scope.requestHash = Get-Hash $failRequestPath
    $failEvidence.scope.runId = "contract-fail-run"
    $failEvidence.steps[0].status = "FAIL"
    $failEvidence.assertions[0].status = "FAIL"
    $failEvidence.assertions[0].actual = "pages/other/index"
    $failEvidence.assertions[0].findingFingerprint = Get-StringHash "home-runtime`thome-active`n"
    Write-Json $failEvidencePath $failEvidence
    $null = & $builder -ProjectAdapterPath $adapterPath -RequestPath $failRequestPath -EvidencePath $failEvidencePath -FreshForSeconds 600
    $failReceiptPath = Join-Path $failRoot "test-receipt.json"
    $failReceiptResult = & $validator -ProjectAdapterPath $adapterPath -RequestPath $failRequestPath -ReceiptPath $failReceiptPath -RequireFresh | ConvertFrom-Json
    $failReceipt = Get-Content -LiteralPath $failReceiptPath -Raw | ConvertFrom-Json
    $results.ValidFailReceipt = [bool]$failReceiptResult.valid -and [string]$failReceipt.result.verdict -eq "FAIL" -and @($failReceipt.findings).Count -eq 1
    $diagnostics.FailReceiptErrors = @($failReceiptResult.errors)

    $blockedRoot = Join-Path $evidenceRoot "blocked-run"
    $blockedRequestPath = Join-Path $blockedRoot "test-request.json"
    $blockedRequest = Copy-Json $request
    $blockedRequest.requestId = "contract-blocked-request"
    $blockedRequest.run.runId = "contract-blocked-run"
    $blockedRequest.output.root = ".local/evidence/blocked-run"
    Write-Json $blockedRequestPath $blockedRequest
    $blockedEvidencePath = Join-Path $blockedRoot "home-runtime/evidence.json"
    $blockedEvidence = Copy-Json $evidence
    $blockedEvidence.evidenceId = "contract-blocked-evidence"
    $blockedEvidence.requestId = "contract-blocked-request"
    $blockedEvidence.verdict = "BLOCKED"
    $blockedEvidence.scope.requestHash = Get-Hash $blockedRequestPath
    $blockedEvidence.scope.runId = "contract-blocked-run"
    $blockedEvidence.scope.observedPages = @()
    $blockedEvidence.steps[0].status = "BLOCKED"
    $blockedEvidence.assertions[0].status = "BLOCKED"
    $blockedEvidence.assertions[0].actual = $null
    $blockedEvidence.blockers = @([ordered]@{ reasonClass = "tool"; detail = "declared controller is unavailable"; nextStep = "restore the declared controller and create a new run" })
    Write-Json $blockedEvidencePath $blockedEvidence
    $null = & $builder -ProjectAdapterPath $adapterPath -RequestPath $blockedRequestPath -EvidencePath $blockedEvidencePath -FreshForSeconds 600
    $blockedReceiptPath = Join-Path $blockedRoot "test-receipt.json"
    $blockedReceiptResult = & $validator -ProjectAdapterPath $adapterPath -RequestPath $blockedRequestPath -ReceiptPath $blockedReceiptPath -RequireFresh | ConvertFrom-Json
    $blockedReceipt = Get-Content -LiteralPath $blockedReceiptPath -Raw | ConvertFrom-Json
    $results.ValidBlockedReceipt = [bool]$blockedReceiptResult.valid -and [string]$blockedReceipt.result.verdict -eq "BLOCKED" -and @($blockedReceipt.blockers).Count -eq 1
    $diagnostics.BlockedReceiptErrors = @($blockedReceiptResult.errors)

    try {
        $null = & $builder -ProjectAdapterPath $adapterPath -RequestPath $requestPath -EvidencePath $evidencePath -FreshnessClass DETERMINISTIC
        $results.RejectFreshnessOverride = $false
    } catch { $results.RejectFreshnessOverride = $true }

    $tamperedReceiptPath = Join-Path $runRoot "tampered-freshness.json"
    $tamperedReceipt = Copy-Json $receipt
    $tamperedReceipt.freshness.class = "DETERMINISTIC"
    $tamperedReceipt.freshness.expiresAt = $null
    Write-Json $tamperedReceiptPath $tamperedReceipt
    $tamperedText = & $validator -ProjectAdapterPath $adapterPath -RequestPath $requestPath -ReceiptPath $tamperedReceiptPath 2>&1 | Out-String
    $results.RejectDowngradedFreshness = $tamperedText -match "freshness|does not conform"

    $unresolvedPass = Copy-Json $evidence
    $unresolvedPass.mutations = @([ordered]@{
        type = "data-mutation"
        target = "contract-record"
        attempts = 1
        preState = [ordered]@{ state = "before" }
        postState = [ordered]@{ state = "unknown" }
        resolution = "UNRESOLVED"
        rollbackOrCompensation = $null
    })
    $unresolvedPassJson = $unresolvedPass | ConvertTo-Json -Depth 100
    try {
        $unresolvedPassValid = Test-Json -Json $unresolvedPassJson -SchemaFile $evidenceSchema -ErrorAction Stop
        $results.RejectPassWithUnresolvedMutation = !$unresolvedPassValid
    } catch { $results.RejectPassWithUnresolvedMutation = $true }

    $unresolvedBlocked = Copy-Json $unresolvedPass
    $unresolvedBlocked.verdict = "BLOCKED"
    $unresolvedBlocked.assertions[0].status = "BLOCKED"
    $unresolvedBlocked.assertions[0].actual = $null
    $unresolvedBlocked.steps[0].status = "BLOCKED"
    $unresolvedBlocked.blockers = @([ordered]@{
        reasonClass = "evidence"
        detail = "contract-record current state is unknown; the affected scope is this isolated fixture"
        nextStep = "inspect the fixture and restore or confirm its state before a new run"
    })
    $unresolvedBlockedJson = $unresolvedBlocked | ConvertTo-Json -Depth 100
    $results.AcceptBlockedWithExplainedUnresolvedMutation = Test-Json -Json $unresolvedBlockedJson -SchemaFile $evidenceSchema -ErrorAction Stop

    $failed = @($results.GetEnumerator() | Where-Object { ![bool]$_.Value })
    [ordered]@{ passed = $failed.Count -eq 0; checks = $results; failedChecks = @($failed | ForEach-Object { $_.Name }); diagnostics = $diagnostics } | ConvertTo-Json -Depth 8
    if ($failed.Count -gt 0) { exit 2 }
} finally {
    $resolvedWorkspace = [IO.Path]::GetFullPath($workspace)
    if (
        $resolvedWorkspace.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedWorkspace).StartsWith("wechat-skill-contract-") -and
        (Test-Path -LiteralPath $resolvedWorkspace)
    ) {
        Remove-Item -LiteralPath $resolvedWorkspace -Recurse -Force
    }
}
