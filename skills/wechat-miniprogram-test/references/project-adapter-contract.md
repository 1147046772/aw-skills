# Project Adapter Contract

A project adapter supplies only project mechanics: roots, source identity, supported channels/capabilities, deterministic runners, and the evidence jail. It conforms to [project.schema.json](project.schema.json) and never grants authorization or defines expected product behavior.

## Discovery

Resolve exactly one adapter from the test request. `roots.workspace` is relative to the adapter file directory and may use parent segments so an adapter can live under `.wechat-test/`; the resolved adapter must still belong to that physical workspace. All other adapter paths and all request/catalog/evidence/receipt paths are relative to the resolved workspace and may not escape it. Execution is `BLOCKED` until the adapter is valid, hash-bound, and unique.

## Runner contract

Each runner has a stable ID, supported test types, one runtime channel, capabilities, a direct-process `argvTemplate`, relative working directory, timeout, environment-variable names, and output mutation class. Its durable result is one `evidence.json` conforming to `evidence.schema.json`; stdout and exit code remain diagnostics and cannot directly determine the canonical verdict.

Template arguments are either literals or one exact token:

- `{workspace}`
- `{requestPath}`
- `{scenarioPath}`
- `{evidencePath}`
- `{artifactRoot}`

Do not interpolate tokens inside larger strings and do not invoke through a shell string. Resolve tokens to canonical paths, prove output paths stay inside the evidence jail, then start the process with an argument array. Unknown tokens are invalid input. Persist only a SHA-256 command identity derived from the resolved argument array; never persist raw arguments or environment values.

The selected scenario `runtime.runnerId` must name exactly one runner whose test type, channel, and capabilities cover the scenario. A null runner ID is permitted only when the selected MCP, human, or device controller is invoked directly and still produces the same scenario evidence contract. Never guess a runner or silently switch after failure.

## Rules

- `candidateIdentity` declares a versioned source-hash method, definition, and optional read-only command. It must cover project-relevant inputs, not path names or timestamps. The surrounding workflow invokes that provider and supplies the observed hash; the contract validator binds and compares recorded values but does not execute project commands.
- Runner IDs must be unique. Runner commands may create build/test output only; they may not modify project source.
- Environment fields name variables only. Secret values stay in the approved runtime secret source.
- Resolve all adapter-relative paths against `roots.workspace` and prove source, DevTools project, config, scenario root, runners, and evidence root belong to the declared workspace.
- `supportedChannels` and capabilities are allowlists. A mismatch is `BLOCKED`, not permission to substitute another controller.
- Every request creates a unique output child. Never overwrite evidence from another request or candidate.

The adapter is shareable only when it contains no secret, login material, real-user identity, or private machine-specific absolute path.
