[CmdletBinding()]
param([switch]$RunRealSmoke)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$contractScript = Join-Path $projectRoot "automation\contracts\AgentContract.ps1"
$adapterScript = Join-Path $projectRoot "automation\adapters\agent\claude-code.ps1"
. $contractScript

$temporaryDirectory = Join-Path `
    $PSScriptRoot `
    (".tmp-claude-code-adapter-" + [Guid]::NewGuid().ToString("N"))
$script:Passed = 0

function Check([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw ("Check failed: " + $Name) }
    $script:Passed++
    Write-Output ("PASS: " + $Name)
}

function New-TestRequest {
    param(
        [string]$AttemptId,
        [object]$Runtime = ([PSCustomObject]@{ Name = "incompatible-runtime" }),
        [object]$Model = ([PSCustomObject]@{ Name = $null; Reasoning = $null }),
        [object]$Options = ([PSCustomObject]@{ PermissionMode = "acceptEdits" }),
        [string]$PromptPath = $script:PromptFile,
        [string]$RequestProjectRoot = $projectRoot
    )
    return [PSCustomObject][ordered]@{
        SchemaVersion = 1
        AttemptId = $AttemptId
        InvocationType = "development"
        ProjectRoot = $RequestProjectRoot
        TaskFile = $script:TaskFile
        PromptFile = $PromptPath
        StdoutFile = Join-Path $temporaryDirectory ($AttemptId + ".stdout.txt")
        StderrFile = Join-Path $temporaryDirectory ($AttemptId + ".stderr.txt")
        Runtime = $Runtime
        Model = $Model
        Options = $Options
    }
}

function Invoke-AdapterCase {
    param([object]$Request, [string]$CaseName)
    $requestPath = Join-Path $temporaryDirectory ($CaseName + ".request.json")
    $resultPath = Join-Path $temporaryDirectory ($CaseName + ".result.json")
    Write-AgentContractJson $requestPath $Request
    $hostCommand = Get-Command "powershell.exe" -ErrorAction Stop
    $process = Start-Process `
        -FilePath $hostCommand.Source `
        -ArgumentList @(
            "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", ('"{0}"' -f $adapterScript),
            "-RequestFile", ('"{0}"' -f $requestPath),
            "-ResultFile", ('"{0}"' -f $resultPath)
        ) `
        -WorkingDirectory $projectRoot `
        -NoNewWindow `
        -Wait `
        -PassThru
    return [PSCustomObject]@{
        Process = $process
        RequestPath = $requestPath
        ResultPath = $resultPath
    }
}

