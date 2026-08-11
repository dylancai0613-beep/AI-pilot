# Run State Contract v1

`state.json` is the authoritative mutable snapshot for one autonomous Run. It
is written atomically in the Run directory and validated strictly before use.

Version 1 contains exactly these top-level fields:

- `SchemaVersion`, `RunId`, `ProjectName`, `Status`, `CurrentStage`
- `Task` and `Config`, each with project-relative `Path` and `Sha256`
- `Git`, with baseline branch/HEAD and current workspace fingerprint
- `Counters` and frozen `EffectiveLimits`
- `Gates`, `LastCheckpoint`, optional `PendingStage`, and `Workflow`
- `CreatedAt`, `UpdatedAt`, and optional terminal `Failure`

Statuses are `initializing`, `running`, `interrupted`, `completed`, and
`failed`. Stages are generic workflow roles: `initializing`, `development`,
`validation`, `review`, `repair`, `cleanup`, and `complete`.

A completed state is valid only at `complete`, with Validation passed and each
enabled Review/Cleanup gate passed. Task, Config, branch, HEAD, counters,
limits, and checkpoint sequence are immutable resume boundaries.

`PendingStage` means an external invocation was checkpointed before launch but
has no completion checkpoint. Resume records it as interrupted and applies the
stage-specific recovery policy without altering historical events.
