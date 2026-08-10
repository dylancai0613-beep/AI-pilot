[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$contractScript = Join-Path `
    $projectRoot `
    "automation\contracts\ReviewContract.ps1"
. $contractScript

$script:Passed = 0
$temporaryDirectory = Join-Path `
    $PSScriptRoot `
    (".tmp-review-contract-" + [Guid]::NewGuid().ToString("N"))
$expectedReviewId = "review-cycle-01"
$expectedAgentAttemptId = "agent-attempt-02"

function New-Finding {
    param(
        [string]$Id = "finding-01",
        [string]$Severity = "major",
        [bool]$Blocking = $true,
        [AllowNull()][object]$File = "automation/core/ReviewGate.ps1",
        [AllowNull()][object]$Line = 1
    )

    return [PSCustomObject][ordered]@{
        Id = $Id
        Severity = $Severity
        Blocking = $Blocking
        Category = "correctness"
        File = $File
        Line = $Line
        Message = "A concrete issue was found."
        Evidence = "The relevant branch returns the wrong state."
    }
}

function New-ReviewResult {
    param(
        [string]$Verdict = "approved",
        [object[]]$Findings = @()
    )

    return [PSCustomObject][ordered]@{
        SchemaVersion = 1
        ReviewId = $expectedReviewId
        ReviewerAgentAttemptId = $expectedAgentAttemptId
        Verdict = $Verdict
        Summary = "Review completed."
        Findings = [object[]]$Findings
        CreatedAt = [DateTimeOffset]::UtcNow.ToString("o")
    }
}

function Copy-ContractObject {
    param([Parameter(Mandatory = $true)][object]$Value)

    return ($Value | ConvertTo-Json -Depth 32 | ConvertFrom-Json)
}

function Assert-Pass {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Name
    )

    [void](& $Action)
    $script:Passed++
    Write-Output ("PASS: " + $Name)
}

function Assert-Fail {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$ExpectedText,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $message = ""
    try {
        & $Action
    }
    catch {
        $message = $_.Exception.Message
    }
    if ([string]::IsNullOrWhiteSpace($message)) {
        throw ($Name + " did not fail.")
    }
    if (-not $message.Contains($ExpectedText)) {
        throw ($Name + " returned an unexpected error: " + $message)
    }
    $script:Passed++
    Write-Output ("PASS: " + $Name)
}

function Assert-ValidReview {
    param([Parameter(Mandatory = $true)][object]$Result)

    return Assert-ReviewResultContract `
        -Result $Result `
        -ExpectedReviewId $expectedReviewId `
        -ExpectedReviewerAgentAttemptId $expectedAgentAttemptId `
        -ProjectRoot $projectRoot
}

