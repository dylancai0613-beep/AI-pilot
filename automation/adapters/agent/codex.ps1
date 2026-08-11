[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$RequestFile,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResultFile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$startedAt = [DateTimeOffset]::UtcNow
$finishedAt = $startedAt
$request = $null
$attemptId = "unknown"
$runtime = $null
$requestedModel = $null
$resolvedModel = $null
$adapterStatus = "invalid_configuration"
$exitCode = 64
$message = "Agent Request was not validated."
$resultPathIsSafe = $false

function Write-AdapterResult {
    $result = [PSCustomObject][ordered]@{
        SchemaVersion = 1
        AttemptId = $attemptId
        AdapterStatus = $adapterStatus
        ExitCode = [int]$exitCode
        StartedAt = $startedAt.ToString("o")
        FinishedAt = $finishedAt.ToString("o")
        Runtime = $runtime
        RequestedModel = $requestedModel
        ResolvedModel = $resolvedModel
        Message = $message
    }
    Write-AgentContractJson -LiteralPath $ResultFile -InputObject $result
}

try {
    $requestFullPath = [System.IO.Path]::GetFullPath($RequestFile)
    $resultFullPath = [System.IO.Path]::GetFullPath($ResultFile)
    if (-not [string]::Equals(
        [System.IO.Path]::GetDirectoryName($requestFullPath),
        [System.IO.Path]::GetDirectoryName($resultFullPath),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "RequestFile and ResultFile must use the same directory."
    }

    $contractScript = [System.IO.Path]::GetFullPath(
        (Join-Path $PSScriptRoot "..\..\contracts\AgentContract.ps1")
    )
    if (-not (Test-Path -LiteralPath $contractScript -PathType Leaf)) {
        throw "Agent Contract implementation was not found."
    }
    . $contractScript

    $request = Read-AgentContractJson `
        -LiteralPath $requestFullPath `
        -Description "Agent Request"
    if (Test-AgentContractProperty -Object $request -Name "AttemptId") {
        $attemptId = [string]$request.AttemptId
    }
    if (Test-AgentContractProperty -Object $request -Name "Runtime") {
        $runtime = $request.Runtime
    }
    if (Test-AgentContractProperty -Object $request -Name "Model") {
        $requestedModel = $request.Model
    }
    if (-not (Test-AgentContractProperty -Object $request -Name "ProjectRoot")) {
        throw "Agent Request is missing ProjectRoot."
    }

    $projectRoot = [System.IO.Path]::GetFullPath([string]$request.ProjectRoot)
    [void](Resolve-AgentContractPath `
        -ProjectRoot $projectRoot `
        -CandidatePath $requestFullPath `
        -Description "RequestFile")
    [void](Resolve-AgentContractPath `
        -ProjectRoot $projectRoot `
        -CandidatePath $resultFullPath `
        -Description "ResultFile")
    $resultPathIsSafe = $true

    [void](Assert-AgentRequestContract `
        -Request $request `
        -ExpectedProjectRoot $projectRoot)

    [System.IO.File]::WriteAllText(
        [string]$request.StdoutFile,
        "",
        (New-Object System.Text.UTF8Encoding($true))
    )
    [System.IO.File]::WriteAllText(
        [string]$request.StderrFile,
        "",
        (New-Object System.Text.UTF8Encoding($true))
    )

    if ([string]$request.Runtime.Name -ne "codex") {
        throw "Runtime.Name is not compatible with the Codex Adapter."
    }
    if (-not (Test-AgentContractProperty -Object $request.Options -Name "Sandbox") -or
        [string]::IsNullOrWhiteSpace([string]$request.Options.Sandbox)) {
        throw "Agent Options.Sandbox must not be empty."
    }
    $sandbox = [string]$request.Options.Sandbox

    $modelName = $null
    $modelReasoning = $null
    if (Test-AgentContractProperty -Object $request.Model -Name "Name") {
        $modelName = $request.Model.Name
    }
    if (Test-AgentContractProperty -Object $request.Model -Name "Reasoning") {
        $modelReasoning = $request.Model.Reasoning
    }
    if (($null -ne $modelName) -or ($null -ne $modelReasoning)) {
        throw (
            "This Adapter does not map explicit Model settings. " +
            "Use null to select the Runtime defaults."
        )
    }

    $nativeRuntime = @(Get-Command "codex.exe" -All -ErrorAction SilentlyContinue) |
        Where-Object {
            $_.CommandType -eq "Application" -and
            (Test-Path -LiteralPath $_.Source -PathType Leaf)
        } |
        Select-Object -First 1
    $runtimeCommands = @(Get-Command "codex" -All -ErrorAction SilentlyContinue)
    $runtimeScript = $runtimeCommands |
        Where-Object {
            ($_.CommandType -eq "ExternalScript") -and
            ([System.IO.Path]::GetExtension($_.Source) -eq ".ps1") -and
            (Test-Path -LiteralPath $_.Source -PathType Leaf)
        } |
        Select-Object -First 1
    if ($null -eq $nativeRuntime -and $null -eq $runtimeScript) {
        $adapterStatus = "failed_to_start"
        $exitCode = 127
        $message = "The Codex executable or PowerShell launcher was not found."
    }
    else {
        if ($null -ne $nativeRuntime) {
            $runtimeFile = [System.IO.Path]::GetFullPath($nativeRuntime.Source)
            $runtimeArguments = @("exec", "--sandbox", $sandbox, "-")
        }
        else {
            $hostCommand = Get-Command "powershell.exe" -ErrorAction Stop
            $runtimeFile = $hostCommand.Source
            $runtimeArguments = @(
                "-NoLogo",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                ('"{0}"' -f ([System.IO.Path]::GetFullPath($runtimeScript.Source))),
                "exec",
                "--sandbox",
                $sandbox,
                "-"
            )
        }
        try {
            $process = Start-Process `
                -FilePath $runtimeFile `
                -ArgumentList $runtimeArguments `
                -WorkingDirectory $projectRoot `
                -RedirectStandardInput ([string]$request.PromptFile) `
                -RedirectStandardOutput ([string]$request.StdoutFile) `
                -RedirectStandardError ([string]$request.StderrFile) `
                -NoNewWindow `
                -Wait `
                -PassThru

            $exitCode = [int]$process.ExitCode
            if ($exitCode -eq 0) {
                $adapterStatus = "completed"
                $message = "Agent Runtime completed successfully."
            }
            else {
                $adapterStatus = "failed"
                $message = "Agent Runtime returned a non-zero exit code."
            }
        }
        catch {
            $adapterStatus = "failed_to_start"
            $exitCode = 127
            $message = "Unable to start Agent Runtime: " + $_.Exception.Message
            [System.IO.File]::WriteAllText(
                [string]$request.StderrFile,
                $message,
                (New-Object System.Text.UTF8Encoding($true))
            )
        }
    }
}
catch {
    $adapterStatus = "invalid_configuration"
    $exitCode = 64
    $message = $_.Exception.Message
    if ($null -ne $request -and
        (Test-AgentContractProperty -Object $request -Name "StderrFile")) {
        try {
            [System.IO.File]::WriteAllText(
                [string]$request.StderrFile,
                $message,
                (New-Object System.Text.UTF8Encoding($true))
            )
        }
        catch {
            [Console]::Error.WriteLine($_.Exception.Message)
        }
    }
}
finally {
    $finishedAt = [DateTimeOffset]::UtcNow
    try {
        if ($resultPathIsSafe) {
            Write-AdapterResult
        }
        else {
            [Console]::Error.WriteLine(
                "Agent Result was not written because ResultFile was not validated."
            )
        }
    }
    catch {
        [Console]::Error.WriteLine(
            "Unable to write Agent Result: " + $_.Exception.Message
        )
        $exitCode = 74
    }
}

exit ([int]$exitCode)
