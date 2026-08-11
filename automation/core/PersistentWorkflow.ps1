Set-StrictMode -Version 2.0

function Get-PersistentStageActor {
    param([string]$Stage)
    switch ($Stage) {
        "development" { return "developer" }
        "repair" { return "developer" }
        "validation" { return "validation" }
        "review" { return "reviewer" }
        "cleanup" { return "cleanup" }
        default { return "core" }
    }
}

function Get-PersistentSpecificEventType {
    param([string]$Stage, [bool]$Started)
    $suffix = $(if ($Started) { "started" } else { "completed" })
    switch ($Stage) {
        "development" { return ("agent_attempt_" + $suffix) }
        "repair" { return ("agent_attempt_" + $suffix) }
        "validation" { return ("validation_" + $suffix) }
        "review" { return ("review_" + $suffix) }
        "cleanup" { return ("cleanup_" + $suffix) }
        default { return ("stage_" + $suffix) }
    }
}

function Get-PersistentFingerprintHash {
    param([scriptblock]$GetWorkspaceFingerprint)
    $value = & $GetWorkspaceFingerprint
    if ($value -is [string]) { return [string]$value }
    if ($null -eq $value -or
        -not ($value.PSObject.Properties.Name -contains "Hash")) {
        throw "Workspace Fingerprint callback did not return Hash."
    }
    return [string]$value.Hash
}

function Assert-PersistentNextActionAllowed {
    param([Parameter(Mandatory = $true)][object]$State)

    if ([string]$State.Status -in @("completed", "failed")) {
        throw ("INVALID_TRANSITION: terminal Run status cannot transition: " +
            [string]$State.Status)
    }

    $action = [string]$State.Workflow.NextAction
    switch ($action) {
        "development" { return $true }
        "validation" {
            if ([int]$State.Counters.DeveloperAttempts -le 0) {
                throw "INVALID_TRANSITION: Validation requires a Developer attempt."
            }
            return $true
        }
        "review" {
            if ([string]$State.Gates.Validation -ne "PASSED") {
                throw "INVALID_TRANSITION: Review requires Validation PASSED."
            }
            if ([string]$State.Gates.Review -in @(
                "CHANGES_REQUESTED", "PASSED", "DISABLED"
            )) {
                throw "INVALID_TRANSITION: Review Gate requires Repair or is terminal."
            }
            return $true
        }
        "repair" {
            $valid = (
                ([string]$State.Workflow.RepairKind -eq "validation" -and
                [string]$State.Gates.Validation -eq "FAILED") -or
                ([string]$State.Workflow.RepairKind -eq "review" -and
                [string]$State.Gates.Review -eq "CHANGES_REQUESTED")
            )
            if (-not $valid) {
                throw "INVALID_TRANSITION: Repair requires a failed Gate request."
            }
            return $true
        }
        "cleanup" {
            if ([string]$State.Workflow.TerminalIntent -eq "failed") {
                return $true
            }
            if ([string]$State.Gates.Validation -ne "PASSED" -or
                [string]$State.Gates.Review -notin @("PASSED", "DISABLED")) {
                throw "INVALID_TRANSITION: Cleanup requires Validation and Review Gates."
            }
            return $true
        }
        "complete" {
            if ([string]$State.Gates.Validation -ne "PASSED" -or
                [string]$State.Gates.Review -notin @("PASSED", "DISABLED") -or
                [string]$State.Gates.Cleanup -notin @("PASSED", "DISABLED")) {
                throw "INVALID_TRANSITION: completion requires every enabled Gate."
            }
            return $true
        }
        default { throw ("INVALID_TRANSITION: unsupported action " + $action) }
    }
}

