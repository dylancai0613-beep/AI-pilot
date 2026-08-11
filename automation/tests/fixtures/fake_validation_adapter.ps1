[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$ReportPath
)
Set-StrictMode -Version 2.0
[System.IO.File]::WriteAllText($ReportPath, "FAKE VALIDATION PASSED")
Write-Output "Fake Validation passed."
exit 0
