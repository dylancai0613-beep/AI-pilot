# Review Contract v1

The Review Contract is separate from the Agent Contract. The Agent Contract
proves that a configured Agent Runtime executed successfully. The Review
Contract carries the independent quality verdict produced by a Reviewer role.

The Reviewer writes UTF-8 JSON to the exact file supplied in its prompt. The
Core never derives a verdict from natural-language stdout.

## Review Result

```json
{
  "SchemaVersion": 1,
  "ReviewId": "review-cycle-01",
  "ReviewerAgentAttemptId": "agent-attempt-02",
  "Verdict": "changes_requested",
  "Summary": "One blocking correctness issue remains.",
  "Findings": [
    {
      "Id": "REV-001",
      "Severity": "major",
      "Blocking": true,
      "Category": "correctness",
      "File": "src/example.ps1",
      "Line": 42,
      "Message": "The failure path returns the success exit code.",
      "Evidence": "The branch at line 42 assigns ExitCode = 0."
    }
  ],
  "CreatedAt": "2026-08-10T00:00:00.0000000+00:00"
}
```

Version 1 allows only `approved` and `changes_requested`. An approved result
cannot contain blocking findings. A changes-requested result requires at least
one blocking finding. Severity is one of `blocker`, `major`, or `minor`.

Every Finding uses the exact fields shown above. `File` and `Line` may both be
null. A non-null File must be a project-relative path without parent traversal;
a non-null Line must be a positive integer. Evidence is inline text, not an
external attachment or file reference.