function Add-PersistentCheckpoint {
    param(
        [hashtable]$RunContext,
        [object]$State,
        [string]$EventType,
        [string]$Stage,
        [AllowNull()][string]$Outcome = $null,
        [AllowNull()][string]$ActorRole = $null,
        [AllowNull()][object]$Attempt = $null,
        [AllowNull()][object]$Artifacts = $null,
        [AllowNull()][string]$Message = $null,
        [AllowNull()][object]$Runtime = $null,
        [AllowNull()][object]$RequestedModel = $null,
        [AllowNull()][object]$ResolvedModel = $null,
        [AllowNull()][object]$DurationMs = $null,
        [AllowNull()][string]$GateResult = $null,
        [AllowNull()][object]$FindingCount = $null,
        [AllowNull()][string]$FailureKind = $null
    )

    return Write-RunCheckpoint `
        -State $State `
        -ProjectRoot $RunContext.ProjectRoot `
        -RunDirectory $RunContext.RunDirectory `
        -StatePath $RunContext.StatePath `
        -TrajectoryPath $RunContext.TrajectoryPath `
        -EventType $EventType `
        -Stage $Stage `
        -Outcome $Outcome `
        -ActorRole $ActorRole `
        -Attempt $Attempt `
        -Artifacts $Artifacts `
        -Message $Message `
        -Runtime $Runtime `
        -RequestedModel $RequestedModel `
        -ResolvedModel $ResolvedModel `
        -DurationMs $DurationMs `
        -GateResult $GateResult `
        -FindingCount $FindingCount `
        -FailureKind $FailureKind
}

function Initialize-PersistentRun {
    param([hashtable]$RunContext, [object]$State)

    Write-RunStateAtomic $State $RunContext.StatePath $RunContext.ProjectRoot
    [void](Add-PersistentCheckpoint `
        -RunContext $RunContext `
        -State $State `
        -EventType "run_created" `
        -Stage "initializing" `
        -Outcome "created" `
        -ActorRole "core" `
        -Message "Persistent Run was created.")
    $State.Status = "running"
    [void](Add-PersistentCheckpoint `
        -RunContext $RunContext `
        -State $State `
        -EventType "run_started" `
        -Stage "initializing" `
        -Outcome "running" `
        -ActorRole "core" `
        -Message "Persistent Run started.")
    [void](Add-PersistentCheckpoint `
        -RunContext $RunContext `
        -State $State `
        -EventType "checkpoint_written" `
        -Stage "initializing" `
        -Outcome "persisted" `
        -ActorRole "core" `
        -Message "Initial Run checkpoint was persisted.")
    return $State
}

