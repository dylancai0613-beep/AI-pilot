Set-StrictMode -Version 2.0

function Assert-ReviewGitSnapshotUnchanged {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Before,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$After
    )

    if (-not [string]::Equals(
        $Before,
        $After,
        [System.StringComparison]::Ordinal
    )) {
        throw "Reviewer changed the Git working tree. No recovery was attempted."
    }
    return $true
}

function Invoke-ReviewGateWorkflow {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 5)][int]$MaxDeveloperAttempts,
        [Parameter(Mandatory = $true)][ValidateRange(0, 5)][int]$MaxReviewCycles,
        [Parameter(Mandatory = $true)][ValidateRange(1, 5)][int]$MaxReviewerAttempts,
        [Parameter(Mandatory = $true)][bool]$ReviewerEnabled,
        [Parameter(Mandatory = $true)][scriptblock]$InvokeDeveloper,
        [Parameter(Mandatory = $true)][scriptblock]$InvokeValidation,
        [Parameter(Mandatory = $true)][scriptblock]$InvokeReviewer
    )

    $developerAttempts = 0
    $reviewRepairCycles = 0
    $reviewSequence = 0
    $nextDeveloperAction = "development"
    $latestValidationReport = ""
    $latestReviewResult = $null
    $validationGate = "NOT_RUN"
    if ($ReviewerEnabled) {
        $reviewGate = "NOT_RUN"
    }
    else {
        $reviewGate = "DISABLED"
    }
    $failureReason = ""

    while ($developerAttempts -lt $MaxDeveloperAttempts) {
        $developerAttempts++
        $developerContext = [PSCustomObject]@{
            Action = $nextDeveloperAction
            DeveloperAttempt = $developerAttempts
            ReviewRepairCycle = $reviewRepairCycles
            ValidationReport = $latestValidationReport
            ReviewResult = $latestReviewResult
        }
        $developerResult = & $InvokeDeveloper $developerContext
        if (-not [bool]$developerResult.Succeeded) {
            $failureReason = [string]$developerResult.FailureReason
            continue
        }

        $validationResult = & $InvokeValidation ([PSCustomObject]@{
            DeveloperAttempt = $developerAttempts
            Action = $nextDeveloperAction
        })
        $latestValidationReport = [string]$validationResult.Report
        if (-not [bool]$validationResult.Passed) {
            $validationGate = "FAILED"
            $failureReason = [string]$validationResult.FailureReason
            $nextDeveloperAction = "validation_repair"
            continue
        }
        $validationGate = "PASSED"

        if (-not $ReviewerEnabled) {
            return [PSCustomObject]@{
                Passed = $true
                FailureReason = ""
                DeveloperAttempts = $developerAttempts
                ReviewRepairCycles = $reviewRepairCycles
                ReviewSequences = $reviewSequence
                ValidationGate = $validationGate
                ReviewGate = "DISABLED"
                LastValidationReport = $latestValidationReport
                LastReviewResult = $null
            }
        }

        $reviewSequence++
        $validReviewReceived = $false
        $reviewRequestedRepair = $false
        for ($reviewerAttempt = 1;
            $reviewerAttempt -le $MaxReviewerAttempts;
            $reviewerAttempt++) {
            $reviewerResult = & $InvokeReviewer ([PSCustomObject]@{
                DeveloperAttempt = $developerAttempts
                ReviewSequence = $reviewSequence
                ReviewerTechnicalAttempt = $reviewerAttempt
                ValidationReport = $latestValidationReport
            })

            if (-not [bool]$reviewerResult.TechnicalSucceeded) {
                $reviewGate = "FAILED"
                $failureReason = [string]$reviewerResult.FailureReason
                if ([bool]$reviewerResult.Fatal) {
                    return [PSCustomObject]@{
                        Passed = $false
                        FailureReason = $failureReason
                        DeveloperAttempts = $developerAttempts
                        ReviewRepairCycles = $reviewRepairCycles
                        ReviewSequences = $reviewSequence
                        ValidationGate = $validationGate
                        ReviewGate = $reviewGate
                        LastValidationReport = $latestValidationReport
                        LastReviewResult = $latestReviewResult
                    }
                }
                continue
            }

            $validReviewReceived = $true
            $latestReviewResult = $reviewerResult.ReviewResult
            if ([string]$reviewerResult.Verdict -eq "approved") {
                return [PSCustomObject]@{
                    Passed = $true
                    FailureReason = ""
                    DeveloperAttempts = $developerAttempts
                    ReviewRepairCycles = $reviewRepairCycles
                    ReviewSequences = $reviewSequence
                    ValidationGate = $validationGate
                    ReviewGate = "APPROVED"
                    LastValidationReport = $latestValidationReport
                    LastReviewResult = $latestReviewResult
                }
            }

            if ([string]$reviewerResult.Verdict -eq "changes_requested") {
                if ($reviewRepairCycles -ge $MaxReviewCycles) {
                    return [PSCustomObject]@{
                        Passed = $false
                        FailureReason = "Maximum review repair cycles reached."
                        DeveloperAttempts = $developerAttempts
                        ReviewRepairCycles = $reviewRepairCycles
                        ReviewSequences = $reviewSequence
                        ValidationGate = $validationGate
                        ReviewGate = "CHANGES_REQUESTED"
                        LastValidationReport = $latestValidationReport
                        LastReviewResult = $latestReviewResult
                    }
                }
                $reviewRepairCycles++
                $nextDeveloperAction = "review_repair"
                $reviewGate = "CHANGES_REQUESTED"
                $failureReason = "Review requested code changes."
                $reviewRequestedRepair = $true
                break
            }

            throw "Reviewer callback returned an unsupported valid verdict."
        }

        if ($reviewRequestedRepair) {
            continue
        }
        if (-not $validReviewReceived) {
            return [PSCustomObject]@{
                Passed = $false
                FailureReason = (
                    "Maximum Reviewer technical attempts reached: " +
                    $MaxReviewerAttempts + ". Last error: " + $failureReason
                )
                DeveloperAttempts = $developerAttempts
                ReviewRepairCycles = $reviewRepairCycles
                ReviewSequences = $reviewSequence
                ValidationGate = $validationGate
                ReviewGate = "FAILED"
                LastValidationReport = $latestValidationReport
                LastReviewResult = $latestReviewResult
            }
        }
    }

    return [PSCustomObject]@{
        Passed = $false
        FailureReason = (
            "Maximum Developer Agent attempts reached: " +
            $MaxDeveloperAttempts + ". Last error: " + $failureReason
        )
        DeveloperAttempts = $developerAttempts
        ReviewRepairCycles = $reviewRepairCycles
        ReviewSequences = $reviewSequence
        ValidationGate = $validationGate
        ReviewGate = $reviewGate
        LastValidationReport = $latestValidationReport
        LastReviewResult = $latestReviewResult
    }
}
