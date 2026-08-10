[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$contractScript = Join-Path $projectRoot "automation\contracts\AgentContract.ps1"
. $contractScript

$script:Passed = 0
$temporaryDirectory = Join-Path `
    $PSScriptRoot `
    (".tmp-agent-contract-" + [Guid]::NewGuid().ToString("N"))

function Assert-Test {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Throws {
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
        throw ($Name + " did not throw.")
    }
    if (-not $message.Contains($ExpectedText)) {
        throw ($Name + " returned an unexpected error: " + $message)
    }
    $script:Passed++
    Write-Output ("PASS: " + $Name)
}

function Assert-Equivalent {
    param(
        [AllowNull()][object]$Left,
        [AllowNull()][object]$Right,
        [Parameter(Mandatory = $true)][bool]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $actual = Test-AgentContractValueEquivalent -Left $Left -Right $Right
    Assert-Test `
        -Condition ($actual -eq $Expected) `
        -Message ("Unexpected semantic comparison result for: " + $Name)
    $script:Passed++
    Write-Output ("PASS: " + $Name)
}

try {
    [void][System.IO.Directory]::CreateDirectory($temporaryDirectory)
    $taskFile = Join-Path $temporaryDirectory "task.md"
    $promptFile = Join-Path $temporaryDirectory "prompt.txt"
    $stdoutFile = Join-Path $temporaryDirectory "stdout.txt"
    $stderrFile = Join-Path $temporaryDirectory "stderr.txt"
    $requestFile = Join-Path $temporaryDirectory "request.json"
    $resultFile = Join-Path $temporaryDirectory "result.json"
    [System.IO.File]::WriteAllText($taskFile, "test task")
    [System.IO.File]::WriteAllText($promptFile, "test prompt")

    $request = [PSCustomObject][ordered]@{
        SchemaVersion = 1
        AttemptId = "agent-attempt-01"
        InvocationType = "review"
        ProjectRoot = $projectRoot
        TaskFile = $taskFile
        PromptFile = $promptFile
        StdoutFile = $stdoutFile
        StderrFile = $stderrFile
        Runtime = [PSCustomObject][ordered]@{
            Name = "fake-runtime"
            Metadata = [PSCustomObject][ordered]@{
                Region = "test"
                Features = @("one", "two")
            }
        }
        Model = [PSCustomObject][ordered]@{
            Name = $null
            Reasoning = $null
            Settings = [PSCustomObject][ordered]@{
                Temperature = 1
                Enabled = $true
            }
        }
        Options = [PSCustomObject][ordered]@{
            TestMode = $true
            Unicode = "$([char]0x5408)$([char]0x7EA6)"
        }
    }

    Write-AgentContractJson -LiteralPath $requestFile -InputObject $request
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $decodedRequest = $strictUtf8.GetString(
        [System.IO.File]::ReadAllBytes($requestFile)
    )
    Assert-Test `
        -Condition $decodedRequest.Contains([string]$request.Options.Unicode) `
        -Message "Agent Request was not written as valid UTF-8."
    $parsedRequest = Read-AgentContractJson `
        -LiteralPath $requestFile `
        -Description "Agent Request"
    Assert-Test `
        -Condition (Assert-AgentRequestContract $parsedRequest $projectRoot) `
        -Message "Valid Agent Request was rejected."
    $script:Passed++
    Write-Output "PASS: Request JSON serialization and parsing"

    $now = [DateTimeOffset]::UtcNow
    $result = [PSCustomObject][ordered]@{
        SchemaVersion = 1
        AttemptId = $parsedRequest.AttemptId
        AdapterStatus = "completed"
        ExitCode = 0
        StartedAt = $now.ToString("o")
        FinishedAt = $now.AddSeconds(1).ToString("o")
        Runtime = [PSCustomObject][ordered]@{
            Metadata = [PSCustomObject][ordered]@{
                Features = @("one", "two")
                Region = "test"
            }
            Name = "fake-runtime"
        }
        RequestedModel = [PSCustomObject][ordered]@{
            Settings = [PSCustomObject][ordered]@{
                Enabled = $true
                Temperature = 1
            }
            Reasoning = $null
            Name = $null
        }
        ResolvedModel = $null
        Message = "Fake adapter completed."
    }
    Write-AgentContractJson -LiteralPath $resultFile -InputObject $result
    $parsedResult = Read-AgentContractJson `
        -LiteralPath $resultFile `
        -Description "Agent Result"
    Assert-Test `
        -Condition (Assert-AgentResultContract $parsedResult $parsedRequest 0) `
        -Message "Valid Agent Result was rejected."
    $script:Passed++
    Write-Output "PASS: Result JSON serialization and parsing"

    Assert-Equivalent `
        -Left $parsedRequest.Runtime `
        -Right $parsedResult.Runtime `
        -Expected $true `
        -Name "Runtime property order is ignored"
    Assert-Equivalent `
        -Left $parsedRequest.Model `
        -Right $parsedResult.RequestedModel `
        -Expected $true `
        -Name "Model property order is ignored"
    Assert-Equivalent `
        -Left ([PSCustomObject][ordered]@{
            Outer = [PSCustomObject][ordered]@{ First = 1; Second = 2 }
        }) `
        -Right ([PSCustomObject][ordered]@{
            Outer = [PSCustomObject][ordered]@{ Second = 2; First = 1 }
        }) `
        -Expected $true `
        -Name "Nested object property order is ignored"
    Assert-Equivalent `
        -Left (@{
            Name = "runtime"
            Nested = @{ First = 1; Second = 2 }
        }) `
        -Right (@{
            Nested = @{ Second = 2; First = 1 }
            Name = "runtime"
        }) `
        -Expected $true `
        -Name "Nested Hashtable property order is ignored"
    Assert-Equivalent `
        -Left ([object[]]@(1, "two", $true)) `
        -Right ([object[]]@(1, "two", $true)) `
        -Expected $true `
        -Name "Array order match"
    Assert-Equivalent `
        -Left ([object[]]@(1, 2, 3)) `
        -Right ([object[]]@(3, 2, 1)) `
        -Expected $false `
        -Name "Array order mismatch rejection"
    Assert-Equivalent `
        -Left ([PSCustomObject]@{ Name = "original" }) `
        -Right ([PSCustomObject]@{ Name = "modified" }) `
        -Expected $false `
        -Name "Modified value rejection"
    Assert-Equivalent `
        -Left ([PSCustomObject][ordered]@{ Name = $null }) `
        -Right ([PSCustomObject][ordered]@{}) `
        -Expected $false `
        -Name "Null and missing field differ"
    Assert-Equivalent `
        -Left ([PSCustomObject][ordered]@{ Name = "same" }) `
        -Right ([PSCustomObject][ordered]@{ Name = "same"; Extra = $true }) `
        -Expected $false `
        -Name "Added field rejection"
    Assert-Equivalent `
        -Left "1" `
        -Right 1 `
        -Expected $false `
        -Name "String and number types differ"

    $badRequest = $parsedRequest | Select-Object *
    $badRequest.SchemaVersion = 2
    Assert-Throws `
        -Action { Assert-AgentRequestContract $badRequest $projectRoot } `
        -ExpectedText "Unsupported Agent Request SchemaVersion" `
        -Name "Request SchemaVersion rejection"

    $badResult = $parsedResult | Select-Object *
    $badResult.SchemaVersion = 2
    Assert-Throws `
        -Action { Assert-AgentResultContract $badResult $parsedRequest 0 } `
        -ExpectedText "Unsupported Agent Result SchemaVersion" `
        -Name "Result SchemaVersion rejection"

    $badResult = $parsedResult | Select-Object *
    $badResult.AttemptId = "agent-attempt-99"
    Assert-Throws `
        -Action { Assert-AgentResultContract $badResult $parsedRequest 0 } `
        -ExpectedText "AttemptId does not match" `
        -Name "AttemptId mismatch rejection"

    $missingResult = Join-Path $temporaryDirectory "missing-result.json"
    Assert-Throws `
        -Action { Read-AgentContractJson $missingResult "Agent Result" } `
        -ExpectedText "was not created" `
        -Name "Missing Result rejection"

    [System.IO.File]::WriteAllText($resultFile, "{ invalid json")
    Assert-Throws `
        -Action { Read-AgentContractJson $resultFile "Agent Result" } `
        -ExpectedText "is not valid JSON" `
        -Name "Invalid Result JSON rejection"

    $badResult = $parsedResult | Select-Object *
    $badResult.AdapterStatus = "unknown"
    Assert-Throws `
        -Action { Assert-AgentResultContract $badResult $parsedRequest 0 } `
        -ExpectedText "Unsupported Agent Result AdapterStatus" `
        -Name "AdapterStatus rejection"

    $missingExitCode = [PSCustomObject][ordered]@{
        SchemaVersion = 1
        AttemptId = $parsedResult.AttemptId
        AdapterStatus = $parsedResult.AdapterStatus
        StartedAt = $parsedResult.StartedAt
        FinishedAt = $parsedResult.FinishedAt
        Runtime = $parsedResult.Runtime
        RequestedModel = $parsedResult.RequestedModel
        ResolvedModel = $null
        Message = $parsedResult.Message
    }
    Assert-Throws `
        -Action { Assert-AgentResultContract $missingExitCode $parsedRequest 0 } `
        -ExpectedText "missing required field: ExitCode" `
        -Name "Missing ExitCode rejection"

    $badRequest = $parsedRequest | Select-Object *
    $badRequest.StdoutFile = [System.IO.Path]::GetFullPath(
        (Join-Path $projectRoot "..\escaped-output.txt")
    )
    Assert-Throws `
        -Action { Assert-AgentRequestContract $badRequest $projectRoot } `
        -ExpectedText "must be inside ProjectRoot" `
        -Name "Request path escape rejection"

    $externalReference = $parsedResult | Select-Object *
    $externalReference | Add-Member `
        -NotePropertyName "OutputFile" `
        -NotePropertyValue ([System.IO.Path]::GetFullPath(
            (Join-Path $projectRoot "..\external.txt")
        ))
    Assert-Throws `
        -Action { Assert-AgentResultContract $externalReference $parsedRequest 0 } `
        -ExpectedText "contains unsupported field" `
        -Name "Result external reference rejection"

    $badResult = $parsedResult | Select-Object *
    $badResult.ExitCode = 1
    $badResult.AdapterStatus = "failed"
    Assert-Throws `
        -Action { Assert-AgentResultContract $badResult $parsedRequest 0 } `
        -ExpectedText "process exit code does not match" `
        -Name "Process and Result ExitCode mismatch rejection"

    $badResult = $parsedResult | Select-Object *
    $badResult.RequestedModel = [PSCustomObject]@{ Name = "invented" }
    Assert-Throws `
        -Action { Assert-AgentResultContract $badResult $parsedRequest 0 } `
        -ExpectedText "RequestedModel does not match" `
        -Name "RequestedModel mismatch rejection"

    Assert-Throws `
        -Action { Assert-AgentOutputFiles $parsedRequest } `
        -ExpectedText "did not create StdoutFile" `
        -Name "Missing stdout rejection"
    [System.IO.File]::WriteAllText($stdoutFile, "")
    Assert-Throws `
        -Action { Assert-AgentOutputFiles $parsedRequest } `
        -ExpectedText "did not create StderrFile" `
        -Name "Missing stderr rejection"
    [System.IO.File]::WriteAllText($stderrFile, "")
    Assert-Test `
        -Condition (Assert-AgentOutputFiles $parsedRequest) `
        -Message "Existing output files were rejected."
    $script:Passed++
    Write-Output "PASS: stdout and stderr existence"

    Write-Output ("AGENT CONTRACT TESTS PASSED: " + $script:Passed)
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