function Open-PersistentRunForResume {
    param(
        [hashtable]$RunContext,
        [string]$ExpectedRunId,
        [string]$ExpectedProjectName,
        [string]$ConfigPath,
        [scriptblock]$GetWorkspaceFingerprint
    )

    $state = Read-RunStateJson $RunContext.StatePath "Run State"
    [void](Assert-RunStateContract $state $RunContext.ProjectRoot $ExpectedRunId)
    [void](Assert-RunTrajectoryStateConsistency `
        $state $RunContext.TrajectoryPath $RunContext.RunDirectory)
    if ([string]$state.Status -eq "completed") {
        throw "RUN_ALREADY_COMPLETED: completed Runs cannot be resumed."
    }
    if ([string]$state.Status -eq "failed") {
        throw "RUN_ALREADY_FAILED: terminal failed Runs cannot be resumed."
    }
    if ([string]$state.ProjectName -ne $ExpectedProjectName) {
        throw "PROJECT_CHANGED: ProjectName does not match the Run State."
    }

    $taskPath = Resolve-RunStateProjectPath `
        $RunContext.ProjectRoot ([string]$state.Task.Path) "Run State Task.Path"
    $savedConfigPath = Resolve-RunStateProjectPath `
        $RunContext.ProjectRoot ([string]$state.Config.Path) "Run State Config.Path"
    $actualConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
    if (-not [string]::Equals(
        $savedConfigPath,
        $actualConfigPath,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or (Get-RunFileSha256 $savedConfigPath) -ne [string]$state.Config.Sha256) {
        throw "CONFIG_CHANGED: Project Config differs from the Run baseline."
    }
    if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf) -or
        (Get-RunFileSha256 $taskPath) -ne [string]$state.Task.Sha256) {
        throw "TASK_CHANGED: TaskFile differs from the Run baseline."
    }

    $fingerprint = & $GetWorkspaceFingerprint
    if ([string]$fingerprint.Branch -ne [string]$state.Git.InitialBranch) {
        throw "BRANCH_CHANGED: current branch differs from the Run baseline."
    }
    if ([string]$fingerprint.Head -ne [string]$state.Git.InitialHead) {
        throw "HEAD_CHANGED: current HEAD differs from the Run baseline."
    }
    $workspaceChanged = ([string]$fingerprint.Hash -ne
        [string]$state.Git.CurrentWorkspaceFingerprint)
    $pendingStage = $null
    if ($null -ne $state.PendingStage) {
        $pendingStage = [string]$state.PendingStage.Stage
    }
    $partialAgentAllowed = $workspaceChanged -and
        $pendingStage -in @("development", "repair")
    if ($workspaceChanged -and -not $partialAgentAllowed) {
        throw "WORKSPACE_CHANGED: workspace fingerprint differs from the checkpoint."
    }

    if ($null -ne $state.PendingStage) {
        $state.Status = "interrupted"
        $state.Workflow.InterruptedStage = $pendingStage
        $state.Workflow.InterruptedWorkspaceChanged = [bool]$workspaceChanged
        if ($workspaceChanged) {
            $state.Git.CurrentWorkspaceFingerprint = [string]$fingerprint.Hash
        }
        $attempt = $state.PendingStage.Attempt
        $state.PendingStage = $null
        [void](Add-PersistentCheckpoint `
            -RunContext $RunContext `
            -State $state `
            -EventType "stage_interrupted" `
            -Stage $pendingStage `
            -Outcome "interrupted" `
            -ActorRole (Get-PersistentStageActor $pendingStage) `
            -Attempt $attempt `
            -Message "An incomplete external stage was detected during Resume.")
    }
    else {
        $state.Workflow.InterruptedStage = $null
        $state.Workflow.InterruptedWorkspaceChanged = $false
    }

    $state.Workflow.ResumeCount = [int]$state.Workflow.ResumeCount + 1
    $state.Status = "running"
    [void](Assert-PersistentNextActionAllowed $state)
    [void](Add-PersistentCheckpoint `
        -RunContext $RunContext `
        -State $state `
        -EventType "run_resumed" `
        -Stage ([string]$state.CurrentStage) `
        -Outcome "running" `
        -ActorRole "core" `
        -Message "Persistent Run resumed without resetting counters or limits.")
    return $state
}

function Set-PersistentRunFailed {
    param(
        [hashtable]$RunContext,
        [object]$State,
        [string]$Kind,
        [string]$Message
    )

    $State.PendingStage = $null
    $State.Failure = [PSCustomObject][ordered]@{
        Kind = $Kind
        Message = $Message
        Terminal = $true
    }
    if ([string]$State.Gates.Cleanup -eq "NOT_RUN" -and
        [string]$State.CurrentStage -ne "cleanup") {
        $State.Status = "running"
        $State.Workflow.TerminalIntent = "failed"
        $State.Workflow.NextAction = "cleanup"
        [void](Add-PersistentCheckpoint `
            -RunContext $RunContext `
            -State $State `
            -EventType "run_failure_pending_cleanup" `
            -Stage ([string]$State.CurrentStage) `
            -Outcome "failed" `
            -ActorRole "core" `
            -Message $Message `
            -FailureKind $Kind)
        if ($RunContext.ContainsKey("GetWorkspaceFingerprint") -and
            $RunContext.ContainsKey("InvokeExternalStage")) {
            return Invoke-PersistentRunWorkflow `
                $RunContext `
                $State `
                $RunContext.GetWorkspaceFingerprint `
                $RunContext.InvokeExternalStage
        }
        return $State
    }
    $State.Status = "failed"
    $State.Workflow.TerminalIntent = "failed"
    [void](Add-PersistentCheckpoint `
        -RunContext $RunContext `
        -State $State `
        -EventType "run_failed" `
        -Stage ([string]$State.CurrentStage) `
        -Outcome "failed" `
        -ActorRole "core" `
        -Message $Message `
        -FailureKind $Kind)
    return $State
}

