# Test Receipt Contract

`test-receipt.json` is the single generic machine-readable summary of one request. Generate it from frozen inputs and child evidence with `scripts/new-test-receipt.ps1`; do not author it by prose.

Never trust `result.verdict` alone. Validate schema, exact hashes, cross-file equality, selected/executed coverage, artifacts, mutation resolution, runtime/auth identity, and current facts with `validate-contract.ps1 -CurrentAttestationPath <path> -RequireCurrentIdentity`. Add `-RequireUnexpired` for a time-bounded generic receipt.

- `PASS` requires executed scenarios to equal selected scenarios, every REQUIRED assertion PASS, no blocker, and no unresolved mutation.
- `FAIL` requires at least one REQUIRED product assertion failure and its finding fingerprint.
- `BLOCKED` requires at least one child blocker; a next step does not authorize that action.

Freshness is derived from facts: deterministic, runtime/session-bound, live mutable, or mixed. Expiry checks only time. Current identity validation independently recollects and compares candidate, service/runtime, destination, contract/index, authentication, and mutation-state facts.

When a project already owns a stricter unique parent summary, set `evidenceMode=PROJECT_NATIVE_PARENT`, generate and validate `api-test-leaf-summary.json`, then map it into that summary. The leaf authority is `TEST_LEAF_EVIDENCE_ONLY`; it is never a second parent receipt.
