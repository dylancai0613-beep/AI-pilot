[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ProjectRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

try {
    $root = [System.IO.Path]::GetFullPath($ProjectRoot)
    if ($null -eq (Get-Command "docker" -ErrorAction SilentlyContinue)) {
        throw "The docker command is not available."
    }

    Push-Location $root
    try {
        $LASTEXITCODE = 0
        & docker compose down 2>&1 | ForEach-Object { Write-Output $_.ToString() }
        $downExitCode = $LASTEXITCODE
        if ($null -eq $downExitCode) {
            $downExitCode = 1
        }
        if ($downExitCode -ne 0) {
            exit ([int]$downExitCode)
        }

        $LASTEXITCODE = 0
        $remaining = @(
            & docker compose ps -a -q 2>&1 |
                ForEach-Object { $_.ToString() }
        )
        $statusExitCode = $LASTEXITCODE
        if ($null -eq $statusExitCode) {
            $statusExitCode = 1
        }
        if ($statusExitCode -ne 0) {
            $remaining | ForEach-Object { [Console]::Error.WriteLine($_) }
            exit ([int]$statusExitCode)
        }
        if ($remaining.Count -ne 0) {
            $remaining | ForEach-Object { [Console]::Error.WriteLine($_) }
            [Console]::Error.WriteLine(
                "Project resources remain after cleanup."
            )
            exit 1
        }
    }
    finally {
        Pop-Location
    }

    exit 0
}
catch {
    [Console]::Error.WriteLine(
        "Cleanup adapter error: " + $_.Exception.Message
    )
    exit 1
}
