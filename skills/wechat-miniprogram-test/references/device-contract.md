# Device Contract

Load this contract only when an assertion depends on physical-device behavior or a device-cloud run.

## Required boundary additions

- Device class and model, operating-system version, WeChat version, mini-program candidate/build identity, network profile, and test timestamp.
- Initial permission state for every used capability: undecided, allowed, denied, or unavailable.
- Manual checkpoints, if any, with the responsible actor and the exact observation required. A manual step cannot be reported as automated coverage.
- Device-only assertions and artifacts, including screenshot/video/trace identity and freshness.
- Any user-visible permission, account, file, location, camera, microphone, notification, clipboard, or storage mutation.

Record the non-sensitive device profile in `evidence.runtime.deviceProfile`; copy it into the matching `test-receipt.runtimeProfiles[]` entry. Hash the declared initial permission map into `permissionStateHash`. When `coverage.deviceValidated=true`, at least one runtime profile must contain a device profile.

Do not record serial numbers, advertising identifiers, phone numbers, account secrets, or full personal identity.

## Rules

- Simulator or DevTools PASS is only a prerequisite when the contract requires it; it cannot satisfy a device-only assertion.
- Do not silently change permissions, network conditions, device settings, foreground/background state, or logged-in account.
- Declare whether state restoration is authorized. If not authorized, stop after recording the resulting state and required manual recovery.
- Repeatability claims require the declared device/network matrix and run count. One device run proves only that bound device case.
- A device case is `BLOCKED` when required hardware, permission, account, network shaping, or credible capture is unavailable.
