Set-StrictMode -Version 2.0

$script:TrajectorySchemaVersion = 1
$script:TrajectoryStages = @(
    "initializing", "development", "validation", "review", "repair",
    "cleanup", "complete"
)
$script:TrajectoryActorRoles = @(
    "core", "developer", "reviewer", "validation", "cleanup"
)

function Test-TrajectoryProperty {
    param([object]$Object, [string]$Name)
    return (@($Object.PSObject.Properties | ForEach-Object { $_.Name }) -contains $Name)
}

function Test-TrajectoryInteger {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $false }
    return @(
        [TypeCode]::SByte, [TypeCode]::Byte, [TypeCode]::Int16,
        [TypeCode]::UInt16, [TypeCode]::Int32, [TypeCode]::UInt32,
        [TypeCode]::Int64, [TypeCode]::UInt64
    ) -contains [System.Type]::GetTypeCode($Value.GetType())
}

function Assert-TrajectoryProperties {
    param([object]$Object, [string[]]$Required, [string]$Description)
    if ($null -eq $Object -or $Object -is [string] -or $Object.GetType().IsValueType) {
        throw ($Description + " must be an object.")
    }
    foreach ($name in $Required) {
        if (-not (Test-TrajectoryProperty $Object $name)) {
            throw ("{0} is missing required field: {1}" -f $Description, $name)
        }
    }
    $extra = @(
        $Object.PSObject.Properties |
            ForEach-Object { $_.Name } |
            Where-Object { $Required -notcontains $_ }
    )
    if ($extra.Count) {
        throw ("{0} contains unsupported field(s): {1}" -f $Description, ($extra -join ", "))
    }
}