function Start-PersistentExternalStage {
    param(
        [hashtable]$RunContext,
        [object]$State,
        [string]$Stage,
        [string]$Action,
        [AllowNull()][object]$Attempt,
        [scriptblock]$GetWorkspaceFingerprint
    )

    $fingerprint = Get-PersistentFingerprintHash $GetWorkspaceFingerprint
    $State.Git.CurrentWorkspaceFingerprint = $fingerprint
    $State.Status = "running"
    $State.CurrentStage = $Stage
    $State.PendingStage = [PSCustomObject][ordered]@{
        Stage = $Stage
        Action = $Action
        StartedSequence = [int64]$State.LastCheckpoint.Sequence + 2
        StartWorkspaceFingerprint = $fingerprint
        Attempt = $Attempt
    }
    [void](Add-PersistentCheckpoint `
        -RunContext $RunContext `
        -State $State `
        -EventType (Get-PersistentSpecificEventType $Stage $true) `
        -Stage $Stage `
        -Outcome "started" `
        -ActorRole (Get-PersistentStageActor $Stage) `
        -Attempt $Attempt `
        -Message ("External invocation prepared: " + $Action))
    [void](Add-PersistentCheckpoint `
        -RunContext $RunContext `
        -State $State `
        -EventType "stage_started" `
        -Stage $Stage `
        -Outcome "started" `
        -ActorRole (Get-PersistentStageActor $Stage) `
        -Attempt $Attempt `
        -Message ("External stage started: " + $Action))
}

function Complete-PersistentExternalStage {
    param(
        [hashtable]$RunContext,
        [object]$State,
        [string]$Stage,
        [AllowNull()][object]$Attempt,
        [bool]$Succeeded,
        [object]$Result,
        [scriptblock]$GetWorkspaceFingerprint
    )

    $State.Git.CurrentWorkspaceFingerprint = Get-PersistentFingerprintHash $GetWorkspaceFingerprint
    $State.PendingStage = $null
    $outcome = $(if ($Succeeded) { "completed" } else { "failed" })
    $artifacts = $null
    if ($null -ne $Result -and
        $Result.PSObject.Properties.Name -contains "Artifacts") {
        $artifacts = $Result.Artifacts
    }
    $message = $null
    if ($null -ne $Result -and
        $Result.PSObject.Properties.Name -contains "Message") {
        $message = [string]$Result.Message
    }
    $duration = $null
    if ($null -ne $Result -and
        $Result.PSObject.Properties.Name -contains "DurationMs") {
        $duration = $Result.DurationMs
    }
    $runtime = $null
    $requestedModel = $null
    $resolvedModel = $null
    $findingCount = $null
    if ($null -ne $Result) {
        if ($Result.PSObject.Properties.Name -contains "Runtime") {
            $runtime = $Result.Runtime
        }
        if ($Result.PSObject.Properties.Name -contains "RequestedModel") {
            $requestedModel = $Result.RequestedModel
        }
        if ($Result.PSObject.Properties.Name -contains "ResolvedModel") {
            $resolvedModel = $Result.ResolvedModel
        }
        if ($Result.PSObject.Properties.Name -contains "FindingCount") {
            $findingCount = $Result.FindingCount
        }
    }
    $eventType = $(if ($Stage -in @("validation", "cleanup")) {
        Get-PersistentSpecificEventType $Stage $false
    } elseif ($Succeeded) {
        Get-PersistentSpecificEventType $Stage $false
    } elseif ($Stage -in @("development", "repair", "review")) {
        "agent_attempt_failed"
    } else { "stage_failed" })
    [void](Add-PersistentCheckpoint `
        -RunContext $RunContext `
        -State $State `
        -EventType $eventType `
        -Stage $Stage `
        -Outcome $outcome `
        -ActorRole (Get-PersistentStageActor $Stage) `
        -Attempt $Attempt `
        -Artifacts $artifacts `
        -Message $message `
        -Runtime $runtime `
        -RequestedModel $requestedModel `
        -ResolvedModel $resolvedModel `
        -DurationMs $duration `
        -FindingCount $findingCount)
    [void](Add-PersistentCheckpoint `
        -RunContext $RunContext `
        -State $State `
        -EventType $(if ($Succeeded) { "stage_completed" } else { "stage_failed" }) `
        -Stage $Stage `
        -Outcome $outcome `
        -ActorRole (Get-PersistentStageActor $Stage) `
        -Attempt $Attempt `
        -Artifacts $artifacts `
        -Message $message `
        -Runtime $runtime `
        -RequestedModel $requestedModel `
        -ResolvedModel $resolvedModel `
        -DurationMs $duration `
        -FindingCount $findingCount)
}

