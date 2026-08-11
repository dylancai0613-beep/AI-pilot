[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ProjectRoot,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigFile,

    [Parameter(Mandatory = $true, ParameterSetName = "New")]
    [ValidateNotNullOrEmpty()]
    [string]$TaskFile,

    [Parameter(Mandatory = $true, ParameterSetName = "Resume")]
    [ValidateNotNullOrEmpty()]
    [string]$ResumeRunId,

    [Parameter(ParameterSetName = "New")]
    [int]$MaxAttempts
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$script:ReportLines = New-Object "System.Collections.Generic.List[string]"
$script:AgentRecords = @()
$script:ValidationRecords = @()
$script:ReviewRecords = @()
$script:AgentSequence = 0

$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$ProjectRootPrefix = $ProjectRoot.TrimEnd([char[]]@("\", "/")) +
    [System.IO.Path]::DirectorySeparatorChar
$StartTime = Get-Date
$EndTime = $null
$ProjectName = "(not loaded)"
$TaskFullPath = ""
$TaskRelativePath = "(not resolved)"
$AgentContractPath = ""
$ReviewContractPath = ""
$ReviewGatePath = ""
$RunStateContractPath = ""
$TrajectoryContractPath = ""
$WorkspaceFingerprintPath = ""
$RunStateModulePath = ""
$PersistentWorkflowPath = ""
$DeveloperProfile = $null
$ReviewerProfile = $null
$ReviewerEnabled = $false
$ReviewerResolvedModel = "null"
$ValidationAdapterPath = ""
$CleanupAdapterPath = ""
$ValidationReportPath = ""
$ReportDirectory = ""
$LatestReportDirectory = ""
$AutonomousReportPath = ""
$RunsDirectory = ""
$RunDirectory = ""
$RunArtifactsDirectory = ""
$RunStatePath = ""
$TrajectoryPath = ""
$RunSummaryPath = ""
$RunId = "(not created)"
$RunState = $null
$RunContext = $null
$InitialBranch = "(not recorded)"
$InitialCommit = "(not recorded)"
$InitialGitStatus = "(not recorded)"
$FinalGitChanges = "(not recorded)"
$WorkflowPassed = $false
$ValidationGateStatus = "NOT_RUN"
$ReviewGateStatus = "NOT_RUN"
$CleanupGateStatus = "NOT_RUN"
$FailureReason = ""
$CleanupConfigured = $false
$CleanupEnabled = $false
$CleanupAttempted = $false
$CleanupExitCode = $null
$CleanupOutput = "(not attempted)"
$ReportsEnabled = $false
$EffectiveMaxAttempts = 0
$EffectiveMaxReviewCycles = 0
$EffectiveMaxReviewerAttempts = 0

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

function Convert-ProjectArtifactToRunRelative {
    param([Parameter(Mandatory = $true)][string]$ProjectRelativePath)
    $full = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $ProjectRelativePath))
    return Get-RunRelativePath $RunDirectory $full
}

function Read-RunArtifactText {
    param([AllowNull()][object]$RelativePath)
    if ($null -eq $RelativePath -or
        [string]::IsNullOrWhiteSpace([string]$RelativePath)) {
        return ""
    }
    $full = [System.IO.Path]::GetFullPath(
        (Join-Path $RunDirectory ([string]$RelativePath))
    )
    [void](Get-RunRelativePath $RunDirectory $full)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw ("Run artifact was not found: " + $RelativePath)
    }
    return Read-TextFile $full
}

function Add-InterruptedContinuationInstructions {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [AllowNull()][object]$InterruptedStage,
        [bool]$WorkspaceChanged
    )
    if ($null -eq $InterruptedStage -or
        [string]$InterruptedStage -notin @("development", "repair")) {
        return $Prompt
    }
    return @"
上一次 Developer Agent attempt 在执行中被中断。
当前 workspace 可能包含 partial changes：$WorkspaceChanged。
先检查当前 Git diff，在现有修改基础上继续完成原任务；
不得假设上一次 attempt 已完成，也不得丢弃或自动恢复现有修改。

$Prompt
"@
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

function Resolve-AgentProfile {
    param(
        [Parameter(Mandatory = $true)][hashtable]$ProfileConfig,
        [Parameter(Mandatory = $true)][string]$Role
    )

    $adapterPath = Resolve-ProjectPath `
        -CandidatePath (Get-RequiredString `
            -Section $ProfileConfig `
            -Name "AdapterPath" `
            -Description ($Role + ".AdapterPath")) `
        -Description ($Role + " Agent Adapter")
    if (-not (Test-Path -LiteralPath $adapterPath -PathType Leaf)) {
        throw ($Role + " Agent Adapter was not found: " + $adapterPath)
    }

    return [PSCustomObject]@{
        Role = $Role
        AdapterPath = $adapterPath
        Runtime = Get-RequiredSection $ProfileConfig "Runtime"
        Model = Get-RequiredSection $ProfileConfig "Model"
        Options = Get-RequiredSection $ProfileConfig "Options"
    }
}

function Invoke-GitReadCommand {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $LASTEXITCODE = 0
    $previousErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $outputLines = @(
            & git -c core.safecrlf=false @Arguments 2>&1 |
                ForEach-Object { $_.ToString() }
        )
    }
    finally { $ErrorActionPreference = $previousErrorPreference }
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

function Get-GitStableStatus {
    $result = Invoke-GitReadCommand `
        -Arguments @("status", "--porcelain=v1", "--untracked-files=all")
    return $result.Text
}

