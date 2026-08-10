[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ProjectRoot,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ReportPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

try {
    $root = [System.IO.Path]::GetFullPath($ProjectRoot)
    $validationScript = [System.IO.Path]::GetFullPath(
        (Join-Path $root "automation\run_validation.ps1")
    )
    $report = [System.IO.Path]::GetFullPath($ReportPath)

    if (-not (Test-Path -LiteralPath $validationScript -PathType Leaf)) {
        throw "The project validation script was not found."
    }
    if (Test-Path -LiteralPath $report -PathType Leaf) {
        Remove-Item -LiteralPath $report
    }

    $hostCommand = Get-Command "powershell.exe" -ErrorAction Stop
    $process = Start-Process `
        -FilePath $hostCommand.Source `
        -ArgumentList @(
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            ('"{0}"' -f $validationScript)
        ) `
        -WorkingDirectory $root `
        -NoNewWindow `
        -Wait `
        -PassThru

    if (-not (Test-Path -LiteralPath $report -PathType Leaf)) {
        [Console]::Error.WriteLine(
            "Validation did not create the configured report."
        )
        exit 2
    }

    exit ([int]$process.ExitCode)
}
catch {
    [Console]::Error.WriteLine(
        "Validation adapter error: " + $_.Exception.Message
    )
    exit 2
}