try {
    [void][System.IO.Directory]::CreateDirectory($temporaryDirectory)

    Assert-Pass -Name "approved with empty findings" -Action {
        Assert-ValidReview (New-ReviewResult)
    }
    Assert-Pass -Name "approved with nonblocking minor finding" -Action {
        Assert-ValidReview (New-ReviewResult `
            -Findings @((New-Finding -Severity "minor" -Blocking $false)))
    }
    Assert-Fail -Name "approved with blocking finding rejection" `
        -ExpectedText "must not contain blocking" -Action {
        Assert-ValidReview (New-ReviewResult `
            -Findings @((New-Finding)))
    }
    Assert-Pass -Name "changes requested with blocking finding" -Action {
        Assert-ValidReview (New-ReviewResult `
            -Verdict "changes_requested" `
            -Findings @((New-Finding)))
    }
    Assert-Fail -Name "changes requested without blocking finding rejection" `
        -ExpectedText "requires at least one" -Action {
        Assert-ValidReview (New-ReviewResult `
            -Verdict "changes_requested" `
            -Findings @((New-Finding -Severity "minor" -Blocking $false)))
    }
    Assert-Fail -Name "invalid Verdict rejection" `
        -ExpectedText "Unsupported Review Result Verdict" -Action {
        Assert-ValidReview (New-ReviewResult -Verdict "maybe")
    }

    $missingPath = Join-Path $temporaryDirectory "missing.json"
    Assert-Fail -Name "missing Review Result rejection" `
        -ExpectedText "was not created" -Action {
        Read-ReviewContractJson $missingPath "Review Result"
    }
    $malformedPath = Join-Path $temporaryDirectory "malformed.json"
    [System.IO.File]::WriteAllText($malformedPath, "{ invalid json")
    Assert-Fail -Name "malformed JSON rejection" `
        -ExpectedText "is not valid JSON" -Action {
        Read-ReviewContractJson $malformedPath "Review Result"
    }

    $result = New-ReviewResult
    $result.SchemaVersion = 2
    Assert-Fail -Name "SchemaVersion mismatch rejection" `
        -ExpectedText "Unsupported Review Result SchemaVersion" -Action {
        Assert-ValidReview $result
    }
    $result = New-ReviewResult
    $result.ReviewId = "review-cycle-99"
    Assert-Fail -Name "ReviewId mismatch rejection" `
        -ExpectedText "ReviewId does not match" -Action {
        Assert-ValidReview $result
    }
    $result = New-ReviewResult
    $result.ReviewerAgentAttemptId = "agent-attempt-99"
    Assert-Fail -Name "ReviewerAgentAttemptId mismatch rejection" `
        -ExpectedText "ReviewerAgentAttemptId does not match" -Action {
        Assert-ValidReview $result
    }
    $result = New-ReviewResult `
        -Verdict "changes_requested" `
        -Findings @((New-Finding), (New-Finding))
    Assert-Fail -Name "duplicate Finding Id rejection" `
        -ExpectedText "Duplicate Review Finding Id" -Action {
        Assert-ValidReview $result
    }
    $result = New-ReviewResult `
        -Verdict "changes_requested" `
        -Findings @((New-Finding -Severity "critical"))
    Assert-Fail -Name "invalid Severity rejection" `
        -ExpectedText "Unsupported Review Finding Severity" -Action {
        Assert-ValidReview $result
    }
    $result = New-ReviewResult `
        -Verdict "changes_requested" `
        -Findings @((New-Finding))
    $result.Findings[0].Blocking = "true"
    Assert-Fail -Name "non-boolean Blocking rejection" `
        -ExpectedText "Blocking must be boolean" -Action {
        Assert-ValidReview $result
    }
    $result = New-ReviewResult `
        -Verdict "changes_requested" `
        -Findings @((New-Finding -File "..\outside.ps1"))
    Assert-Fail -Name "Finding File path escape rejection" `
        -ExpectedText "must not contain parent traversal" -Action {
        Assert-ValidReview $result
    }
    $result = New-ReviewResult `
        -Verdict "changes_requested" `
        -Findings @((New-Finding -Line 0))
    Assert-Fail -Name "invalid Finding Line rejection" `
        -ExpectedText "positive integer" -Action {
        Assert-ValidReview $result
    }
    $result = New-ReviewResult
    $result | Add-Member -NotePropertyName "Extra" -NotePropertyValue $true
    Assert-Fail -Name "extra top-level field rejection" `
        -ExpectedText "contains unsupported field" -Action {
        Assert-ValidReview $result
    }
    $result = New-ReviewResult `
        -Verdict "changes_requested" `
        -Findings @((New-Finding))
    $result.Findings[0] | Add-Member `
        -NotePropertyName "Extra" `
        -NotePropertyValue $true
    Assert-Fail -Name "extra Finding field rejection" `
        -ExpectedText "contains unsupported field" -Action {
        Assert-ValidReview $result
    }
    $result = New-ReviewResult
    $result.CreatedAt = "not-a-timestamp"
    Assert-Fail -Name "invalid CreatedAt rejection" `
        -ExpectedText "not a valid timestamp" -Action {
        Assert-ValidReview $result
    }
    $result = New-ReviewResult | Select-Object `
        SchemaVersion, ReviewId, ReviewerAgentAttemptId, Verdict, Findings, CreatedAt
    Assert-Fail -Name "missing Summary rejection" `
        -ExpectedText "missing required field: Summary" -Action {
        Assert-ValidReview $result
    }
    $result = New-ReviewResult | Select-Object `
        SchemaVersion, ReviewId, ReviewerAgentAttemptId, Verdict, Summary, CreatedAt
    Assert-Fail -Name "missing Findings rejection" `
        -ExpectedText "missing required field: Findings" -Action {
        Assert-ValidReview $result
    }
    $result = New-ReviewResult
    $result.Findings = "not-an-array"
    Assert-Fail -Name "non-array Findings rejection" `
        -ExpectedText "Findings must be an array" -Action {
        Assert-ValidReview $result
    }
    $incompleteFinding = New-Finding | Select-Object `
        Id, Severity, Blocking, Category, File, Line, Message
    $result = New-ReviewResult `
        -Verdict "changes_requested" `
        -Findings @($incompleteFinding)
    Assert-Fail -Name "Finding missing required field rejection" `
        -ExpectedText "missing required field: Evidence" -Action {
        Assert-ValidReview $result
    }
    $externalPath = [System.IO.Path]::GetFullPath(
        (Join-Path $projectRoot "..\outside.ps1")
    )
    $result = New-ReviewResult `
        -Verdict "changes_requested" `
        -Findings @((New-Finding -File $externalPath))
    Assert-Fail -Name "absolute Finding File rejection" `
        -ExpectedText "must be a project-relative path" -Action {
        Assert-ValidReview $result
    }
    Assert-Pass -Name "null File and null Line" -Action {
        Assert-ValidReview (New-ReviewResult `
            -Findings @((New-Finding `
                -Severity "minor" `
                -Blocking $false `
                -File $null `
                -Line $null)))
    }

    $roundTripPath = Join-Path $temporaryDirectory "valid.json"
    Write-ReviewContractJson `
        -LiteralPath $roundTripPath `
        -InputObject (New-ReviewResult)
    $roundTrip = Read-ReviewContractJson $roundTripPath "Review Result"
    Assert-Pass -Name "UTF-8 JSON write and read" -Action {
        Assert-ValidReview $roundTrip
    }

    Write-Output ("REVIEW CONTRACT TESTS PASSED: " + $script:Passed)
}
finally {
    $resolvedTemporary = [System.IO.Path]::GetFullPath($temporaryDirectory)
    $testRootPrefix = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd("\") + "\"
    if (-not $resolvedTemporary.StartsWith(
        $testRootPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing to remove a temporary directory outside automation/tests."
    }
    if (Test-Path -LiteralPath $resolvedTemporary -PathType Container) {
        Remove-Item -LiteralPath $resolvedTemporary -Recurse
    }
}
