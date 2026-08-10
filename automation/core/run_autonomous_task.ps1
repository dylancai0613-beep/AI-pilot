[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ProjectRoot,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigFile,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TaskFile,

    [int]$MaxAttempts
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$script:ReportLines = New-Object "System.Collections.Generic.List[string]"
$script:AgentRecords = @()
$script:ValidationRecords = @()

$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$ProjectRootPrefix = $ProjectRoot.TrimEnd([char[]]@("\", "/")) +
    [System.IO.Path]::DirectorySeparatorChar
$StartTime = Get-Date
$EndTime = $null
$ProjectName = "(not loaded)"
$TaskFullPath = ""
$TaskRelativePath = "(not resolved)"
$AgentContractPath = ""
$AgentAdapterPath = ""
$AgentRuntime = $null
$AgentModel = $null
$AgentOptions = $null
$ValidationAdapterPath = ""
$CleanupAdapterPath = ""
$ValidationReportPath = ""
$ReportDirectory = ""
$AutonomousReportPath = ""
$InitialBranch = "(not recorded)"
$InitialCommit = "(not recorded)"
$InitialGitStatus = "(not recorded)"
$FinalGitChanges = "(not recorded)"
$WorkflowPassed = $false
$ValidationPassed = $false
$FailureReason = ""
$CleanupConfigured = $false
$CleanupEnabled = $false
$CleanupAttempted = $false
$CleanupExitCode = $null
$CleanupOutput = "(not attempted)"
$ReportsEnabled = $false
$EffectiveMaxAttempts = 0

function Add-ReportLine {
    param([AllowEmptyString()][string]$Line)

    [void]$script:ReportLines.Add($Line)
}

function Add-FailureReason {
    param([Parameter(Mandatory = $true)][string]$Message)

    if ([string]::IsNullOrWhiteSpace($FailureReason)) {
        $script:FailureReason = $Message
    }
    else {
        $script:FailureReason += "; " + $Message
    }
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

    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        (New-Object System.Text.UTF8Encoding($true))
    )
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

function Resolve-ProjectPath {
    param(
        [Parameter(Mandatory = $true)][string]$CandidatePath,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$AllowProjectRoot
    )

    if ([System.IO.Path]::IsPathRooted($CandidatePath)) {
        $fullPath = [System.IO.Path]::GetFullPath($CandidatePath)
    }
    else {
        $fullPath = [System.IO.Path]::GetFullPath(
            (Join-Path $ProjectRoot $CandidatePath)
        )
    }

    $isRoot = [string]::Equals(
        $fullPath.TrimEnd([char[]]@("\", "/")),
        $ProjectRoot.TrimEnd([char[]]@("\", "/")),
        [System.StringComparison]::OrdinalIgnoreCase
    )
    $isChild = $fullPath.StartsWith(
        $ProjectRootPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )
    if ((-not $isChild) -and (-not ($AllowProjectRoot -and $isRoot))) {
        throw ("{0} must be inside the project root: {1}" -f `
            $Description,
            $ProjectRoot)
    }

    return $fullPath
}

function Get-ProjectRelativePath {
    param([Parameter(Mandatory = $true)][string]$FullPath)

    $checked = Resolve-ProjectPath `
        -CandidatePath $FullPath `
        -Description "Path"
    return $checked.Substring($ProjectRootPrefix.Length).Replace("\", "/")
}

function Get-RequiredString {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Section,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not $Section.ContainsKey($Name)) {
        throw ("Missing configuration value: " + $Description)
    }
    $value = [string]$Section[$Name]
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw ("Configuration value must not be empty: " + $Description)
    }
    return $value
}

function Get-RequiredSection {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Configuration,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not $Configuration.ContainsKey($Name)) {
        throw ("Missing configuration section: " + $Name)
    }
    if (-not ($Configuration[$Name] -is [hashtable])) {
        throw ("Configuration section must be a hashtable: " + $Name)
    }
    return [hashtable]$Configuration[$Name]
}

function Invoke-GitReadCommand {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $LASTEXITCODE = 0
    $outputLines = @(
        & git @Arguments 2>&1 | ForEach-Object { $_.ToString() }
    )
    $commandExitCode = $LASTEXITCODE
    if ($null -eq $commandExitCode) {
        $commandExitCode = 0
    }
    if ($commandExitCode -ne 0) {
        throw (
            "git {0} failed with exit code {1}: {2}" -f `
                ($Arguments -join " "),
                $commandExitCode,
                ($outputLines -join [Environment]::NewLine)
        )
    }

    return [PSCustomObject]@{
        Lines = [string[]]$outputLines
        Text = ($outputLines -join [Environment]::NewLine)
    }
}

function Get-GitChangeText {
    $result = Invoke-GitReadCommand `
        -Arguments @("status", "--short", "--untracked-files=all")
    if ($result.Lines.Count -eq 0) {
        return "(clean)"
    }
    return $result.Text
}

function Assert-GitIdentityUnchanged {
    $branch = (Invoke-GitReadCommand `
        -Arguments @("rev-parse", "--abbrev-ref", "HEAD")).Text.Trim()
    $commit = (Invoke-GitReadCommand `
        -Arguments @("rev-parse", "HEAD")).Text.Trim()

    if ($branch -ne $InitialBranch) {
        throw (
            "The current Git branch changed from '{0}' to '{1}'. " +
            "No automatic recovery was attempted." -f $InitialBranch, $branch
        )
    }
    if ($commit -ne $InitialCommit) {
        throw (
            "HEAD changed from '{0}' to '{1}'. " +
            "No automatic recovery was attempted." -f $InitialCommit, $commit
        )
    }
}

function New-DevelopmentPrompt {
    return @"
你是本次自动开发任务的 Agent。

开始前必须完整读取：
1. AGENTS.md
2. 原任务文件：$TaskRelativePath
3. 与原任务直接相关的现有代码

严格执行原任务文件，并遵守其中允许和禁止修改范围。
不要运行由总控负责的独立 Validation。
不得执行任何 Git 写操作，包括 add、commit、push、reset、restore、checkout、clean；
不得改变分支或 HEAD，不得提交代码。
不得扩大原任务允许修改范围。
可以执行任务允许的静态检查。
完成后输出中文总结，但总控不会把 Agent 自述作为验收成功依据。
"@
}

function New-RepairPrompt {
    param(
        [Parameter(Mandatory = $true)][int]$RepairNumber,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ValidationReport,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$GitChanges
    )

    return @"
你是本次自动开发任务的 Agent，正在执行第 $RepairNumber 次受限修复。

开始前必须完整读取：
1. AGENTS.md
2. 原任务文件：$TaskRelativePath
3. 与原任务直接相关的现有代码

严格遵守原任务文件的允许和禁止修改范围，不得扩大修改范围。
只修复下面 Validation Report 证明的真实问题，不要处理无关事项。
不要运行由总控负责的独立 Validation。
不得执行任何 Git 写操作，包括 add、commit、push、reset、restore、checkout、clean；
不得改变分支或 HEAD，不得提交代码。
可以执行任务允许的静态检查。
完成后输出中文总结，但总控不会把 Agent 自述作为验收成功依据。

===== 上一次 Validation Report 全文 =====
$ValidationReport

===== 当前 Git 修改文件列表 =====
$GitChanges
"@
}

function Invoke-AgentAttempt {
    param(
        [Parameter(Mandatory = $true)][int]$Attempt,
        [Parameter(Mandatory = $true)][string]$InvocationType,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Prompt
    )

    $attemptText = "{0:D2}" -f $Attempt
    $attemptId = "agent-attempt-" + $attemptText
    $logPath = Join-Path $ReportDirectory `
        ("current-agent-attempt-{0}.log" -f $attemptText)
    $promptPath = Join-Path $ReportDirectory `
        ("current-agent-attempt-{0}.prompt.txt" -f $attemptText)
    $stdoutPath = Join-Path $ReportDirectory `
        ("current-agent-attempt-{0}.stdout.txt" -f $attemptText)
    $stderrPath = Join-Path $ReportDirectory `
        ("current-agent-attempt-{0}.stderr.txt" -f $attemptText)
    $requestPath = Join-Path $ReportDirectory `
        ("current-agent-attempt-{0}.request.json" -f $attemptText)
    $resultPath = Join-Path $ReportDirectory `
        ("current-agent-attempt-{0}.result.json" -f $attemptText)
    $adapterStdoutPath = Join-Path $ReportDirectory `
        ("current-agent-attempt-{0}.adapter-stdout.tmp" -f $attemptText)
    $adapterStderrPath = Join-Path $ReportDirectory `
        ("current-agent-attempt-{0}.adapter-stderr.tmp" -f $attemptText)

    foreach ($stalePath in @(
        $logPath,
        $promptPath,
        $stdoutPath,
        $stderrPath,
        $requestPath,
        $resultPath,
        $adapterStdoutPath,
        $adapterStderrPath
    )) {
        Remove-TemporaryFile -Path $stalePath
    }

    Write-Utf8File -Path $promptPath -Content $Prompt
    $request = [PSCustomObject][ordered]@{
        SchemaVersion = 1
        AttemptId = $attemptId
        InvocationType = $InvocationType
        ProjectRoot = $ProjectRoot
        TaskFile = $TaskFullPath
        PromptFile = $promptPath
        StdoutFile = $stdoutPath
        StderrFile = $stderrPath
        Runtime = $AgentRuntime
        Model = $AgentModel
        Options = $AgentOptions
    }
    Write-AgentContractJson -LiteralPath $requestPath -InputObject $request
    $request = Read-AgentContractJson `
        -LiteralPath $requestPath `
        -Description "Agent Request"
    [void](Assert-AgentRequestContract `
        -Request $request `
        -ExpectedProjectRoot $ProjectRoot)

    $started = Get-Date
    $adapterProcessExitCode = -1
    $startError = ""

    Write-Host ("Starting Agent attempt {0:D2} ({1})." -f `
        $Attempt,
        $InvocationType)

    try {
        $process = Start-Process `
            -FilePath $script:PowerShellHost `
            -ArgumentList @(
                "-NoLogo",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                ('"{0}"' -f $AgentAdapterPath),
                "-RequestFile",
                ('"{0}"' -f $requestPath),
                "-ResultFile",
                ('"{0}"' -f $resultPath)
            ) `
            -WorkingDirectory $ProjectRoot `
            -RedirectStandardOutput $adapterStdoutPath `
            -RedirectStandardError $adapterStderrPath `
            -NoNewWindow `
            -Wait `
            -PassThru
        $adapterProcessExitCode = [int]$process.ExitCode
    }
    catch {
        $startError = $_.Exception.Message
    }

    $finished = Get-Date
    $result = $null
    $contractValid = $false
    $contractError = ""
    try {
        if (-not [string]::IsNullOrWhiteSpace($startError)) {
            throw ("Agent Adapter failed to start: " + $startError)
        }
        $result = Read-AgentContractJson `
            -LiteralPath $resultPath `
            -Description "Agent Result"
        [void](Assert-AgentOutputFiles -Request $request)
        [void](Assert-AgentResultContract `
            -Result $result `
            -Request $request `
            -AdapterProcessExitCode $adapterProcessExitCode)
        $contractValid = $true
    }
    catch {
        $contractError = $_.Exception.Message
    }

    $stdoutText = ""
    $stderrText = ""
    $adapterStdoutText = ""
    $adapterStderrText = ""
    if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
        $stdoutText = Read-TextFile -Path $stdoutPath
    }
    if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
        $stderrText = Read-TextFile -Path $stderrPath
    }
    if (Test-Path -LiteralPath $adapterStdoutPath -PathType Leaf) {
        $adapterStdoutText = Read-TextFile -Path $adapterStdoutPath
    }
    if (Test-Path -LiteralPath $adapterStderrPath -PathType Leaf) {
        $adapterStderrText = Read-TextFile -Path $adapterStderrPath
    }

    if ($contractValid) {
        $adapterStatus = [string]$result.AdapterStatus
        $agentExitCode = [int]$result.ExitCode
        $resultStarted = [string]$result.StartedAt
        $resultFinished = [string]$result.FinishedAt
        $resolvedModel = $result.ResolvedModel
        $message = [string]$result.Message
    }
    else {
        $adapterStatus = "contract_violation"
        $agentExitCode = -1
        $resultStarted = Format-Timestamp -Value $started
        $resultFinished = Format-Timestamp -Value $finished
        $resolvedModel = $null
        $message = $contractError
    }

    $runtimeText = ConvertTo-AgentContractDisplayJson -Value $request.Runtime
    $requestedModelText = ConvertTo-AgentContractDisplayJson -Value $request.Model
    $resolvedModelText = ConvertTo-AgentContractDisplayJson -Value $resolvedModel

    $log = @"
Agent attempt: $attemptText
Invocation type: $InvocationType
Adapter: $(Get-ProjectRelativePath -FullPath $AgentAdapterPath)
Request file: $(Get-ProjectRelativePath -FullPath $requestPath)
Result file: $(Get-ProjectRelativePath -FullPath $resultPath)
Runtime: $runtimeText
Requested model: $requestedModelText
Resolved model: $resolvedModelText
Started: $resultStarted
Finished: $resultFinished
Adapter status: $adapterStatus
Adapter process exit code: $adapterProcessExitCode
Agent exit code: $agentExitCode
Contract valid: $contractValid
Contract error: $contractError
Message: $message

===== PROMPT =====
$Prompt

===== STANDARD OUTPUT =====
$stdoutText

===== STANDARD ERROR =====
$stderrText

===== ADAPTER PROCESS OUTPUT =====
$adapterStdoutText

===== ADAPTER PROCESS ERROR =====
$adapterStderrText
"@
    Write-Utf8File -Path $logPath -Content $log

    foreach ($temporaryPath in @($adapterStdoutPath, $adapterStderrPath)) {
        Remove-TemporaryFile -Path $temporaryPath
    }

    if (-not [string]::IsNullOrWhiteSpace($stdoutText)) {
        Write-Host $stdoutText
    }
    if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
        Write-Host $stderrText
    }

    return [PSCustomObject]@{
        Attempt = $Attempt
        AttemptId = $attemptId
        InvocationType = $InvocationType
        Started = $resultStarted
        Finished = $resultFinished
        AdapterProcessExitCode = [int]$adapterProcessExitCode
        AdapterStatus = $adapterStatus
        ExitCode = [int]$agentExitCode
        ContractValid = $contractValid
        ContractError = $contractError
        Runtime = $runtimeText
        RequestedModel = $requestedModelText
        ResolvedModel = $resolvedModelText
        Message = $message
        RequestPath = Get-ProjectRelativePath -FullPath $requestPath
        ResultPath = Get-ProjectRelativePath -FullPath $resultPath
        LogPath = Get-ProjectRelativePath -FullPath $logPath
    }
}

function Invoke-ValidationAttempt {
    param([Parameter(Mandatory = $true)][int]$Attempt)

    $attemptText = "{0:D2}" -f $Attempt
    $stdoutPath = Join-Path $ReportDirectory `
        ("current-validation-attempt-{0}.stdout.tmp" -f $attemptText)
    $stderrPath = Join-Path $ReportDirectory `
        ("current-validation-attempt-{0}.stderr.tmp" -f $attemptText)
    $started = Get-Date
    $exitCode = -1
    $startError = ""

    Write-Host ("Starting Validation attempt {0}." -f $attemptText)
    try {
        $process = Start-Process `
            -FilePath $script:PowerShellHost `
            -ArgumentList @(
                "-NoLogo",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                ('"{0}"' -f $ValidationAdapterPath),
                "-ProjectRoot",
                ('"{0}"' -f $ProjectRoot),
                "-ReportPath",
                ('"{0}"' -f $ValidationReportPath)
            ) `
            -WorkingDirectory $ProjectRoot `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -NoNewWindow `
            -Wait `
            -PassThru
        $exitCode = [int]$process.ExitCode
    }
    catch {
        $startError = $_.Exception.Message
    }

    $finished = Get-Date
    $stdoutText = ""
    $stderrText = ""
    if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
        $stdoutText = Read-TextFile -Path $stdoutPath
    }
    if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
        $stderrText = Read-TextFile -Path $stderrPath
    }
    if (-not [string]::IsNullOrWhiteSpace($startError)) {
        $stderrText += [Environment]::NewLine + "Adapter start error: " + $startError
    }
    if (-not [string]::IsNullOrWhiteSpace($stdoutText)) {
        Write-Host $stdoutText
    }
    if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
        Write-Host $stderrText
    }
    Remove-TemporaryFile -Path $stdoutPath
    Remove-TemporaryFile -Path $stderrPath

    return [PSCustomObject]@{
        Started = $started
        Finished = $finished
        ExitCode = [int]$exitCode
    }
}

function Save-ValidationSnapshot {
    param([Parameter(Mandatory = $true)][int]$Attempt)

    if (-not (Test-Path -LiteralPath $ValidationReportPath -PathType Leaf)) {
        throw "Validation finished without creating its configured report."
    }
    $text = Read-TextFile -Path $ValidationReportPath
    $snapshotPath = Join-Path $ReportDirectory `
        ("current-validation-attempt-{0:D2}.txt" -f $Attempt)
    Write-Utf8File -Path $snapshotPath -Content $text

    return [PSCustomObject]@{
        Text = $text
        RelativePath = Get-ProjectRelativePath -FullPath $snapshotPath
    }
}

function Invoke-CleanupAdapter {
    $stdoutPath = Join-Path $ReportDirectory "current-cleanup.stdout.tmp"
    $stderrPath = Join-Path $ReportDirectory "current-cleanup.stderr.tmp"
    $exitCode = -1
    $startError = ""

    try {
        $process = Start-Process `
            -FilePath $script:PowerShellHost `
            -ArgumentList @(
                "-NoLogo",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                ('"{0}"' -f $CleanupAdapterPath),
                "-ProjectRoot",
                ('"{0}"' -f $ProjectRoot)
            ) `
            -WorkingDirectory $ProjectRoot `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -NoNewWindow `
            -Wait `
            -PassThru
        $exitCode = [int]$process.ExitCode
    }
    catch {
        $startError = $_.Exception.Message
    }

    $lines = New-Object "System.Collections.Generic.List[string]"
    foreach ($path in @($stdoutPath, $stderrPath)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $text = Read-TextFile -Path $path
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                [void]$lines.Add($text.TrimEnd())
            }
        }
        Remove-TemporaryFile -Path $path
    }
    if (-not [string]::IsNullOrWhiteSpace($startError)) {
        [void]$lines.Add("Adapter start error: " + $startError)
    }
    if ($lines.Count -eq 0) {
        $output = "(no output)"
    }
    else {
        $output = $lines.ToArray() -join [Environment]::NewLine
    }

    return [PSCustomObject]@{
        ExitCode = [int]$exitCode
        Output = $output
    }
}

function Add-AutonomousReportContent {
    Add-ReportLine ($ProjectName + " - Autonomous Task Report")
    Add-ReportLine ("ProjectName: " + $ProjectName)
    Add-ReportLine ("Project root: " + $ProjectRoot)
    Add-ReportLine ("TaskFile: " + $TaskRelativePath)
    Add-ReportLine ("Agent Adapter: " + (Get-ProjectRelativePath $AgentAdapterPath))
    Add-ReportLine (
        "Runtime: " + (ConvertTo-AgentContractDisplayJson -Value $AgentRuntime)
    )
    Add-ReportLine (
        "RequestedModel: " + (ConvertTo-AgentContractDisplayJson -Value $AgentModel)
    )
    Add-ReportLine (
        "Agent Options: " + (ConvertTo-AgentContractDisplayJson -Value $AgentOptions)
    )
    Add-ReportLine ("Validation Adapter: " + (Get-ProjectRelativePath $ValidationAdapterPath))
    if ($CleanupEnabled) {
        Add-ReportLine ("Cleanup Adapter: " + (Get-ProjectRelativePath $CleanupAdapterPath))
    }
    else {
        Add-ReportLine "Cleanup Adapter: (disabled)"
    }
    Add-ReportLine ("Branch: " + $InitialBranch)
    Add-ReportLine ("InitialCommit: " + $InitialCommit)
    Add-ReportLine ("Initial Git status: " + $InitialGitStatus)
    Add-ReportLine ("Started: " + (Format-Timestamp $StartTime))
    Add-ReportLine ("Finished: " + (Format-Timestamp $EndTime))
    Add-ReportLine ("MaxAttempts: " + $EffectiveMaxAttempts)

    Add-ReportLine ""
    Add-ReportLine "===== Agent attempts ====="
    if ($script:AgentRecords.Count -eq 0) {
        Add-ReportLine "(none)"
    }
    else {
        foreach ($record in $script:AgentRecords) {
            Add-ReportLine (
                "Agent attempt {0:D2}: id={1}; type={2}; status={3}; " +
                "started={4}; finished={5}; adapterProcessExitCode={6}; " +
                "agentExitCode={7}; runtime={8}; requestedModel={9}; " +
                "resolvedModel={10}; request={11}; result={12}; log={13}" -f `
                    $record.Attempt,
                    $record.AttemptId,
                    $record.InvocationType,
                    $record.AdapterStatus,
                    $record.Started,
                    $record.Finished,
                    $record.AdapterProcessExitCode,
                    $record.ExitCode,
                    $record.Runtime,
                    $record.RequestedModel,
                    $record.ResolvedModel,
                    $record.RequestPath,
                    $record.ResultPath,
                    $record.LogPath
            )
        }
    }

    Add-ReportLine ""
    Add-ReportLine "===== Validation attempts ====="
    if ($script:ValidationRecords.Count -eq 0) {
        Add-ReportLine "(none)"
    }
    else {
        foreach ($record in $script:ValidationRecords) {
            Add-ReportLine (
                "Validation attempt {0:D2}: started={1}; finished={2}; " +
                "exitCode={3}; result={4}; snapshot={5}" -f `
                    $record.Attempt,
                    (Format-Timestamp $record.Started),
                    (Format-Timestamp $record.Finished),
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
    Add-ReportLine "===== Cleanup result ====="
    Add-ReportLine ("Enabled: " + $CleanupEnabled)
    Add-ReportLine ("Attempted: " + $CleanupAttempted)
    Add-ReportLine ("ExitCode: " + $CleanupExitCode)
    Add-ReportLine ("Output: " + $CleanupOutput)

    Add-ReportLine ""
    Add-ReportLine "===== Final conclusion ====="
    if ($WorkflowPassed) {
        Add-ReportLine "AUTONOMOUS TASK PASSED"
        Add-ReportLine "The independent Validation Adapter returned exit code 0."
    }
    else {
        Add-ReportLine "AUTONOMOUS TASK FAILED"
        Add-ReportLine ("Failure reason: " + $FailureReason)
    }

    Add-ReportLine ""
    Add-ReportLine "Code has not been committed."
    Add-ReportLine "A human must inspect the Git diff."
}

try {
    if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
        throw ("Project root was not found: " + $ProjectRoot)
    }
    $currentDirectory = [System.IO.Path]::GetFullPath((Get-Location).Path)
    if (-not [string]::Equals(
        $currentDirectory.TrimEnd([char[]]@("\", "/")),
        $ProjectRoot.TrimEnd([char[]]@("\", "/")),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw ("Run this script from the project root: " + $ProjectRoot)
    }

    $ConfigFile = Resolve-ProjectPath `
        -CandidatePath $ConfigFile `
        -Description "Project Config"
    if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
        throw ("Project Config was not found: " + $ConfigFile)
    }
    $configuration = Import-PowerShellDataFile -LiteralPath $ConfigFile
    if (-not ($configuration -is [hashtable])) {
        throw "Project Config must return a hashtable."
    }

    $ProjectName = Get-RequiredString `
        -Section $configuration `
        -Name "ProjectName" `
        -Description "ProjectName"
    $agentConfig = Get-RequiredSection $configuration "Agent"
    $AgentRuntime = Get-RequiredSection $agentConfig "Runtime"
    $AgentModel = Get-RequiredSection $agentConfig "Model"
    $AgentOptions = Get-RequiredSection $agentConfig "Options"
    $validationConfig = Get-RequiredSection $configuration "Validation"
    $cleanupConfig = Get-RequiredSection $configuration "Cleanup"
    $reportsConfig = Get-RequiredSection $configuration "Reports"
    $defaultsConfig = Get-RequiredSection $configuration "Defaults"

    $AgentAdapterPath = Resolve-ProjectPath `
        -CandidatePath (Get-RequiredString $agentConfig "AdapterPath" "Agent.AdapterPath") `
        -Description "Agent Adapter"
    $AgentContractPath = Resolve-ProjectPath `
        -CandidatePath "automation\contracts\AgentContract.ps1" `
        -Description "Agent Contract"
    $ValidationAdapterPath = Resolve-ProjectPath `
        -CandidatePath (Get-RequiredString $validationConfig "AdapterPath" "Validation.AdapterPath") `
        -Description "Validation Adapter"
    $ValidationReportPath = Resolve-ProjectPath `
        -CandidatePath (Get-RequiredString $validationConfig "ReportPath" "Validation.ReportPath") `
        -Description "Validation Report"
    $ReportDirectory = Resolve-ProjectPath `
        -CandidatePath (Get-RequiredString $reportsConfig "Directory" "Reports.Directory") `
        -Description "Reports Directory"
    $AutonomousReportPath = Resolve-ProjectPath `
        -CandidatePath (Get-RequiredString $reportsConfig "AutonomousLatest" "Reports.AutonomousLatest") `
        -Description "Autonomous Report"

    if (-not $cleanupConfig.ContainsKey("Enabled")) {
        throw "Missing configuration value: Cleanup.Enabled"
    }
    $CleanupEnabled = [bool]$cleanupConfig.Enabled
    if ($CleanupEnabled) {
        $CleanupAdapterPath = Resolve-ProjectPath `
            -CandidatePath (Get-RequiredString $cleanupConfig "AdapterPath" "Cleanup.AdapterPath") `
            -Description "Cleanup Adapter"
    }
    $CleanupConfigured = $true
    $ReportsEnabled = $true

    if (-not (Test-Path -LiteralPath $AgentContractPath -PathType Leaf)) {
        throw ("Agent Contract was not found: " + $AgentContractPath)
    }
    . $AgentContractPath

    foreach ($adapterPath in @($AgentAdapterPath, $ValidationAdapterPath)) {
        if (-not (Test-Path -LiteralPath $adapterPath -PathType Leaf)) {
            throw ("Configured Adapter was not found: " + $adapterPath)
        }
    }
    if ($CleanupEnabled -and
        (-not (Test-Path -LiteralPath $CleanupAdapterPath -PathType Leaf))) {
        throw ("Configured Adapter was not found: " + $CleanupAdapterPath)
    }
    $agentsFile = Resolve-ProjectPath `
        -CandidatePath "AGENTS.md" `
        -Description "Agent instructions"
    if (-not (Test-Path -LiteralPath $agentsFile -PathType Leaf)) {
        throw ("Agent instructions were not found: " + $agentsFile)
    }

    $TaskFullPath = Resolve-ProjectPath `
        -CandidatePath $TaskFile `
        -Description "TaskFile"
    if (-not (Test-Path -LiteralPath $TaskFullPath -PathType Leaf)) {
        throw ("TaskFile was not found: " + $TaskFullPath)
    }
    $TaskRelativePath = Get-ProjectRelativePath $TaskFullPath

    if ($PSBoundParameters.ContainsKey("MaxAttempts")) {
        $EffectiveMaxAttempts = $MaxAttempts
    }
    else {
        if (-not $defaultsConfig.ContainsKey("MaxAttempts")) {
            throw "Missing configuration value: Defaults.MaxAttempts"
        }
        $EffectiveMaxAttempts = [int]$defaultsConfig.MaxAttempts
    }
    if (($EffectiveMaxAttempts -lt 1) -or ($EffectiveMaxAttempts -gt 5)) {
        throw "MaxAttempts must be between 1 and 5."
    }

    if ($null -eq (Get-Command "git" -ErrorAction SilentlyContinue)) {
        throw "The git command is not available."
    }
    $hostCommand = Get-Command "powershell.exe" -ErrorAction Stop
    $script:PowerShellHost = $hostCommand.Source

    $gitRoot = [System.IO.Path]::GetFullPath(
        (Invoke-GitReadCommand @("rev-parse", "--show-toplevel")).Text.Trim()
    )
    if (-not [string]::Equals(
        $gitRoot.TrimEnd([char[]]@("\", "/")),
        $ProjectRoot.TrimEnd([char[]]@("\", "/")),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw ("Git root does not match the project root: " + $gitRoot)
    }

    $InitialBranch = (Invoke-GitReadCommand `
        @("rev-parse", "--abbrev-ref", "HEAD")).Text.Trim()
    $InitialCommit = (Invoke-GitReadCommand `
        @("rev-parse", "HEAD")).Text.Trim()
    $InitialGitStatus = Get-GitChangeText
    if ($InitialGitStatus -ne "(clean)") {
        throw (
            "The initial Git working tree is not clean. " +
            "No Agent process will be started. Changes:" +
            [Environment]::NewLine + $InitialGitStatus
        )
    }

    [void][System.IO.Directory]::CreateDirectory($ReportDirectory)

    $nextInvocationType = "development"
    $latestValidationReport = ""
    $repairNumber = 0

    for ($attempt = 1; $attempt -le $EffectiveMaxAttempts; $attempt++) {
        if ($nextInvocationType -eq "development") {
            $prompt = New-DevelopmentPrompt
        }
        else {
            $repairNumber++
            $prompt = New-RepairPrompt `
                -RepairNumber $repairNumber `
                -ValidationReport $latestValidationReport `
                -GitChanges (Get-GitChangeText)
        }

        $agentRecord = Invoke-AgentAttempt `
            -Attempt $attempt `
            -InvocationType $nextInvocationType `
            -Prompt $prompt
        $script:AgentRecords += $agentRecord
        Assert-GitIdentityUnchanged

        if (-not $agentRecord.ContractValid) {
            $FailureReason = (
                "Agent attempt {0:D2} violated the Agent Contract: {1}" -f `
                    $attempt,
                    $agentRecord.ContractError
            )
            continue
        }

        if ($agentRecord.ExitCode -ne 0) {
            $FailureReason = (
                "Agent attempt {0:D2} returned exit code {1}. " +
                "Validation was not run for this attempt." -f `
                    $attempt,
                    $agentRecord.ExitCode
            )
            continue
        }

        $validationResult = Invoke-ValidationAttempt -Attempt $attempt
        Assert-GitIdentityUnchanged
        $snapshot = Save-ValidationSnapshot -Attempt $attempt
        if ($validationResult.ExitCode -eq 0) {
            $resultText = "PASSED"
        }
        else {
            $resultText = "FAILED"
        }
        $script:ValidationRecords += [PSCustomObject]@{
            Attempt = $attempt
            Started = $validationResult.Started
            Finished = $validationResult.Finished
            ExitCode = [int]$validationResult.ExitCode
            Result = $resultText
            SnapshotPath = $snapshot.RelativePath
        }

        if ($validationResult.ExitCode -eq 0) {
            $ValidationPassed = $true
            $WorkflowPassed = $true
            $FailureReason = ""
            break
        }

        $latestValidationReport = $snapshot.Text
        $nextInvocationType = "repair"
        $FailureReason = (
            "Validation attempt {0:D2} returned exit code {1}." -f `
                $attempt,
                $validationResult.ExitCode
        )
    }

    if (-not $ValidationPassed) {
        $WorkflowPassed = $false
        if ([string]::IsNullOrWhiteSpace($FailureReason)) {
            $FailureReason = (
                "The maximum number of Agent attempts was reached: " +
                $EffectiveMaxAttempts
            )
        }
    }
}
catch {
    $WorkflowPassed = $false
    Add-FailureReason $_.Exception.Message
    Write-Host ("Autonomous task error: " + $_.Exception.Message)
}
finally {
    if ($CleanupConfigured) {
        if ($CleanupEnabled) {
            $CleanupAttempted = $true
            Write-Host "Running Cleanup Adapter."
            try {
                $cleanupResult = Invoke-CleanupAdapter
                $CleanupExitCode = $cleanupResult.ExitCode
                $CleanupOutput = $cleanupResult.Output
                if ($CleanupExitCode -ne 0) {
                    $WorkflowPassed = $false
                    Add-FailureReason (
                        "Cleanup Adapter returned exit code " + $CleanupExitCode
                    )
                }
            }
            catch {
                $CleanupExitCode = -1
                $CleanupOutput = $_.Exception.Message
                $WorkflowPassed = $false
                Add-FailureReason ("Cleanup Adapter failed: " + $_.Exception.Message)
            }
        }
        else {
            $CleanupExitCode = 0
            $CleanupOutput = "(disabled by Project Config)"
        }
    }

    if ($InitialBranch -ne "(not recorded)" -and
        $InitialCommit -ne "(not recorded)") {
        try {
            Assert-GitIdentityUnchanged
        }
        catch {
            $WorkflowPassed = $false
            Add-FailureReason $_.Exception.Message
        }
    }
}

$EndTime = Get-Date
if ($InitialBranch -ne "(not recorded)") {
    try {
        $FinalGitChanges = Get-GitChangeText
    }
    catch {
        $FinalGitChanges = "Unable to read final Git changes: " + $_.Exception.Message
        $WorkflowPassed = $false
        Add-FailureReason $FinalGitChanges
    }
}

if ($ReportsEnabled) {
    try {
        [void][System.IO.Directory]::CreateDirectory($ReportDirectory)
        Add-AutonomousReportContent
        Write-Utf8File `
            -Path $AutonomousReportPath `
            -Content ($script:ReportLines -join [Environment]::NewLine)
        Write-Host ("Autonomous report written to: " + $AutonomousReportPath)
    }
    catch {
        $WorkflowPassed = $false
        Add-FailureReason ("Unable to write autonomous report: " + $_.Exception.Message)
        Write-Host ("Unable to write autonomous report: " + $_.Exception.Message)
    }
}

if ($WorkflowPassed) {
    Write-Host "AUTONOMOUS TASK PASSED"
    Write-Host "Code has not been committed; a human must inspect the Git diff."
    exit 0
}

Write-Host "AUTONOMOUS TASK FAILED"
if (-not [string]::IsNullOrWhiteSpace($FailureReason)) {
    Write-Host ("Failure reason: " + $FailureReason)
}
exit 1
