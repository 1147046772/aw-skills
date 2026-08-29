# Test Receipt Contract

`test-receipt.json` is the single machine-readable summary of one test request. It is derived from the frozen adapter, request, catalog, scenarios, and current scenario evidence; it is not an independently authored report.

## Production

Use `scripts/new-test-receipt.ps1`. Supply exactly one evidence file for every executed scenario and no evidence outside the selected boundary. The generator must fail rather than infer missing evidence, reuse another run, overwrite an existing receipt, or accept contradictory assertion and blocker states.

The receipt contains:

- exact input paths and SHA-256 hashes;
- candidate, environment, AppID, API, build, and configuration identity;
- requested mode, defect lineage, exact selected/executed/excluded boundary, and selection reasons;
- controller, DevTools/protocol, command, session, and device identity per executed scenario;
- aggregate verdict and assertion counts;
- hash-bound scenario results, product/advisory findings, and blockers with one next action;
- tested pages and impact-key coverage;
- mutation count and unresolved state;
- freshness class, expiry, and invalidation keys;
- producer and validator identity.

`scenarioResults`, `runtimeProfiles`, `findings`, and `blockers` are indexes into scenario evidence. They do not replace child evidence.

## Consumer rules

Never trust the `verdict` field alone. Validate schema and all cross-file invariants with `validate-contract.ps1 -RequireFresh`, then consume the complete receipt.

`-RequireFresh` verifies recorded file identities, cross-file equality, artifact bytes, runtime facts, expiry, and invalidation keys. It does not execute a project's candidate identity command, read the current AppID/configuration, or query a live DevTools session. A consumer that needs current-state attestation must obtain those observations independently and compare them with the receipt before acceptance.

- `PASS` is valid only when executed scenarios equal selected scenarios, all REQUIRED assertions pass, coverage is complete, blockers are empty, and mutations are resolved.
- `FAIL` requires at least one current REQUIRED product assertion failure and its finding fingerprint/evidence hash.
- `BLOCKED` requires at least one blocker copied from child evidence. Its `nextStep` describes how a later run may proceed; it does not authorize that action.
- Any `UNRESOLVED` mutation forces child evidence and the aggregate receipt to `BLOCKED`; PASS evidence cannot carry unresolved state.
- A session-bound receipt must expose the session fingerprint for every session-backed scenario and include `session` in `freshness.invalidationKeys`.
- Any changed input bytes, subject identity, session fingerprint, artifact bytes, or expired freshness invalidates reuse.

The authority is always `TEST_EVIDENCE_ONLY`.

## Required 3.2 evidence fields

Producers upgrading from 3.1 must add:

- `evidence.scope.observedPages` with only pages actually observed;
- `evidence.runtime.sessionFingerprint` (`null` only for non-session channels);
- `evidence.mutations[].resolution` for every mutation record;
- `receipt.runtimeProfiles[].sessionFingerprint`;
- top-level `receipt.blockers`, empty for PASS/FAIL and populated from child evidence for BLOCKED.
