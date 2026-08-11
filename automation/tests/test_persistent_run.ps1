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

$temporaryDirectory = Join-Path $PSScriptRoot (".tmp-persistent-run-" + [Guid]::NewGuid().ToString("N"))
$script:Passed = 0
function Check([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw ("Scenario failed: " + $Name) }
    $script:Passed++; Write-Output ("PASS: " + $Name)
}
function Expect-Failure([scriptblock]$Action, [string]$Expected, [string]$Name) {
    $message = ""; try { & $Action } catch { $message = $_.Exception.Message }
    if (-not $message.Contains($Expected)) { throw ($Name + ": " + $message) }
    $script:Passed++; Write-Output ("PASS: " + $Name)
}

function New-TestRun {
    param([string]$Name)
    $runId = New-RunId
    $runDirectory = Join-Path (Join-Path $temporaryDirectory "runs") $runId
    [void][System.IO.Directory]::CreateDirectory((Join-Path $runDirectory "artifacts"))
    $context = @{
        ProjectRoot = $projectRoot
        RunDirectory = $runDirectory
        StatePath = Join-Path $runDirectory "state.json"
        TrajectoryPath = Join-Path $runDirectory "trajectory.jsonl"
    }
    $taskRelative = $script:TaskPath.Substring($projectRoot.Length + 1)
    $configRelative = $script:ConfigPath.Substring($projectRoot.Length + 1)
    $fingerprint = @{ Hash = (Get-Sha256HexFromText ("fingerprint-" + $Name)); Branch = "test-branch"; Head = "test-head" }
    $state = New-InitialRunState `
        -RunId $runId -ProjectName "Test Project" `
        -TaskPath $taskRelative -TaskSha256 (Get-RunFileSha256 $script:TaskPath) `
        -ConfigPath $configRelative -ConfigSha256 (Get-RunFileSha256 $script:ConfigPath) `
        -InitialBranch $fingerprint.Branch -InitialHead $fingerprint.Head `
        -WorkspaceFingerprint $fingerprint.Hash `
        -MaxAttempts 3 -MaxReviewCycles 2 -MaxReviewerAttempts 2 `
        -ReviewerEnabled $true -CleanupEnabled $true
    [void](Initialize-PersistentRun $context $state)
    return @{
        Context = $context
        State = $state
        Fingerprint = $fingerprint
        GetFingerprint = { [PSCustomObject]@{
            Hash = $fingerprint.Hash; Branch = $fingerprint.Branch; Head = $fingerprint.Head
        } }.GetNewClosure()
    }
}

function New-TestStageInvoker {
    param([hashtable]$Run, [AllowNull()][string]$InterruptStage)
    $control = @{ InterruptStage = $InterruptStage; Interrupted = $false; Calls = @() }
    $callback = {
        param($context)
        $control.Calls += [string]$context.Stage
        if (-not $control.Interrupted -and
            [string]$context.Stage -eq [string]$control.InterruptStage) {
            $control.Interrupted = $true
            return [PSCustomObject]@{ SimulatedInterrupt = $true }
        }
        switch ([string]$context.Stage) {
            { $_ -in @("development", "repair") } {
                return [PSCustomObject]@{
                    Succeeded = $true
                    Message = "Developer stage completed."
                    DurationMs = 1
                    Artifacts = [PSCustomObject]@{
                        AgentResult = ("artifacts/agent-{0}.result.json" -f $context.Attempt)
                    }
                }
            }
            "validation" {
                $relative = "artifacts/validation-{0}.txt" -f $context.Attempt
                [System.IO.File]::WriteAllText(
                    (Join-Path $Run.Context.RunDirectory $relative),
                    "validation passed"
                )
                return [PSCustomObject]@{
                    Passed = $true
                    Message = "Validation passed."
                    ArtifactPath = $relative
                    DurationMs = 1
                    Artifacts = [PSCustomObject]@{ ValidationReport = $relative }
                }
            }
            "review" {
                $relative = "artifacts/review-{0}.json" -f $context.ReviewSequence
                [System.IO.File]::WriteAllText(
                    (Join-Path $Run.Context.RunDirectory $relative),
                    "{}"
                )
                return [PSCustomObject]@{
                    TechnicalSucceeded = $true
                    Fatal = $false
                    Verdict = "approved"
                    Message = "Review approved."
                    ArtifactPath = $relative
                    DurationMs = 1
                    Artifacts = [PSCustomObject]@{ ReviewResult = $relative }
                }
            }
            "cleanup" {
                return [PSCustomObject]@{
                    Passed = $true
                    Message = "Cleanup passed."
                    DurationMs = 1
                    Artifacts = [PSCustomObject]@{}
                }
            }
            default { throw ("Unexpected fake stage: " + $context.Stage) }
        }
    }.GetNewClosure()
    return @{ Callback = $callback; Control = $control }
}

function Resume-TestRun([hashtable]$Run) {
    return Open-PersistentRunForResume `
        -RunContext $Run.Context `
        -ExpectedRunId $Run.State.RunId `
        -ExpectedProjectName "Test Project" `
        -ConfigPath $script:ConfigPath `
        -GetWorkspaceFingerprint $Run.GetFingerprint
}

