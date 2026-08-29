---
name: wechat-miniprogram-test
description: Execute bounded WeChat Mini Program test cases, reproduce defects, verify fixes with impact-based regression, and emit hash-bound scenario evidence plus one canonical test receipt. Use for static, compile, simulator, runtime, integration, or device testing; it does not authorize source changes, undeclared state mutation, account switching, upload, release, or deployment.
---

# WeChat Mini Program Test

Execute the smallest sufficient test boundary and produce independently verifiable evidence.

Canonical input consists of one project adapter, one complete test catalog, its hash-bound scenarios, and one `test-request.json`. Canonical output consists of one `evidence.json` for every executed scenario and one non-overwriting `test-receipt.json` aggregating the run. Project-specific pages, selectors, fixtures, expected behavior, runners, and impact relations belong in those inputs, not in this Skill.

## Hard rules

1. Expected behavior comes only from versioned scenario assertions. Never infer success from the observed UI.
2. Before execution, validate exact bytes, identities, permissions, runner compatibility, selection closure, lineage, and physical output containment. Invalid input is `BLOCKED`; do not repair or broaden it during the run.
3. `IMPACT` must equal the computed change/defect closure. Use `FULL` only when requested or when a full-suite trigger makes the boundary unsafe.
4. One scenario uses one declared controller. Do not restart tools, clear state, switch account/controller, add cases, or change the environment to obtain a result.
5. An authorized write executes at most once, has an idempotency strategy, verifies the result once, and is never retried after an unknown outcome.
6. Emit only observations from the current run. A product assertion failure is `FAIL`; unavailable authorization, identity, tool, environment, session, fixture, device, or credible evidence is `BLOCKED`.
7. Persist no secrets, cookies, tickets, codes, raw runner arguments, or full personal identifiers. Store only approved identities, redacted observations, exact-file hashes, and a hash of resolved runner arguments.

## Run modes

| Mode | Selection | Lineage |
|---|---|---|
| `BASELINE` | `FULL` | none |
| `TARGETED` | `IMPACT` from changed impact keys | none |
| `DEFECT_REPRODUCTION` | `IMPACT`, depth 0 | parent receipt or hash-bound external evidence |
| `FIX_VERIFICATION` | `IMPACT`, depth at least 1 upstream and downstream | parent receipt |
| `REGRESSION` | `IMPACT` or `FULL` | optional parent receipt |

Read [incremental-regression-contract.md](references/incremental-regression-contract.md) for `IMPACT` or lineage runs.

## Execute

1. **Freeze input** — Run [validate-contract.ps1](scripts/validate-contract.ps1) with the adapter and request. Stop if invalid.
2. **Preflight once** — For the frozen candidate, check only prerequisites declared by selected scenarios: runner/controller, build/AppID/environment, DevTools/client/business session, fixture/API/device, and output jail. Record missing prerequisites as scenario evidence with `BLOCKED`.
3. **Run selected scenarios** — Execute the declared runner or controller without substitution. Use semantic actions, observable waits, immediate assertions, and only requested artifacts. In `FIX_VERIFICATION`, run prior reproducers first and stop the remaining closure if a prior failure is reproduced.
4. **Write scenario evidence** — Record actual pages observed, assertion results, fresh diagnostics, mutations, artifacts, controller/session identity, and blockers. Validate each `evidence.json` against [evidence.schema.json](references/evidence.schema.json).
5. **Build the receipt** — Run [new-test-receipt.ps1](scripts/new-test-receipt.ps1) with the adapter, request, and every scenario evidence path. The script deterministically derives selection, findings, blockers, coverage, lineage status, verdict, and closure.
6. **Verify output** — Rerun `validate-contract.ps1` with the generated receipt and `-RequireFresh`. A receipt is valid only while its candidate, request, catalog, scenarios, environment, runtime/session profile, artifacts, and invalidation keys still match.

A runner exit code is diagnostic input, never the test verdict. Stable runner output must be transformed into scenario evidence; the canonical receipt must never be composed by prose or copied from a previous run.

## Verdict and claim boundary

- `PASS`: every selected scenario executed and every REQUIRED assertion passed.
- `FAIL`: at least one REQUIRED product assertion failed with credible current evidence.
- `BLOCKED`: the selected boundary could not be completed or trusted.

`PASS` proves only the selected boundary for the receipt subject and freshness window. `DEFECT_NOT_REPRODUCED` remains `PARTIAL`. `FIX_VERIFIED + CLOSED` additionally requires valid parent lineage, a changed candidate identity, all prior failed assertions passing, the exact impact closure, no new product finding, resolved mutations, and fresh evidence.

Human output should summarize—not duplicate—the canonical receipt: verdict, outcome/closure, selected and excluded scenarios, subject identity, failed/blocked assertions, finding fingerprints, blocker next actions, evidence hashes, freshness, and one next action. The receipt has authority `TEST_EVIDENCE_ONLY` and authorizes no source change, upload, release, or deployment.

## References

- Workflow integration: [INTEGRATION.md](INTEGRATION.md)
- Project mechanics: [project-adapter-contract.md](references/project-adapter-contract.md), [project.schema.json](references/project.schema.json)
- Test cases: [scenario-contract.md](references/scenario-contract.md), [scenario.schema.json](references/scenario.schema.json), [test-catalog.schema.json](references/test-catalog.schema.json)
- Input/output: [test-request.schema.json](references/test-request.schema.json), [evidence.schema.json](references/evidence.schema.json), [receipt-contract.md](references/receipt-contract.md), [test-receipt.schema.json](references/test-receipt.schema.json)
- Identity/device: [hash-contract.md](references/hash-contract.md), [device-contract.md](references/device-contract.md)

After installing or changing the Skill, run `scripts/test-contract.ps1` before using it on a project.