function Add-PersistentGateEvent {
    param(
        [hashtable]$RunContext,
        [object]$State,
        [string]$Stage,
        [string]$GateResult,
        [AllowNull()][string]$Message = $null
    )
    [void](Add-PersistentCheckpoint `
        -RunContext $RunContext `
        -State $State `
        -EventType "gate_changed" `
        -Stage $Stage `
        -Outcome "changed" `
        -ActorRole "core" `
        -GateResult $GateResult `
        -Message $Message)
}

function Save-PersistentWorkflowPosition {
    param(
        [hashtable]$RunContext,
        [object]$State,
        [string]$Message
    )
    [void](Add-PersistentCheckpoint `
        -RunContext $RunContext `
        -State $State `
        -EventType "checkpoint_written" `
        -Stage ([string]$State.CurrentStage) `
        -Outcome "persisted" `
        -ActorRole "core" `
        -Message $Message)
}

function Invoke-PersistentRunWorkflow {
    param(
        [hashtable]$RunContext,
        [object]$State,
        [scriptblock]$GetWorkspaceFingerprint,
        [scriptblock]$InvokeExternalStage
    )

    $RunContext.GetWorkspaceFingerprint = $GetWorkspaceFingerprint
    $RunContext.InvokeExternalStage = $InvokeExternalStage
    while ([string]$State.Status -eq "running") {
        $action = [string]$State.Workflow.NextAction
        try { [void](Assert-PersistentNextActionAllowed $State) }
        catch {
            return Set-PersistentRunFailed `
                $RunContext $State "INVALID_TRANSITION" $_.Exception.Message
        }
        if ($action -in @("development", "repair")) {
            if ([int]$State.Counters.DeveloperAttempts -ge
                [int]$State.EffectiveLimits.MaxAttempts) {
                return Set-PersistentRunFailed $RunContext $State `
                    "BUDGET_EXHAUSTED" "Maximum Developer attempts were exhausted."
            }
            $stage = $action
            $State.Counters.DeveloperAttempts =
                [int]$State.Counters.DeveloperAttempts + 1
            $attempt = [int]$State.Counters.DeveloperAttempts
            $State.Gates.Validation = "NOT_RUN"
            if ([string]$State.Gates.Review -ne "DISABLED") {
                $State.Gates.Review = "NOT_RUN"
            }
            $interruptedStage = $State.Workflow.InterruptedStage
            $interruptedChanged = $State.Workflow.InterruptedWorkspaceChanged
            Start-PersistentExternalStage `
                $RunContext $State $stage $action $attempt $GetWorkspaceFingerprint
            $context = [PSCustomObject]@{
                Stage = $stage
                Action = $action
                RepairKind = $State.Workflow.RepairKind
                Attempt = $attempt
                ReviewCycle = [int]$State.Counters.ReviewCycles
                ReviewSequence = [int]$State.Workflow.ReviewSequence
                ReviewerTechnicalAttempt = $null
                LastValidationArtifact = $State.Workflow.LastValidationArtifact
                LastReviewArtifact = $State.Workflow.LastReviewArtifact
                InterruptedStage = $interruptedStage
                InterruptedWorkspaceChanged = [bool]$interruptedChanged
            }
            try { $result = & $InvokeExternalStage $context }
            catch {
                Complete-PersistentExternalStage `
                    $RunContext $State $stage $attempt $false `
                    ([PSCustomObject]@{ Message = $_.Exception.Message }) `
                    $GetWorkspaceFingerprint
                return Set-PersistentRunFailed `
                    $RunContext $State "STAGE_EXCEPTION" $_.Exception.Message
            }
            if ($null -ne $result -and
                $result.PSObject.Properties.Name -contains "SimulatedInterrupt" -and
                [bool]$result.SimulatedInterrupt) {
                return $State
            }
            $succeeded = [bool]$result.Succeeded
            $State.Workflow.InterruptedStage = $null
            $State.Workflow.InterruptedWorkspaceChanged = $false
            if ($succeeded) {
                $State.Workflow.NextAction = "validation"
            }
            Complete-PersistentExternalStage `
                $RunContext $State $stage $attempt $succeeded $result `
                $GetWorkspaceFingerprint
            if ($succeeded) {
                Save-PersistentWorkflowPosition `
                    $RunContext $State "Next workflow action: validation."
            }
            elseif ([int]$State.Counters.DeveloperAttempts -ge
                [int]$State.EffectiveLimits.MaxAttempts) {
                return Set-PersistentRunFailed $RunContext $State `
                    "BUDGET_EXHAUSTED" ([string]$result.Message)
            }
            continue
        }

        if ($action -eq "validation") {
            $State.Counters.ValidationAttempts =
                [int]$State.Counters.ValidationAttempts + 1
            $attempt = [int]$State.Counters.ValidationAttempts
            $interruptedStage = $State.Workflow.InterruptedStage
            Start-PersistentExternalStage `
                $RunContext $State "validation" "validation" $attempt `
                $GetWorkspaceFingerprint
            $context = [PSCustomObject]@{
                Stage = "validation"; Action = "validation"; Attempt = $attempt
                InterruptedStage = $interruptedStage
                LastValidationArtifact = $State.Workflow.LastValidationArtifact
                LastReviewArtifact = $State.Workflow.LastReviewArtifact
            }
            try { $result = & $InvokeExternalStage $context }
            catch {
                Complete-PersistentExternalStage $RunContext $State "validation" `
                    $attempt $false ([PSCustomObject]@{ Message = $_.Exception.Message }) `
                    $GetWorkspaceFingerprint
                return Set-PersistentRunFailed `
                    $RunContext $State "STAGE_EXCEPTION" $_.Exception.Message
            }
            if ($result.PSObject.Properties.Name -contains "SimulatedInterrupt" -and
                [bool]$result.SimulatedInterrupt) { return $State }
            $passed = [bool]$result.Passed
            $State.Workflow.InterruptedStage = $null
            if ($result.PSObject.Properties.Name -contains "ArtifactPath") {
                $State.Workflow.LastValidationArtifact = $result.ArtifactPath
            }
            if ($passed) {
                $State.Gates.Validation = "PASSED"
                if ([string]$State.Gates.Review -eq "DISABLED") {
                    $State.Workflow.NextAction = "cleanup"
                }
                else {
                    $State.Workflow.ReviewSequence =
                        [int]$State.Workflow.ReviewSequence + 1
                    $State.Workflow.ReviewerTechnicalAttemptsInCycle = 0
                    $State.Workflow.NextAction = "review"
                }
            }
            else {
                $State.Gates.Validation = "FAILED"
                if ([int]$State.Counters.DeveloperAttempts -lt
                    [int]$State.EffectiveLimits.MaxAttempts) {
                    $State.Workflow.NextAction = "repair"
                    $State.Workflow.RepairKind = "validation"
                }
            }
            Complete-PersistentExternalStage `
                $RunContext $State "validation" $attempt $passed $result `
                $GetWorkspaceFingerprint
            if ($passed) {
                Add-PersistentGateEvent $RunContext $State "validation" "PASSED"
                Save-PersistentWorkflowPosition `
                    $RunContext $State ("Next workflow action: " + $State.Workflow.NextAction)
            }
            else {
                Add-PersistentGateEvent $RunContext $State "validation" "FAILED" `
                    ([string]$result.Message)
                if ([int]$State.Counters.DeveloperAttempts -ge
                    [int]$State.EffectiveLimits.MaxAttempts) {
                    return Set-PersistentRunFailed $RunContext $State `
                        "BUDGET_EXHAUSTED" ([string]$result.Message)
                }
                [void](Add-PersistentCheckpoint $RunContext $State `
                    "repair_requested" "repair" "requested" "core" $null $null `
                    "Validation requested Developer repair.")
            }
            continue
        }

        if ($action -eq "review") {
            if ([int]$State.Workflow.ReviewerTechnicalAttemptsInCycle -ge
                [int]$State.EffectiveLimits.MaxReviewerAttempts) {
                return Set-PersistentRunFailed $RunContext $State `
                    "REVIEWER_BUDGET_EXHAUSTED" "Maximum Reviewer technical attempts were exhausted."
            }
            $State.Counters.ReviewerAttempts =
                [int]$State.Counters.ReviewerAttempts + 1
            $State.Workflow.ReviewerTechnicalAttemptsInCycle =
                [int]$State.Workflow.ReviewerTechnicalAttemptsInCycle + 1
            $attempt = [int]$State.Counters.ReviewerAttempts
            $technicalAttempt = [int]$State.Workflow.ReviewerTechnicalAttemptsInCycle
            $interruptedStage = $State.Workflow.InterruptedStage
            Start-PersistentExternalStage `
                $RunContext $State "review" "review" $attempt $GetWorkspaceFingerprint
            $context = [PSCustomObject]@{
                Stage = "review"; Action = "review"; Attempt = $attempt
                ReviewSequence = [int]$State.Workflow.ReviewSequence
                ReviewerTechnicalAttempt = $technicalAttempt
                LastValidationArtifact = $State.Workflow.LastValidationArtifact
                LastReviewArtifact = $State.Workflow.LastReviewArtifact
                InterruptedStage = $interruptedStage
            }
            try { $result = & $InvokeExternalStage $context }
            catch {
                Complete-PersistentExternalStage $RunContext $State "review" `
                    $attempt $false ([PSCustomObject]@{ Message = $_.Exception.Message }) `
                    $GetWorkspaceFingerprint
                return Set-PersistentRunFailed `
                    $RunContext $State "STAGE_EXCEPTION" $_.Exception.Message
            }
            if ($result.PSObject.Properties.Name -contains "SimulatedInterrupt" -and
                [bool]$result.SimulatedInterrupt) { return $State }
            $technicalSucceeded = [bool]$result.TechnicalSucceeded
            $State.Workflow.InterruptedStage = $null
            if (-not $technicalSucceeded) {
                $State.Gates.Review = "FAILED"
                $State.Workflow.NextAction = "review"
            }
            else {
                if ($result.PSObject.Properties.Name -contains "ArtifactPath") {
                    $State.Workflow.LastReviewArtifact = $result.ArtifactPath
                }
                if ([string]$result.Verdict -eq "approved") {
                    $State.Gates.Review = "PASSED"
                    $State.Workflow.NextAction = "cleanup"
                }
                elseif ([string]$result.Verdict -eq "changes_requested") {
                    $State.Gates.Review = "CHANGES_REQUESTED"
                    if ([int]$State.Counters.ReviewCycles -lt
                        [int]$State.EffectiveLimits.MaxReviewCycles -and
                        [int]$State.Counters.DeveloperAttempts -lt
                        [int]$State.EffectiveLimits.MaxAttempts) {
                        $State.Counters.ReviewCycles =
                            [int]$State.Counters.ReviewCycles + 1
                        $State.Workflow.NextAction = "repair"
                        $State.Workflow.RepairKind = "review"
                    }
                }
            }
            Complete-PersistentExternalStage `
                $RunContext $State "review" $attempt $technicalSucceeded $result `
                $GetWorkspaceFingerprint
            if (-not $technicalSucceeded) {
                Add-PersistentGateEvent $RunContext $State "review" "FAILED" `
                    ([string]$result.Message)
                if ([bool]$result.Fatal) {
                    return Set-PersistentRunFailed $RunContext $State `
                        "REVIEW_FATAL" ([string]$result.Message)
                }
                if ($technicalAttempt -ge [int]$State.EffectiveLimits.MaxReviewerAttempts) {
                    return Set-PersistentRunFailed $RunContext $State `
                        "REVIEWER_BUDGET_EXHAUSTED" ([string]$result.Message)
                }
                continue
            }
            if ([string]$result.Verdict -eq "approved") {
                Add-PersistentGateEvent $RunContext $State "review" "PASSED"
                Save-PersistentWorkflowPosition `
                    $RunContext $State "Next workflow action: cleanup."
                continue
            }
            if ([string]$result.Verdict -eq "changes_requested") {
                Add-PersistentGateEvent $RunContext $State "review" `
                    "CHANGES_REQUESTED" ([string]$result.Message)
                if ([string]$State.Workflow.NextAction -eq "repair") {
                    [void](Add-PersistentCheckpoint $RunContext $State `
                        "repair_requested" "repair" "requested" "core" $null $null `
                        "Review requested Developer repair.")
                    continue
                }
                if ([int]$State.Counters.ReviewCycles -ge
                    [int]$State.EffectiveLimits.MaxReviewCycles) {
                    return Set-PersistentRunFailed $RunContext $State `
                        "REVIEW_CYCLES_EXHAUSTED" "Maximum Review repair cycles were exhausted."
                }
                return Set-PersistentRunFailed $RunContext $State `
                    "BUDGET_EXHAUSTED" "Review requested changes but no Developer attempts remain."
            }
            return Set-PersistentRunFailed $RunContext $State `
                "REVIEW_CONTRACT" "Reviewer returned an unsupported valid verdict."
        }

        if ($action -eq "cleanup") {
            if ([string]$State.Gates.Cleanup -eq "DISABLED") {
                $State.Workflow.NextAction = "complete"
                Save-PersistentWorkflowPosition `
                    $RunContext $State "Cleanup disabled; next action: complete."
                continue
            }
            $interruptedStage = $State.Workflow.InterruptedStage
            Start-PersistentExternalStage `
                $RunContext $State "cleanup" "cleanup" $null $GetWorkspaceFingerprint
            $context = [PSCustomObject]@{
                Stage = "cleanup"; Action = "cleanup"; Attempt = $null
                InterruptedStage = $interruptedStage
            }
            try { $result = & $InvokeExternalStage $context }
            catch {
                Complete-PersistentExternalStage $RunContext $State "cleanup" `
                    $null $false ([PSCustomObject]@{ Message = $_.Exception.Message }) `
                    $GetWorkspaceFingerprint
                return Set-PersistentRunFailed `
                    $RunContext $State "CLEANUP_FAILED" $_.Exception.Message
            }
            if ($result.PSObject.Properties.Name -contains "SimulatedInterrupt" -and
                [bool]$result.SimulatedInterrupt) { return $State }
            $passed = [bool]$result.Passed
            $State.Workflow.InterruptedStage = $null
            if ($passed) {
                $State.Gates.Cleanup = "PASSED"
                if ([string]$State.Workflow.TerminalIntent -ne "failed") {
                    $State.Workflow.NextAction = "complete"
                }
            }
            else {
                $State.Gates.Cleanup = "FAILED"
            }
            Complete-PersistentExternalStage `
                $RunContext $State "cleanup" $null $passed $result `
                $GetWorkspaceFingerprint
            if (-not $passed) {
                Add-PersistentGateEvent $RunContext $State "cleanup" "FAILED" `
                    ([string]$result.Message)
                return Set-PersistentRunFailed $RunContext $State `
                    "CLEANUP_FAILED" ([string]$result.Message)
            }
            Add-PersistentGateEvent $RunContext $State "cleanup" "PASSED"
            if ([string]$State.Workflow.TerminalIntent -eq "failed") {
                $State.Status = "failed"
                $State.PendingStage = $null
                [void](Add-PersistentCheckpoint `
                    -RunContext $RunContext `
                    -State $State `
                    -EventType "run_failed" `
                    -Stage "cleanup" `
                    -Outcome "failed" `
                    -ActorRole "core" `
                    -Message ([string]$State.Failure.Message) `
                    -FailureKind ([string]$State.Failure.Kind))
                return $State
            }
            Save-PersistentWorkflowPosition `
                $RunContext $State "Next workflow action: complete."
            continue
        }

        if ($action -eq "complete") {
            $State.Status = "completed"
            $State.CurrentStage = "complete"
            $State.PendingStage = $null
            $State.Failure = $null
            [void](Add-PersistentCheckpoint $RunContext $State `
                "run_completed" "complete" "completed" "core" $null $null `
                "All enabled quality Gates passed.")
            return $State
        }

        return Set-PersistentRunFailed $RunContext $State `
            "INVALID_TRANSITION" ("Unsupported workflow action: " + $action)
    }
    return $State
}
