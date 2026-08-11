Set-StrictMode -Version 2.0

function New-RunId {
    $timestamp = [DateTimeOffset]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'")
    $suffix = [Guid]::NewGuid().ToString("N").Substring(0, 8)
    return ("run-{0}-{1}" -f $timestamp, $suffix)
}

function Get-RunFileSha256 {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        throw ("File was not found for SHA256: " + $LiteralPath)
    }
    return Get-Sha256HexFromBytes ([System.IO.File]::ReadAllBytes($LiteralPath))
}

function Get-RunRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$RunDirectory,
        [Parameter(Mandatory = $true)][string]$LiteralPath
    )
    $root = [System.IO.Path]::GetFullPath($RunDirectory)
    $prefix = $root.TrimEnd([char[]]@("\", "/")) +
        [System.IO.Path]::DirectorySeparatorChar
    $full = [System.IO.Path]::GetFullPath($LiteralPath)
    if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Artifact path must remain inside the Run directory."
    }
    return $full.Substring($prefix.Length).Replace("\", "/")
}

function New-InitialRunState {
    param(
        [string]$RunId,
        [string]$ProjectName,
        [string]$TaskPath,
        [string]$TaskSha256,
        [string]$ConfigPath,
        [string]$ConfigSha256,
        [string]$InitialBranch,
        [string]$InitialHead,
        [string]$WorkspaceFingerprint,
        [int]$MaxAttempts,
        [int]$MaxReviewCycles,
        [int]$MaxReviewerAttempts,
        [bool]$ReviewerEnabled,
        [bool]$CleanupEnabled
    )

    $now = [DateTimeOffset]::UtcNow.ToString("o")
    return [PSCustomObject][ordered]@{
        SchemaVersion = 1
        RunId = $RunId
        ProjectName = $ProjectName
        Status = "initializing"
        CurrentStage = "initializing"
        Task = [PSCustomObject][ordered]@{ Path = $TaskPath; Sha256 = $TaskSha256 }
        Config = [PSCustomObject][ordered]@{ Path = $ConfigPath; Sha256 = $ConfigSha256 }
        Git = [PSCustomObject][ordered]@{
            InitialBranch = $InitialBranch
            InitialHead = $InitialHead
            CurrentWorkspaceFingerprint = $WorkspaceFingerprint
        }
        Counters = [PSCustomObject][ordered]@{
            DeveloperAttempts = 0
            ReviewerAttempts = 0
            ReviewCycles = 0
            ValidationAttempts = 0
        }
        EffectiveLimits = [PSCustomObject][ordered]@{
            MaxAttempts = $MaxAttempts
            MaxReviewCycles = $MaxReviewCycles
            MaxReviewerAttempts = $MaxReviewerAttempts
        }
        Gates = [PSCustomObject][ordered]@{
            Validation = "NOT_RUN"
            Review = $(if ($ReviewerEnabled) { "NOT_RUN" } else { "DISABLED" })
            Cleanup = $(if ($CleanupEnabled) { "NOT_RUN" } else { "DISABLED" })
        }
        LastCheckpoint = [PSCustomObject][ordered]@{
            Sequence = 0
            Timestamp = $now
            Stage = "initializing"
        }
        PendingStage = $null
        Workflow = [PSCustomObject][ordered]@{
            NextAction = "development"
            RepairKind = $null
            ReviewSequence = 0
            ReviewerTechnicalAttemptsInCycle = 0
            LastValidationArtifact = $null
            LastReviewArtifact = $null
            ResumeCount = 0
            InterruptedStage = $null
            InterruptedWorkspaceChanged = $false
            TerminalIntent = $null
        }
        CreatedAt = $now
        UpdatedAt = $now
        Failure = $null
    }
}

function Write-RunStateAtomic {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    [void](Assert-RunStateContract $State $ProjectRoot ([string]$State.RunId))
    $path = [System.IO.Path]::GetFullPath($StatePath)
    $directory = [System.IO.Path]::GetDirectoryName($path)
    [void][System.IO.Directory]::CreateDirectory($directory)
    $temporary = Join-Path $directory (".state-" + [Guid]::NewGuid().ToString("N") + ".tmp")
    $backup = Join-Path $directory ".state-replace.backup"
    $json = $State | ConvertTo-Json -Depth 32
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    try {
        $stream = New-Object System.IO.FileStream(
            $temporary,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            4096,
            [System.IO.FileOptions]::WriteThrough
        )
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }

        if (Test-Path -LiteralPath $path -PathType Leaf) {
            [System.IO.File]::Replace($temporary, $path, $backup, $true)
            if (Test-Path -LiteralPath $backup -PathType Leaf) {
                Remove-Item -LiteralPath $backup
            }
        }
        else {
            [System.IO.File]::Move($temporary, $path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary
        }
    }
}

function New-TrajectoryEvent {
    param(
        [object]$State,
        [int64]$Sequence,
        [string]$EventType,
        [string]$Stage,
        [AllowNull()][string]$Outcome,
        [AllowNull()][string]$ActorRole,
        [AllowNull()][object]$Attempt,
        [AllowNull()][object]$Artifacts,
        [AllowNull()][string]$Message,
        [AllowNull()][object]$Runtime,
        [AllowNull()][object]$RequestedModel,
        [AllowNull()][object]$ResolvedModel,
        [AllowNull()][object]$DurationMs,
        [AllowNull()][string]$GateResult,
        [AllowNull()][object]$FindingCount,
        [AllowNull()][string]$FailureKind
    )

    if ($null -eq $Artifacts) { $Artifacts = [PSCustomObject]@{} }
    return [PSCustomObject][ordered]@{
        SchemaVersion = 1
        RunId = [string]$State.RunId
        Sequence = [int64]$Sequence
        Timestamp = [DateTimeOffset]::UtcNow.ToString("o")
        EventType = $EventType
        Stage = $Stage
        Outcome = $(if ([string]::IsNullOrWhiteSpace($Outcome)) { $null } else { $Outcome })
        ActorRole = $(if ([string]::IsNullOrWhiteSpace($ActorRole)) { $null } else { $ActorRole })
        Attempt = $Attempt
        Artifacts = $Artifacts
        WorkspaceFingerprint = [string]$State.Git.CurrentWorkspaceFingerprint
        Message = $(if ($null -eq $Message) { $null } else { $Message })
        Runtime = $Runtime
        RequestedModel = $RequestedModel
        ResolvedModel = $ResolvedModel
        DurationMs = $DurationMs
        GateResult = $(if ([string]::IsNullOrWhiteSpace($GateResult)) { $null } else { $GateResult })
        FindingCount = $FindingCount
        FailureKind = $(if ([string]::IsNullOrWhiteSpace($FailureKind)) { $null } else { $FailureKind })
    }
}

function Add-TrajectoryEvent {
    param(
        [object]$State,
        [string]$TrajectoryPath,
        [string]$RunDirectory,
        [string]$EventType,
        [string]$Stage,
        [AllowNull()][string]$Outcome = $null,
        [AllowNull()][string]$ActorRole = $null,
        [AllowNull()][object]$Attempt = $null,
        [AllowNull()][object]$Artifacts = $null,
        [AllowNull()][string]$Message = $null,
        [AllowNull()][object]$Runtime = $null,
        [AllowNull()][object]$RequestedModel = $null,
        [AllowNull()][object]$ResolvedModel = $null,
        [AllowNull()][object]$DurationMs = $null,
        [AllowNull()][string]$GateResult = $null,
        [AllowNull()][object]$FindingCount = $null,
        [AllowNull()][string]$FailureKind = $null
    )

    $events = @(Read-TrajectoryJsonLines `
        -LiteralPath $TrajectoryPath `
        -ExpectedRunId ([string]$State.RunId) `
        -RunDirectory $RunDirectory `
        -AllowMissing)
    $sequence = $events.Count + 1
    $newEventParameters = @{
        State = $State
        Sequence = $sequence
        EventType = $EventType
        Stage = $Stage
        Outcome = $Outcome
        ActorRole = $ActorRole
        Attempt = $Attempt
        Artifacts = $Artifacts
        Message = $Message
        Runtime = $Runtime
        RequestedModel = $RequestedModel
        ResolvedModel = $ResolvedModel
        DurationMs = $DurationMs
        GateResult = $GateResult
        FindingCount = $FindingCount
        FailureKind = $FailureKind
    }
    $event = New-TrajectoryEvent @newEventParameters
    [void](Assert-TrajectoryEventContract $event ([string]$State.RunId) $RunDirectory)
    $line = $event | ConvertTo-Json -Depth 32 -Compress
    $path = [System.IO.Path]::GetFullPath($TrajectoryPath)
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($path))
    $stream = New-Object System.IO.FileStream(
        $path,
        [System.IO.FileMode]::Append,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::Read,
        4096,
        [System.IO.FileOptions]::WriteThrough
    )
    try {
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($line + "`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    return $event
}

function Write-RunCheckpoint {
    param(
        [object]$State,
        [string]$ProjectRoot,
        [string]$RunDirectory,
        [string]$StatePath,
        [string]$TrajectoryPath,
        [string]$EventType,
        [string]$Stage,
        [AllowNull()][string]$Outcome = $null,
        [AllowNull()][string]$ActorRole = $null,
        [AllowNull()][object]$Attempt = $null,
        [AllowNull()][object]$Artifacts = $null,
        [AllowNull()][string]$Message = $null,
        [AllowNull()][object]$Runtime = $null,
        [AllowNull()][object]$RequestedModel = $null,
        [AllowNull()][object]$ResolvedModel = $null,
        [AllowNull()][object]$DurationMs = $null,
        [AllowNull()][string]$GateResult = $null,
        [AllowNull()][object]$FindingCount = $null,
        [AllowNull()][string]$FailureKind = $null
    )

    $eventParameters = @{}
    foreach ($name in @(
        "State", "TrajectoryPath", "RunDirectory", "EventType", "Stage",
        "Outcome", "ActorRole", "Attempt", "Artifacts", "Message", "Runtime",
        "RequestedModel", "ResolvedModel", "DurationMs", "GateResult",
        "FindingCount", "FailureKind"
    )) { $eventParameters[$name] = $PSBoundParameters[$name] }
    $event = Add-TrajectoryEvent @eventParameters
    $State.UpdatedAt = [DateTimeOffset]::UtcNow.ToString("o")
    $State.LastCheckpoint.Sequence = [int64]$event.Sequence
    $State.LastCheckpoint.Timestamp = [string]$event.Timestamp
    $State.LastCheckpoint.Stage = $Stage
    Write-RunStateAtomic $State $StatePath $ProjectRoot
    return $event
}

function Assert-RunTrajectoryStateConsistency {
    param([object]$State, [string]$TrajectoryPath, [string]$RunDirectory)
    $events = @(Read-TrajectoryJsonLines $TrajectoryPath ([string]$State.RunId) $RunDirectory)
    if ($events.Count -ne [int64]$State.LastCheckpoint.Sequence) {
        throw ("TRAJECTORY_STATE_MISMATCH: State Sequence {0}, trajectory {1}." -f `
            $State.LastCheckpoint.Sequence, $events.Count)
    }
    return [object[]]$events
}
