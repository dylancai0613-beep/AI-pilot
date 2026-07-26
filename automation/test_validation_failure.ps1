[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$script:Failures = New-Object "System.Collections.Generic.List[string]"

$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$FrontendPath = Join-Path $ProjectRoot "frontend\index.html"
$ValidationScript = Join-Path $ProjectRoot "automation\run_validation.ps1"
$FailureReportPath = Join-Path $ProjectRoot "automation\reports\validation-latest.txt"

function Add-Failure {
    param([Parameter(Mandatory = $true)][string]$Message)

    [void]$script:Failures.Add($Message)
    Write-Host ("ERROR: " + $Message)
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($Bytes)
        return ([System.BitConverter]::ToString($hashBytes)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-ProtectedGitChanges {
    $LASTEXITCODE = 0
    $statusLines = @(& git status --short --untracked-files=all 2>&1)
    $gitExitCode = $LASTEXITCODE
    if ($gitExitCode -ne 0) {
        throw ("git status --short failed with exit code {0}: {1}" -f `
            $gitExitCode,
            ($statusLines -join [Environment]::NewLine))
    }

    $protectedChanges = New-Object "System.Collections.Generic.List[string]"
    $protectedPathPattern = '^(backend|frontend|tests)(/|$)|^(docker-compose\.yml|requirements\.txt)$'

    foreach ($statusLine in $statusLines) {
        $line = [string]$statusLine
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line.Length -lt 4) {
            throw ("Unexpected git status --short output: " + $line)
        }

        $pathText = $line.Substring(3).Trim()
        $candidatePaths = @($pathText -split '\s+->\s+')
        foreach ($candidatePath in $candidatePaths) {
            $normalizedPath = $candidatePath.Trim().Trim('"').Replace("\", "/")
            if ($normalizedPath -match $protectedPathPattern) {
                [void]$protectedChanges.Add($line)
                break
            }
        }
    }

    return $protectedChanges.ToArray()
}

function Invoke-Validation {
    Write-Host ("Running: powershell.exe -File " + $ValidationScript)
    $validationProcess = Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList @(
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            ('"{0}"' -f $ValidationScript)
        ) `
        -NoNewWindow `
        -Wait `
        -PassThru

    return [int]$validationProcess.ExitCode
}

function Invoke-DockerComposeDown {
    Write-Host "Running final cleanup: docker compose down"
    Push-Location $ProjectRoot
    try {
        $LASTEXITCODE = 0
        & docker compose down 2>&1 |
            ForEach-Object { Write-Host ([string]$_) }
        $dockerExitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($null -eq $dockerExitCode) {
        throw "Unable to determine the docker compose down exit code."
    }
    if ($dockerExitCode -ne 0) {
        throw ("docker compose down failed with exit code " + $dockerExitCode)
    }
}

$OriginalBytes = $null
$OriginalSha256 = ""
$OriginalBytesLoaded = $false
$WorkflowSucceeded = $false
$RestoreSucceeded = $false
$CleanupSucceeded = $false
$RecoveredValidationSucceeded = $false
$FinalGitCheckSucceeded = $false
$FailureReport = $null

try {
    Write-Host "Checking project root."
    $currentDirectory = [System.IO.Path]::GetFullPath((Get-Location).Path)
    if (-not [string]::Equals(
        $currentDirectory.TrimEnd("\"),
        $ProjectRoot.TrimEnd("\"),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw ("Run this script from the project root: " + $ProjectRoot)
    }
    if (-not (Test-Path -LiteralPath $FrontendPath -PathType Leaf)) {
        throw ("Frontend file was not found: " + $FrontendPath)
    }
    if (-not (Test-Path -LiteralPath $ValidationScript -PathType Leaf)) {
        throw ("Validation script was not found: " + $ValidationScript)
    }
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "The git command is not available."
    }
    if ($null -eq (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        throw "Windows PowerShell is not available."
    }

    Write-Host "Checking for pre-existing business-code changes."
    $initialProtectedChanges = @(Get-ProtectedGitChanges)
    if ($initialProtectedChanges.Count -ne 0) {
        throw ("Business-code changes already exist: " + ($initialProtectedChanges -join "; "))
    }

    $OriginalBytes = [System.IO.File]::ReadAllBytes($FrontendPath)
    $OriginalBytesLoaded = $true
    $OriginalSha256 = Get-Sha256 -Bytes $OriginalBytes
    Write-Host ("Original frontend/index.html SHA256: " + $OriginalSha256)

    Write-Host "Running validation in the normal state."
    $normalExitCode = Invoke-Validation
    if ($normalExitCode -ne 0) {
        throw ("Normal-state validation returned exit code " + $normalExitCode)
    }

    $hasUtf8Bom = (
        ($OriginalBytes.Length -ge 3) -and
        ($OriginalBytes[0] -eq 0xEF) -and
        ($OriginalBytes[1] -eq 0xBB) -and
        ($OriginalBytes[2] -eq 0xBF)
    )
    if ($hasUtf8Bom) {
        $textOffset = 3
    }
    else {
        $textOffset = 0
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $html = $utf8.GetString(
        $OriginalBytes,
        $textOffset,
        $OriginalBytes.Length - $textOffset
    )
    $targetElementId = 'id="results"'
    $disabledElementId = 'id="results-disabled"'
    $targetCount = ([regex]::Matches(
        $html,
        [regex]::Escape($targetElementId)
    )).Count
    if ($targetCount -ne 1) {
        throw ("Expected id=results exactly once, but found " + $targetCount)
    }

    $modifiedHtml = $html.Replace($targetElementId, $disabledElementId)
    $modifiedPayload = $utf8.GetBytes($modifiedHtml)
    if ($hasUtf8Bom) {
        $modifiedBytes = New-Object byte[] ($modifiedPayload.Length + 3)
        $modifiedBytes[0] = 0xEF
        $modifiedBytes[1] = 0xBB
        $modifiedBytes[2] = 0xBF
        [System.Array]::Copy(
            $modifiedPayload,
            0,
            $modifiedBytes,
            3,
            $modifiedPayload.Length
        )
    }
    else {
        $modifiedBytes = $modifiedPayload
    }
    [System.IO.File]::WriteAllBytes($FrontendPath, $modifiedBytes)
    Write-Host "Injected temporary id=results-disabled failure."

    Write-Host "Running validation in the failure state."
    $failureExitCode = Invoke-Validation
    if ($failureExitCode -eq 0) {
        throw "Failure-state validation unexpectedly returned exit code 0."
    }

    # Read the failed report immediately, before any restored-state validation can overwrite it.
    $FailureReport = [System.IO.File]::ReadAllText($FailureReportPath, $utf8)
    if (-not $FailureReport.Contains("VALIDATION FAILED")) {
        throw "Failure report does not contain: VALIDATION FAILED"
    }

    $hasResultsElementId = (
        $FailureReport.Contains('id="results"') -or
        $FailureReport.Contains("id=results")
    )
    $hasHomepageCheckEvidence = (
        $FailureReport.Contains("The homepage is missing required element") -and
        $hasResultsElementId
    )

    $pytestCommandMatch = [regex]::Match(
        $FailureReport,
        '(?ms)^\$\s+docker compose exec app pytest -q[^\r\n]*\r?\n(?<output>(?:(?!^Exit code:).)*)^Exit code:\s*(?<exitCode>\d+)[ \t]*\r?$'
    )
    $pytestCommandFailed = (
        $pytestCommandMatch.Success -and
        ([int]$pytestCommandMatch.Groups["exitCode"].Value -ne 0)
    )
    $pytestFailureOutput = $pytestCommandMatch.Groups["output"].Value
    $hasHomepageRequiredTestFailure = [regex]::IsMatch(
        $pytestFailureOutput,
        '(?m)^(?:FAILED\s+tests[\\/]test_app\.py::test_homepage_contains_required_form_elements\b|_+\s+test_homepage_contains_required_form_elements\s+_+)'
    )
    $hasResultsAssertionFailure = [regex]::IsMatch(
        $pytestFailureOutput,
        '(?m)^(?:>\s*|E\s+)assert\s+''id="results"''\s+in\s+response\.text'
    )
    $hasRelatedPytestFailure = (
        $pytestCommandFailed -and
        ($hasHomepageRequiredTestFailure -or $hasResultsAssertionFailure)
    )

    if (-not ($hasHomepageCheckEvidence -or $hasRelatedPytestFailure)) {
        throw (
            "Failure report does not contain evidence for the injected id=results fault. " +
            "Expected either the Homepage missing-element error with id=results, or a " +
            "failed docker compose exec app pytest -q command with the related homepage " +
            "test or id=results assertion failure."
        )
    }

    $WorkflowSucceeded = $true
}
catch {
    Add-Failure -Message $_.Exception.Message
}
finally {
    try {
        if ($OriginalBytesLoaded) {
            [System.IO.File]::WriteAllBytes($FrontendPath, $OriginalBytes)
            $restoredBytes = [System.IO.File]::ReadAllBytes($FrontendPath)
            $restoredSha256 = Get-Sha256 -Bytes $restoredBytes
            Write-Host ("Restored frontend/index.html SHA256: " + $restoredSha256)
            if ($restoredSha256 -ne $OriginalSha256) {
                throw (
                    "Restored frontend/index.html SHA256 does not match the original. " +
                    "Original: {0}; restored: {1}" -f $OriginalSha256, $restoredSha256
                )
            }
            $RestoreSucceeded = $true
        }
        else {
            Write-Host "Original bytes were not loaded; frontend/index.html was not modified."
        }
    }
    catch {
        Add-Failure -Message ("Failed to restore frontend/index.html: " + $_.Exception.Message)
    }

    try {
        Invoke-DockerComposeDown
        $CleanupSucceeded = $true
    }
    catch {
        Add-Failure -Message ("Final Docker cleanup failed: " + $_.Exception.Message)
    }
}

if ($WorkflowSucceeded -and $RestoreSucceeded) {
    try {
        Write-Host "Running validation after restoring frontend/index.html."
        $recoveredExitCode = Invoke-Validation
        if ($recoveredExitCode -ne 0) {
            throw ("Restored-state validation returned exit code " + $recoveredExitCode)
        }
        $RecoveredValidationSucceeded = $true
    }
    catch {
        Add-Failure -Message $_.Exception.Message
    }
}

try {
    Write-Host "Checking final Git modification scope."
    $finalProtectedChanges = @(Get-ProtectedGitChanges)
    if ($finalProtectedChanges.Count -ne 0) {
        throw ("Protected files remain modified: " + ($finalProtectedChanges -join "; "))
    }
    $FinalGitCheckSucceeded = $true
}
catch {
    Add-Failure -Message $_.Exception.Message
}

$passed = (
    $WorkflowSucceeded -and
    $RestoreSucceeded -and
    $CleanupSucceeded -and
    $RecoveredValidationSucceeded -and
    $FinalGitCheckSucceeded -and
    ($script:Failures.Count -eq 0)
)

if ($passed) {
    Write-Host "FAILURE PATH TEST PASSED"
    exit 0
}

Write-Host "FAILURE PATH TEST FAILED"
foreach ($failure in $script:Failures) {
    Write-Host ("- " + $failure)
}
exit 1
