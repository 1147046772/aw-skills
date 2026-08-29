# Project Adapter Contract

The adapter supplies project mechanics only: workspace roots, identity providers, exact destinations, API contracts, deterministic runners, and the evidence jail. It never grants authorization or defines expected behavior.

Each destination is an exact tuple of service, scheme, host, port, base path, environment class, network scope, and external/production classification. The Request binds its deterministic fingerprint. Environment labels and environment variables cannot redefine that tuple; redirects are forbidden.

Each contract entry binds a deterministic contract manifest, an Operation index, and optional traceability. For stable OpenAPI support, both files are generated from an OpenAPI 3.0/3.1 JSON root by `new-openapi-contract.ps1`; YAML is blocked without a project-pinned parser. The validator rehashes every manifest file, recomputes the combined digest, and independently compares indexed operations with the root contract. The Operation index is the machine source for exact method/path, READ/WRITE effect, and external-call classification; Scenario self-description cannot override it. GraphQL, gRPC, WebSocket, and custom contracts remain adapter-explicit and do not inherit the stable OpenAPI claim.

Each runner has a stable ID, supported test types and protocols, capabilities, a direct-process `argvTemplate`, relative working directory, timeout, environment-variable names, and mutation class. Arguments are literals or one exact token: `{workspace}`, `{requestPath}`, `{scenarioPath}`, `{evidencePath}`, `{artifactRoot}`. Do not interpolate tokens inside larger strings or invoke them as a shell command.

The Adapter may live below the workspace. `roots.workspace` is only `.`, `..`, `../..`, `../../..`, or `../../../..`; after physical resolution it must contain the Adapter. Every other declared path resolves from that workspace. `evidenceRoot` is the evidence jail: the Request file and output root must stay inside it, and receipt/leaf paths must equal the exact configured output filenames. Reject symlink/reparse-point escape.

Environment fields name variables only; values remain in the project-approved secret source. Persist only a SHA-256 identity of resolved arguments.

The surrounding workflow invokes the adapter's read-only candidate and service identity providers before and after the run and writes a current attestation. The generic validator binds observations but does not guess or execute project commands. A final Request is created only after the target runtime exists and its identity is known.

`evidenceMode` is exclusive:

- `GENERIC_CANONICAL`: this Skill emits the sole `test-receipt.json`.
- `PROJECT_NATIVE_PARENT`: this Skill emits `api-test-leaf-summary.json` with authority `TEST_LEAF_EVIDENCE_ONLY`; the project validates and maps it into its existing sole parent summary. Do not emit a competing final receipt.
