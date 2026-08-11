[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
. (Join-Path $projectRoot "automation\contracts\RunStateContract.ps1")
. (Join-Path $projectRoot "automation\contracts\TrajectoryContract.ps1")
. (Join-Path $projectRoot "automation\core\WorkspaceFingerprint.ps1")
. (Join-Path $projectRoot "automation\core\RunState.ps1")
$temporaryDirectory = Join-Path $PSScriptRoot (".tmp-trajectory-" + [Guid]::NewGuid().ToString("N"))
$script:Passed = 0
function Pass([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw $Name }; $script:Passed++; Write-Output ("PASS: " + $Name)
}
function Fail([scriptblock]$Action, [string]$Expected, [string]$Name) {
    $m="";try{&$Action}catch{$m=$_.Exception.Message};if(-not $m.Contains($Expected)){throw($Name+": "+$m)};$script:Passed++;Write-Output("PASS: "+$Name)
}
try {
    $runDirectory = Join-Path $temporaryDirectory "run-20260811T000000Z-1234abcd"
    $artifacts = Join-Path $runDirectory "artifacts"
    [void][System.IO.Directory]::CreateDirectory($artifacts)
    $trajectory = Join-Path $runDirectory "trajectory.jsonl"
    $state = [PSCustomObject]@{
        RunId = "run-20260811T000000Z-1234abcd"
        Git = [PSCustomObject]@{ CurrentWorkspaceFingerprint = ("a" * 64) }
    }
    $event1 = Add-TrajectoryEvent $state $trajectory $runDirectory `
        "run_created" "initializing" "created" "core"
    $event2 = Add-TrajectoryEvent $state $trajectory $runDirectory `
        "stage_started" "development" "started" "developer" 1 `
        ([PSCustomObject]@{ AgentRequest = "artifacts/request.json" })
    Pass ($event1.Sequence -eq 1) "first Sequence is 1"
    Pass ($event2.Sequence -eq 2) "append Sequence is continuous"
    $events = @(Read-TrajectoryJsonLines $trajectory $state.RunId $runDirectory)
    Pass ($events.Count -eq 2) "JSONL lines independently parse"
    $event3 = Add-TrajectoryEvent $state $trajectory $runDirectory `
        "run_resumed" "development" "running" "core"
    Pass ($event3.Sequence -eq 3) "Resume-style append continues Sequence"

    $bad = $event1 | Select-Object *; $bad.Sequence = 0
    Fail { Assert-TrajectoryEventContract $bad $state.RunId $runDirectory } `
        "positive integer" "non-positive Sequence rejection"
    # Contract-level duplicate/continuity checks are exercised through a copied JSONL.
    $corrupt = Join-Path $runDirectory "corrupt.jsonl"
    $line1 = $event1 | ConvertTo-Json -Depth 32 -Compress
    $duplicate = $event2 | Select-Object *; $duplicate.Sequence = 1
    $line2 = $duplicate | ConvertTo-Json -Depth 32 -Compress
    [System.IO.File]::WriteAllText($corrupt, $line1+"`n"+$line2+"`n")
    Fail { Read-TrajectoryJsonLines $corrupt $state.RunId $runDirectory } `
        "continuous" "duplicate Sequence rejection"
    $gap = $event2 | Select-Object *; $gap.Sequence = 3
    [System.IO.File]::WriteAllText($corrupt, $line1+"`n"+($gap|ConvertTo-Json -Depth 32 -Compress)+"`n")
    Fail { Read-TrajectoryJsonLines $corrupt $state.RunId $runDirectory } `
        "continuous" "Sequence gap rejection"
    [System.IO.File]::WriteAllText($corrupt, "{ bad`n")
    Fail { Read-TrajectoryJsonLines $corrupt $state.RunId $runDirectory } `
        "malformed JSON" "malformed line rejection"

    $bad = $event1 | Select-Object *; $bad.SchemaVersion = 2
    Fail { Assert-TrajectoryEventContract $bad $state.RunId $runDirectory } `
        "Unsupported Trajectory SchemaVersion" "schema rejection"
    Fail { Assert-TrajectoryEventContract $event1 "run-20260811T000000Z-deadbeef" $runDirectory } `
        "RunId does not match" "RunId rejection"
    $bad = $event1 | Select-Object *; $bad.Timestamp = "bad"
    Fail { Assert-TrajectoryEventContract $bad $state.RunId $runDirectory } `
        "Timestamp is invalid" "timestamp rejection"
    $bad = $event1 | Select-Object *; $bad.EventType = ""
    Fail { Assert-TrajectoryEventContract $bad $state.RunId $runDirectory } `
        "EventType" "EventType rejection"
    $bad = $event1 | Select-Object *; $bad.Stage = "specific-runtime"
    Fail { Assert-TrajectoryEventContract $bad $state.RunId $runDirectory } `
        "Unsupported Trajectory Stage" "stage rejection"
    $bad = $event1 | Select-Object *; $bad.ActorRole = "model"
    Fail { Assert-TrajectoryEventContract $bad $state.RunId $runDirectory } `
        "Unsupported Trajectory ActorRole" "ActorRole rejection"
    $bad = $event1 | Select-Object *; $bad.Artifacts = [PSCustomObject]@{ X = "..\outside" }
    Fail { Assert-TrajectoryEventContract $bad $state.RunId $runDirectory } `
        "parent traversal" "artifact path rejection"
    $bad = $event1 | Select-Object *; $bad | Add-Member Extra 1
    Fail { Assert-TrajectoryEventContract $bad $state.RunId $runDirectory } `
        "unsupported field" "extra field rejection"
    $bad = $event1 | Select-Object *; $bad.DurationMs = -1
    Fail { Assert-TrajectoryEventContract $bad $state.RunId $runDirectory } `
        "non-negative" "Duration rejection"
    $text = [System.IO.File]::ReadAllText($trajectory)
    Pass (-not $text.Contains("FULL PROMPT CONTENT") -and
        -not $text.Contains("FULL STDOUT CONTENT")) "trajectory stores references, not large logs"
    Pass ($event1.Runtime -eq $null -and $event1.RequestedModel -eq $null) `
        "Runtime and Model may be null"
    Write-Output ("TRAJECTORY CONTRACT TESTS PASSED: " + $script:Passed)
}
finally {
    $full=[System.IO.Path]::GetFullPath($temporaryDirectory)
    if(-not $full.StartsWith([System.IO.Path]::GetFullPath($PSScriptRoot)+"\")){throw"Unsafe cleanup"}
    if(Test-Path $full){Remove-Item -LiteralPath $full -Recurse}
}
