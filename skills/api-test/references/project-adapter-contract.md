# Project Adapter Contract

The adapter supplies project mechanics only: workspace roots, identity providers, exact destinations, API contracts, deterministic runners, and the evidence jail. It never grants authorization or defines expected behavior.

Each destination is an exact tuple of service, scheme, host, port, base path, environment class, network scope, and external/production classification. The Request binds its deterministic fingerprint. Environment labels and environment variables cannot redefine that tuple; redirects are forbidden.

Each contract entry binds a deterministic contract manifest, an Operation index, and optional traceability. The validator rehashes every manifest file and recomputes the combined digest. The Operation index is the machine source for exact method/path, READ/WRITE effect, and external-call classification; Scenario self-description cannot override it.

Each runner has a stable ID, supported test types and protocols, capabilities, a direct-process `argvTemplate`, relative working directory, timeout, environment-variable names, and mutation class. Arguments are literals or one exact token: `{workspace}`, `{requestPath}`, `{scenarioPath}`, `{evidencePath}`, `{artifactRoot}`. Do not interpolate tokens inside larger strings or invoke them as a shell command.

`roots.workspace` is either `.` or a bounded ancestor-only path of one to four `..` segments, so a versioned Adapter may live under `.api-test/` or inside one repository of a multi-repository workspace. The validator resolves that ancestor, rejects filesystem roots and symlink/reparse-point chains, then requires the Adapter, Request and every other portable path to remain inside the physical workspace. The Request output root must also remain inside the Adapter's `evidenceRoot`; receipt and leaf-summary paths must exactly match the Request output contract. Environment fields name variables only; values remain in the project-approved secret source. Persist only a SHA-256 identity of resolved arguments.

The surrounding workflow invokes the adapter's read-only candidate and service identity providers before and after the run and writes a current attestation. The generic validator binds observations but does not guess or execute project commands. A final Request is created only after the target runtime exists and its identity is known.

`evidenceMode` is exclusive:

- `GENERIC_CANONICAL`: this Skill emits the sole `test-receipt.json`.
- `PROJECT_NATIVE_PARENT`: this Skill emits `api-test-leaf-summary.json` with authority `TEST_LEAF_EVIDENCE_ONLY`; the project validates and maps it into its existing sole parent summary. Do not emit a competing final receipt.
