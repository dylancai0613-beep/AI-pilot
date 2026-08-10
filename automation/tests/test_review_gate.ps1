[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$gateScript = Join-Path $projectRoot "automation\core\ReviewGate.ps1"
. $gateScript

$script:Passed = 0

function Assert-Test {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Complete-Scenario {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-Test -Condition $Condition -Message ("Scenario failed: " + $Name)
    $script:Passed++
    Write-Output ("PASS: " + $Name)
}

function New-ApprovedReviewerResult {
    return [PSCustomObject]@{
        TechnicalSucceeded = $true
        Fatal = $false
        FailureReason = ""
        Verdict = "approved"
        ReviewResult = [PSCustomObject]@{ Verdict = "approved"; Findings = @() }
    }
}

function New-ChangesReviewerResult {
    return [PSCustomObject]@{
        TechnicalSucceeded = $true
        Fatal = $false
        FailureReason = ""
        Verdict = "changes_requested"
        ReviewResult = [PSCustomObject]@{
            Verdict = "changes_requested"
            Findings = @([PSCustomObject]@{ Blocking = $true })
        }
    }
}

# Scenario A: Development -> Validation PASS -> Review APPROVED.
$state = @{ Developer = 0; Validation = 0; Reviewer = 0 }
$result = Invoke-ReviewGateWorkflow 3 2 2 $true `
    { param($context) $state.Developer++; [PSCustomObject]@{
        Succeeded = $true; FailureReason = ""
    } } `
    { param($context) $state.Validation++; [PSCustomObject]@{
        Passed = $true; Report = "pass"; FailureReason = ""
    } } `
    { param($context) $state.Reviewer++; New-ApprovedReviewerResult }
Complete-Scenario `
    -Name "Scenario A approved first review" `
    -Condition ($result.Passed -and $state.Developer -eq 1 -and
        $state.Validation -eq 1 -and $state.Reviewer -eq 1 -and
        $result.ReviewGate -eq "APPROVED")

# Scenario B: changes requested -> Developer repair -> Validation -> approval.
$state = @{ Actions = @(); Validation = 0; Reviewer = 0 }
$result = Invoke-ReviewGateWorkflow 3 2 2 $true `
    { param($context) $state.Actions += [string]$context.Action; [PSCustomObject]@{
        Succeeded = $true; FailureReason = ""
    } } `
    { param($context) $state.Validation++; [PSCustomObject]@{
        Passed = $true; Report = "pass"; FailureReason = ""
    } } `
    { param($context) $state.Reviewer++; if ($state.Reviewer -eq 1) {
        New-ChangesReviewerResult
      } else { New-ApprovedReviewerResult } }
Complete-Scenario `
    -Name "Scenario B review repair completes full gates" `
    -Condition ($result.Passed -and $state.Validation -eq 2 -and
        $state.Reviewer -eq 2 -and
        (($state.Actions -join ",") -eq "development,review_repair"))

# Scenario C: review repair breaks Validation and MaxDeveloperAttempts stops it.
$state = @{ Actions = @(); Validation = 0; Reviewer = 0 }
$result = Invoke-ReviewGateWorkflow 2 2 2 $true `
    { param($context) $state.Actions += [string]$context.Action; [PSCustomObject]@{
        Succeeded = $true; FailureReason = ""
    } } `
    { param($context) $state.Validation++; if ($state.Validation -eq 1) {
        [PSCustomObject]@{ Passed = $true; Report = "pass"; FailureReason = "" }
      } else { [PSCustomObject]@{
        Passed = $false; Report = "failed"; FailureReason = "validation failed"
      } } } `
    { param($context) $state.Reviewer++; New-ChangesReviewerResult }
Complete-Scenario `
    -Name "Scenario C Developer attempt limit after failed re-validation" `
    -Condition ((-not $result.Passed) -and $state.Validation -eq 2 -and
        $state.Reviewer -eq 1 -and $result.ValidationGate -eq "FAILED" -and
        $result.FailureReason.Contains("Maximum Developer Agent attempts"))

# Scenario D: Reviewer technical failure retries Reviewer without Developer repair.
$state = @{ Developer = 0; Reviewer = 0 }
$result = Invoke-ReviewGateWorkflow 3 2 2 $true `
    { param($context) $state.Developer++; [PSCustomObject]@{
        Succeeded = $true; FailureReason = ""
    } } `
    { param($context) [PSCustomObject]@{
        Passed = $true; Report = "pass"; FailureReason = ""
    } } `
    { param($context) $state.Reviewer++; if ($state.Reviewer -eq 1) {
        [PSCustomObject]@{
            TechnicalSucceeded = $false
            Fatal = $false
            FailureReason = "temporary reviewer failure"
            Verdict = $null
            ReviewResult = $null
        }
      } else { New-ApprovedReviewerResult } }
Complete-Scenario `
    -Name "Scenario D Reviewer technical retry" `
    -Condition ($result.Passed -and $state.Developer -eq 1 -and
        $state.Reviewer -eq 2)

# Scenario E: malformed Review Results exhaust Reviewer retries, never repair.
$state = @{ Actions = @(); Reviewer = 0 }
$result = Invoke-ReviewGateWorkflow 3 2 2 $true `
    { param($context) $state.Actions += [string]$context.Action; [PSCustomObject]@{
        Succeeded = $true; FailureReason = ""
    } } `
    { param($context) [PSCustomObject]@{
        Passed = $true; Report = "pass"; FailureReason = ""
    } } `
    { param($context) $state.Reviewer++; [PSCustomObject]@{
        TechnicalSucceeded = $false
        Fatal = $false
        FailureReason = "Review Contract violation: malformed JSON"
        Verdict = $null
        ReviewResult = $null
    } }
Complete-Scenario `
    -Name "Scenario E malformed Review Result exhausts technical retries" `
    -Condition ((-not $result.Passed) -and $state.Reviewer -eq 2 -and
        $state.Actions.Count -eq 1 -and
        $result.FailureReason.Contains("Maximum Reviewer technical attempts"))

# Scenario F: Reviewer mutation is fatal and is never restored or repaired.
$state = @{ Actions = @(); Reviewer = 0 }
$result = Invoke-ReviewGateWorkflow 3 2 2 $true `
    { param($context) $state.Actions += [string]$context.Action; [PSCustomObject]@{
        Succeeded = $true; FailureReason = ""
    } } `
    { param($context) [PSCustomObject]@{
        Passed = $true; Report = "pass"; FailureReason = ""
    } } `
    { param($context) $state.Reviewer++; [PSCustomObject]@{
        TechnicalSucceeded = $false
        Fatal = $true
        FailureReason = "Reviewer changed the Git working tree. No recovery was attempted."
        Verdict = $null
        ReviewResult = $null
    } }
Complete-Scenario `
    -Name "Scenario F Reviewer Git mutation is fatal" `
    -Condition ((-not $result.Passed) -and $state.Reviewer -eq 1 -and
        $state.Actions.Count -eq 1 -and
        $result.FailureReason.Contains("No recovery was attempted"))

# Scenario G: continued changes requested reaches MaxReviewCycles.
$state = @{ Developer = 0; Validation = 0; Reviewer = 0 }
$result = Invoke-ReviewGateWorkflow 4 1 2 $true `
    { param($context) $state.Developer++; [PSCustomObject]@{
        Succeeded = $true; FailureReason = ""
    } } `
    { param($context) $state.Validation++; [PSCustomObject]@{
        Passed = $true; Report = "pass"; FailureReason = ""
    } } `
    { param($context) $state.Reviewer++; New-ChangesReviewerResult }
Complete-Scenario `
    -Name "Scenario G Review repair cycle limit" `
    -Condition ((-not $result.Passed) -and $state.Developer -eq 2 -and
        $state.Validation -eq 2 -and $state.Reviewer -eq 2 -and
        $result.ReviewGate -eq "CHANGES_REQUESTED" -and
        $result.FailureReason.Contains("Maximum review repair cycles"))

# Reviewer disabled is explicit, not represented as approval.
$result = Invoke-ReviewGateWorkflow 1 0 1 $false `
    { param($context) [PSCustomObject]@{ Succeeded = $true; FailureReason = "" } } `
    { param($context) [PSCustomObject]@{
        Passed = $true; Report = "pass"; FailureReason = ""
    } } `
    { param($context) throw "Reviewer callback must not run when disabled." }
Complete-Scenario `
    -Name "Reviewer disabled gate status" `
    -Condition ($result.Passed -and $result.ReviewGate -eq "DISABLED")

Assert-Test `
    -Condition (Assert-ReviewGitSnapshotUnchanged "same" "same") `
    -Message "Equal Git snapshots were rejected."
$script:Passed++
Write-Output "PASS: equal Reviewer Git snapshots"

$snapshotError = ""
try {
    Assert-ReviewGitSnapshotUnchanged "before" "after"
}
catch {
    $snapshotError = $_.Exception.Message
}
Assert-Test `
    -Condition $snapshotError.Contains("No recovery was attempted") `
    -Message "Changed Git snapshots were not rejected."
$script:Passed++
Write-Output "PASS: changed Reviewer Git snapshot rejection"

Write-Output ("REVIEW GATE TESTS PASSED: " + $script:Passed)
