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

    $request = Read-AgentContractJson $requestFullPath "Agent Request"
    if (Test-AgentContractProperty $request "AttemptId") {
        $attemptId = [string]$request.AttemptId
    }
    if (Test-AgentContractProperty $request "Runtime") {
        $runtime = $request.Runtime
    }
    if (Test-AgentContractProperty $request "Model") {
        $requestedModel = $request.Model
    }
    if (-not (Test-AgentContractProperty $request "ProjectRoot")) {
        throw "Agent Request is missing ProjectRoot."
    }

    $projectRoot = [System.IO.Path]::GetFullPath([string]$request.ProjectRoot)
    [void](Resolve-AgentContractPath $projectRoot $requestFullPath "RequestFile")
    [void](Resolve-AgentContractPath $projectRoot $resultFullPath "ResultFile")
    $resultPathIsSafe = $true
    [void](Assert-AgentRequestContract $request $projectRoot)

    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText([string]$request.StdoutFile, "", $utf8Bom)
    [System.IO.File]::WriteAllText([string]$request.StderrFile, "", $utf8Bom)

    if ([string]$request.Runtime.Name -ne "claude-code") {
        throw "Runtime.Name is not compatible with the Claude Code Adapter."
    }

    $allowedOptionNames = @("PermissionMode", "AllowedTools")
    $unexpectedOptions = @(
        $request.Options.PSObject.Properties.Name |
            Where-Object { $allowedOptionNames -notcontains $_ }
    )
    if ($unexpectedOptions.Count -ne 0) {
        throw ("Unsupported Agent Options: " + ($unexpectedOptions -join ", "))
    }
    if (-not (Test-AgentContractProperty $request.Options "PermissionMode") -or
        [string]::IsNullOrWhiteSpace([string]$request.Options.PermissionMode)) {
        throw "Agent Options.PermissionMode must not be empty."
    }
    $permissionMode = [string]$request.Options.PermissionMode
    if ($permissionMode -notin @("acceptEdits", "auto", "manual", "dontAsk", "plan")) {
        throw "Agent Options.PermissionMode is not supported by this Adapter."
    }
    $allowedTools = @()
    if (Test-AgentContractProperty $request.Options "AllowedTools") {
        if (-not ($request.Options.AllowedTools -is [System.Array])) {
            throw "Agent Options.AllowedTools must be an Array."
        }
        foreach ($toolName in @($request.Options.AllowedTools)) {
            if (-not ($toolName -is [string]) -or
                [string]::IsNullOrWhiteSpace([string]$toolName) -or
                [string]$toolName -match "[,\r\n]") {
                throw "Agent Options.AllowedTools contains an invalid tool name."
            }
            $allowedTools += [string]$toolName
        }
    }

    $modelName = $null
    $modelReasoning = $null
    if (Test-AgentContractProperty $request.Model "Name") {
        $modelName = $request.Model.Name
    }
    if (Test-AgentContractProperty $request.Model "Reasoning") {
        $modelReasoning = $request.Model.Reasoning
    }
    if ($null -ne $modelName -and
        [string]::IsNullOrWhiteSpace([string]$modelName)) {
        throw "Agent Model.Name must be null or a non-empty string."
    }
    if ($null -ne $modelReasoning -and
        [string]$modelReasoning -notin @("low", "medium", "high", "xhigh", "max")) {
        throw "Agent Model.Reasoning is not supported by this Adapter."
    }

    $runtimeCommands = @(Get-Command "claude" -All -ErrorAction SilentlyContinue)
    $runtimeScript = $runtimeCommands |
        Where-Object {
            $_.CommandType -eq "ExternalScript" -and
            [System.IO.Path]::GetExtension($_.Source) -eq ".ps1" -and
            (Test-Path -LiteralPath $_.Source -PathType Leaf)
        } |
        Select-Object -First 1
    if ($null -eq $runtimeScript) {
        $adapterStatus = "failed_to_start"
        $exitCode = 127
        $message = "The Claude Code PowerShell launcher was not found."
    }
    else {
        $arguments = @(
            "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", ('"{0}"' -f ([System.IO.Path]::GetFullPath($runtimeScript.Source))),
            "--print", "--output-format", "text", "--no-session-persistence", "--safe-mode",
            "--permission-mode", $permissionMode
        )
        if ($allowedTools.Count -gt 0) {
            $arguments += @("--allowedTools", ($allowedTools -join ","))
        }
        if ($null -ne $modelName) {
            $arguments += @("--model", [string]$modelName)
        }
        if ($null -ne $modelReasoning) {
            $arguments += @("--effort", [string]$modelReasoning)
        }

        $hostCommand = Get-Command "powershell.exe" -ErrorAction Stop
        try {
            $process = Start-Process `
                -FilePath $hostCommand.Source `
                -ArgumentList $arguments `
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
                [string]$request.StderrFile, $message, $utf8Bom
            )
        }
    }
}
catch {
    $adapterStatus = "invalid_configuration"
    $exitCode = 64
    $message = $_.Exception.Message
    if ($null -ne $request -and
        (Test-AgentContractProperty $request "StderrFile")) {
        try {
            [System.IO.File]::WriteAllText(
                [string]$request.StderrFile,
                $message,
                (New-Object System.Text.UTF8Encoding($true))
            )
        }
        catch { [Console]::Error.WriteLine($_.Exception.Message) }
    }
}
finally {
    $finishedAt = [DateTimeOffset]::UtcNow
    try {
        if ($resultPathIsSafe) { Write-AdapterResult }
        else {
            [Console]::Error.WriteLine(
                "Agent Result was not written because ResultFile was not validated."
            )
        }
    }
    catch {
        [Console]::Error.WriteLine("Unable to write Agent Result: " + $_.Exception.Message)
        $exitCode = 74
    }
}

exit ([int]$exitCode)