try {
    [void][System.IO.Directory]::CreateDirectory($temporaryDirectory)
    $script:TaskPath = Join-Path $temporaryDirectory "task.md"
    $script:ConfigPath = Join-Path $temporaryDirectory "config.psd1"
    [System.IO.File]::WriteAllText($script:TaskPath, "task baseline")
    [System.IO.File]::WriteAllText($script:ConfigPath, "@{ ProjectName = 'Test Project' }")

    # A: complete workflow.
    $runA = New-TestRun "A"
    $fakeA = New-TestStageInvoker $runA $null
    $stateA = Invoke-PersistentRunWorkflow `
        $runA.Context $runA.State $runA.GetFingerprint $fakeA.Callback
    $eventsA = @(Read-TrajectoryJsonLines `
        $runA.Context.TrajectoryPath $stateA.RunId $runA.Context.RunDirectory)
    Check ($stateA.Status -eq "completed" -and
        $stateA.Gates.Validation -eq "PASSED" -and
        $stateA.Gates.Review -eq "PASSED" -and
        $stateA.Gates.Cleanup -eq "PASSED") "Scenario A normal Run completed"
    Check ($eventsA[-1].EventType -eq "run_completed" -and
        $eventsA.Count -eq $stateA.LastCheckpoint.Sequence) `
        "Scenario A State and Trajectory are continuous"

    # B: interrupted Development resumes with same RunId and partial changes allowed.
    $runB = New-TestRun "B"
    $fakeB = New-TestStageInvoker $runB "development"
    $interruptedB = Invoke-PersistentRunWorkflow `
        $runB.Context $runB.State $runB.GetFingerprint $fakeB.Callback
    $originalRunId = $interruptedB.RunId
    $runB.Fingerprint.Hash = Get-Sha256HexFromText "partial developer changes"
    $resumedB = Resume-TestRun $runB
    $resumedB = Invoke-PersistentRunWorkflow `
        $runB.Context $resumedB $runB.GetFingerprint $fakeB.Callback
    Check ($resumedB.Status -eq "completed" -and $resumedB.RunId -eq $originalRunId -and
        $resumedB.Counters.DeveloperAttempts -eq 2) `
        "Scenario B Development interruption resumes same Run"

    # C: interrupted Validation reruns Validation.
    $runC = New-TestRun "C"; $fakeC = New-TestStageInvoker $runC "validation"
    [void](Invoke-PersistentRunWorkflow $runC.Context $runC.State $runC.GetFingerprint $fakeC.Callback)
    $resumedC = Resume-TestRun $runC
    $resumedC = Invoke-PersistentRunWorkflow $runC.Context $resumedC $runC.GetFingerprint $fakeC.Callback
    Check ($resumedC.Status -eq "completed" -and $resumedC.Counters.ValidationAttempts -eq 2) `
        "Scenario C Validation interruption reruns Validation"

    # D: interrupted Review counts the attempt and reruns Review.
    $runD = New-TestRun "D"; $fakeD = New-TestStageInvoker $runD "review"
    [void](Invoke-PersistentRunWorkflow $runD.Context $runD.State $runD.GetFingerprint $fakeD.Callback)
    $resumedD = Resume-TestRun $runD
    $resumedD = Invoke-PersistentRunWorkflow $runD.Context $resumedD $runD.GetFingerprint $fakeD.Callback
    Check ($resumedD.Status -eq "completed" -and $resumedD.Counters.ReviewerAttempts -eq 2) `
        "Scenario D Review interruption preserves ReviewerAttempts"

    # E: interrupted Cleanup reruns idempotent Cleanup.
    $runE = New-TestRun "E"; $fakeE = New-TestStageInvoker $runE "cleanup"
    [void](Invoke-PersistentRunWorkflow $runE.Context $runE.State $runE.GetFingerprint $fakeE.Callback)
    $resumedE = Resume-TestRun $runE
    $resumedE = Invoke-PersistentRunWorkflow $runE.Context $resumedE $runE.GetFingerprint $fakeE.Callback
    Check ($resumedE.Status -eq "completed" -and
        @($fakeE.Control.Calls | Where-Object { $_ -eq "cleanup" }).Count -eq 2) `
        "Scenario E Cleanup interruption reruns Cleanup"

    # F/G: any non-Agent workspace fingerprint change rejects Resume.
    $runF = New-TestRun "F"; $runF.Fingerprint.Hash = Get-Sha256HexFromText "tracked change"
    Expect-Failure { Resume-TestRun $runF } "WORKSPACE_CHANGED" `
        "Scenario F tracked workspace modification rejected"
    $runG = New-TestRun "G"; $runG.Fingerprint.Hash = Get-Sha256HexFromText "untracked addition"
    Expect-Failure { Resume-TestRun $runG } "WORKSPACE_CHANGED" `
        "Scenario G untracked workspace addition rejected"

    # H/I: Task and Config hashes are immutable.
    $runH = New-TestRun "H"; $taskOriginal = [System.IO.File]::ReadAllText($script:TaskPath)
    [System.IO.File]::WriteAllText($script:TaskPath, "task changed")
    Expect-Failure { Resume-TestRun $runH } "TASK_CHANGED" "Scenario H Task change rejected"
    [System.IO.File]::WriteAllText($script:TaskPath, $taskOriginal)
    $runI = New-TestRun "I"; $configOriginal = [System.IO.File]::ReadAllText($script:ConfigPath)
    [System.IO.File]::WriteAllText($script:ConfigPath, "@{ Changed = `$true }")
    Expect-Failure { Resume-TestRun $runI } "CONFIG_CHANGED" "Scenario I Config change rejected"
    [System.IO.File]::WriteAllText($script:ConfigPath, $configOriginal)

    # J: branch and HEAD mismatches are independently rejected.
    $runJ1 = New-TestRun "J1"; $runJ1.Fingerprint.Branch = "other-branch"
    Expect-Failure { Resume-TestRun $runJ1 } "BRANCH_CHANGED" `
        "Scenario J branch change rejected"
    $runJ2 = New-TestRun "J2"; $runJ2.Fingerprint.Head = "other-head"
    Expect-Failure { Resume-TestRun $runJ2 } "HEAD_CHANGED" `
        "Scenario J HEAD change rejected"

    # K: malformed State is rejected.
    $runK = New-TestRun "K"
    [System.IO.File]::WriteAllText($runK.Context.StatePath, "{ bad")
    Expect-Failure { Resume-TestRun $runK } "not valid JSON" `
        "Scenario K malformed State rejected"

    # L: corrupted trajectory Sequence is rejected.
    $runL = New-TestRun "L"
    [System.IO.File]::AppendAllText($runL.Context.TrajectoryPath, "{}`n")
    Expect-Failure { Resume-TestRun $runL } "missing required field" `
        "Scenario L corrupted Trajectory rejected"

    # M: frozen exhausted budget cannot be reset by Resume.
    $runM = New-TestRun "M"
    $runM.State.Counters.DeveloperAttempts = $runM.State.EffectiveLimits.MaxAttempts
    Write-RunStateAtomic $runM.State $runM.Context.StatePath $projectRoot
    $resumedM = Resume-TestRun $runM
    $fakeM = New-TestStageInvoker $runM $null
    $resumedM = Invoke-PersistentRunWorkflow `
        $runM.Context $resumedM $runM.GetFingerprint $fakeM.Callback
    Check ($resumedM.Status -eq "failed" -and
        (@($fakeM.Control.Calls | Where-Object { $_ -in @("development", "repair") }).Count -eq 0) -and
        $resumedM.Failure.Kind -eq "BUDGET_EXHAUSTED") `
        "Scenario M exhausted MaxAttempts gains no attempt"

    # N: terminal completed Run cannot Resume.
    Expect-Failure { Resume-TestRun $runA } "RUN_ALREADY_COMPLETED" `
        "Scenario N completed Run rejected"

    # Gate regression: changes_requested must repair, re-validate, and re-review.
    $runGate = New-TestRun "gate"
    $gateControl = @{ Reviews = 0; Stages = @() }
    $gateCallback = {
        param($context)
        $gateControl.Stages += [string]$context.Stage
        if ($context.Stage -in @("development", "repair")) {
            return [PSCustomObject]@{Succeeded=$true;Message="ok";Artifacts=[PSCustomObject]@{}}
        }
        if ($context.Stage -eq "validation") {
            return [PSCustomObject]@{Passed=$true;Message="pass";Artifacts=[PSCustomObject]@{}}
        }
        if ($context.Stage -eq "review") {
            $gateControl.Reviews++
            $verdict = $(if($gateControl.Reviews -eq 1){"changes_requested"}else{"approved"})
            return [PSCustomObject]@{
                TechnicalSucceeded=$true;Fatal=$false;Verdict=$verdict
                Message=$verdict;Artifacts=[PSCustomObject]@{}
            }
        }
        return [PSCustomObject]@{Passed=$true;Message="cleanup";Artifacts=[PSCustomObject]@{}}
    }.GetNewClosure()
    $gateState = Invoke-PersistentRunWorkflow `
        $runGate.Context $runGate.State $runGate.GetFingerprint $gateCallback
    Check ($gateState.Status -eq "completed" -and
        $gateState.Counters.ReviewCycles -eq 1 -and
        (($gateControl.Stages -join ",") -eq
        "development,validation,review,repair,validation,review,cleanup")) `
        "Review repair enforces re-Validation and re-Review"

    # MaxReviewCycles counts permitted repair cycles without an off-by-one loss.
    $runCycles = New-TestRun "review-cycles"
    $runCycles.State.EffectiveLimits.MaxAttempts = 3
    $runCycles.State.EffectiveLimits.MaxReviewCycles = 2
    $cycleControl = @{ Reviews = 0; Stages = @() }
    $cycleCallback = {
        param($context)
        $cycleControl.Stages += [string]$context.Stage
        if ($context.Stage -in @("development", "repair")) {
            return [PSCustomObject]@{Succeeded=$true;Message="ok";Artifacts=[PSCustomObject]@{}}
        }
        if ($context.Stage -eq "validation") {
            return [PSCustomObject]@{Passed=$true;Message="pass";Artifacts=[PSCustomObject]@{}}
        }
        if ($context.Stage -eq "review") {
            $cycleControl.Reviews++
            return [PSCustomObject]@{
                TechnicalSucceeded=$true;Fatal=$false;Verdict="changes_requested"
                Message="changes_requested";Artifacts=[PSCustomObject]@{}
            }
        }
        return [PSCustomObject]@{Passed=$true;Message="cleanup";Artifacts=[PSCustomObject]@{}}
    }.GetNewClosure()
    $cycleState = Invoke-PersistentRunWorkflow `
        $runCycles.Context $runCycles.State $runCycles.GetFingerprint $cycleCallback
    Check ($cycleState.Status -eq "failed" -and
        $cycleState.Failure.Kind -eq "REVIEW_CYCLES_EXHAUSTED" -and
        $cycleState.Counters.ReviewCycles -eq 2 -and
        (@($cycleControl.Stages | Where-Object { $_ -eq "repair" }).Count -eq 2)) `
        "MaxReviewCycles permits the configured number of repairs"

    # Reviewer technical failure retries Reviewer and does not repair code.
    $runTech = New-TestRun "technical"
    $techControl = @{ Reviews = 0; Developers = 0 }
    $techCallback = {
        param($context)
        if ($context.Stage -in @("development", "repair")) {
            $techControl.Developers++; return [PSCustomObject]@{Succeeded=$true;Message="ok";Artifacts=[PSCustomObject]@{}}
        }
        if ($context.Stage -eq "validation") {
            return [PSCustomObject]@{Passed=$true;Message="pass";Artifacts=[PSCustomObject]@{}}
        }
        if ($context.Stage -eq "review") {
            $techControl.Reviews++
            if($techControl.Reviews -eq 1){return [PSCustomObject]@{
                TechnicalSucceeded=$false;Fatal=$false;Verdict=$null
                Message="technical";Artifacts=[PSCustomObject]@{}
            }}
            return [PSCustomObject]@{TechnicalSucceeded=$true;Fatal=$false;Verdict="approved";Message="approved";Artifacts=[PSCustomObject]@{}}
        }
        return [PSCustomObject]@{Passed=$true;Message="cleanup";Artifacts=[PSCustomObject]@{}}
    }.GetNewClosure()
    $techState = Invoke-PersistentRunWorkflow `
        $runTech.Context $runTech.State $runTech.GetFingerprint $techCallback
    Check ($techState.Status -eq "completed" -and $techControl.Reviews -eq 2 -and
        $techControl.Developers -eq 1) `
        "Reviewer technical retry does not trigger Developer repair"

    # Illegal transitions cannot bypass quality Gates or restart terminal Runs.
    $runIllegalReview = New-TestRun "illegal-review"
    $runIllegalReview.State.Workflow.NextAction = "review"
    Expect-Failure {
        Assert-PersistentNextActionAllowed $runIllegalReview.State
    } "Review requires Validation PASSED" `
        "Illegal transition development to Review rejected"

    $runIllegalChanges = New-TestRun "illegal-changes"
    $runIllegalChanges.State.Gates.Validation = "PASSED"
    $runIllegalChanges.State.Gates.Review = "CHANGES_REQUESTED"
    $runIllegalChanges.State.Workflow.NextAction = "review"
    Expect-Failure {
        Assert-PersistentNextActionAllowed $runIllegalChanges.State
    } "Review Gate requires Repair" `
        "Illegal transition Changes Requested directly to Review rejected"

    $runIllegalTerminal = New-TestRun "illegal-terminal"
    $runIllegalTerminal.State.Status = "completed"
    $runIllegalTerminal.State.Workflow.NextAction = "development"
    Expect-Failure {
        Assert-PersistentNextActionAllowed $runIllegalTerminal.State
    } "terminal Run status cannot transition" `
        "Illegal transition completed to Development rejected"

    Write-Output ("PERSISTENT RUN SCENARIOS PASSED: " + $script:Passed)
}
finally {
    $full = [System.IO.Path]::GetFullPath($temporaryDirectory)
    if (-not $full.StartsWith([System.IO.Path]::GetFullPath($PSScriptRoot) + "\")) {
        throw "Unsafe persistent test cleanup path."
    }
    if (Test-Path $full) { Remove-Item -LiteralPath $full -Recurse }
}