try {
    [void][System.IO.Directory]::CreateDirectory($temporaryDirectory)
    $script:TaskFile = Join-Path $temporaryDirectory "task.md"
    $script:PromptFile = Join-Path $temporaryDirectory "prompt.txt"
    [System.IO.File]::WriteAllText($script:TaskFile, "test task")
    [System.IO.File]::WriteAllText($script:PromptFile, "test prompt")

    $incompatibleRequest = New-TestRequest "claude-contract-01"
    $incompatible = Invoke-AdapterCase $incompatibleRequest "incompatible"
    $incompatibleResult = Read-AgentContractJson $incompatible.ResultPath "Agent Result"
    [void](Assert-AgentOutputFiles $incompatibleRequest)
    [void](Assert-AgentResultContract `
        $incompatibleResult $incompatibleRequest $incompatible.Process.ExitCode)
    Check ($incompatible.Process.ExitCode -eq 64 -and
        $incompatibleResult.AdapterStatus -eq "invalid_configuration") `
        "incompatible Runtime is invalid_configuration"
    Check ($null -eq $incompatibleResult.ResolvedModel) `
        "ResolvedModel is not fabricated"

    $invalidModelRequest = New-TestRequest `
        -AttemptId "claude-contract-02" `
        -Runtime ([PSCustomObject]@{ Name = "claude-code" }) `
        -Model ([PSCustomObject]@{ Name = $null; Reasoning = "unsupported" })
    $invalidModel = Invoke-AdapterCase $invalidModelRequest "invalid-model"
    $invalidModelResult = Read-AgentContractJson $invalidModel.ResultPath "Agent Result"
    [void](Assert-AgentOutputFiles $invalidModelRequest)
    [void](Assert-AgentResultContract `
        $invalidModelResult $invalidModelRequest $invalidModel.Process.ExitCode)
    Check ($invalidModel.Process.ExitCode -eq 64 -and
        $invalidModelResult.AdapterStatus -eq "invalid_configuration") `
        "unsupported Model override is rejected"

    $invalidOptionRequest = New-TestRequest `
        -AttemptId "claude-contract-03" `
        -Runtime ([PSCustomObject]@{ Name = "claude-code" }) `
        -Options ([PSCustomObject]@{ PermissionMode = "acceptEdits"; Secret = "no" })
    $invalidOption = Invoke-AdapterCase $invalidOptionRequest "invalid-option"
    $invalidOptionResult = Read-AgentContractJson $invalidOption.ResultPath "Agent Result"
    [void](Assert-AgentResultContract `
        $invalidOptionResult $invalidOptionRequest $invalidOption.Process.ExitCode)
    Check ($invalidOption.Process.ExitCode -eq 64 -and
        $invalidOptionResult.AdapterStatus -eq "invalid_configuration") `
        "unsupported Options are rejected"

    $missingPrompt = Join-Path $temporaryDirectory "missing-prompt.txt"
    $missingPathRequest = New-TestRequest `
        -AttemptId "claude-contract-04" `
        -Runtime ([PSCustomObject]@{ Name = "claude-code" }) `
        -PromptPath $missingPrompt
    $missingPath = Invoke-AdapterCase $missingPathRequest "missing-path"
    $missingPathResult = Read-AgentContractJson $missingPath.ResultPath "Agent Result"
    [void](Assert-AgentResultContract `
        $missingPathResult $missingPathRequest $missingPath.Process.ExitCode)
    Check ($missingPath.Process.ExitCode -eq 64 -and
        $missingPathResult.AdapterStatus -eq "invalid_configuration") `
        "missing required path is rejected"

    $malformedRequestPath = Join-Path $temporaryDirectory "malformed.request.json"
    $malformedResultPath = Join-Path $temporaryDirectory "malformed.result.json"
    [System.IO.File]::WriteAllText($malformedRequestPath, "{bad")
    $hostCommand = Get-Command "powershell.exe" -ErrorAction Stop
    $malformedProcess = Start-Process `
        -FilePath $hostCommand.Source `
        -ArgumentList @(
            "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", ('"{0}"' -f $adapterScript),
            "-RequestFile", ('"{0}"' -f $malformedRequestPath),
            "-ResultFile", ('"{0}"' -f $malformedResultPath)
        ) `
        -WorkingDirectory $projectRoot `
        -NoNewWindow `
        -Wait `
        -PassThru
    Check ($malformedProcess.ExitCode -eq 64 -and
        -not (Test-Path -LiteralPath $malformedResultPath)) `
        "malformed Request fails before an unsafe Result can be written"

    if ($RunRealSmoke) {
        $runtimeVersion = (& claude --version | Out-String).Trim()
        Write-Output "REAL CLAUDE CODE RUNTIME STARTED"
        Write-Output ("Runtime version: " + $runtimeVersion)
        $artifactPath = Join-Path $temporaryDirectory "real-smoke-artifact.txt"
        $prompt = @"
Create exactly one file at this absolute path:
$artifactPath
The file content must be exactly: claude-code-contract-smoke
Do not modify any other file. Do not run tests. Then stop.
"@
        [System.IO.File]::WriteAllText($script:PromptFile, $prompt)
        $smokeRequest = New-TestRequest `
            -AttemptId "claude-real-smoke-01" `
            -Runtime ([PSCustomObject]@{ Name = "claude-code" }) `
            -Options ([PSCustomObject]@{
                PermissionMode = "acceptEdits"
                AllowedTools = @("Write")
            }) `
            -RequestProjectRoot $temporaryDirectory
        $smoke = Invoke-AdapterCase $smokeRequest "real-smoke"
        $smokeResult = Read-AgentContractJson $smoke.ResultPath "Agent Result"
        [void](Assert-AgentOutputFiles $smokeRequest)
        [void](Assert-AgentResultContract `
            $smokeResult $smokeRequest $smoke.Process.ExitCode)
        Check ($smoke.Process.ExitCode -eq 0 -and
            $smokeResult.AdapterStatus -eq "completed") `
            "real Runtime completed through Agent Contract"
        Check ((Test-Path -LiteralPath $artifactPath -PathType Leaf) -and
            [System.IO.File]::ReadAllText($artifactPath).Trim() -eq
                "claude-code-contract-smoke") `
            "real Runtime created the requested isolated artifact"
        Check ($null -eq $smokeResult.ResolvedModel) `
            "real smoke does not fabricate ResolvedModel"
    }

    Write-Output ("CLAUDE CODE ADAPTER CONTRACT TESTS PASSED: " + $script:Passed)
}
finally {
    $resolvedTemporary = [System.IO.Path]::GetFullPath($temporaryDirectory)
    $prefix = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd("\") + "\"
    if (-not $resolvedTemporary.StartsWith(
        $prefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing to remove a temporary directory outside automation/tests."
    }
    if (Test-Path -LiteralPath $resolvedTemporary -PathType Container) {
        Remove-Item -LiteralPath $resolvedTemporary -Recurse
    }
}
