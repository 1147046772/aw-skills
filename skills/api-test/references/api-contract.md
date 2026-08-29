# API Scenario Contract

Use stable Operation identities from the hash-bound Operation index, such as `http:GET:/v1/tasks/{id}`, `graphql:Query.task`, `grpc:TaskService/GetTask`, or `websocket:task.updated`. Never persist a secret-bearing full URL or infer the destination from runner output.

Each scenario declares protocol, indexed operations, authentication requirements, fixture, permissions, steps, REQUIRED/ADVISORY assertions, evidence policy, and stop conditions. Project roles, routes, headers, fixtures, and business states remain project facts. `operationId + method + pathOrOperation + serviceId + contractId` must match exactly one indexed Operation.

## Assertions

HTTP success alone is insufficient. Select assertions relevant to the scenario:

- status and protocol envelope;
- response/body schema;
- headers and caching/version semantics;
- authorization and data scope;
- business state transition and side effects;
- idempotency, optimistic concurrency, or deduplication;
- negative validation and stable error contract;
- bounded timing or polling convergence.

An expected 4xx/5xx can PASS when the versioned negative assertion requires it. A 2xx can FAIL when its business, schema, permission, or side-effect assertion fails.

## Mutations and retries

READ/WRITE is derived from the Operation index and cross-checked against protocol method semantics. `GET/HEAD/OPTIONS/QUERY` are READ; `POST/PUT/PATCH/DELETE/MUTATION` are WRITE. Other protocols require an explicit indexed effect. Business/test-data writes require an owned fixture, a one-attempt write policy, an idempotency strategy when supported, and declared compensation or authorized persistence. Unsafe writes and external calls have zero automatic retries. If the connection fails after dispatch and the outcome cannot be proven, record `UNKNOWN` plus an `UNRESOLVED` mutation and stop as `BLOCKED`.

Polling is not a retry of the mutation. It must use a declared read-only operation, bounded attempts/interval, and a terminal state contract. Provider `ACCEPTED`, queued, or unknown states are not final business success unless the scenario explicitly tests submission only.

## Sanitization

Never persist authorization/cookie headers, credential query parameters, secret environment values, raw personal data, one-time codes, or uncontrolled bodies. Store status, duration, content type, selected redacted fields, stable hashes, correlation/idempotency-key hashes, and approved object identifiers.
