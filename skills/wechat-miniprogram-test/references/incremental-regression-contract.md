# Incremental Regression Contract

This contract defines when a run may use an impact slice instead of the full catalog. Validate the catalog, request, scenarios, lineage source, evidence, and receipt with `scripts/validate-contract.ps1`; Schema validation alone does not prove the slice is complete.

## Stable inputs

- A versioned test catalog lists every active scenario and its exact-file hash.
- Each scenario declares typed `impact.keys`; every assertion declares the subset it proves.
- Catalog relations point from an upstream scenario to a downstream scenario and name the impact keys carried across the edge.
- A first reproduction may import path/hash-bound external evidence. Later defect runs reference the exact parent receipt and prior failing scenario/assertion. One defect record tracks one finding fingerprint; multiple failing assertions use multiple records and may share the same external `defectId`.

## Selection algorithm

For `FULL`, select the entire catalog.

For `IMPACT`:

1. Seed with every prior failing scenario/assertion named by the defect and every scenario whose impact keys intersect `changedImpactKeys`.
2. Except in exact `DEFECT_REPRODUCTION`, add every scenario sharing a seeded assertion or changed impact key. This closes shared state, contract, and invariant coverage without broad tag matching.
3. Traverse relevant catalog edges upstream and downstream to the declared depth. An edge is relevant only when its `impactKeys` intersects the affected keys.
4. The selected IDs must equal the computed closure. Missing cases are unsafe; unrelated extras are inefficient. Correct the catalog, impact keys, graph, or strategy instead of overriding the result.

Use depth 0 only for exact defect reproduction. Fix verification requires at least one upstream and one downstream hop. Use depth 2 only for a demonstrated multi-hop state or contract propagation. If the graph cannot bound propagation, run `FULL`.

## Mandatory full-suite triggers

`IMPACT` is invalid when any active trigger is present:

- `impact-unknown`
- `catalog-stale`
- `shared-foundation-change`
- `test-infrastructure-change`
- `multi-domain-change`
- `unexpected-outside-impact-failure`
- `release-baseline`
- `policy-required`

Do not run full merely because a bug exists. Run full because the impact boundary is unknown, unusually broad, explicitly required, or due for a baseline.

## Efficient round order

For fix verification, run the prior defect reproducer first. If it still fails, stop with `DEFECT_REPRODUCED`; downstream execution adds no closure value. If it passes, run direct/shared-key cases, then upstream/downstream closure. Build and preflight once per candidate identity.

Fresh deterministic evidence may be reused only for the identical candidate, request hash, runtime profile, scenario hash, and invalidation keys. A new source/build/environment identity requires new evidence for the selected slice; old full-suite evidence is historical context, not proof for the new candidate.

## Closure

A defect is `CLOSED` only when the parent-receipt lineage is hash-valid, the candidate identity changed, all prior failing assertions now pass, the exact computed impact closure ran, all selected required assertions passed, no new product finding exists, mutations are resolved, and no full-suite trigger is active. External evidence can seed reproduction but cannot directly authorize `CLOSED`.

Otherwise report `OPEN`, `PARTIAL`, or `BLOCKED`. A targeted PASS proves only the declared impact closure; it does not claim the entire catalog ran.
