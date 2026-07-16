# SatelliteSimPlatformRuntime

Phase 2A Runtime Application Service for the SatelliteSim platform. This is a
pure-Julia, transport-neutral application core. It has no network, no
credentials, no FastMCP adapter and no real runner; those arrive in later PRs.

## Scope (Phase 2A / PR1)

- Runtime Application Service exposing the ten runtime operations:
  `runtime_health`, `runtime_capabilities`, `validate_experiment`,
  `submit_experiment`, `get_job`, `list_jobs`, `cancel_job`, `get_artifacts`,
  `read_result`, `reproduce_job`.
- `RuntimeJobStore`: durable SQLite persistence (WAL, foreign keys, busy
  timeout, `BEGIN IMMEDIATE` for every multi-row invariant) with a versioned
  migration table (schema version 1).
- Fencing-token leases: monotonically increasing tokens, heartbeat renewal,
  lease expiry recovery, and stale-worker fencing (a worker that lost its lease
  cannot renew, transition, or publish).
- Public state machine (`queued`/`running`/`succeeded`/`failed`/`cancelled`)
  with internal progress phases.
- Idempotency (`UNIQUE(tenant_id, idempotency_key)`), per-tenant admission and
  concurrency quota, and an append-only audit log.
- Single-transaction terminal commit: terminal state, quota release and the
  terminal audit event are written atomically.
- Recoverable submit workflow: the normalized config object is persisted before
  the durable job row.
- Admission control and resource profiles (`small`, `standard`, CPU-only) plus
  the stable error taxonomy and envelope.
- `AbstractExecutionBackend` contract (`start`/`status`/`wait_result`/`cancel`)
  with an in-process `DeterministicTestBackend`.
- `LocalFilesystemStorage` integration and artifact-contract verification.
- Test principal injected through the constructor (no real identity or token).

## Explicitly out of scope (later PRs)

FastMCP / Bearer termination, UDS transport, Cloudflare, systemd, the rootless
container worker and real Julia runner, Azure/S3 storage, real credentials and
cross-machine deployment.

## Tests

```
julia --project=platform/runtime -e 'using Pkg; Pkg.test()'
```

Suites: `contract` (the ten operations plus the deterministic end-to-end closure
driven by `platform/examples/walker8-local-v1.json`), `persistence`
(durability, migrations, idempotency, quota, single-transaction finalize),
`lease_race` (fencing / stale-worker eviction) and `characterization` (pins the
reused behavior of PlatformRunner, Control, Storage and Kubernetes packages).
