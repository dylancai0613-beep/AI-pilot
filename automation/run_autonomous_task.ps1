[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TaskFile,

    [ValidateRange(1, 5)]
    [int]$MaxAttempts = 3
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$script:ReportLines = New-Object "System.Collections.Generic.List[string]"
$script:CodexRecords = @()
$script:ValidationRecords = @()

$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$ProjectRootPrefix = $ProjectRoot.TrimEnd([char[]]@("\", "/")) +
    [System.IO.Path]::DirectorySeparatorChar
$AgentsFile = Join-Path $ProjectRoot "AGENTS.md"
$ValidationScript = Join-Path $ProjectRoot "automation\run_validation.ps1"
$ReportDirectory = Join-Path $ProjectRoot "automation\reports"
$AutonomousReportPath = Join-Path $ReportDirectory "autonomous-latest.txt"
$ValidationLatestPath = Join-Path $ReportDirectory "validation-latest.txt"

$TaskFullPath = ""
$TaskRelativePath = ""
$InitialBranch = "(not recorded)"
$InitialCommit = "(not recorded)"
$InitialGitStatus = "(not recorded)"
$FinalGitChanges = "(not recorded)"
$StartTime = Get-Date
$EndTime = $null
$WorkflowPassed = $false
$ReportsEnabled = $false
$FailureReason = ""
$DockerCleanupExitCode = $null
$DockerCleanupOutput = "(not attempted)"
$FinalDockerStatus = "(not checked)"
$CodexLauncher = "powershell.exe"
$CodexScriptPath = ""

function Add-ReportLine {
    param([AllowEmptyString()][string]$Line)

    [void]$script:ReportLines.Add($Line)
}

function Format-Timestamp {
    param([Parameter(Mandatory = $true)][datetime]$Value)

    return $Value.ToString("yyyy-MM-dd HH:mm:ss zzz")
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $utf8WithBom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8WithBom)
}

function Read-TextFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.File]::ReadAllText($Path)
}

function Remove-TemporaryFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path
    }
}

