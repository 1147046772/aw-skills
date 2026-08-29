# Hash and Identity Contract

Use this contract whenever a test request, catalog, scenario, evidence file, artifact, or receipt is persisted. A displayed Git SHA, path, timestamp, or parsed-object hash is not a substitute.

## Exact-file hash

Adapter, catalog, scenario, request, evidence, artifact, parent-receipt, and receipt references use lowercase SHA-256 of exact file bytes. Do not normalize JSON, line endings, whitespace, encoding, or key order. Validate the file first, hash it second, and reject any later byte change.

The catalog is the complete active test-case index. Its exact-file hash binds scenario IDs, paths, hashes, and upstream/downstream relations. Each referenced scenario hash must match the current file.

## Request hash

The exact-file SHA-256 of validated `test-request.json` is the request hash. It must equal:

- each scenario evidence `scope.requestHash`;
- aggregate receipt `input.requestSha256`.

This binds candidate, environment/AppID/API identity, parent lineage, catalog, selected impact closure, authorization, budget, and output policy without a second canonicalization algorithm.

## Finding fingerprint

For a failed assertion, hash the UTF-8 bytes with no BOM of:

`<scenarioId>\t<assertionId>\n`

The lowercase SHA-256 is `findingFingerprint`. Keep assertion meaning stable for an ID; change the ID or scenario version when the asserted contract changes. A lineage-bound run must use the same fingerprint.

## Candidate identity

`candidate.sourceHash` identifies project-relevant source inputs using the adapter's versioned method. A fix-verification run must differ from its parent in source hash, build ID, API identity, or environment config hash. A changed candidate invalidates old scenario evidence even when the selected impact slice is smaller than the catalog.

## Consumer checks

Generate the receipt from child evidence with `scripts/new-test-receipt.ps1`; do not hand-copy hashes, counts, findings, blockers, or coverage.

Schema validates shape, not cross-file equality. Recompute all hashes and repeated identities, validate parent failure lineage, compute the selected impact closure from current catalog/scenario bytes, and verify evidence/artifact hashes and freshness. Missing files, duplicate IDs, stale catalog bytes, invalid relation keys, mismatched findings, or identity drift invalidate the receipt.
