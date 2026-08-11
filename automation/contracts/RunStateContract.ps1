Set-StrictMode -Version 2.0

$script:RunStateSchemaVersion = 1
$script:RunStatuses = @("initializing", "running", "completed", "failed", "interrupted")
$script:RunStages = @(
    "initializing",
    "development",
    "validation",
    "review",
    "repair",
    "cleanup",
    "complete"
)
$script:RunGateStates = @(
    "NOT_RUN",
    "PASSED",
    "FAILED",
    "DISABLED",
    "CHANGES_REQUESTED"
)
$script:RunNextActions = @(
    "development",
    "validation",
    "review",
    "repair",
    "cleanup",
    "complete"
)

function Test-RunStateProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return ($Object.PSObject.Properties.Name -contains $Name)
}

function Assert-RunStateProperties {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string[]]$Required,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($null -eq $Object -or $Object -is [string] -or $Object.GetType().IsValueType) {
        throw ($Description + " must be an object.")
    }
    foreach ($name in $Required) {
        if (-not (Test-RunStateProperty $Object $name)) {
            throw ("{0} is missing required field: {1}" -f $Description, $name)
        }
    }
    $unexpected = @(
        $Object.PSObject.Properties.Name |
            Where-Object { $Required -notcontains $_ }
    )
    if ($unexpected.Count -ne 0) {
        throw (
            "{0} contains unsupported field(s): {1}" -f `
                $Description,
                ($unexpected -join ", ")
        )
    }
}

function Test-RunStateInteger {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $false }
    return @(
        [TypeCode]::SByte,
        [TypeCode]::Byte,
        [TypeCode]::Int16,
        [TypeCode]::UInt16,
        [TypeCode]::Int32,
        [TypeCode]::UInt32,
        [TypeCode]::Int64,
        [TypeCode]::UInt64
    ) -contains [System.Type]::GetTypeCode($Value.GetType())
}

function Assert-RunStateNonEmptyString {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not ($Value -is [string]) -or
        [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw ($Description + " must be a non-empty string.")
    }
}

function Assert-RunStateSha256 {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-RunStateNonEmptyString $Value $Description
    if (-not ([string]$Value -match "\A[0-9a-fA-F]{64}\z")) {
        throw ($Description + " must be a SHA256 hex digest.")
    }
}

function Resolve-RunStateProjectPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [System.IO.Path]::IsPathRooted($RelativePath)) {
        throw ($Description + " must be a project-relative path.")
    }
    if (@($RelativePath.Replace("\", "/").Split("/")) -contains "..") {
        throw ($Description + " must not contain parent traversal.")
    }
    $root = [System.IO.Path]::GetFullPath($ProjectRoot)
    $prefix = $root.TrimEnd([char[]]@("\", "/")) +
        [System.IO.Path]::DirectorySeparatorChar
    $full = [System.IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    if (-not $full.StartsWith(
        $prefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw ($Description + " must remain inside ProjectRoot.")
    }
    return $full
}

function Read-RunStateJson {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [string]$Description = "Run State"
    )

    $path = [System.IO.Path]::GetFullPath($LiteralPath)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw ($Description + " was not found: " + $path)
    }
    try {
        return ([System.IO.File]::ReadAllText($path) | ConvertFrom-Json)
    }
    catch {
        throw ($Description + " is not valid JSON: " + $_.Exception.Message)
    }
}

function Assert-RunStateContract {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [AllowNull()][string]$ExpectedRunId
    )

    $topFields = @(
        "SchemaVersion", "RunId", "ProjectName", "Status", "CurrentStage",
        "Task", "Config", "Git", "Counters", "EffectiveLimits", "Gates",
        "LastCheckpoint", "PendingStage", "Workflow", "CreatedAt", "UpdatedAt",
        "Failure"
    )
    Assert-RunStateProperties $State $topFields "Run State"

    if (-not (Test-RunStateInteger $State.SchemaVersion) -or
        [int]$State.SchemaVersion -ne $script:RunStateSchemaVersion) {
        throw ("Unsupported Run State SchemaVersion: " + $State.SchemaVersion)
    }
    Assert-RunStateNonEmptyString $State.RunId "Run State RunId"
    if (-not ([string]$State.RunId -match
        "\Arun-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}\z")) {
        throw "Run State RunId has an unsupported format."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRunId) -and
        [string]$State.RunId -ne $ExpectedRunId) {
        throw "RUN_ID_MISMATCH: Run State RunId does not match the requested RunId."
    }
    Assert-RunStateNonEmptyString $State.ProjectName "Run State ProjectName"
    if (-not ($State.Status -is [string]) -or
        $script:RunStatuses -notcontains [string]$State.Status) {
        throw ("Unsupported Run State Status: " + $State.Status)
    }
    if (-not ($State.CurrentStage -is [string]) -or
        $script:RunStages -notcontains [string]$State.CurrentStage) {
        throw ("Unsupported Run State CurrentStage: " + $State.CurrentStage)
    }

    foreach ($pair in @(
        @("Task", $State.Task),
        @("Config", $State.Config)
    )) {
        $description = "Run State " + $pair[0]
        $value = $pair[1]
        Assert-RunStateProperties $value @("Path", "Sha256") $description
        Assert-RunStateNonEmptyString $value.Path ($description + ".Path")
        [void](Resolve-RunStateProjectPath `
            -ProjectRoot $ProjectRoot `
            -RelativePath ([string]$value.Path) `
            -Description ($description + ".Path"))
        Assert-RunStateSha256 $value.Sha256 ($description + ".Sha256")
    }

    Assert-RunStateProperties `
        $State.Git `
        @("InitialBranch", "InitialHead", "CurrentWorkspaceFingerprint") `
        "Run State Git"
    Assert-RunStateNonEmptyString $State.Git.InitialBranch "Run State Git.InitialBranch"
    Assert-RunStateNonEmptyString $State.Git.InitialHead "Run State Git.InitialHead"
    Assert-RunStateSha256 `
        $State.Git.CurrentWorkspaceFingerprint `
        "Run State Git.CurrentWorkspaceFingerprint"

    Assert-RunStateProperties `
        $State.Counters `
        @("DeveloperAttempts", "ReviewerAttempts", "ReviewCycles", "ValidationAttempts") `
        "Run State Counters"
    foreach ($name in $State.Counters.PSObject.Properties.Name) {
        $value = $State.Counters.$name
        if (-not (Test-RunStateInteger $value) -or [int64]$value -lt 0) {
            throw ("Run State Counters.{0} must be a non-negative integer." -f $name)
        }
    }

    Assert-RunStateProperties `
        $State.EffectiveLimits `
        @("MaxAttempts", "MaxReviewCycles", "MaxReviewerAttempts") `
        "Run State EffectiveLimits"
    foreach ($name in @("MaxAttempts", "MaxReviewerAttempts")) {
        $value = $State.EffectiveLimits.$name
        if (-not (Test-RunStateInteger $value) -or
            [int]$value -lt 1 -or [int]$value -gt 5) {
            throw ("Run State EffectiveLimits.{0} must be between 1 and 5." -f $name)
        }
    }
    $reviewLimit = $State.EffectiveLimits.MaxReviewCycles
    if (-not (Test-RunStateInteger $reviewLimit) -or
        [int]$reviewLimit -lt 0 -or [int]$reviewLimit -gt 5) {
        throw "Run State EffectiveLimits.MaxReviewCycles must be between 0 and 5."
    }

    Assert-RunStateProperties `
        $State.Gates `
        @("Validation", "Review", "Cleanup") `
        "Run State Gates"
    foreach ($name in $State.Gates.PSObject.Properties.Name) {
        if (-not ($State.Gates.$name -is [string]) -or
            $script:RunGateStates -notcontains [string]$State.Gates.$name) {
            throw ("Unsupported Run State Gate value: {0}={1}" -f `
                $name, $State.Gates.$name)
        }
    }

    Assert-RunStateProperties `
        $State.LastCheckpoint `
        @("Sequence", "Timestamp", "Stage") `
        "Run State LastCheckpoint"
    if (-not (Test-RunStateInteger $State.LastCheckpoint.Sequence) -or
        [int64]$State.LastCheckpoint.Sequence -lt 0) {
        throw "Run State LastCheckpoint.Sequence must be a non-negative integer."
    }
    if ($script:RunStages -notcontains [string]$State.LastCheckpoint.Stage) {
        throw "Run State LastCheckpoint.Stage is invalid."
    }
    $checkpointTime = [DateTimeOffset]::MinValue
    if (-not ($State.LastCheckpoint.Timestamp -is [string]) -or
        -not [DateTimeOffset]::TryParse(
            [string]$State.LastCheckpoint.Timestamp,
            [ref]$checkpointTime
        )) {
        throw "Run State LastCheckpoint.Timestamp is invalid."
    }

    if ($null -ne $State.PendingStage) {
        Assert-RunStateProperties `
            $State.PendingStage `
            @("Stage", "Action", "StartedSequence", "StartWorkspaceFingerprint", "Attempt") `
            "Run State PendingStage"
        if ($script:RunStages -notcontains [string]$State.PendingStage.Stage -or
            [string]$State.PendingStage.Stage -in @("initializing", "complete")) {
            throw "Run State PendingStage.Stage is invalid."
        }
        Assert-RunStateNonEmptyString $State.PendingStage.Action "Run State PendingStage.Action"
        if (-not (Test-RunStateInteger $State.PendingStage.StartedSequence) -or
            [int64]$State.PendingStage.StartedSequence -le 0) {
            throw "Run State PendingStage.StartedSequence must be positive."
        }
        Assert-RunStateSha256 `
            $State.PendingStage.StartWorkspaceFingerprint `
            "Run State PendingStage.StartWorkspaceFingerprint"
        if ($null -ne $State.PendingStage.Attempt -and
            (-not (Test-RunStateInteger $State.PendingStage.Attempt) -or
            [int64]$State.PendingStage.Attempt -le 0)) {
            throw "Run State PendingStage.Attempt must be null or positive."
        }
    }

    $workflowFields = @(
        "NextAction", "RepairKind", "ReviewSequence",
        "ReviewerTechnicalAttemptsInCycle", "LastValidationArtifact",
        "LastReviewArtifact", "ResumeCount", "InterruptedStage",
        "InterruptedWorkspaceChanged", "TerminalIntent"
    )
    Assert-RunStateProperties $State.Workflow $workflowFields "Run State Workflow"
    if ($script:RunNextActions -notcontains [string]$State.Workflow.NextAction) {
        throw "Run State Workflow.NextAction is invalid."
    }
    if ($null -ne $State.Workflow.RepairKind -and
        [string]$State.Workflow.RepairKind -notin @("validation", "review")) {
        throw "Run State Workflow.RepairKind is invalid."
    }
    foreach ($name in @(
        "ReviewSequence", "ReviewerTechnicalAttemptsInCycle", "ResumeCount"
    )) {
        if (-not (Test-RunStateInteger $State.Workflow.$name) -or
            [int64]$State.Workflow.$name -lt 0) {
            throw ("Run State Workflow.{0} must be non-negative." -f $name)
        }
    }
    foreach ($name in @("LastValidationArtifact", "LastReviewArtifact")) {
        if ($null -ne $State.Workflow.$name -and
            (-not ($State.Workflow.$name -is [string]) -or
            [string]::IsNullOrWhiteSpace([string]$State.Workflow.$name))) {
            throw ("Run State Workflow.{0} must be null or a string." -f $name)
        }
    }
    if ($null -ne $State.Workflow.InterruptedStage -and
        $script:RunStages -notcontains [string]$State.Workflow.InterruptedStage) {
        throw "Run State Workflow.InterruptedStage is invalid."
    }
    if (-not ($State.Workflow.InterruptedWorkspaceChanged -is [bool])) {
        throw "Run State Workflow.InterruptedWorkspaceChanged must be boolean."
    }
    if ($null -ne $State.Workflow.TerminalIntent -and
        [string]$State.Workflow.TerminalIntent -ne "failed") {
        throw "Run State Workflow.TerminalIntent is invalid."
    }

    $createdAt = [DateTimeOffset]::MinValue
    $updatedAt = [DateTimeOffset]::MinValue
    if (-not ($State.CreatedAt -is [string]) -or
        -not [DateTimeOffset]::TryParse([string]$State.CreatedAt, [ref]$createdAt)) {
        throw "Run State CreatedAt is invalid."
    }
    if (-not ($State.UpdatedAt -is [string]) -or
        -not [DateTimeOffset]::TryParse([string]$State.UpdatedAt, [ref]$updatedAt)) {
        throw "Run State UpdatedAt is invalid."
    }
    if ($updatedAt -lt $createdAt) {
        throw "Run State UpdatedAt must not be earlier than CreatedAt."
    }

    if ($null -ne $State.Failure) {
        Assert-RunStateProperties `
            $State.Failure `
            @("Kind", "Message", "Terminal") `
            "Run State Failure"
        Assert-RunStateNonEmptyString $State.Failure.Kind "Run State Failure.Kind"
        Assert-RunStateNonEmptyString $State.Failure.Message "Run State Failure.Message"
        if (-not ($State.Failure.Terminal -is [bool])) {
            throw "Run State Failure.Terminal must be boolean."
        }
    }

    if ([string]$State.Status -eq "completed") {
        if ([string]$State.CurrentStage -ne "complete") {
            throw "A completed Run State requires CurrentStage complete."
        }
        if ([string]$State.Gates.Validation -ne "PASSED" -or
            [string]$State.Gates.Review -notin @("PASSED", "DISABLED") -or
            [string]$State.Gates.Cleanup -notin @("PASSED", "DISABLED")) {
            throw "A completed Run State requires all enabled Gates to pass."
        }
        if ($null -ne $State.PendingStage) {
            throw "A completed Run State cannot contain PendingStage."
        }
        if ([string]$State.Workflow.NextAction -ne "complete") {
            throw "A completed Run State cannot transition to another stage."
        }
    }

    return $true
}
