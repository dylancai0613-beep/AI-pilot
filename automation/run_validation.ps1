[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$script:ReportLines = New-Object "System.Collections.Generic.List[string]"
$script:CurrentStep = "Initialize validation"
$script:CurrentCommand = "(none)"
$script:ValidationSucceeded = $false
$script:FailureStep = ""
$script:FailureCommand = ""
$script:FailureMessage = ""

$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$ComposeFile = Join-Path $ProjectRoot "docker-compose.yml"
$ReportDirectory = Join-Path $ProjectRoot "automation\reports"
$ReportPath = Join-Path $ReportDirectory "validation-latest.txt"
$BaseUrl = "http://localhost:8000"

function Add-ReportLine {
    param([AllowEmptyString()][string]$Line)

    [void]$script:ReportLines.Add($Line)
    Write-Host $Line
}

function Add-Section {
    param([string]$Title)

    Add-ReportLine ""
    Add-ReportLine ("===== " + $Title + " =====")
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [switch]$AllowFailure
    )

    $script:CurrentCommand = $Command
    Add-ReportLine ("$ " + $Command)

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $outputLines = @(& $Action 2>&1 | ForEach-Object { $_.ToString() })
        $commandExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($null -eq $commandExitCode) {
        $commandExitCode = 0
    }

    if ($outputLines.Count -gt 0) {
        foreach ($line in $outputLines) {
            Add-ReportLine $line
        }
    }
    else {
        Add-ReportLine "(no output)"
    }
    Add-ReportLine ("Exit code: " + $commandExitCode)

    $result = [PSCustomObject]@{
        ExitCode = [int]$commandExitCode
        Output = ($outputLines -join [Environment]::NewLine)
    }

    if (($commandExitCode -ne 0) -and (-not $AllowFailure)) {
        throw ("Command failed with exit code {0}: {1}" -f $commandExitCode, $Command)
    }

    return $result
}

function Invoke-Utf8HttpRequest {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("GET", "POST")][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Body = ""
    )

    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Proxy = $null
    $request.Method = $Method
    $request.Accept = "application/json, text/html"
    $request.Timeout = 10000
    $request.ReadWriteTimeout = 10000

    if ($Method -eq "POST") {
        $request.ContentType = "application/json; charset=utf-8"
        $requestBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $request.ContentLength = $requestBytes.Length
        $requestStream = $null
        try {
            $requestStream = $request.GetRequestStream()
            $requestStream.Write($requestBytes, 0, $requestBytes.Length)
        }
        finally {
            if ($null -ne $requestStream) {
                $requestStream.Dispose()
            }
        }
    }

    $response = $null
    $reader = $null
    try {
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
        $reader = New-Object System.IO.StreamReader(
            $response.GetResponseStream(),
            [System.Text.Encoding]::UTF8,
            $true
        )
        $responseBody = $reader.ReadToEnd()

        return [PSCustomObject]@{
            StatusCode = [int]$response.StatusCode
            ContentType = [string]$response.ContentType
            Body = $responseBody
        }
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
        if ($null -ne $response) {
            $response.Dispose()
        }
    }
}

function Add-FailureDiagnostics {
    Add-Section "Failure diagnostics"

    if ($null -eq (Get-Command docker -ErrorAction SilentlyContinue)) {
        Add-ReportLine "Docker status: unavailable because the docker command was not found."
        Add-ReportLine "Recent Docker logs: unavailable because the docker command was not found."
        return
    }

    Push-Location $ProjectRoot
    try {
        Add-ReportLine "Docker status:"
        [void](Invoke-ExternalCommand `
            -Command "docker compose ps -a" `
            -Action { & docker compose ps -a } `
            -AllowFailure)

        Add-ReportLine "Recent Docker logs (last 200 lines):"
        [void](Invoke-ExternalCommand `
            -Command "docker compose logs --tail 200" `
            -Action { & docker compose logs --tail 200 } `
            -AllowFailure)
    }
    finally {
        Pop-Location
    }
}

Add-ReportLine "Travel Cost Pilot - Validation Report"
Add-ReportLine ("Started: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"))
Add-ReportLine ("PowerShell: " + $PSVersionTable.PSVersion.ToString())
Add-ReportLine ("Project root: " + $ProjectRoot)
Add-ReportLine ("Report path: " + $ReportPath)

