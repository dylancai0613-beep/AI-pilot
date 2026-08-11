[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
foreach ($file in @(
    "automation\contracts\RunStateContract.ps1",
    "automation\contracts\TrajectoryContract.ps1",
    "automation\core\WorkspaceFingerprint.ps1",
    "automation\core\RunState.ps1",
    "automation\core\PersistentWorkflow.ps1"
)) { . (Join-Path $projectRoot $file) }
$temporary = Join-Path $PSScriptRoot (".tmp-core-run-" + [Guid]::NewGuid().ToString("N"))
try {
    [void][System.IO.Directory]::CreateDirectory($temporary)
    $task = Join-Path $temporary "task.md"
    $config = Join-Path $temporary "project.config.psd1"
    $runs = Join-Path $temporary "runs"
    $reports = Join-Path $temporary "reports"
    [void][System.IO.Directory]::CreateDirectory($runs)
    [void][System.IO.Directory]::CreateDirectory($reports)
    [System.IO.File]::WriteAllText($task, "Fake integration task")
    $relative = {
        param($path)
        return ([System.IO.Path]::GetFullPath($path).Substring($projectRoot.Length + 1).Replace("\", "/"))
    }
    $agent = & $relative (Join-Path $PSScriptRoot "fixtures\fake_agent_adapter.ps1")
    $validation = & $relative (Join-Path $PSScriptRoot "fixtures\fake_validation_adapter.ps1")
    $cleanup = & $relative (Join-Path $PSScriptRoot "fixtures\fake_cleanup_adapter.ps1")
    $runsRelative = & $relative $runs
    $reportsRelative = & $relative $reports
    $configText = @"
@{
 ProjectName='Fake Integration Project'
 Agents=@{
  Developer=@{AdapterPath='$agent';Runtime=@{Name='fake'};Model=@{Name=`$null;Reasoning=`$null};Options=@{}}
  Reviewer=@{Enabled=`$true;AdapterPath='$agent';Runtime=@{Name='fake'};Model=@{Name=`$null;Reasoning=`$null};Options=@{}}
 }
 Validation=@{AdapterPath='$validation';ReportPath='$reportsRelative/validation.txt'}
 Cleanup=@{Enabled=`$true;AdapterPath='$cleanup'}
 Reports=@{Directory='$reportsRelative';AutonomousLatest='$reportsRelative/latest.txt'}
 Runs=@{Directory='$runsRelative'}
 Defaults=@{MaxAttempts=3;MaxReviewCycles=2;MaxReviewerAttempts=2}
}
"@
    [System.IO.File]::WriteAllText($config, $configText)
    $fingerprint = Get-WorkspaceFingerprint $projectRoot @($runsRelative, $reportsRelative)
    $runId = New-RunId
    $runDirectory = Join-Path $runs $runId
    [void][System.IO.Directory]::CreateDirectory((Join-Path $runDirectory "artifacts"))
    $context = @{
        ProjectRoot = $projectRoot
        RunDirectory = $runDirectory
        StatePath = Join-Path $runDirectory "state.json"
        TrajectoryPath = Join-Path $runDirectory "trajectory.jsonl"
    }
    $state = New-InitialRunState `
        -RunId $runId -ProjectName "Fake Integration Project" `
        -TaskPath (& $relative $task) -TaskSha256 (Get-RunFileSha256 $task) `
        -ConfigPath (& $relative $config) -ConfigSha256 (Get-RunFileSha256 $config) `
        -InitialBranch $fingerprint.Branch -InitialHead $fingerprint.Head `
        -WorkspaceFingerprint $fingerprint.Hash `
        -MaxAttempts 3 -MaxReviewCycles 2 -MaxReviewerAttempts 2 `
        -ReviewerEnabled $true -CleanupEnabled $true
    [void](Initialize-PersistentRun $context $state)

    $core = Join-Path $projectRoot "automation\core\run_autonomous_task.ps1"
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $core `
        -ProjectRoot $projectRoot -ConfigFile $config -ResumeRunId $runId
    if ($LASTEXITCODE -ne 0) { throw ("Fake Core workflow exit code: " + $LASTEXITCODE) }
    $final = Read-RunStateJson $context.StatePath
    [void](Assert-RunStateContract $final $projectRoot $runId)
    if ($final.Status -ne "completed" -or
        $final.Counters.DeveloperAttempts -ne 1 -or
        $final.Counters.ValidationAttempts -ne 1 -or
        $final.Counters.ReviewerAttempts -ne 1) {
        throw "Fake Core workflow produced unexpected State."
    }
    $events = @(Read-TrajectoryJsonLines $context.TrajectoryPath $runId $runDirectory)
    if ($events[-1].EventType -ne "run_completed") {
        throw "Fake Core workflow did not complete its Trajectory."
    }
    if (-not (Test-Path (Join-Path $runDirectory "summary.txt"))) {
        throw "Fake Core workflow did not write summary.txt."
    }
    Write-Output "CORE PERSISTENT INTEGRATION PASSED (FAKE ADAPTERS ONLY)"
}
finally {
    $full=[System.IO.Path]::GetFullPath($temporary)
    if(-not $full.StartsWith([System.IO.Path]::GetFullPath($PSScriptRoot)+"\")){throw"Unsafe cleanup"}
    if ($env:KEEP_CORE_TEST_ARTIFACTS -eq "1") {
        Write-Output ("KEPT TEST ARTIFACTS: " + $full)
    }
    elseif(Test-Path $full){Remove-Item -LiteralPath $full -Recurse}
}
