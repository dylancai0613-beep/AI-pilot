[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "New")]
    [ValidateNotNullOrEmpty()]
    [string]$TaskFile,

    [Parameter(Mandatory = $true, ParameterSetName = "Resume")]
    [ValidateNotNullOrEmpty()]
    [string]$ResumeRunId,

    [Parameter(ParameterSetName = "New")]
    [ValidateRange(1, 5)]
    [int]$MaxAttempts
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$configFile = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot "project.config.psd1")
)
$coreScript = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot "core\run_autonomous_task.ps1")
)

$invokeParameters = @{
    ProjectRoot = $projectRoot
    ConfigFile = $configFile
}
if ($PSCmdlet.ParameterSetName -eq "Resume") {
    $invokeParameters.ResumeRunId = $ResumeRunId
}
else {
    $invokeParameters.TaskFile = $TaskFile
}
if ($PSCmdlet.ParameterSetName -eq "New" -and
    $PSBoundParameters.ContainsKey("MaxAttempts")) {
    $invokeParameters.MaxAttempts = $MaxAttempts
}

& $coreScript @invokeParameters
exit $LASTEXITCODE