function Assert-PathInsideProject {
    param(
        [Parameter(Mandatory = $true)][string]$CandidatePath,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ([System.IO.Path]::IsPathRooted($CandidatePath)) {
        $fullPath = [System.IO.Path]::GetFullPath($CandidatePath)
    }
    else {
        $fullPath = [System.IO.Path]::GetFullPath(
            (Join-Path $ProjectRoot $CandidatePath)
        )
    }

    if (-not $fullPath.StartsWith(
        $ProjectRootPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw ("{0} must be inside the project root: {1}" -f `
            $Description,
            $ProjectRoot)
    }

    return $fullPath
}

function Get-ProjectRelativePath {
    param([Parameter(Mandatory = $true)][string]$FullPath)

    $checkedPath = Assert-PathInsideProject `
        -CandidatePath $FullPath `
        -Description "Path"
    return $checkedPath.Substring($ProjectRootPrefix.Length).Replace("\", "/")
}

function Invoke-GitReadCommand {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $LASTEXITCODE = 0
    $outputLines = @(
        & git @Arguments 2>&1 |
            ForEach-Object { $_.ToString() }
    )
    $commandExitCode = $LASTEXITCODE
    if ($null -eq $commandExitCode) {
        $commandExitCode = 0
    }

    if (($commandExitCode -ne 0) -and (-not $AllowFailure)) {
        throw (
            "git {0} failed with exit code {1}: {2}" -f `
                ($Arguments -join " "),
                $commandExitCode,
                ($outputLines -join [Environment]::NewLine)
        )
    }

    return [PSCustomObject]@{
        ExitCode = [int]$commandExitCode
        Lines = [string[]]$outputLines
        Text = ($outputLines -join [Environment]::NewLine)
    }
}

function Get-GitChangeText {
    $statusResult = Invoke-GitReadCommand `
        -Arguments @("status", "--short", "--untracked-files=all")
    if ($statusResult.Lines.Count -eq 0) {
        return "(clean)"
    }
    return $statusResult.Text
}

function Assert-GitIdentityUnchanged {
    $branchResult = Invoke-GitReadCommand `
        -Arguments @("rev-parse", "--abbrev-ref", "HEAD")
    $commitResult = Invoke-GitReadCommand `
        -Arguments @("rev-parse", "HEAD")
    $currentBranch = $branchResult.Text.Trim()
    $currentCommit = $commitResult.Text.Trim()

    if ($currentBranch -ne $InitialBranch) {
        throw (
            "The current Git branch changed from '{0}' to '{1}'. " +
            "The orchestrator will not attempt to restore it." -f `
                $InitialBranch,
                $currentBranch
        )
    }
    if ($currentCommit -ne $InitialCommit) {
        throw (
            "HEAD changed from '{0}' to '{1}'. " +
            "The orchestrator will not attempt to restore it." -f `
                $InitialCommit,
                $currentCommit
        )
    }
}

function New-DevelopmentPrompt {
    return @"
你正在项目根目录中执行一次受限的自动开发任务。

开始前必须完整读取：
1. AGENTS.md
2. 原任务文件：$TaskRelativePath
3. 与原任务直接相关的现有代码

严格执行原任务文件，并遵守其中允许和禁止修改范围。
不得运行 Docker 或任何依赖 Docker 的命令。
不得执行任何 Git 写操作，不得改变分支或 HEAD，不得提交代码。
不得扩大原任务允许修改范围。
可以执行不依赖 Docker 的静态检查。
完成后输出中文总结，但总控脚本不会把你的总结作为验收成功依据。
"@
}

function New-RepairPrompt {
    param(
        [Parameter(Mandatory = $true)][int]$RepairNumber,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ValidationReport,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$GitChanges
    )

    return @"
你正在项目根目录中执行第 $RepairNumber 次受限修复。

开始前必须完整读取：
1. AGENTS.md
2. 原任务文件：$TaskRelativePath
3. 与原任务直接相关的现有代码

严格遵守原任务文件的允许和禁止修改范围，不得扩大修改范围。
只修复下面真实验收报告中证明的问题，不要处理无关事项。
不得运行 Docker 或任何依赖 Docker 的命令。
不得执行任何 Git 写操作，不得改变分支或 HEAD，不得提交代码。
可以执行不依赖 Docker 的静态检查。
完成后输出中文总结，但总控脚本不会把你的总结作为验收成功依据。

===== 上一次宿主机验收报告全文 =====
$ValidationReport

===== 当前 Git 修改文件列表 =====
$GitChanges
"@
}

function Invoke-CodexAttempt {
    param(
        [Parameter(Mandatory = $true)][int]$Attempt,
        [Parameter(Mandatory = $true)][string]$InvocationType,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$CodexLauncher,
        [Parameter(Mandatory = $true)][string]$CodexScriptPath
    )

    $attemptText = "{0:D2}" -f $Attempt
    $logPath = Join-Path `
        $ReportDirectory `
        ("current-codex-attempt-{0}.log" -f $attemptText)
    $promptPath = Join-Path `
        $ReportDirectory `
        ("current-codex-attempt-{0}.prompt.tmp" -f $attemptText)
    $stdoutPath = Join-Path `
        $ReportDirectory `
        ("current-codex-attempt-{0}.stdout.tmp" -f $attemptText)
    $stderrPath = Join-Path `
        $ReportDirectory `
        ("current-codex-attempt-{0}.stderr.tmp" -f $attemptText)

    Write-Utf8File -Path $promptPath -Content $Prompt
    $attemptStart = Get-Date
    $processExitCode = -1
    $startError = ""

    Write-Host (
        "Starting Codex attempt {0:D2} ({1})." -f `
            $Attempt,
            $InvocationType
    )

    try {
        $codexProcess = Start-Process `
            -FilePath $CodexLauncher `
            -ArgumentList @(
                "-NoLogo",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                ('"{0}"' -f $CodexScriptPath),
                "exec",
                "--sandbox",
                "workspace-write",
                "-"
            ) `
            -WorkingDirectory $ProjectRoot `
            -RedirectStandardInput $promptPath `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -NoNewWindow `
            -Wait `
            -PassThru
        $processExitCode = [int]$codexProcess.ExitCode
    }
    catch {
        $startError = $_.Exception.Message
        $processExitCode = -1
    }

    $attemptEnd = Get-Date
    $stdoutText = ""
    $stderrText = ""
    if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
        $stdoutText = Read-TextFile -Path $stdoutPath
    }
    if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
        $stderrText = Read-TextFile -Path $stderrPath
    }
    if (-not [string]::IsNullOrWhiteSpace($startError)) {
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            $stderrText += [Environment]::NewLine
        }
        $stderrText += ("Start-Process error: " + $startError)
    }

    $combinedLog = @"
Codex attempt: $attemptText
Invocation type: $InvocationType
Started: $(Format-Timestamp -Value $attemptStart)
Finished: $(Format-Timestamp -Value $attemptEnd)
Exit code: $processExitCode

===== PROMPT =====
$Prompt

===== STANDARD OUTPUT =====
$stdoutText

===== STANDARD ERROR =====
$stderrText
"@
    Write-Utf8File -Path $logPath -Content $combinedLog

    Remove-TemporaryFile -Path $promptPath
    Remove-TemporaryFile -Path $stdoutPath
    Remove-TemporaryFile -Path $stderrPath

    if (-not [string]::IsNullOrWhiteSpace($stdoutText)) {
        Write-Host $stdoutText
    }
    if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
        Write-Host $stderrText
    }

    return [PSCustomObject]@{
        Attempt = $Attempt
        InvocationType = $InvocationType
        Started = $attemptStart
        Finished = $attemptEnd
        ExitCode = [int]$processExitCode
        LogPath = Get-ProjectRelativePath -FullPath $logPath
    }
}

function Invoke-HostValidation {
    param([Parameter(Mandatory = $true)][int]$Attempt)

    $attemptText = "{0:D2}" -f $Attempt
    $stdoutPath = Join-Path `
        $ReportDirectory `
        ("current-validation-attempt-{0}.stdout.tmp" -f $attemptText)
    $stderrPath = Join-Path `
        $ReportDirectory `
        ("current-validation-attempt-{0}.stderr.tmp" -f $attemptText)

    $validationStart = Get-Date
    Write-Host ("Starting host validation for attempt {0}." -f $attemptText)

    try {
        $validationProcess = Start-Process `
            -FilePath "powershell.exe" `
            -ArgumentList @(
                "-NoLogo",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                ('"{0}"' -f $ValidationScript)
            ) `
            -WorkingDirectory $ProjectRoot `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -NoNewWindow `
            -Wait `
            -PassThru
        $validationExitCode = [int]$validationProcess.ExitCode
    }
    catch {
        throw ("Unable to start host validation: " + $_.Exception.Message)
    }
    finally {
        $stdoutText = ""
        $stderrText = ""
        if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
            $stdoutText = Read-TextFile -Path $stdoutPath
        }
        if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            $stderrText = Read-TextFile -Path $stderrPath
        }
        if (-not [string]::IsNullOrWhiteSpace($stdoutText)) {
            Write-Host $stdoutText
        }
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            Write-Host $stderrText
        }
        Remove-TemporaryFile -Path $stdoutPath
        Remove-TemporaryFile -Path $stderrPath
    }

    $validationEnd = Get-Date
    return [PSCustomObject]@{
        Started = $validationStart
        Finished = $validationEnd
        ExitCode = [int]$validationExitCode
    }
}

function Save-ValidationSnapshot {
    param([Parameter(Mandatory = $true)][int]$Attempt)

    if (-not (Test-Path -LiteralPath $ValidationLatestPath -PathType Leaf)) {
        throw (
            "Validation finished without creating its required report: " +
            $ValidationLatestPath
        )
    }

    $reportText = Read-TextFile -Path $ValidationLatestPath
    $snapshotPath = Join-Path `
        $ReportDirectory `
        ("current-validation-attempt-{0:D2}.txt" -f $Attempt)
    Write-Utf8File -Path $snapshotPath -Content $reportText

    return [PSCustomObject]@{
        Text = $reportText
        RelativePath = Get-ProjectRelativePath -FullPath $snapshotPath
    }
}

function Add-AutonomousReportContent {
    Add-ReportLine "Travel Cost Pilot - Autonomous Task Report"
    Add-ReportLine ("Project root: " + $ProjectRoot)
    Add-ReportLine ("Task file: " + $TaskRelativePath)
    Add-ReportLine ("Initial branch: " + $InitialBranch)
    Add-ReportLine ("Initial commit: " + $InitialCommit)
    Add-ReportLine ("Initial Git status: " + $InitialGitStatus)
    Add-ReportLine ("Started: " + (Format-Timestamp -Value $StartTime))
    Add-ReportLine ("Finished: " + (Format-Timestamp -Value $EndTime))
    Add-ReportLine ("MaxAttempts: " + $MaxAttempts)

    Add-ReportLine ""
    Add-ReportLine "===== Codex attempts ====="
    if ($script:CodexRecords.Count -eq 0) {
        Add-ReportLine "(none)"
    }
    else {
        foreach ($record in $script:CodexRecords) {
            Add-ReportLine (
                "Attempt {0:D2}: type={1}; started={2}; finished={3}; " +
                "exitCode={4}; log={5}" -f `
                    $record.Attempt,
                    $record.InvocationType,
                    (Format-Timestamp -Value $record.Started),
                    (Format-Timestamp -Value $record.Finished),
                    $record.ExitCode,
                    $record.LogPath
            )
        }
    }

    Add-ReportLine ""
    Add-ReportLine "===== Host validations ====="
    if ($script:ValidationRecords.Count -eq 0) {
        Add-ReportLine "(none)"
    }
    else {
        foreach ($record in $script:ValidationRecords) {
            Add-ReportLine (
                "Attempt {0:D2}: started={1}; finished={2}; exitCode={3}; " +
                "result={4}; snapshot={5}" -f `
                    $record.Attempt,
                    (Format-Timestamp -Value $record.Started),
                    (Format-Timestamp -Value $record.Finished),
                    $record.ExitCode,
                    $record.Result,
                    $record.SnapshotPath
            )
        }
    }

    Add-ReportLine ""
    Add-ReportLine "===== Final Git changes ====="
    Add-ReportLine $FinalGitChanges

    Add-ReportLine ""
    Add-ReportLine "===== Final Docker state ====="
    Add-ReportLine ("docker compose down exit code: " + $DockerCleanupExitCode)
    Add-ReportLine ("docker compose down output: " + $DockerCleanupOutput)
    Add-ReportLine ("Docker status: " + $FinalDockerStatus)

    Add-ReportLine ""
    Add-ReportLine "===== Conclusion ====="
    if ($WorkflowPassed) {
        Add-ReportLine "AUTONOMOUS TASK PASSED"
        Add-ReportLine "The independent host validation returned exit code 0."
    }
    else {
        Add-ReportLine "AUTONOMOUS TASK FAILED"
        Add-ReportLine ("Failure reason: " + $FailureReason)
    }

    Add-ReportLine ""
    Add-ReportLine "===== Manual next steps ====="
    Add-ReportLine "Code has not been committed."
    Add-ReportLine "A human must inspect the Git diff."
    Add-ReportLine "Claude Code independent review is still required."
}

try {
    $currentDirectory = [System.IO.Path]::GetFullPath((Get-Location).Path)
    if (-not [string]::Equals(
        $currentDirectory.TrimEnd([char[]]@("\", "/")),
        $ProjectRoot.TrimEnd([char[]]@("\", "/")),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw ("Run this script from the project root: " + $ProjectRoot)
    }

    foreach ($requiredFile in @($AgentsFile, $ValidationScript)) {
        $checkedRequiredFile = Assert-PathInsideProject `
            -CandidatePath $requiredFile `
            -Description "Required file"
        if (-not (Test-Path -LiteralPath $checkedRequiredFile -PathType Leaf)) {
            throw ("Required file was not found: " + $checkedRequiredFile)
        }
    }

    $TaskFullPath = Assert-PathInsideProject `
        -CandidatePath $TaskFile `
        -Description "Task file"
    if (-not (Test-Path -LiteralPath $TaskFullPath -PathType Leaf)) {
        throw ("Task file was not found: " + $TaskFullPath)
    }
    $TaskRelativePath = Get-ProjectRelativePath -FullPath $TaskFullPath

    $commandPaths = @{}
    foreach ($commandName in @("git", "powershell.exe", "docker")) {
        $commandInfo = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($null -eq $commandInfo) {
            throw ("Required command is not available: " + $commandName)
        }
        $commandPaths[$commandName] = $commandInfo.Source
    }

    $codexCommands = @(Get-Command "codex" -All -ErrorAction SilentlyContinue)
    if ($codexCommands.Count -eq 0) {
        throw "Required command is not available: codex"
    }
    $codexScriptCommand = $codexCommands |
        Where-Object {
            ($_.CommandType -eq "ExternalScript") -and
            ([System.IO.Path]::GetExtension($_.Source) -eq ".ps1") -and
            (Test-Path -LiteralPath $_.Source -PathType Leaf)
        } |
        Select-Object -First 1
    if ($null -eq $codexScriptCommand) {
        throw "Required Codex PowerShell script was not found: codex.ps1"
    }
    $CodexScriptPath = [System.IO.Path]::GetFullPath(
        $codexScriptCommand.Source
    )
    Write-Host (
        "Codex launch chain: {0} -File `"{1}`" exec --sandbox " +
        "workspace-write -" -f `
            $CodexLauncher,
            $CodexScriptPath
    )

    $rootResult = Invoke-GitReadCommand `
        -Arguments @("rev-parse", "--show-toplevel")
    $gitRoot = [System.IO.Path]::GetFullPath($rootResult.Text.Trim())
    if (-not [string]::Equals(
        $gitRoot.TrimEnd([char[]]@("\", "/")),
        $ProjectRoot.TrimEnd([char[]]@("\", "/")),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw ("Git root does not match the project root: " + $gitRoot)
    }

    $branchResult = Invoke-GitReadCommand `
        -Arguments @("rev-parse", "--abbrev-ref", "HEAD")
    $commitResult = Invoke-GitReadCommand `
        -Arguments @("rev-parse", "HEAD")
    $InitialBranch = $branchResult.Text.Trim()
    $InitialCommit = $commitResult.Text.Trim()
    $InitialGitStatus = Get-GitChangeText
    if ($InitialGitStatus -ne "(clean)") {
        throw (
            "The initial Git working tree is not clean. " +
            "No Codex process will be started. Changes:" +
            [Environment]::NewLine +
            $InitialGitStatus
        )
    }

    $ReportsEnabled = $true
    if (-not (Test-Path -LiteralPath $ReportDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $ReportDirectory)
    }

    $nextInvocationType = "开发"
    $latestValidationReport = ""
    $repairNumber = 0

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if ($nextInvocationType -eq "开发") {
            $prompt = New-DevelopmentPrompt
        }
        else {
            $repairNumber++
            $currentGitChanges = Get-GitChangeText
            $prompt = New-RepairPrompt `
                -RepairNumber $repairNumber `
                -ValidationReport $latestValidationReport `
                -GitChanges $currentGitChanges
        }

        $codexRecord = Invoke-CodexAttempt `
            -Attempt $attempt `
            -InvocationType $nextInvocationType `
            -Prompt $prompt `
            -CodexLauncher $CodexLauncher `
            -CodexScriptPath $CodexScriptPath
        $script:CodexRecords += $codexRecord

        Assert-GitIdentityUnchanged

        if ($codexRecord.ExitCode -ne 0) {
            $FailureReason = (
                "Codex attempt {0:D2} returned exit code {1}. " +
                "Host validation was not run for this attempt." -f `
                    $attempt,
                    $codexRecord.ExitCode
            )
            Write-Host $FailureReason
            continue
        }

        $validationProcessResult = Invoke-HostValidation -Attempt $attempt
        $snapshotResult = Save-ValidationSnapshot -Attempt $attempt
        if ($validationProcessResult.ExitCode -eq 0) {
            $validationResultText = "PASSED"
        }
        else {
            $validationResultText = "FAILED"
        }

        $script:ValidationRecords += [PSCustomObject]@{
            Attempt = $attempt
            Started = $validationProcessResult.Started
            Finished = $validationProcessResult.Finished
            ExitCode = [int]$validationProcessResult.ExitCode
            Result = $validationResultText
            SnapshotPath = $snapshotResult.RelativePath
        }

        if ($validationProcessResult.ExitCode -eq 0) {
            $WorkflowPassed = $true
            $FailureReason = ""
            break
        }

        $latestValidationReport = $snapshotResult.Text
        $nextInvocationType = "修复"
        $FailureReason = (
            "Host validation for attempt {0:D2} returned exit code {1}." -f `
                $attempt,
                $validationProcessResult.ExitCode
        )
    }

    if (-not $WorkflowPassed) {
        if ([string]::IsNullOrWhiteSpace($FailureReason)) {
            $FailureReason = (
                "The maximum number of Codex attempts was reached: " +
                $MaxAttempts
            )
        }
    }
}
catch {
    $WorkflowPassed = $false
    $FailureReason = $_.Exception.Message
    Write-Host ("Autonomous task error: " + $FailureReason)
}
finally {
    Write-Host "Running final cleanup: docker compose down"
    try {
        Push-Location $ProjectRoot
        try {
            $LASTEXITCODE = 0
            $cleanupLines = @(
                & docker compose down 2>&1 |
                    ForEach-Object {
                        Write-Host $_.ToString()
                        $_.ToString()
                    }
            )
            $DockerCleanupExitCode = $LASTEXITCODE
            if ($null -eq $DockerCleanupExitCode) {
                $DockerCleanupExitCode = -1
            }
            if ($cleanupLines.Count -eq 0) {
                $DockerCleanupOutput = "(no output)"
            }
            else {
                $DockerCleanupOutput = $cleanupLines -join [Environment]::NewLine
            }
            if ($DockerCleanupExitCode -ne 0) {
                $WorkflowPassed = $false
                $cleanupFailure = (
                    "Final docker compose down returned exit code " +
                    $DockerCleanupExitCode
                )
                if ([string]::IsNullOrWhiteSpace($FailureReason)) {
                    $FailureReason = $cleanupFailure
                }
                else {
                    $FailureReason += ("; " + $cleanupFailure)
                }
            }

            $LASTEXITCODE = 0
            $statusLines = @(
                & docker compose ps -a -q 2>&1 |
                    ForEach-Object { $_.ToString() }
            )
            $statusExitCode = $LASTEXITCODE
            if ($null -eq $statusExitCode) {
                $statusExitCode = -1
            }
            if ($statusExitCode -ne 0) {
                $FinalDockerStatus = (
                    "Unable to query final Docker status; exit code {0}: {1}" -f `
                        $statusExitCode,
                        ($statusLines -join [Environment]::NewLine)
                )
                $WorkflowPassed = $false
                if ([string]::IsNullOrWhiteSpace($FailureReason)) {
                    $FailureReason = $FinalDockerStatus
                }
            }
            elseif ($statusLines.Count -eq 0) {
                $FinalDockerStatus = "No project containers remain."
            }
            else {
                $FinalDockerStatus = (
                    "Project containers remain: " +
                    ($statusLines -join ", ")
                )
                $WorkflowPassed = $false
                if ([string]::IsNullOrWhiteSpace($FailureReason)) {
                    $FailureReason = $FinalDockerStatus
                }
            }
        }
        finally {
            Pop-Location
        }
    }
    catch {
        $DockerCleanupExitCode = -1
        $DockerCleanupOutput = $_.Exception.Message
        $FinalDockerStatus = "Final Docker cleanup or status check failed."
        $WorkflowPassed = $false
        if ([string]::IsNullOrWhiteSpace($FailureReason)) {
            $FailureReason = $_.Exception.Message
        }
        else {
            $FailureReason += ("; " + $_.Exception.Message)
        }
        Write-Host ("Final Docker cleanup error: " + $_.Exception.Message)
    }
}

$EndTime = Get-Date

if ($ReportsEnabled) {
    try {
        $FinalGitChanges = Get-GitChangeText
    }
    catch {
        $FinalGitChanges = "Unable to read final Git changes: " + $_.Exception.Message
        $WorkflowPassed = $false
        if ([string]::IsNullOrWhiteSpace($FailureReason)) {
            $FailureReason = $FinalGitChanges
        }
    }

    try {
        Add-AutonomousReportContent
        Write-Utf8File `
            -Path $AutonomousReportPath `
            -Content ($script:ReportLines -join [Environment]::NewLine)
        Write-Host ("Autonomous report written to: " + $AutonomousReportPath)
    }
    catch {
        $WorkflowPassed = $false
        if ([string]::IsNullOrWhiteSpace($FailureReason)) {
            $FailureReason = "Unable to write autonomous report: " + $_.Exception.Message
        }
        Write-Host ("Unable to write autonomous report: " + $_.Exception.Message)
    }
}

if ($WorkflowPassed) {
    Write-Host "AUTONOMOUS TASK PASSED"
    Write-Host "Code has not been committed; a human must inspect the Git diff."
    Write-Host "Claude Code independent review is still required."
    exit 0
}

Write-Host "AUTONOMOUS TASK FAILED"
if (-not [string]::IsNullOrWhiteSpace($FailureReason)) {
    Write-Host ("Failure reason: " + $FailureReason)
}
exit 1