function Get-GitDiffText {
    $result = Invoke-GitReadCommand `
        -Arguments @("diff", "--no-ext-diff", "--")
    if ($result.Lines.Count -eq 0) {
        return "(no tracked diff)"
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

function New-ValidationRepairPrompt {
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

function New-ReviewPrompt {
    param(
        [Parameter(Mandatory = $true)][string]$ReviewId,
        [Parameter(Mandatory = $true)][string]$ReviewerAgentAttemptId,
        [Parameter(Mandatory = $true)][string]$ReviewResultFile,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ValidationReport,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$GitChanges,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$GitDiff
    )

    return @"
你是独立 Reviewer。你只执行 Review，不修改或修复项目代码。

必须完整读取：
1. AGENTS.md
2. 原任务文件：$TaskRelativePath
3. 当前 Git diff 与 Git 修改列表
4. 当前 Validation Report
5. 与修改直接相关的代码和测试

只允许写入 Review Result 文件：$ReviewResultFile
不得修改其他项目文件，不得删除文件，不得执行任何 Git 写操作；
不得 add、commit、push、reset、restore、checkout、clean；
不得改变 branch 或 HEAD，不得运行项目 Validation 或任何容器命令。
Validation 通过不等于 Review Approved，Agent 的自然语言自述也不是质量证据。

至少检查：
1. 原任务是否真正完成；
2. 是否超出允许修改范围；
3. 是否存在明显 correctness bug；
4. 是否存在安全或破坏性行为；
5. 是否存在测试覆盖缺口；
6. 是否存在与 Task 不一致的实现；
7. 是否存在明显维护性问题；
8. Validation 未覆盖的重要问题。

必须将最终结论作为 UTF-8 JSON 写入指定文件，stdout 仅作为日志且不会参与 Gate。
Review Result 必须严格使用 SchemaVersion 1：
- ReviewId 必须为 "$ReviewId"；
- ReviewerAgentAttemptId 必须为 "$ReviewerAgentAttemptId"；
- Verdict 只能为 approved 或 changes_requested；
- approved 不得包含 Blocking=true 的 Finding；
- changes_requested 必须至少包含一个 Blocking=true 的 Finding；
- Finding 字段必须为 Id、Severity、Blocking、Category、File、Line、Message、Evidence；
- Severity 只能为 blocker、major、minor；
- File 为 null 或项目内相对路径，Line 为 null 或正整数；
- Evidence 必须是简洁的内联文本证据，不得依赖外部附件。

===== Git 修改列表 =====
$GitChanges

===== 当前 Git diff =====
$GitDiff

===== Validation Report =====
$ValidationReport
"@
}

function New-ReviewRepairPrompt {
    param(
        [Parameter(Mandatory = $true)][int]$ReviewRepairCycle,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ValidationReport,
        [Parameter(Mandatory = $true)][object]$ReviewResult,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$GitChanges
    )

    $reviewJson = $ReviewResult | ConvertTo-Json -Depth 32
    $blockingFindings = @(
        $ReviewResult.Findings | Where-Object { $_.Blocking -eq $true }
    ) | ConvertTo-Json -Depth 32
    return @"
你是 Developer Agent，正在执行第 $ReviewRepairCycle 个 Review Repair Cycle。

开始前必须完整读取 AGENTS.md、原任务文件 $TaskRelativePath 和相关代码。
只修复下方有效 Review Result 中真实存在的 Blocking Findings。
不得扩大原 Task 的修改范围，不得运行项目 Validation 或任何容器命令。
不得执行任何 Git 写操作，不得 add、commit、push、reset、restore、checkout、clean；
不得改变 branch 或 HEAD，不得提交代码。
修复后总控会重新执行完整 Validation，再重新 Review。

===== 最新 Validation Report =====
$ValidationReport

===== 完整 Review Result =====
$reviewJson

===== Blocking Findings =====
$blockingFindings

===== 当前 Git 修改列表 =====
$GitChanges
"@
}

function Invoke-AgentAttempt {
    param(
        [Parameter(Mandatory = $true)][int]$Attempt,
        [Parameter(Mandatory = $true)][object]$AgentProfile,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$InvocationType,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Prompt
    )

    $agentAdapterPath = [string]$AgentProfile.AdapterPath
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
        Runtime = $AgentProfile.Runtime
        Model = $AgentProfile.Model
        Options = $AgentProfile.Options
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
                ('"{0}"' -f $agentAdapterPath),
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
Role: $Role
Invocation type: $InvocationType
Adapter: $(Get-ProjectRelativePath -FullPath $agentAdapterPath)
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
        Role = $Role
        AdapterPath = Get-ProjectRelativePath -FullPath $agentAdapterPath
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
        ResolvedModelValue = $resolvedModel
        Message = $message
        PromptPath = Get-ProjectRelativePath -FullPath $promptPath
        StdoutPath = Get-ProjectRelativePath -FullPath $stdoutPath
        StderrPath = Get-ProjectRelativePath -FullPath $stderrPath
        RequestPath = Get-ProjectRelativePath -FullPath $requestPath
        ResultPath = Get-ProjectRelativePath -FullPath $resultPath
        LogPath = Get-ProjectRelativePath -FullPath $logPath
    }
}

function Invoke-NextAgentAttempt {
    param(
        [Parameter(Mandatory = $true)][object]$AgentProfile,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$InvocationType,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Prompt
    )

    $script:AgentSequence++
    $record = Invoke-AgentAttempt `
        -Attempt $script:AgentSequence `
        -AgentProfile $AgentProfile `
        -Role $Role `
        -InvocationType $InvocationType `
        -Prompt $Prompt
    $script:AgentRecords += $record
    return $record
}

