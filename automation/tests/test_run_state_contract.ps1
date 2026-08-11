[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
. (Join-Path $projectRoot "automation\contracts\RunStateContract.ps1")
. (Join-Path $projectRoot "automation\contracts\TrajectoryContract.ps1")
. (Join-Path $projectRoot "automation\core\WorkspaceFingerprint.ps1")
. (Join-Path $projectRoot "automation\core\RunState.ps1")

$temporaryDirectory = Join-Path $PSScriptRoot (".tmp-run-state-" + [Guid]::NewGuid().ToString("N"))
$script:Passed = 0

function Assert-Pass([scriptblock]$Action, [string]$Name) {
    [void](& $Action); $script:Passed++; Write-Output ("PASS: " + $Name)
}
function Assert-Fail([scriptblock]$Action, [string]$Expected, [string]$Name) {
    $message = ""; try { & $Action } catch { $message = $_.Exception.Message }
    if (-not $message.Contains($Expected)) { throw ($Name + ": " + $message) }
    $script:Passed++; Write-Output ("PASS: " + $Name)
}
function Copy-State([object]$State) {
    return ($State | ConvertTo-Json -Depth 32 | ConvertFrom-Json)
}

try {
    [void][System.IO.Directory]::CreateDirectory($temporaryDirectory)
    $task = Join-Path $temporaryDirectory "task.md"
    $config = Join-Path $temporaryDirectory "config.psd1"
    [System.IO.File]::WriteAllText($task, "task")
    [System.IO.File]::WriteAllText($config, "@{}")
    $relativeTask = $task.Substring($projectRoot.Length + 1)
    $relativeConfig = $config.Substring($projectRoot.Length + 1)
    $hash = "a" * 64
    $state = New-InitialRunState `
        -RunId (New-RunId) -ProjectName "Example" `
        -TaskPath $relativeTask -TaskSha256 (Get-RunFileSha256 $task) `
        -ConfigPath $relativeConfig -ConfigSha256 (Get-RunFileSha256 $config) `
        -InitialBranch "branch" -InitialHead "head" `
        -WorkspaceFingerprint $hash -MaxAttempts 3 `
        -MaxReviewCycles 2 -MaxReviewerAttempts 2 `
        -ReviewerEnabled $true -CleanupEnabled $true

    Assert-Pass { Assert-RunStateContract $state $projectRoot $state.RunId } `
        "valid Run State"

    $statePath = Join-Path $temporaryDirectory "state.json"
    Write-RunStateAtomic $state $statePath $projectRoot
    $state.UpdatedAt = [DateTimeOffset]::UtcNow.AddSeconds(1).ToString("o")
    Write-RunStateAtomic $state $statePath $projectRoot
    $loaded = Read-RunStateJson $statePath
    Assert-Pass { Assert-RunStateContract $loaded $projectRoot $state.RunId } `
        "atomic write and replacement"
    if ((@(Get-ChildItem $temporaryDirectory -Filter ".state-*.tmp").Count -ne 0) `
        -or (Test-Path (Join-Path $temporaryDirectory ".state-replace.backup"))) {
        throw "Atomic State left temporary files."
    }
    $script:Passed++; Write-Output "PASS: atomic temporary cleanup"

    Assert-Fail { Read-RunStateJson (Join-Path $temporaryDirectory "missing.json") } `
        "was not found" "missing state"
    [System.IO.File]::WriteAllText($statePath, "{ bad")
    Assert-Fail { Read-RunStateJson $statePath } "not valid JSON" "malformed state"
    Write-RunStateAtomic $state $statePath $projectRoot

    $bad = Copy-State $state; $bad.SchemaVersion = 2
    Assert-Fail { Assert-RunStateContract $bad $projectRoot $state.RunId } `
        "Unsupported Run State SchemaVersion" "schema mismatch"
    Assert-Fail { Assert-RunStateContract $state $projectRoot "run-20000101T000000Z-deadbeef" } `
        "RUN_ID_MISMATCH" "RunId mismatch"
    $bad = Copy-State $state; $bad | Add-Member Extra 1
    Assert-Fail { Assert-RunStateContract $bad $projectRoot $state.RunId } `
        "unsupported field" "extra top-level field"
    $bad = Copy-State $state; $bad.Status = "unknown"
    Assert-Fail { Assert-RunStateContract $bad $projectRoot $state.RunId } `
        "Unsupported Run State Status" "invalid status"
    $bad = Copy-State $state; $bad.CurrentStage = "runtime-stage"
    Assert-Fail { Assert-RunStateContract $bad $projectRoot $state.RunId } `
        "Unsupported Run State CurrentStage" "invalid stage"
    $bad = Copy-State $state; $bad.Counters.DeveloperAttempts = -1
    Assert-Fail { Assert-RunStateContract $bad $projectRoot $state.RunId } `
        "non-negative integer" "negative counter"
    $bad = Copy-State $state; $bad.Gates.Validation = "MAYBE"
    Assert-Fail { Assert-RunStateContract $bad $projectRoot $state.RunId } `
        "Unsupported Run State Gate" "invalid gate"
    $bad = Copy-State $state; $bad.CreatedAt = "bad"
    Assert-Fail { Assert-RunStateContract $bad $projectRoot $state.RunId } `
        "CreatedAt is invalid" "invalid CreatedAt"
    $bad = Copy-State $state; $bad.UpdatedAt = "2000-01-01T00:00:00Z"
    Assert-Fail { Assert-RunStateContract $bad $projectRoot $state.RunId } `
        "must not be earlier" "UpdatedAt before CreatedAt"
    $bad = Copy-State $state; $bad.Task.Path = "..\outside.md"
    Assert-Fail { Assert-RunStateContract $bad $projectRoot $state.RunId } `
        "parent traversal" "Task path escape"
    $bad = Copy-State $state; $bad.Config.Path = "C:\outside.psd1"
    Assert-Fail { Assert-RunStateContract $bad $projectRoot $state.RunId } `
        "project-relative" "Config path escape"
    $bad = Copy-State $state; $bad.Task.Sha256 = "short"
    Assert-Fail { Assert-RunStateContract $bad $projectRoot $state.RunId } `
        "SHA256" "missing SHA256"
    $bad = Copy-State $state; $bad.Git.InitialHead = ""
    Assert-Fail { Assert-RunStateContract $bad $projectRoot $state.RunId } `
        "InitialHead" "missing branch or HEAD"
    $bad = Copy-State $state; $bad.LastCheckpoint.Sequence = -1
    Assert-Fail { Assert-RunStateContract $bad $projectRoot $state.RunId } `
        "Sequence must be" "invalid checkpoint Sequence"
    $bad = Copy-State $state; $bad.Status = "completed"; $bad.CurrentStage = "complete"
    Assert-Fail { Assert-RunStateContract $bad $projectRoot $state.RunId } `
        "requires all enabled Gates" "completed with failed gates"
    $bad = Copy-State $state; $bad.Status = "completed"
    Assert-Fail { Assert-RunStateContract $bad $projectRoot $state.RunId } `
        "requires CurrentStage complete" "completed with wrong stage"

    Write-Output ("RUN STATE CONTRACT TESTS PASSED: " + $script:Passed)
}
finally {
    $full = [System.IO.Path]::GetFullPath($temporaryDirectory)
    if (-not $full.StartsWith([System.IO.Path]::GetFullPath($PSScriptRoot) + "\")) {
        throw "Unsafe test cleanup path."
    }
    if (Test-Path $full) { Remove-Item -LiteralPath $full -Recurse }
}
