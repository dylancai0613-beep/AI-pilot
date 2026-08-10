Set-StrictMode -Version 2.0

$script:ReviewContractSchemaVersion = 1
$script:ReviewVerdicts = @("approved", "changes_requested")
$script:ReviewSeverities = @("blocker", "major", "minor")

function Test-ReviewContractProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return ($Object.PSObject.Properties.Name -contains $Name)
}

function Assert-ReviewContractProperties {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string[]]$Required,
        [Parameter(Mandatory = $true)][string]$Description
    )

    foreach ($name in $Required) {
        if (-not (Test-ReviewContractProperty -Object $Object -Name $name)) {
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

function Test-ReviewContractInteger {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $false
    }
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

function Resolve-ReviewFindingPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw "Review Finding File must not be empty when provided."
    }
    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Review Finding File must be a project-relative path."
    }
    $segments = @($RelativePath.Replace("\", "/").Split("/"))
    if ($segments -contains "..") {
        throw "Review Finding File must not contain parent traversal."
    }

    $root = [System.IO.Path]::GetFullPath($ProjectRoot)
    $prefix = $root.TrimEnd([char[]]@("\", "/")) +
        [System.IO.Path]::DirectorySeparatorChar
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    if (-not $fullPath.StartsWith(
        $prefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Review Finding File must remain inside ProjectRoot."
    }
    return $fullPath
}

function Write-ReviewContractJson {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][object]$InputObject
    )

    $json = $InputObject | ConvertTo-Json -Depth 32
    [System.IO.File]::WriteAllText(
        [System.IO.Path]::GetFullPath($LiteralPath),
        $json,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Read-ReviewContractJson {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $path = [System.IO.Path]::GetFullPath($LiteralPath)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw ($Description + " was not created: " + $path)
    }
    try {
        return ([System.IO.File]::ReadAllText($path) | ConvertFrom-Json)
    }
    catch {
        throw ($Description + " is not valid JSON: " + $_.Exception.Message)
    }
}

function Assert-ReviewResultContract {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$ExpectedReviewId,
        [Parameter(Mandatory = $true)][string]$ExpectedReviewerAgentAttemptId,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    $topFields = @(
        "SchemaVersion",
        "ReviewId",
        "ReviewerAgentAttemptId",
        "Verdict",
        "Summary",
        "Findings",
        "CreatedAt"
    )
    Assert-ReviewContractProperties `
        -Object $Result `
        -Required $topFields `
        -Description "Review Result"

    if (-not (Test-ReviewContractInteger -Value $Result.SchemaVersion) -or
        [int]$Result.SchemaVersion -ne $script:ReviewContractSchemaVersion) {
        throw ("Unsupported Review Result SchemaVersion: " + $Result.SchemaVersion)
    }
    if (-not ($Result.ReviewId -is [string]) -or
        [string]$Result.ReviewId -ne $ExpectedReviewId) {
        throw "Review Result ReviewId does not match the expected ReviewId."
    }
    if (-not ($Result.ReviewerAgentAttemptId -is [string]) -or
        [string]$Result.ReviewerAgentAttemptId -ne $ExpectedReviewerAgentAttemptId) {
        throw (
            "Review Result ReviewerAgentAttemptId does not match the " +
            "Reviewer Agent AttemptId."
        )
    }
    if (-not ($Result.Verdict -is [string]) -or
        $script:ReviewVerdicts -notcontains [string]$Result.Verdict) {
        throw ("Unsupported Review Result Verdict: " + $Result.Verdict)
    }
    if (-not ($Result.Summary -is [string]) -or
        [string]::IsNullOrWhiteSpace([string]$Result.Summary)) {
        throw "Review Result Summary must be a non-empty string."
    }
    if (-not (($Result.Findings -is [System.Array]) -or
        ($Result.Findings -is [System.Collections.IList]))) {
        throw "Review Result Findings must be an array."
    }

    $createdAt = [DateTimeOffset]::MinValue
    if (-not ($Result.CreatedAt -is [string]) -or
        -not [DateTimeOffset]::TryParse(
        [string]$Result.CreatedAt,
        [ref]$createdAt
        )) {
        throw "Review Result CreatedAt is not a valid timestamp."
    }

    $findingFields = @(
        "Id",
        "Severity",
        "Blocking",
        "Category",
        "File",
        "Line",
        "Message",
        "Evidence"
    )
    $findingIds = New-Object `
        "System.Collections.Generic.HashSet[string]" `
        ([System.StringComparer]::Ordinal)
    $blockingCount = 0
    foreach ($finding in $Result.Findings) {
        if ($null -eq $finding) {
            throw "Review Result Finding must be an object."
        }
        Assert-ReviewContractProperties `
            -Object $finding `
            -Required $findingFields `
            -Description "Review Finding"

        if (-not ($finding.Id -is [string]) -or
            [string]::IsNullOrWhiteSpace([string]$finding.Id)) {
            throw "Review Finding Id must be a non-empty string."
        }
        if (-not $findingIds.Add([string]$finding.Id)) {
            throw ("Duplicate Review Finding Id: " + $finding.Id)
        }
        if ($script:ReviewSeverities -notcontains [string]$finding.Severity) {
            throw ("Unsupported Review Finding Severity: " + $finding.Severity)
        }
        if (-not ($finding.Blocking -is [bool])) {
            throw "Review Finding Blocking must be boolean."
        }
        if ([bool]$finding.Blocking) {
            $blockingCount++
        }
        if (-not ($finding.Category -is [string]) -or
            [string]::IsNullOrWhiteSpace([string]$finding.Category)) {
            throw "Review Finding Category must be a non-empty string."
        }
        if ($null -ne $finding.File) {
            if (-not ($finding.File -is [string])) {
                throw "Review Finding File must be a string or null."
            }
            [void](Resolve-ReviewFindingPath `
                -ProjectRoot $ProjectRoot `
                -RelativePath ([string]$finding.File))
        }
        if ($null -ne $finding.Line) {
            if (-not (Test-ReviewContractInteger -Value $finding.Line) -or
                [int64]$finding.Line -le 0) {
                throw "Review Finding Line must be a positive integer or null."
            }
        }
        foreach ($textField in @("Message", "Evidence")) {
            if (-not ($finding.$textField -is [string]) -or
                [string]::IsNullOrWhiteSpace([string]$finding.$textField)) {
                throw ("Review Finding {0} must be a non-empty string." -f `
                    $textField)
            }
        }
    }

    if (($Result.Verdict -eq "approved") -and ($blockingCount -ne 0)) {
        throw "An approved Review Result must not contain blocking findings."
    }
    if (($Result.Verdict -eq "changes_requested") -and ($blockingCount -eq 0)) {
        throw (
            "A changes_requested Review Result requires at least one " +
            "blocking finding."
        )
    }

    return [PSCustomObject]@{
        Verdict = [string]$Result.Verdict
        BlockingFindingCount = [int]$blockingCount
        TotalFindingCount = [int]$Result.Findings.Count
    }
}