function Invoke-ReviewerGateAttempt {
    param(
        [Parameter(Mandatory = $true)][int]$ReviewSequence,
        [Parameter(Mandatory = $true)][int]$ReviewerTechnicalAttempt,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ValidationReport
    )

    $reviewId = "review-cycle-{0:D2}" -f $ReviewSequence
    $reviewResultPath = Join-Path `
        $ReportDirectory `
        ("current-review-cycle-{0:D2}.result.json" -f $ReviewSequence)
    Remove-TemporaryFile -Path $reviewResultPath

    $nextAgentAttempt = $script:AgentSequence + 1
    $expectedAgentAttemptId = "agent-attempt-{0:D2}" -f $nextAgentAttempt
    $beforeStatus = Get-GitStableStatus
    $prompt = New-ReviewPrompt `
        -ReviewId $reviewId `
        -ReviewerAgentAttemptId $expectedAgentAttemptId `
        -ReviewResultFile $reviewResultPath `
        -ValidationReport $ValidationReport `
        -GitChanges (Get-GitChangeText) `
        -GitDiff (Get-GitDiffText)

    $agentRecord = Invoke-NextAgentAttempt `
        -AgentProfile $ReviewerProfile `
        -Role "Reviewer" `
        -InvocationType "review" `
        -Prompt $prompt
    $afterStatus = Get-GitStableStatus
    try {
        Assert-GitIdentityUnchanged
        [void](Assert-ReviewGitSnapshotUnchanged `
            -Before $beforeStatus `
            -After $afterStatus)
    }
    catch {
        return [PSCustomObject]@{
            TechnicalSucceeded = $false
            Fatal = $true
            FailureReason = $_.Exception.Message
            Verdict = $null
            ReviewResult = $null
        }
    }

    if (-not $agentRecord.ContractValid) {
        return [PSCustomObject]@{
            TechnicalSucceeded = $false
            Fatal = $false
            FailureReason = (
                "Reviewer Agent violated the Agent Contract: " +
                $agentRecord.ContractError
            )
            Verdict = $null
            ReviewResult = $null
        }
    }
    if ($agentRecord.ExitCode -ne 0) {
        return [PSCustomObject]@{
            TechnicalSucceeded = $false
            Fatal = $false
            FailureReason = (
                "Reviewer Agent returned exit code " + $agentRecord.ExitCode
            )
            Verdict = $null
            ReviewResult = $null
        }
    }

    try {
        $reviewResult = Read-ReviewContractJson `
            -LiteralPath $reviewResultPath `
            -Description "Review Result"
        $contractSummary = Assert-ReviewResultContract `
            -Result $reviewResult `
            -ExpectedReviewId $reviewId `
            -ExpectedReviewerAgentAttemptId $agentRecord.AttemptId `
            -ProjectRoot $ProjectRoot
    }
    catch {
        return [PSCustomObject]@{
            TechnicalSucceeded = $false
            Fatal = $false
            FailureReason = ("Review Contract violation: " + $_.Exception.Message)
            Verdict = $null
            ReviewResult = $null
        }
    }

    $script:ReviewerResolvedModel = $agentRecord.ResolvedModel
    $script:ReviewRecords += [PSCustomObject]@{
        ReviewId = $reviewId
        ReviewerAgentAttemptId = $agentRecord.AttemptId
        ReviewerTechnicalAttempt = $ReviewerTechnicalAttempt
        Verdict = $contractSummary.Verdict
        Summary = [string]$reviewResult.Summary
        BlockingFindingCount = $contractSummary.BlockingFindingCount
        TotalFindingCount = $contractSummary.TotalFindingCount
        ResultPath = Get-ProjectRelativePath -FullPath $reviewResultPath
    }
    return [PSCustomObject]@{
        TechnicalSucceeded = $true
        Fatal = $false
        FailureReason = ""
        Verdict = $contractSummary.Verdict
        ReviewResult = $reviewResult
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
    Add-ReportLine ("RunId: " + $RunId)
    Add-ReportLine ("Authoritative State: " + (Get-ProjectRelativePath $RunStatePath))
    Add-ReportLine ("Trajectory: " + (Get-ProjectRelativePath $TrajectoryPath))
    Add-ReportLine ("ProjectName: " + $ProjectName)
    Add-ReportLine ("Project root: " + $ProjectRoot)
    Add-ReportLine ("TaskFile: " + $TaskRelativePath)
    Add-ReportLine (
        "Developer Agent Adapter: " +
        (Get-ProjectRelativePath $DeveloperProfile.AdapterPath)
    )
    Add-ReportLine (
        "Developer Runtime: " +
        (ConvertTo-AgentContractDisplayJson -Value $DeveloperProfile.Runtime)
    )
    Add-ReportLine (
        "Developer Requested Model: " +
        (ConvertTo-AgentContractDisplayJson -Value $DeveloperProfile.Model)
    )
    Add-ReportLine (
        "Developer Agent Options: " +
        (ConvertTo-AgentContractDisplayJson -Value $DeveloperProfile.Options)
    )
    Add-ReportLine ("Reviewer Enabled: " + $ReviewerEnabled)
    if ($ReviewerEnabled) {
        Add-ReportLine (
            "Reviewer Agent Adapter: " +
            (Get-ProjectRelativePath $ReviewerProfile.AdapterPath)
        )
        Add-ReportLine (
            "Reviewer Runtime: " +
            (ConvertTo-AgentContractDisplayJson -Value $ReviewerProfile.Runtime)
        )
        Add-ReportLine (
            "Reviewer Requested Model: " +
            (ConvertTo-AgentContractDisplayJson -Value $ReviewerProfile.Model)
        )
        Add-ReportLine ("Reviewer Resolved Model: " + $ReviewerResolvedModel)
    }
    else {
        Add-ReportLine "Reviewer Agent Adapter: (disabled)"
        Add-ReportLine "Reviewer Runtime: (disabled)"
        Add-ReportLine "Reviewer Requested Model: (disabled)"
        Add-ReportLine "Reviewer Resolved Model: (disabled)"
    }
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
    Add-ReportLine ("MaxReviewCycles: " + $EffectiveMaxReviewCycles)
    Add-ReportLine ("MaxReviewerAttempts: " + $EffectiveMaxReviewerAttempts)
    if ($null -ne $RunState) {
        Add-ReportLine ("DeveloperAttempts: " + $RunState.Counters.DeveloperAttempts)
        Add-ReportLine ("ValidationAttempts: " + $RunState.Counters.ValidationAttempts)
        Add-ReportLine ("ReviewerAttempts: " + $RunState.Counters.ReviewerAttempts)
        Add-ReportLine ("ReviewCycles: " + $RunState.Counters.ReviewCycles)
    }

    Add-ReportLine ""
    Add-ReportLine "===== Agent attempts ====="
    if ($script:AgentRecords.Count -eq 0) {
        Add-ReportLine "(none)"
    }
    else {
        foreach ($record in $script:AgentRecords) {
            Add-ReportLine (
                "Agent attempt {0:D2}: id={1}; role={2}; type={3}; status={4}; " +
                "started={5}; finished={6}; adapterProcessExitCode={7}; " +
                "agentExitCode={8}; adapter={9}; runtime={10}; " +
                "requestedModel={11}; resolvedModel={12}; request={13}; " +
                "result={14}; log={15}" -f `
                    $record.Attempt,
                    $record.AttemptId,
                    $record.Role,
                    $record.InvocationType,
                    $record.AdapterStatus,
                    $record.Started,
                    $record.Finished,
                    $record.AdapterProcessExitCode,
                    $record.ExitCode,
                    $record.AdapterPath,
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
    Add-ReportLine "===== Review cycles ====="
    if (-not $ReviewerEnabled) {
        Add-ReportLine "Review Gate: DISABLED"
    }
    elseif ($script:ReviewRecords.Count -eq 0) {
        Add-ReportLine "(none)"
    }
    else {
        foreach ($record in $script:ReviewRecords) {
            Add-ReportLine (
                "ReviewId={0}; reviewerAgentAttempt={1}; technicalAttempt={2}; " +
                "verdict={3}; summary={4}; blockingFindings={5}; " +
                "totalFindings={6}; result={7}" -f `
                    $record.ReviewId,
                    $record.ReviewerAgentAttemptId,
                    $record.ReviewerTechnicalAttempt,
                    $record.Verdict,
                    $record.Summary,
                    $record.BlockingFindingCount,
                    $record.TotalFindingCount,
                    $record.ResultPath
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
    Add-ReportLine "===== Quality gates ====="
    Add-ReportLine ("Validation Gate: " + $ValidationGateStatus)
    Add-ReportLine ("Review Gate: " + $ReviewGateStatus)
    Add-ReportLine ("Cleanup Gate: " + $CleanupGateStatus)

    Add-ReportLine ""
    Add-ReportLine "===== Final conclusion ====="
    if ($WorkflowPassed) {
        Add-ReportLine "AUTONOMOUS TASK PASSED"
        Add-ReportLine "All enabled quality gates passed."
    }
    else {
        Add-ReportLine "AUTONOMOUS TASK FAILED"
        Add-ReportLine ("Failure reason: " + $FailureReason)
    }

    Add-ReportLine ""
    Add-ReportLine "Code has not been committed."
    Add-ReportLine "A human must inspect the Git diff."
}

function Write-RunSummary {
    if ($null -eq $RunState -or
        [string]$RunState.Status -notin @("completed", "failed")) {
        return
    }
    $created = [DateTimeOffset]::Parse([string]$RunState.CreatedAt)
    $finished = [DateTimeOffset]::Parse([string]$RunState.UpdatedAt)
    $duration = [math]::Max(0, [int64]($finished - $created).TotalSeconds)
    $failureText = ""
    if ($null -ne $RunState.Failure) {
        $failureText = [string]$RunState.Failure.Message
    }
    $summary = @"
RunId: $RunId
Project: $ProjectName
Task: $TaskRelativePath
StartedAt: $($RunState.CreatedAt)
FinishedAt: $($RunState.UpdatedAt)
DurationSeconds: $duration
FinalStatus: $($RunState.Status)
DeveloperAttempts: $($RunState.Counters.DeveloperAttempts)
ValidationAttempts: $($RunState.Counters.ValidationAttempts)
ReviewerAttempts: $($RunState.Counters.ReviewerAttempts)
ReviewCycles: $($RunState.Counters.ReviewCycles)
ValidationGate: $($RunState.Gates.Validation)
ReviewGate: $($RunState.Gates.Review)
CleanupGate: $($RunState.Gates.Cleanup)
FinalGitChanges: $FinalGitChanges
FailureReason: $failureText
TrajectoryPath: $(Get-ProjectRelativePath $TrajectoryPath)
"@
    Write-Utf8File -Path $RunSummaryPath -Content $summary
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
    $agentsConfig = Get-RequiredSection $configuration "Agents"
    $developerConfig = Get-RequiredSection $agentsConfig "Developer"
    $reviewerConfig = Get-RequiredSection $agentsConfig "Reviewer"
    if (-not $reviewerConfig.ContainsKey("Enabled") -or
        -not ($reviewerConfig.Enabled -is [bool])) {
        throw "Agents.Reviewer.Enabled must be boolean."
    }
    $ReviewerEnabled = [bool]$reviewerConfig.Enabled
    $validationConfig = Get-RequiredSection $configuration "Validation"
    $cleanupConfig = Get-RequiredSection $configuration "Cleanup"
    $reportsConfig = Get-RequiredSection $configuration "Reports"
    $runsConfig = Get-RequiredSection $configuration "Runs"
    $defaultsConfig = Get-RequiredSection $configuration "Defaults"

    $AgentContractPath = Resolve-ProjectPath `
        -CandidatePath "automation\contracts\AgentContract.ps1" `
        -Description "Agent Contract"
    $ReviewContractPath = Resolve-ProjectPath `
        -CandidatePath "automation\contracts\ReviewContract.ps1" `
        -Description "Review Contract"
    $ReviewGatePath = Resolve-ProjectPath `
        -CandidatePath "automation\core\ReviewGate.ps1" `
        -Description "Review Gate"
    $RunStateContractPath = Resolve-ProjectPath `
        -CandidatePath "automation\contracts\RunStateContract.ps1" `
        -Description "Run State Contract"
    $TrajectoryContractPath = Resolve-ProjectPath `
        -CandidatePath "automation\contracts\TrajectoryContract.ps1" `
        -Description "Trajectory Contract"
    $WorkspaceFingerprintPath = Resolve-ProjectPath `
        -CandidatePath "automation\core\WorkspaceFingerprint.ps1" `
        -Description "Workspace Fingerprint"
    $RunStateModulePath = Resolve-ProjectPath `
        -CandidatePath "automation\core\RunState.ps1" `
        -Description "Run State module"
    $PersistentWorkflowPath = Resolve-ProjectPath `
        -CandidatePath "automation\core\PersistentWorkflow.ps1" `
        -Description "Persistent Workflow"
    $ValidationAdapterPath = Resolve-ProjectPath `
        -CandidatePath (Get-RequiredString $validationConfig "AdapterPath" "Validation.AdapterPath") `
        -Description "Validation Adapter"
    $ValidationReportPath = Resolve-ProjectPath `
        -CandidatePath (Get-RequiredString $validationConfig "ReportPath" "Validation.ReportPath") `
        -Description "Validation Report"
    $LatestReportDirectory = Resolve-ProjectPath `
        -CandidatePath (Get-RequiredString $reportsConfig "Directory" "Reports.Directory") `
        -Description "Reports Directory"
    $AutonomousReportPath = Resolve-ProjectPath `
        -CandidatePath (Get-RequiredString $reportsConfig "AutonomousLatest" "Reports.AutonomousLatest") `
        -Description "Autonomous Report"
    $RunsDirectory = Resolve-ProjectPath `
        -CandidatePath (Get-RequiredString $runsConfig "Directory" "Runs.Directory") `
        -Description "Runs Directory"

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

    foreach ($requiredFrameworkFile in @(
        $AgentContractPath,
        $ReviewContractPath,
        $ReviewGatePath,
        $RunStateContractPath,
        $TrajectoryContractPath,
        $WorkspaceFingerprintPath,
        $RunStateModulePath,
        $PersistentWorkflowPath
    )) {
        if (-not (Test-Path -LiteralPath $requiredFrameworkFile -PathType Leaf)) {
            throw ("Required framework file was not found: " + $requiredFrameworkFile)
        }
    }
    . $AgentContractPath
    . $ReviewContractPath
    . $ReviewGatePath
    . $RunStateContractPath
    . $TrajectoryContractPath
    . $WorkspaceFingerprintPath
    . $RunStateModulePath
    . $PersistentWorkflowPath

    $DeveloperProfile = Resolve-AgentProfile `
        -ProfileConfig $developerConfig `
        -Role "Developer"
    if ($ReviewerEnabled) {
        $ReviewerProfile = Resolve-AgentProfile `
            -ProfileConfig $reviewerConfig `
            -Role "Reviewer"
    }
    if (-not (Test-Path -LiteralPath $ValidationAdapterPath -PathType Leaf)) {
        throw ("Configured Adapter was not found: " + $ValidationAdapterPath)
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

    if ($PSCmdlet.ParameterSetName -eq "Resume") {
        if (-not ($ResumeRunId -match
            "\Arun-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}\z")) {
            throw "RunId has an unsupported or unsafe format."
        }
        $RunId = $ResumeRunId
        $RunDirectory = Resolve-ProjectPath `
            -CandidatePath (Join-Path $RunsDirectory $RunId) `
            -Description "Run Directory"
        if (-not (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
            throw ("RUN_NOT_FOUND: " + $RunId)
        }
        $RunStatePath = Join-Path $RunDirectory "state.json"
        $TrajectoryPath = Join-Path $RunDirectory "trajectory.jsonl"
        $RunSummaryPath = Join-Path $RunDirectory "summary.txt"
        $RunArtifactsDirectory = Join-Path $RunDirectory "artifacts"
        $statePreview = Read-RunStateJson $RunStatePath "Run State"
        [void](Assert-RunStateContract $statePreview $ProjectRoot $RunId)
        $TaskFile = [string]$statePreview.Task.Path
    }

    $TaskFullPath = Resolve-ProjectPath `
        -CandidatePath $TaskFile `
        -Description "TaskFile"
    if (-not (Test-Path -LiteralPath $TaskFullPath -PathType Leaf)) {
        throw ("TaskFile was not found: " + $TaskFullPath)
    }
    $TaskRelativePath = Get-ProjectRelativePath $TaskFullPath

    if ($PSCmdlet.ParameterSetName -eq "Resume") {
        $EffectiveMaxAttempts = [int]$statePreview.EffectiveLimits.MaxAttempts
        $EffectiveMaxReviewCycles = [int]$statePreview.EffectiveLimits.MaxReviewCycles
        $EffectiveMaxReviewerAttempts = [int]$statePreview.EffectiveLimits.MaxReviewerAttempts
    }
    elseif ($PSBoundParameters.ContainsKey("MaxAttempts")) {
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
    foreach ($defaultName in @("MaxReviewCycles", "MaxReviewerAttempts")) {
        if (-not $defaultsConfig.ContainsKey($defaultName)) {
            throw ("Missing configuration value: Defaults." + $defaultName)
        }
    }
    if ($PSCmdlet.ParameterSetName -ne "Resume") {
        $EffectiveMaxReviewCycles = [int]$defaultsConfig.MaxReviewCycles
        $EffectiveMaxReviewerAttempts = [int]$defaultsConfig.MaxReviewerAttempts
    }
    if (($EffectiveMaxReviewCycles -lt 0) -or
        ($EffectiveMaxReviewCycles -gt 5)) {
        throw "MaxReviewCycles must be between 0 and 5."
    }
    if (($EffectiveMaxReviewerAttempts -lt 1) -or
        ($EffectiveMaxReviewerAttempts -gt 5)) {
        throw "MaxReviewerAttempts must be between 1 and 5."
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
    if ($PSCmdlet.ParameterSetName -eq "New" -and
        $InitialGitStatus -ne "(clean)") {
        throw (
            "The initial Git working tree is not clean. " +
            "No Agent process will be started. Changes:" +
            [Environment]::NewLine + $InitialGitStatus
        )
    }

    $fingerprintExclusions = @(
        (Get-ProjectRelativePath $RunsDirectory),
        (Get-ProjectRelativePath $LatestReportDirectory)
    )
    $getFingerprint = {
        Get-WorkspaceFingerprint `
            -ProjectRoot $ProjectRoot `
            -ExcludeRelativePrefixes $fingerprintExclusions
    }

    if ($PSCmdlet.ParameterSetName -eq "New") {
        [void][System.IO.Directory]::CreateDirectory($RunsDirectory)
        do {
            $RunId = New-RunId
            $RunDirectory = Join-Path $RunsDirectory $RunId
        } while (Test-Path -LiteralPath $RunDirectory)
        $RunArtifactsDirectory = Join-Path $RunDirectory "artifacts"
        [void][System.IO.Directory]::CreateDirectory($RunArtifactsDirectory)
        $RunStatePath = Join-Path $RunDirectory "state.json"
        $TrajectoryPath = Join-Path $RunDirectory "trajectory.jsonl"
        $RunSummaryPath = Join-Path $RunDirectory "summary.txt"
        $initialFingerprint = & $getFingerprint
        $RunState = New-InitialRunState `
            -RunId $RunId `
            -ProjectName $ProjectName `
            -TaskPath $TaskRelativePath `
            -TaskSha256 (Get-RunFileSha256 $TaskFullPath) `
            -ConfigPath (Get-ProjectRelativePath $ConfigFile) `
            -ConfigSha256 (Get-RunFileSha256 $ConfigFile) `
            -InitialBranch $InitialBranch `
            -InitialHead $InitialCommit `
            -WorkspaceFingerprint $initialFingerprint.Hash `
            -MaxAttempts $EffectiveMaxAttempts `
            -MaxReviewCycles $EffectiveMaxReviewCycles `
            -MaxReviewerAttempts $EffectiveMaxReviewerAttempts `
            -ReviewerEnabled $ReviewerEnabled `
            -CleanupEnabled $CleanupEnabled
        $RunContext = @{
            ProjectRoot = $ProjectRoot
            RunDirectory = $RunDirectory
            StatePath = $RunStatePath
            TrajectoryPath = $TrajectoryPath
        }
        [void](Initialize-PersistentRun $RunContext $RunState)
    }
    else {
        [void][System.IO.Directory]::CreateDirectory($RunArtifactsDirectory)
        $RunContext = @{
            ProjectRoot = $ProjectRoot
            RunDirectory = $RunDirectory
            StatePath = $RunStatePath
            TrajectoryPath = $TrajectoryPath
        }
        $RunState = Open-PersistentRunForResume `
            -RunContext $RunContext `
            -ExpectedRunId $RunId `
            -ExpectedProjectName $ProjectName `
            -ConfigPath $ConfigFile `
            -GetWorkspaceFingerprint $getFingerprint
        $InitialBranch = [string]$RunState.Git.InitialBranch
        $InitialCommit = [string]$RunState.Git.InitialHead
        $StartTime = [DateTimeOffset]::Parse([string]$RunState.CreatedAt).LocalDateTime
    }
    $ReportDirectory = $RunArtifactsDirectory
    $script:AgentSequence = [int]$RunState.Counters.DeveloperAttempts +
        [int]$RunState.Counters.ReviewerAttempts

    $stageCallback = {
        param($context)

        if ([string]$context.Stage -in @("development", "repair")) {
            if ([string]$context.Stage -eq "development") {
                $prompt = New-DevelopmentPrompt
                $invocationType = "development"
            }
            elseif ([string]$context.RepairKind -eq "validation") {
                $prompt = New-ValidationRepairPrompt `
                    -RepairNumber ([int]$context.Attempt - 1) `
                    -ValidationReport (Read-RunArtifactText $context.LastValidationArtifact) `
                    -GitChanges (Get-GitChangeText)
                $invocationType = "repair"
            }
            elseif ([string]$context.RepairKind -eq "review") {
                $reviewPath = Join-Path $RunDirectory ([string]$context.LastReviewArtifact)
                $reviewResult = Read-ReviewContractJson $reviewPath "Review Result"
                $prompt = New-ReviewRepairPrompt `
                    -ReviewRepairCycle ([int]$context.ReviewCycle) `
                    -ValidationReport (Read-RunArtifactText $context.LastValidationArtifact) `
                    -ReviewResult $reviewResult `
                    -GitChanges (Get-GitChangeText)
                $invocationType = "repair"
            }
            else { throw "Unsupported persisted RepairKind." }
            $prompt = Add-InterruptedContinuationInstructions `
                -Prompt $prompt `
                -InterruptedStage $context.InterruptedStage `
                -WorkspaceChanged ([bool]$context.InterruptedWorkspaceChanged)
            $started = Get-Date
            $agentRecord = Invoke-NextAgentAttempt `
                -AgentProfile $DeveloperProfile `
                -Role "Developer" `
                -InvocationType $invocationType `
                -Prompt $prompt
            Assert-GitIdentityUnchanged
            $succeeded = $agentRecord.ContractValid -and $agentRecord.ExitCode -eq 0
            $message = $(if ($succeeded) {
                "Developer Agent completed."
            } elseif (-not $agentRecord.ContractValid) {
                "Developer Agent Contract violation: " + $agentRecord.ContractError
            } else { "Developer Agent exit code: " + $agentRecord.ExitCode })
            return [PSCustomObject]@{
                Succeeded = $succeeded
                Message = $message
                DurationMs = [int64]((Get-Date) - $started).TotalMilliseconds
                Runtime = $DeveloperProfile.Runtime
                RequestedModel = $DeveloperProfile.Model
                ResolvedModel = $agentRecord.ResolvedModelValue
                Artifacts = [PSCustomObject]@{
                    AgentRequest = Convert-ProjectArtifactToRunRelative $agentRecord.RequestPath
                    AgentResult = Convert-ProjectArtifactToRunRelative $agentRecord.ResultPath
                    AgentPrompt = Convert-ProjectArtifactToRunRelative $agentRecord.PromptPath
                    Stdout = Convert-ProjectArtifactToRunRelative $agentRecord.StdoutPath
                    Stderr = Convert-ProjectArtifactToRunRelative $agentRecord.StderrPath
                    AgentLog = Convert-ProjectArtifactToRunRelative $agentRecord.LogPath
                }
            }
        }

        if ([string]$context.Stage -eq "validation") {
            $validationResult = Invoke-ValidationAttempt -Attempt ([int]$context.Attempt)
            Assert-GitIdentityUnchanged
            $validationFingerprint = & $getFingerprint
            if ([string]$validationFingerprint.Hash -ne
                [string]$RunState.PendingStage.StartWorkspaceFingerprint) {
                throw "Validation changed the project workspace."
            }
            $snapshot = Save-ValidationSnapshot -Attempt ([int]$context.Attempt)
            $passed = ($validationResult.ExitCode -eq 0)
            $resultText = $(if ($passed) { "PASSED" } else { "FAILED" })
            $message = $(if ($passed) { "Validation passed." } else {
                "Validation returned exit code " + $validationResult.ExitCode
            })
            $script:ValidationRecords += [PSCustomObject]@{
                Attempt = [int]$context.Attempt
                Started = $validationResult.Started
                Finished = $validationResult.Finished
                ExitCode = [int]$validationResult.ExitCode
                Result = $resultText
                SnapshotPath = $snapshot.RelativePath
            }
            $artifact = Convert-ProjectArtifactToRunRelative $snapshot.RelativePath
            return [PSCustomObject]@{
                Passed = $passed
                Message = $message
                ArtifactPath = $artifact
                DurationMs = [int64]($validationResult.Finished - $validationResult.Started).TotalMilliseconds
                Artifacts = [PSCustomObject]@{ ValidationReport = $artifact }
            }
        }

        if ([string]$context.Stage -eq "review") {
            $started = Get-Date
            $review = Invoke-ReviewerGateAttempt `
                -ReviewSequence ([int]$context.ReviewSequence) `
                -ReviewerTechnicalAttempt ([int]$context.ReviewerTechnicalAttempt) `
                -ValidationReport (Read-RunArtifactText $context.LastValidationArtifact)
            $message = [string]$review.FailureReason
            if ($review.TechnicalSucceeded) { $message = "Review " + $review.Verdict }
            $artifact = $null
            $artifacts = [PSCustomObject]@{}
            $findingCount = $null
            if ($review.TechnicalSucceeded) {
                $record = $script:ReviewRecords[-1]
                $artifact = Convert-ProjectArtifactToRunRelative $record.ResultPath
                $artifacts = [PSCustomObject]@{ ReviewResult = $artifact }
                $findingCount = [int]$record.TotalFindingCount
            }
            return [PSCustomObject]@{
                TechnicalSucceeded = [bool]$review.TechnicalSucceeded
                Fatal = [bool]$review.Fatal
                Verdict = $review.Verdict
                Message = $message
                ArtifactPath = $artifact
                FindingCount = $findingCount
                DurationMs = [int64]((Get-Date) - $started).TotalMilliseconds
                Runtime = $ReviewerProfile.Runtime
                RequestedModel = $ReviewerProfile.Model
                ResolvedModel = $null
                Artifacts = $artifacts
            }
        }

        if ([string]$context.Stage -eq "cleanup") {
            $CleanupAttempted = $true
            $started = Get-Date
            $cleanupResult = Invoke-CleanupAdapter
            $CleanupExitCode = $cleanupResult.ExitCode
            $CleanupOutput = $cleanupResult.Output
            Assert-GitIdentityUnchanged
            $cleanupFingerprint = & $getFingerprint
            if ([string]$cleanupFingerprint.Hash -ne
                [string]$RunState.PendingStage.StartWorkspaceFingerprint) {
                throw "Cleanup changed the project workspace."
            }
            return [PSCustomObject]@{
                Passed = ($CleanupExitCode -eq 0)
                Message = $(if ($CleanupExitCode -eq 0) {
                    "Cleanup passed."
                } else { "Cleanup exit code: " + $CleanupExitCode })
                DurationMs = [int64]((Get-Date) - $started).TotalMilliseconds
                Artifacts = [PSCustomObject]@{}
            }
        }
        throw ("Unsupported persistent stage: " + $context.Stage)
    }

    $RunState = Invoke-PersistentRunWorkflow `
        -RunContext $RunContext `
        -State $RunState `
        -GetWorkspaceFingerprint $getFingerprint `
        -InvokeExternalStage $stageCallback
    $ValidationGateStatus = [string]$RunState.Gates.Validation
    $ReviewGateStatus = [string]$RunState.Gates.Review
    $CleanupGateStatus = [string]$RunState.Gates.Cleanup
    $WorkflowPassed = ([string]$RunState.Status -eq "completed")
    if ($CleanupGateStatus -eq "DISABLED") {
        $CleanupExitCode = 0
        $CleanupOutput = "(disabled by Project Config)"
    }
    if ($null -ne $RunState.Failure) {
        $FailureReason = [string]$RunState.Failure.Message
    }
}
catch {
    $WorkflowPassed = $false
    Add-FailureReason $_.Exception.Message
    Write-Host ("Autonomous task error: " + $_.Exception.Message)
}
finally {
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
        Write-RunSummary
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
