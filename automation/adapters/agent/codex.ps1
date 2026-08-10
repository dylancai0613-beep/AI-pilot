[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ProjectRoot,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PromptFile,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$StdoutFile,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$StderrFile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

try {
    $runtimeCommands = @(Get-Command "codex" -All -ErrorAction SilentlyContinue)
    $runtimeScript = $runtimeCommands |
        Where-Object {
            ($_.CommandType -eq "ExternalScript") -and
            ([System.IO.Path]::GetExtension($_.Source) -eq ".ps1") -and
            (Test-Path -LiteralPath $_.Source -PathType Leaf)
        } |
        Select-Object -First 1
    if ($null -eq $runtimeScript) {
        throw "The Codex PowerShell launcher was not found."
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
            ('"{0}"' -f ([System.IO.Path]::GetFullPath($runtimeScript.Source))),
            "exec",
            "--sandbox",
            "workspace-write",
            "-"
        ) `
        -WorkingDirectory ([System.IO.Path]::GetFullPath($ProjectRoot)) `
        -RedirectStandardInput ([System.IO.Path]::GetFullPath($PromptFile)) `
        -RedirectStandardOutput ([System.IO.Path]::GetFullPath($StdoutFile)) `
        -RedirectStandardError ([System.IO.Path]::GetFullPath($StderrFile)) `
        -NoNewWindow `
        -Wait `
        -PassThru

    exit ([int]$process.ExitCode)
}
catch {
    $message = "Agent adapter error: " + $_.Exception.Message
    [System.IO.File]::WriteAllText(
        [System.IO.Path]::GetFullPath($StderrFile),
        $message,
        (New-Object System.Text.UTF8Encoding($true))
    )
    exit 127
}