try {
    Add-Section "1. Project root"
    $script:CurrentStep = "Confirm current working directory is the project root"
    $script:CurrentCommand = "Get-Location"
    $currentDirectory = [System.IO.Path]::GetFullPath((Get-Location).Path)
    Add-ReportLine ("Current directory: " + $currentDirectory)
    if (-not [string]::Equals(
        $currentDirectory.TrimEnd("\"),
        $ProjectRoot.TrimEnd("\"),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw ("Run this script from the project root: " + $ProjectRoot)
    }
    if (-not (Test-Path -LiteralPath $ComposeFile -PathType Leaf)) {
        throw ("docker-compose.yml was not found at: " + $ComposeFile)
    }
    Add-ReportLine "Project root check: PASSED"

    Add-Section "2. Docker availability"
    $script:CurrentStep = "Check Docker command and engine"
    $script:CurrentCommand = "Get-Command docker"
    if ($null -eq (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "The docker command is not available."
    }
    [void](Invoke-ExternalCommand `
        -Command "docker --version" `
        -Action { & docker --version })
    [void](Invoke-ExternalCommand `
        -Command "docker info" `
        -Action { & docker info })

    Add-Section "3. Docker Compose availability"
    $script:CurrentStep = "Check docker compose"
    [void](Invoke-ExternalCommand `
        -Command "docker compose version" `
        -Action { & docker compose version })

    Add-Section "4. Initial Git status"
    $script:CurrentStep = "Record current Git status"
    [void](Invoke-ExternalCommand `
        -Command "git status --short --branch" `
        -Action { & git status --short --branch })

    Add-Section "5. Stop existing project containers"
    $script:CurrentStep = "Stop existing project containers"
    [void](Invoke-ExternalCommand `
        -Command "docker compose down" `
        -Action { & docker compose down })

    Add-Section "6. Build and start project"
    $script:CurrentStep = "Build and start project containers"
    [void](Invoke-ExternalCommand `
        -Command "docker compose up --build -d" `
        -Action { & docker compose up --build -d })

    Add-Section "7. Wait for app health"
    $script:CurrentStep = "Wait up to 60 seconds for the app container to become healthy"
    $healthStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $healthy = $false
    $lastHealthStatus = "container not found"

    while ($healthStopwatch.Elapsed.TotalSeconds -lt 60) {
        $containerResult = Invoke-ExternalCommand `
            -Command "docker compose ps -q app" `
            -Action { & docker compose ps -q app }
        $containerId = $containerResult.Output.Trim()

        if ($containerId.Length -gt 0) {
            $inspectResult = Invoke-ExternalCommand `
                -Command ("docker inspect --format health-status " + $containerId) `
                -Action {
                    & docker inspect `
                        --format "{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}" `
                        $containerId
                }
            $lastHealthStatus = $inspectResult.Output.Trim()
            Add-ReportLine ("Observed app health: " + $lastHealthStatus)
            if ($lastHealthStatus -eq "healthy") {
                $healthy = $true
                break
            }
        }

        Start-Sleep -Seconds 2
    }
    $healthStopwatch.Stop()

    if (-not $healthy) {
        throw ("App container did not become healthy within 60 seconds. Last status: " + $lastHealthStatus)
    }
    Add-ReportLine ("Healthy after {0:N1} seconds." -f $healthStopwatch.Elapsed.TotalSeconds)

    Add-Section "8. Pytest"
    $script:CurrentStep = "Run all nine Pytest tests in the app container"
    $pytestResult = Invoke-ExternalCommand `
        -Command "docker compose exec app pytest -q" `
        -Action { & docker compose exec app pytest -q }
    if ($pytestResult.Output -notmatch "(?m)\b9 passed\b") {
        throw "Pytest completed successfully, but the expected '9 passed' summary was not found."
    }
    Add-ReportLine "Pytest count check: 9 passed"

    Add-Section "9. Health endpoint"
    $script:CurrentStep = "Validate GET /health"
    $script:CurrentCommand = "GET " + $BaseUrl + "/health"
    Add-ReportLine ("$ " + $script:CurrentCommand)
    $healthResponse = Invoke-Utf8HttpRequest `
        -Method "GET" `
        -Uri ($BaseUrl + "/health")
    Add-ReportLine ("HTTP status: " + $healthResponse.StatusCode)
    Add-ReportLine ("UTF-8 response: " + $healthResponse.Body)
    $healthPayload = $healthResponse.Body | ConvertFrom-Json
    if (($healthResponse.StatusCode -ne 200) -or ($healthPayload.status -ne "ok")) {
        throw "The health endpoint did not return HTTP 200 with status 'ok'."
    }

    Add-Section "10. Homepage"
    $script:CurrentStep = "Validate GET /"
    $script:CurrentCommand = "GET " + $BaseUrl + "/"
    Add-ReportLine ("$ " + $script:CurrentCommand)
    $homeResponse = Invoke-Utf8HttpRequest `
        -Method "GET" `
        -Uri ($BaseUrl + "/")
    Add-ReportLine ("HTTP status: " + $homeResponse.StatusCode)
    Add-ReportLine ("UTF-8 response length: " + $homeResponse.Body.Length)
    if ($homeResponse.StatusCode -ne 200) {
        throw "The homepage did not return HTTP 200."
    }
    $requiredElementIds = @(
        'id="origin"',
        'id="destination"',
        'id="passengers"',
        'id="submit-button"',
        'id="results"',
        'id="error-message"'
    )
    foreach ($requiredElementId in $requiredElementIds) {
        if (-not $homeResponse.Body.Contains($requiredElementId)) {
            throw ("The homepage is missing required element: " + $requiredElementId)
        }
    }
    Add-ReportLine "Homepage required elements: PASSED"

    Add-Section "11-14. UTF-8 route comparison"
    $script:CurrentStep = "Validate Guangzhou to Shenzhen comparison for two passengers"
    $script:CurrentCommand = "POST " + $BaseUrl + "/api/compare"

    $guangzhou = "$([char]0x5E7F)$([char]0x5DDE)"
    $shenzhen = "$([char]0x6DF1)$([char]0x5733)"
    $highSpeedRail = "$([char]0x9AD8)$([char]0x94C1)"
    $coach = "$([char]0x957F)$([char]0x9014)$([char]0x6C7D)$([char]0x8F66)"
    $rideHailing = "$([char]0x7F51)$([char]0x7EA6)$([char]0x8F66)"

    $requestObject = [ordered]@{
        origin = $guangzhou
        destination = $shenzhen
        passengers = 2
    }
    $requestJson = $requestObject | ConvertTo-Json -Compress
    Add-ReportLine ("$ " + $script:CurrentCommand)
    Add-ReportLine ("UTF-8 request: " + $requestJson)
    $compareResponse = Invoke-Utf8HttpRequest `
        -Method "POST" `
        -Uri ($BaseUrl + "/api/compare") `
        -Body $requestJson
    Add-ReportLine ("HTTP status: " + $compareResponse.StatusCode)
    Add-ReportLine ("UTF-8 response: " + $compareResponse.Body)

    if ($compareResponse.StatusCode -ne 200) {
        throw "The comparison endpoint did not return HTTP 200."
    }
    $comparePayload = $compareResponse.Body | ConvertFrom-Json
    $expectedOptions = @(
        [PSCustomObject]@{ Mode = $highSpeedRail; Cost = 160; Duration = 60 },
        [PSCustomObject]@{ Mode = $coach; Cost = 130; Duration = 150 },
        [PSCustomObject]@{ Mode = $rideHailing; Cost = 360; Duration = 120 }
    )
    foreach ($expectedOption in $expectedOptions) {
        $matchingOptions = @(
            $comparePayload.options |
                Where-Object { $_.mode -eq $expectedOption.Mode }
        )
        if ($matchingOptions.Count -ne 1) {
            throw ("Expected exactly one comparison option for mode: " + $expectedOption.Mode)
        }
        $actualOption = $matchingOptions[0]
        if ([decimal]$actualOption.total_cost -ne [decimal]$expectedOption.Cost) {
            throw ("Unexpected total cost for mode: " + $expectedOption.Mode)
        }
        if ([int]$actualOption.duration_minutes -ne [int]$expectedOption.Duration) {
            throw ("Unexpected duration for mode: " + $expectedOption.Mode)
        }
        Add-ReportLine (
            "Validated option: {0}, {1} CNY, {2} minutes" -f `
                $expectedOption.Mode,
                $expectedOption.Cost,
                $expectedOption.Duration
        )
    }

    Add-Section "15-16. Docker logs"
    $script:CurrentStep = "Read and scan the latest 200 lines of Docker logs"
    $logsResult = Invoke-ExternalCommand `
        -Command "docker compose logs --tail 200" `
        -Action { & docker compose logs --tail 200 }
    $forbiddenLogPattern = "(?i)(Traceback|ERROR|FATAL|Exception)"
    $logMatches = [regex]::Matches($logsResult.Output, $forbiddenLogPattern)
    if ($logMatches.Count -gt 0) {
        $matchedTerms = @($logMatches | ForEach-Object { $_.Value } | Select-Object -Unique)
        throw ("Docker logs contain forbidden error terms: " + ($matchedTerms -join ", "))
    }
    Add-ReportLine "Docker log scan: no Traceback, ERROR, FATAL, or Exception entries found."

    $script:ValidationSucceeded = $true
}
catch {
    $script:ValidationSucceeded = $false
    $script:FailureStep = $script:CurrentStep
    $script:FailureCommand = $script:CurrentCommand
    $script:FailureMessage = $_.Exception.Message

    Add-Section "Validation failure"
    Add-ReportLine ("Failed step: " + $script:FailureStep)
    Add-ReportLine ("Command: " + $script:FailureCommand)
    Add-ReportLine ("Error: " + $script:FailureMessage)
    if ($_.ScriptStackTrace) {
        Add-ReportLine ("Stack: " + $_.ScriptStackTrace)
    }

    $savedStep = $script:CurrentStep
    $savedCommand = $script:CurrentCommand
    try {
        Add-FailureDiagnostics
    }
    catch {
        Add-ReportLine ("Failed to collect complete diagnostics: " + $_.Exception.Message)
    }
    finally {
        $script:CurrentStep = $savedStep
        $script:CurrentCommand = $savedCommand
    }
}
finally {
    Add-Section "17-18. Final cleanup"
    $cleanupFailed = $false
    $cleanupError = ""

    try {
        Push-Location $ProjectRoot
        try {
            $cleanupResult = Invoke-ExternalCommand `
                -Command "docker compose down" `
                -Action { & docker compose down } `
                -AllowFailure
            if ($cleanupResult.ExitCode -ne 0) {
                $cleanupFailed = $true
                $cleanupError = "docker compose down returned exit code " + $cleanupResult.ExitCode
            }
        }
        finally {
            Pop-Location
        }
    }
    catch {
        $cleanupFailed = $true
        $cleanupError = $_.Exception.Message
        Add-ReportLine ("Cleanup error: " + $cleanupError)
    }

    if ($cleanupFailed) {
        $script:ValidationSucceeded = $false
        if ([string]::IsNullOrEmpty($script:FailureStep)) {
            $script:FailureStep = "Stop project containers in finally"
            $script:FailureCommand = "docker compose down"
            $script:FailureMessage = $cleanupError
        }
    }
    else {
        Add-ReportLine "Final docker compose down: PASSED"
    }

    try {
        Push-Location $ProjectRoot
        try {
            Add-ReportLine "Docker status after final cleanup:"
            $finalStatus = Invoke-ExternalCommand `
                -Command "docker compose ps -a -q" `
                -Action { & docker compose ps -a -q } `
                -AllowFailure
            if ($finalStatus.ExitCode -ne 0) {
                $script:ValidationSucceeded = $false
                if ([string]::IsNullOrEmpty($script:FailureStep)) {
                    $script:FailureStep = "Check Docker status after cleanup"
                    $script:FailureCommand = "docker compose ps -a -q"
                    $script:FailureMessage = "Unable to confirm that project containers stopped."
                }
            }
            elseif (-not [string]::IsNullOrWhiteSpace($finalStatus.Output)) {
                $script:ValidationSucceeded = $false
                if ([string]::IsNullOrEmpty($script:FailureStep)) {
                    $script:FailureStep = "Check Docker status after cleanup"
                    $script:FailureCommand = "docker compose ps -a -q"
                    $script:FailureMessage = "Project containers remain after docker compose down."
                }
            }
            else {
                Add-ReportLine "Docker final state: no project containers remain."
            }
        }
        finally {
            Pop-Location
        }
    }
    catch {
        $script:ValidationSucceeded = $false
        Add-ReportLine ("Final Docker status check error: " + $_.Exception.Message)
        if ([string]::IsNullOrEmpty($script:FailureStep)) {
            $script:FailureStep = "Check Docker status after cleanup"
            $script:FailureCommand = "docker compose ps -a -q"
            $script:FailureMessage = $_.Exception.Message
        }
    }
}

Add-Section "Result"
Add-ReportLine ("Finished: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"))
if ($script:ValidationSucceeded) {
    Add-ReportLine "VALIDATION PASSED"
    $processExitCode = 0
}
else {
    if (-not [string]::IsNullOrEmpty($script:FailureStep)) {
        Add-ReportLine ("Failed step: " + $script:FailureStep)
        Add-ReportLine ("Command: " + $script:FailureCommand)
        Add-ReportLine ("Error: " + $script:FailureMessage)
    }
    Add-ReportLine "VALIDATION FAILED"
    $processExitCode = 1
}

try {
    if (-not (Test-Path -LiteralPath $ReportDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $ReportDirectory -Force)
    }
    $utf8WithBom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllLines(
        $ReportPath,
        [string[]]$script:ReportLines,
        $utf8WithBom
    )
    Write-Host ("Report written to: " + $ReportPath)
}
catch {
    Write-Host ("Failed to write validation report: " + $_.Exception.Message)
    Write-Host "VALIDATION FAILED"
    $processExitCode = 2
}

exit $processExitCode
