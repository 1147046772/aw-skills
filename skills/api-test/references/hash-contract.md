# Hash and Identity Contract

Adapter, catalog, scenario, request, attestation, contract manifest, Operation index, evidence, artifact, leaf summary, and receipt references use lowercase SHA-256 of exact file bytes. Do not normalize JSON, whitespace, line endings, encoding, or key order.

The API contract combination digest is SHA-256 of UTF-8 without BOM for sorted, case-sensitive lines `relative/path<TAB>exact-file-sha256<LF>`. Paths use `/`. The manifest root and all transitive local references must appear exactly once; external references are rejected by the v2 baseline.

The exact request hash binds candidate, environment, service identity, adapter, catalog, authorization, selection, budget, and output policy. Every child evidence repeats it.

The candidate source hash covers project-relevant source/config/build inputs. Runtime evidence separately binds the actual service, image/container or process identity, contract hash, and authentication-profile fingerprint. A source hash is not a runtime identity.

Finding fingerprint is SHA-256 of UTF-8 `<scenarioId>\t<assertionId>\n`. Keep assertion meaning stable or change its ID/version.

Schema validates shape, not cross-file equality. `validate-contract.ps1` recomputes contract files, destination fingerprint, cross-file identities, Operation semantics, coverage, evidence, and current attestation before consumption.
