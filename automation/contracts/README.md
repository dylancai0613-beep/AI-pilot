# Agent Contract v1

This directory defines the stable boundary between the Generic Core and an
Agent Adapter. Contract JSON files are UTF-8 encoded. All paths in a Request
are absolute paths inside `ProjectRoot`.

## Adapter command interface

```text
powershell.exe -File <adapter> -RequestFile <request.json> -ResultFile <result.json>
```

The Adapter process exit code must exactly equal `Agent Result.ExitCode`.

## Agent Request v1

The Core owns Request creation. Version 1 requires exactly these fields:

```json
{
  "SchemaVersion": 1,
  "AttemptId": "agent-attempt-01",
  "InvocationType": "development",
  "ProjectRoot": "D:\\project",
  "TaskFile": "D:\\project\\automation\\tasks\\task.md",
  "PromptFile": "D:\\project\\automation\\reports\\current-agent-attempt-01.prompt.txt",
  "StdoutFile": "D:\\project\\automation\\reports\\current-agent-attempt-01.stdout.txt",
  "StderrFile": "D:\\project\\automation\\reports\\current-agent-attempt-01.stderr.txt",
  "Runtime": { "Name": "example-runtime" },
  "Model": { "Name": null, "Reasoning": null },
  "Options": {}
}
```

`Runtime`, `Model`, and `Options` are opaque to the Core. The selected Adapter
owns their semantics. `InvocationType` is an extensible non-empty string;
current orchestration uses `development`, `repair`, and `review` without
changing the Runtime boundary.

## Agent Result v1

The Adapter owns Result creation. Version 1 requires exactly these fields:

```json
{
  "SchemaVersion": 1,
  "AttemptId": "agent-attempt-01",
  "AdapterStatus": "completed",
  "ExitCode": 0,
  "StartedAt": "2026-08-10T00:00:00.0000000+00:00",
  "FinishedAt": "2026-08-10T00:00:01.0000000+00:00",
  "Runtime": { "Name": "example-runtime" },
  "RequestedModel": { "Name": null, "Reasoning": null },
  "ResolvedModel": null,
  "Message": "Agent Runtime completed successfully."
}
```

Allowed `AdapterStatus` values are:

- `completed`
- `failed`
- `invalid_configuration`
- `failed_to_start`

`completed` requires exit code 0. Every other status requires a non-zero exit
code. `Runtime` and `RequestedModel` must exactly echo the Request. An Adapter
must leave `ResolvedModel` as `null` unless it has authoritative evidence of
the model actually used.

Echo consistency is structural, not serialized-text equality. Object property
order is ignored recursively, while the exact case-sensitive key set and every
value must match. Array length, element order, and element values must match.
Missing and null fields differ, and strings, numbers, and booleans are never
coerced into one another.

Version 1 Result objects are strict and cannot reference files. Adding fields
or artifact references requires a future schema version and corresponding
Core validation. This prevents an Adapter from smuggling unvalidated external
paths into the report boundary.

## Core acceptance rules

An Agent Attempt is rejected when the Result is missing or invalid, schema or
AttemptId differs, status is unsupported, exit codes differ, timestamps are
invalid, Runtime or RequestedModel differs, an unsupported field is present,
or the Adapter did not create both configured output files. An accepted Agent
result never decides overall project success. Independent Validation, the
optional Review Gate, and Cleanup determine the final outcome.
