[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TaskFile,

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
    TaskFile = $TaskFile
}
if ($PSBoundParameters.ContainsKey("MaxAttempts")) {
    $invokeParameters.MaxAttempts = $MaxAttempts
}

& $coreScript @invokeParameters
exit $LASTEXITCODE