function Resolve-TrajectoryArtifactPath {
    param([string]$RunDirectory, [string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Trajectory Artifact must be a Run-relative path."
    }
    if (@($RelativePath.Replace("\", "/").Split("/")) -contains "..") {
        throw "Trajectory Artifact must not contain parent traversal."
    }
    $root = [System.IO.Path]::GetFullPath($RunDirectory)
    $prefix = $root.TrimEnd([char[]]@("\", "/")) +
        [System.IO.Path]::DirectorySeparatorChar
    $full = [System.IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Trajectory Artifact must remain inside the Run directory."
    }
    return $full
}

function Assert-TrajectoryEventContract {
    param(
        [Parameter(Mandatory = $true)][object]$Event,
        [Parameter(Mandatory = $true)][string]$ExpectedRunId,
        [Parameter(Mandatory = $true)][string]$RunDirectory
    )

    $fields = @(
        "SchemaVersion", "RunId", "Sequence", "Timestamp", "EventType",
        "Stage", "Outcome", "ActorRole", "Attempt", "Artifacts",
        "WorkspaceFingerprint", "Message", "Runtime", "RequestedModel",
        "ResolvedModel", "DurationMs", "GateResult", "FindingCount",
        "FailureKind"
    )
    Assert-TrajectoryProperties $Event $fields "Trajectory Event"
    if (-not (Test-TrajectoryInteger $Event.SchemaVersion) -or
        [int]$Event.SchemaVersion -ne $script:TrajectorySchemaVersion) {
        throw ("Unsupported Trajectory SchemaVersion: " + $Event.SchemaVersion)
    }
    if (-not ($Event.RunId -is [string]) -or [string]$Event.RunId -ne $ExpectedRunId) {
        throw "Trajectory RunId does not match the expected RunId."
    }
    if (-not (Test-TrajectoryInteger $Event.Sequence) -or
        [int64]$Event.Sequence -le 0) {
        throw "Trajectory Sequence must be a positive integer."
    }
    $timestamp = [DateTimeOffset]::MinValue
    if (-not ($Event.Timestamp -is [string]) -or
        -not [DateTimeOffset]::TryParse([string]$Event.Timestamp, [ref]$timestamp)) {
        throw "Trajectory Timestamp is invalid."
    }
    if (-not ($Event.EventType -is [string]) -or
        [string]::IsNullOrWhiteSpace([string]$Event.EventType)) {
        throw "Trajectory EventType must be a non-empty string."
    }
    if (-not ($Event.Stage -is [string]) -or
        $script:TrajectoryStages -notcontains [string]$Event.Stage) {
        throw ("Unsupported Trajectory Stage: " + $Event.Stage)
    }
    if ($null -ne $Event.ActorRole -and
        (-not ($Event.ActorRole -is [string]) -or
        $script:TrajectoryActorRoles -notcontains [string]$Event.ActorRole)) {
        throw ("Unsupported Trajectory ActorRole: " + $Event.ActorRole)
    }
    if ($null -ne $Event.Attempt -and
        (-not (Test-TrajectoryInteger $Event.Attempt) -or
        [int64]$Event.Attempt -le 0)) {
        throw "Trajectory Attempt must be null or a positive integer."
    }
    if ($null -eq $Event.Artifacts -or $Event.Artifacts -is [string] -or
        $Event.Artifacts.GetType().IsValueType) {
        throw "Trajectory Artifacts must be an object."
    }
    foreach ($property in $Event.Artifacts.PSObject.Properties) {
        if ([string]::IsNullOrWhiteSpace([string]$property.Name) -or
            -not ($property.Value -is [string])) {
            throw "Trajectory Artifact names and values must be strings."
        }
        [void](Resolve-TrajectoryArtifactPath $RunDirectory ([string]$property.Value))
    }
    if ($null -ne $Event.WorkspaceFingerprint -and
        (-not ($Event.WorkspaceFingerprint -is [string]) -or
        -not ([string]$Event.WorkspaceFingerprint -match "\A[0-9a-fA-F]{64}\z"))) {
        throw "Trajectory WorkspaceFingerprint must be null or SHA256."
    }
    if ($null -ne $Event.Message -and -not ($Event.Message -is [string])) {
        throw "Trajectory Message must be null or a string."
    }
    foreach ($field in @("Runtime", "RequestedModel", "ResolvedModel")) {
        $value = $Event.$field
        if ($null -ne $value -and
            (($value -is [string]) -or $value.GetType().IsValueType)) {
            throw ("Trajectory {0} must be null or an object." -f $field)
        }
    }
    foreach ($field in @("DurationMs", "FindingCount")) {
        $value = $Event.$field
        if ($null -ne $value -and
            (-not (Test-TrajectoryInteger $value) -or [int64]$value -lt 0)) {
            throw ("Trajectory {0} must be null or non-negative." -f $field)
        }
    }
    foreach ($field in @("Outcome", "GateResult", "FailureKind")) {
        $value = $Event.$field
        if ($null -ne $value -and
            (-not ($value -is [string]) -or
            [string]::IsNullOrWhiteSpace([string]$value))) {
            throw ("Trajectory {0} must be null or a non-empty string." -f $field)
        }
    }
    return $true
}

function Read-TrajectoryJsonLines {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$ExpectedRunId,
        [Parameter(Mandatory = $true)][string]$RunDirectory,
        [switch]$AllowMissing
    )

    $path = [System.IO.Path]::GetFullPath($LiteralPath)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        if ($AllowMissing) { return @() }
        throw ("Trajectory was not found: " + $path)
    }
    $events = @()
    $expectedSequence = 1
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) {
            throw ("Trajectory contains an empty line at " + $lineNumber)
        }
        try { $event = $line | ConvertFrom-Json }
        catch { throw ("Trajectory line {0} is malformed JSON: {1}" -f $lineNumber, $_.Exception.Message) }
        [void](Assert-TrajectoryEventContract $event $ExpectedRunId $RunDirectory)
        if ([int64]$event.Sequence -ne $expectedSequence) {
            throw ("Trajectory Sequence must be continuous. Expected {0}, got {1}." -f `
                $expectedSequence, $event.Sequence)
        }
        $events += $event
        $expectedSequence++
    }
    return [object[]]$events
}
