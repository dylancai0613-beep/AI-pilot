# Trajectory Contract v1

`trajectory.jsonl` is the append-only event history for one Run. Every line is
an independent UTF-8 JSON object with a strictly continuous Sequence starting
at 1.

Each event contains the stable fields:

```text
SchemaVersion, RunId, Sequence, Timestamp, EventType, Stage, Outcome,
ActorRole, Attempt, Artifacts, WorkspaceFingerprint, Message, Runtime,
RequestedModel, ResolvedModel, DurationMs, GateResult, FindingCount,
FailureKind
```

Runtime and model metadata may be null and are never inferred. Adapter Options,
environment dumps, credentials, and secret values are not copied into the
trajectory.

Large prompts, stdout/stderr, Validation reports, and Review Results remain in
the Run's `artifacts/` directory. Events contain only Run-relative artifact
references, which are path-validated against the Run directory.

Event types are generic and extensible. Current orchestration emits run,
checkpoint, stage, Agent attempt, Validation, Review, repair, gate, Cleanup,
resume, interruption, completion, and failure events without project- or
Runtime-specific event names.
