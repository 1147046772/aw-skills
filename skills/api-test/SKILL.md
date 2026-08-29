---
name: api-test
description: Execute bounded API contract, runtime, authorization, state, idempotency, and integration tests through project-declared runners, and emit hash-bound scenario evidence plus one canonical test receipt. It does not authorize source changes, undeclared data mutation, production access, external-provider calls, release, or deployment.
metadata:
  version: "0.2.0-rc.1"
---

# API Test

Execute the smallest sufficient API test boundary through project-owned runners and produce independently verifiable evidence.

Canonical input consists of one project adapter, deterministic contract manifest and operation index, one complete test catalog, hash-bound scenarios, one current runtime attestation, and one `test-request.json`. Output consists of one `evidence.json` for each attempted scenario plus either a generic `test-receipt.json` or a project-native `api-test-leaf-summary.json`. Project routes, roles, fixtures, credentials, environment discovery, runners, and business expectations belong in project inputs, not in this Skill.

The `0.2` stable capability is HTTP with OpenAPI 3.0/3.1 JSON, plus explicitly enumerated `custom` contracts with weaker project-owned truth. YAML without a pinned project parser and GraphQL, gRPC, or WebSocket contract formats are `BLOCKED_UNSUPPORTED`; they must not inherit the OpenAPI assurance claim.

## Hard rules

1. Expected behavior comes only from versioned scenario assertions or a hash-bound API contract. Never infer success from HTTP status alone.
2. Recompute exact-file hashes, the contract combination digest, operation identity, candidate/runtime identity, exact destination allowlist, permissions, runner compatibility, selection closure, and output containment before execution. Invalid or untrusted input is `BLOCKED`; do not repair or broaden it during the run.
3. Use `FULL` only when requested or a declared full-suite trigger makes impact selection unsafe. Otherwise execute the exact computed `IMPACT` closure.
4. Use exactly one declared runner per scenario. Resolve the target only from the Adapter destination entry; do not replace its protocol, authentication profile, fixture, environment, or destination after failure. Redirects are forbidden by the v2 contract.
5. A write or external call executes at most once. Unsafe requests have zero automatic retries. Unknown outcomes stop the scenario as `BLOCKED`; never replay them blindly.
6. A product assertion failure is `FAIL`. Missing authorization, identity, destination trust, runner, authentication, fixture, runtime health, or credible evidence is `BLOCKED`.
7. Persist no secret values, cookies, authorization headers, tokens, personal identifiers, raw bodies, or raw runner arguments. Persist approved fingerprints, redacted observations, exact-file hashes, and a hash of resolved arguments.
8. API testing, source modification, data/database mutation, account or credential changes, production access, external-provider calls, release, and deployment are separate authorization scopes.

## Run modes

| Mode | Selection | Lineage |
|---|---|---|
| `BASELINE` | `FULL` | none |
| `TARGETED` | `IMPACT` from changed impact keys | none |
| `DEFECT_REPRODUCTION` | `IMPACT`, depth 0 | optional parent evidence |
| `FIX_VERIFICATION` | `IMPACT`, depth at least 1 upstream/downstream | parent receipt |
| `REGRESSION` | `IMPACT` or `FULL` | optional parent receipt |

Read [incremental-regression-contract.md](references/incremental-regression-contract.md) only for impact or lineage runs.

## Execute

1. **Freeze the API contract** — For the stable OpenAPI path, run [new-openapi-contract.ps1](scripts/new-openapi-contract.ps1) against an OpenAPI 3.0/3.1 JSON root. It recursively rejects external or escaping references and produces both the exact-file manifest and Operation index from contract truth. YAML is `BLOCKED` until a project declares a pinned parser. [new-contract-manifest.ps1](scripts/new-contract-manifest.ps1) is only for an explicitly enumerated `custom` contract; it cannot claim OpenAPI reference closure.
2. **Attest the running target** — After the service starts, collect candidate, destination, service/process or image/container, contract/index, auth-profile, and mutation-state facts into `current-attestation.json`. Only then generate the final Request.
3. **Freeze input** — Run [validate-contract.ps1](scripts/validate-contract.ps1) with the Adapter and Request. It cross-checks the destination fingerprint, contract bytes, Operation index, catalog coverage, Scenario steps, mutation permissions, selection boundary, and initial attestation.
4. **Run selected scenarios** — Execute the declared direct-process runner without shell substitution. A request or poll step may reference only an indexed Operation. The validator derives READ/WRITE from the Operation; a Scenario cannot make a POST safe by labeling it `none`.
5. **Write evidence** — Record sanitized request metadata, exact observed Operation IDs, target/runtime/attestation fingerprints, response hashes or approved redacted extracts, assertion results, mutations, artifacts, and blockers. Validate every file against [evidence.schema.json](references/evidence.schema.json).
6. **Re-attest and summarize** — Recollect current facts. For `GENERIC_CANONICAL`, run [new-test-receipt.ps1](scripts/new-test-receipt.ps1). For `PROJECT_NATIVE_PARENT`, run [new-native-leaf-summary.ps1](scripts/new-native-leaf-summary.ps1) and map that leaf into the project's sole parent summary.
7. **Verify current output** — Run `validate-contract.ps1 -CurrentAttestationPath <path> -RequireCurrentIdentity`; add `-RequireUnexpired` when consuming a time-bounded generic receipt. Any source, runtime, destination, contract, auth, or mutation-state drift is `BLOCKED`.

Runner exit code and HTTP status are diagnostic inputs, never the canonical verdict. `TEST_EVIDENCE_ONLY` and `TEST_LEAF_EVIDENCE_ONLY` never claim source quality, migration correctness, release readiness, deployment, or third-party business completion. Read [receipt-contract.md](references/receipt-contract.md).

## Verdict boundary

- `PASS`: every selected scenario executed, every REQUIRED assertion passed, identities matched, and all mutations resolved.
- `FAIL`: at least one REQUIRED product assertion failed with credible current evidence.
- `BLOCKED`: the selected boundary could not be completed or trusted.

A targeted PASS proves only the selected boundary. A source/runtime provenance check does not by itself prove business acceptance or release readiness. The receipt authority is always `TEST_EVIDENCE_ONLY`.

## References

- Project mechanics: [project-adapter-contract.md](references/project-adapter-contract.md), [project.schema.json](references/project.schema.json), [current-attestation.schema.json](references/current-attestation.schema.json)
- API scenarios: [api-contract.md](references/api-contract.md), [scenario.schema.json](references/scenario.schema.json), [test-catalog.schema.json](references/test-catalog.schema.json)
- Contract identity: [contract-manifest.schema.json](references/contract-manifest.schema.json), [operation-index.schema.json](references/operation-index.schema.json), [traceability.schema.json](references/traceability.schema.json)
- Input/output: [test-request.schema.json](references/test-request.schema.json), [evidence.schema.json](references/evidence.schema.json), [receipt-contract.md](references/receipt-contract.md), [test-receipt.schema.json](references/test-receipt.schema.json), [native-leaf-summary.schema.json](references/native-leaf-summary.schema.json)
- Identity and selection: [hash-contract.md](references/hash-contract.md), [incremental-regression-contract.md](references/incremental-regression-contract.md)
- Project integration: [INTEGRATION.md](INTEGRATION.md)

After installing or changing the Skill, run `scripts/test-contract.ps1` before using it on a project.
