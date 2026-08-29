# Scenario Contract

A scenario is a reusable expected-behavior fragment. Project mechanics belong to the adapter; candidate, environment, run, optional defect lineage, authorization, selection, and output belong to the test request. Validate with [scenario.schema.json](scenario.schema.json).

## Test-case format

- `impact.keys` uses `kind:value` keys. Allowed kinds are `source`, `page`, `component`, `api`, `state`, `data`, `permission`, `config`, `contract`, `invariant`, and `device`.
- Use stable business/runtime identities, not broad labels such as `login`, `common`, or `other`. Two scenarios share an impact only when the exact key is the same.
- Every assertion lists the subset of scenario impact keys it proves. Assertion keys may not escape the scenario boundary.
- Changing an assertion's meaning requires a new assertion ID or scenario version. The failure fingerprint is SHA-256 of UTF-8 `<scenarioId>\t<assertionId>\n`, so stable IDs support exact multi-round matching. One defect record tracks one failing assertion fingerprint; correlated assertions may share the same external defect ID.
- Static, compile, unit, component, and integration scenarios may have no target page, but must select a project runner. UI and device scenarios name every allowed page; device scenarios use the device channel.
- Steps use semantic targets and observable waits. Coordinates and arbitrary sleeps are not an acceptance contract.
- Every expected result declares operator, source of truth, severity, impact keys, and evidence type. Never infer expected behavior from the observation.

## Boundary

- Preconditions gate execution; a missing required precondition is normally `BLOCKED`.
- Scenario evidence records only pages actually observed in `scope.observedPages`; allowed or intended target pages are not automatically counted as tested.
- Scenario permissions are a least-privilege subset of request authorization.
- Every scenario has at least one `REQUIRED` assertion. `REQUIRED` assertions determine the verdict; `ADVISORY` failures remain findings and cannot hide or manufacture a product failure.
- Business/test-data writes require a fixture, one-attempt write policy, an idempotency-bound write step, and declared compensation or explicit absence of one.
- Evidence for every attempted mutation declares whether it was restored, compensated, intentionally persisted under authorization, or remains unresolved. `UNRESOLVED` forces scenario verdict `BLOCKED`; its blocker must state the current data state, affected scope, and concrete manual recovery or verification step.
- Human observation must use the human channel and declare `manualObservation=true`; it cannot replace a required machine/device assertion.
- A stable flow discovered through MCP should become a versioned scenario when repetition has value.

The test catalog owns cross-scenario upstream/downstream relations. The validator cross-checks catalog/scenario IDs and hashes, impact keys, relation endpoints, assertions, runner, channel, capabilities, permissions, and output paths. JSON Schema validation alone is insufficient.
