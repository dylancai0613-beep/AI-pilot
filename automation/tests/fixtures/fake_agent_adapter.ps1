[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestFile,
    [Parameter(Mandatory = $true)][string]$ResultFile
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$contract = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot "..\..\contracts\AgentContract.ps1")
)
. $contract
$request = Read-AgentContractJson $RequestFile "Agent Request"
[void](Assert-AgentRequestContract $request ([string]$request.ProjectRoot))
[System.IO.File]::WriteAllText([string]$request.StdoutFile, "fake stdout")
[System.IO.File]::WriteAllText([string]$request.StderrFile, "")
$started = [DateTimeOffset]::UtcNow
if ([string]$request.InvocationType -eq "review") {
    $prompt = [System.IO.File]::ReadAllText([string]$request.PromptFile)
    $pathMatch = [regex]::Match(
        $prompt,
        '[A-Za-z]:\\[^\r\n]*current-review-cycle-[0-9]+\.result\.json'
    )
    $reviewMatch = [regex]::Match($prompt, 'ReviewId[^\r\n]*"(review-cycle-[0-9]+)"')
    $attemptMatch = [regex]::Match(
        $prompt,
        'ReviewerAgentAttemptId[^\r\n]*"(agent-attempt-[0-9]+)"'
    )
    if (-not $pathMatch.Success -or -not $reviewMatch.Success -or
        -not $attemptMatch.Success) {
        throw "Fake Reviewer could not parse the Review Result instructions."
    }
    $review = [PSCustomObject][ordered]@{
        SchemaVersion = 1
        ReviewId = $reviewMatch.Groups[1].Value
        ReviewerAgentAttemptId = $attemptMatch.Groups[1].Value
        Verdict = "approved"
        Summary = "Fake review approved."
        Findings = @()
        CreatedAt = [DateTimeOffset]::UtcNow.ToString("o")
    }
    $json = $review | ConvertTo-Json -Depth 32
    [System.IO.File]::WriteAllText(
        $pathMatch.Value.Trim(),
        $json,
        (New-Object System.Text.UTF8Encoding($false))
    )
}
$result = [PSCustomObject][ordered]@{
    SchemaVersion = 1
    AttemptId = [string]$request.AttemptId
    AdapterStatus = "completed"
    ExitCode = 0
    StartedAt = $started.ToString("o")
    FinishedAt = [DateTimeOffset]::UtcNow.ToString("o")
    Runtime = $request.Runtime
    RequestedModel = $request.Model
    ResolvedModel = $null
    Message = "Fake Agent completed."
}
Write-AgentContractJson $ResultFile $result
exit 0
