[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$contractScript = Join-Path $projectRoot "automation\contracts\AgentContract.ps1"
$adapterScript = Join-Path $projectRoot "automation\adapters\agent\codex.ps1"
. $contractScript

$temporaryDirectory = Join-Path `
    $PSScriptRoot `
    (".tmp-codex-adapter-" + [Guid]::NewGuid().ToString("N"))

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

    # The incompatible Runtime forces a pre-launch configuration failure. This
    # exercises the production Adapter Contract without starting the real CLI.
    $request = [PSCustomObject][ordered]@{
        SchemaVersion = 1
        AttemptId = "adapter-contract-test-01"
        InvocationType = "development"
        ProjectRoot = $projectRoot
        TaskFile = $taskFile
        PromptFile = $promptFile
        StdoutFile = $stdoutFile
        StderrFile = $stderrFile
        Runtime = [PSCustomObject][ordered]@{ Name = "incompatible-runtime" }
        Model = [PSCustomObject][ordered]@{ Name = $null; Reasoning = $null }
        Options = [PSCustomObject][ordered]@{ Sandbox = "test-only" }
    }
    Write-AgentContractJson -LiteralPath $requestFile -InputObject $request
    $parsedRequest = Read-AgentContractJson $requestFile "Agent Request"
    [void](Assert-AgentRequestContract $parsedRequest $projectRoot)

    $hostCommand = Get-Command "powershell.exe" -ErrorAction Stop
    $process = Start-Process `
        -FilePath $hostCommand.Source `
        -ArgumentList @(
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            ('"{0}"' -f $adapterScript),
            "-RequestFile",
            ('"{0}"' -f $requestFile),
            "-ResultFile",
            ('"{0}"' -f $resultFile)
        ) `
        -WorkingDirectory $projectRoot `
        -NoNewWindow `
        -Wait `
        -PassThru

    if ($process.ExitCode -ne 64) {
        throw ("Expected Adapter exit code 64, got " + $process.ExitCode)
    }
    $result = Read-AgentContractJson $resultFile "Agent Result"
    [void](Assert-AgentOutputFiles $parsedRequest)
    [void](Assert-AgentResultContract $result $parsedRequest $process.ExitCode)
    if ($result.AdapterStatus -ne "invalid_configuration") {
        throw ("Unexpected AdapterStatus: " + $result.AdapterStatus)
    }
    if ($null -ne $result.ResolvedModel) {
        throw "ResolvedModel must remain null when the Runtime did not start."
    }

    Write-Output "CODEX ADAPTER CONTRACT TEST PASSED (REAL RUNTIME NOT STARTED)"
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
