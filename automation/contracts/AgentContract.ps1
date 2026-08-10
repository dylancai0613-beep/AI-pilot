Set-StrictMode -Version 2.0

$script:AgentContractSchemaVersion = 1
$script:AgentResultStatuses = @(
    "completed",
    "failed",
    "invalid_configuration",
    "failed_to_start"
)

function Test-AgentContractProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return ($Object.PSObject.Properties.Name -contains $Name)
}

function Assert-AgentContractProperties {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string[]]$Required,
        [Parameter(Mandatory = $true)][string]$Description
    )

    foreach ($name in $Required) {
        if (-not (Test-AgentContractProperty -Object $Object -Name $name)) {
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

function Assert-AgentContractObject {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (($null -eq $Value) -or
        ($Value -is [string]) -or
        ($Value.GetType().IsValueType)) {
        throw ($Description + " must be an object.")
    }
}

function Resolve-AgentContractPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$CandidatePath,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$AllowProjectRoot
    )

    $root = [System.IO.Path]::GetFullPath($ProjectRoot)
    $prefix = $root.TrimEnd([char[]]@("\", "/")) +
        [System.IO.Path]::DirectorySeparatorChar
    if ([System.IO.Path]::IsPathRooted($CandidatePath)) {
        $fullPath = [System.IO.Path]::GetFullPath($CandidatePath)
    }
    else {
        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $root $CandidatePath))
    }

    $isRoot = [string]::Equals(
        $fullPath.TrimEnd([char[]]@("\", "/")),
        $root.TrimEnd([char[]]@("\", "/")),
        [System.StringComparison]::OrdinalIgnoreCase
    )
    $isChild = $fullPath.StartsWith(
        $prefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )
    if ((-not $isChild) -and (-not ($AllowProjectRoot -and $isRoot))) {
        throw ("{0} must be inside ProjectRoot." -f $Description)
    }

    return $fullPath
}

function ConvertTo-AgentContractJson {
    param([Parameter(Mandatory = $true)][object]$InputObject)

    return ($InputObject | ConvertTo-Json -Depth 32)
}

function Write-AgentContractJson {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][object]$InputObject
    )

    $json = ConvertTo-AgentContractJson -InputObject $InputObject
    [System.IO.File]::WriteAllText(
        [System.IO.Path]::GetFullPath($LiteralPath),
        $json,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Read-AgentContractJson {
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

function ConvertTo-AgentContractDisplayJson {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return "null"
    }
    return ($Value | ConvertTo-Json -Depth 32 -Compress)
}

function Test-AgentContractNumber {
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
        [TypeCode]::UInt64,
        [TypeCode]::Single,
        [TypeCode]::Double,
        [TypeCode]::Decimal
    ) -contains [System.Type]::GetTypeCode($Value.GetType())
}

function Get-AgentContractValueKind {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return "null"
    }
    if ($Value -is [string]) {
        return "string"
    }
    if ($Value -is [bool]) {
        return "boolean"
    }
    if (Test-AgentContractNumber -Value $Value) {
        return "number"
    }
    if (($Value -is [System.Array]) -or
        ($Value -is [System.Collections.IList])) {
        return "array"
    }
    if (($Value -is [System.Collections.IDictionary]) -or
        ($Value -is [PSCustomObject])) {
        return "object"
    }
    return "unsupported"
}

function Get-AgentContractPropertyMap {
    param([Parameter(Mandatory = $true)][object]$Value)

    $properties = New-Object `
        "System.Collections.Generic.Dictionary[string,object]" `
        ([System.StringComparer]::Ordinal)
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if (-not ($key -is [string])) {
                throw "Agent Contract object keys must be strings."
            }
            if ($properties.ContainsKey([string]$key)) {
                throw ("Duplicate Agent Contract object key: " + $key)
            }
            $properties.Add([string]$key, $Value[$key])
        }
    }
    else {
        foreach ($property in $Value.PSObject.Properties) {
            if ($properties.ContainsKey([string]$property.Name)) {
                throw ("Duplicate Agent Contract object key: " + $property.Name)
            }
            $properties.Add([string]$property.Name, $property.Value)
        }
    }
    return $properties
}

function Test-AgentContractValueEquivalent {
    param(
        [AllowNull()][object]$Left,
        [AllowNull()][object]$Right
    )

    $leftKind = Get-AgentContractValueKind -Value $Left
    $rightKind = Get-AgentContractValueKind -Value $Right
    if ($leftKind -ne $rightKind) {
        return $false
    }

    switch ($leftKind) {
        "null" {
            return $true
        }
        "string" {
            return [string]::Equals(
                [string]$Left,
                [string]$Right,
                [System.StringComparison]::Ordinal
            )
        }
        "boolean" {
            return ([bool]$Left -eq [bool]$Right)
        }
        "number" {
            $culture = [System.Globalization.CultureInfo]::InvariantCulture
            $style = [System.Globalization.NumberStyles]::Float
            try {
                $leftDecimal = [decimal]::Parse(
                    [System.Convert]::ToString($Left, $culture),
                    $style,
                    $culture
                )
                $rightDecimal = [decimal]::Parse(
                    [System.Convert]::ToString($Right, $culture),
                    $style,
                    $culture
                )
                return ($leftDecimal -eq $rightDecimal)
            }
            catch [System.OverflowException] {
                return ([double]$Left -eq [double]$Right)
            }
        }
        "array" {
            if (($Left -is [System.Array]) -and ($Left.Rank -ne 1)) {
                return $false
            }
            if (($Right -is [System.Array]) -and ($Right.Rank -ne 1)) {
                return $false
            }
            if ($Left.Count -ne $Right.Count) {
                return $false
            }
            for ($index = 0; $index -lt $Left.Count; $index++) {
                if (-not (Test-AgentContractValueEquivalent `
                    -Left $Left[$index] `
                    -Right $Right[$index])) {
                    return $false
                }
            }
            return $true
        }
        "object" {
            $leftProperties = Get-AgentContractPropertyMap -Value $Left
            $rightProperties = Get-AgentContractPropertyMap -Value $Right
            if ($leftProperties.Count -ne $rightProperties.Count) {
                return $false
            }
            foreach ($entry in $leftProperties.GetEnumerator()) {
                if (-not $rightProperties.ContainsKey($entry.Key)) {
                    return $false
                }
                if (-not (Test-AgentContractValueEquivalent `
                    -Left $entry.Value `
                    -Right $rightProperties[$entry.Key])) {
                    return $false
                }
            }
            return $true
        }
        default {
            return $false
        }
    }
}

function Assert-AgentRequestContract {
    param(
        [Parameter(Mandatory = $true)][object]$Request,
        [Parameter(Mandatory = $true)][string]$ExpectedProjectRoot
    )

    $required = @(
        "SchemaVersion",
        "AttemptId",
        "InvocationType",
        "ProjectRoot",
        "TaskFile",
        "PromptFile",
        "StdoutFile",
        "StderrFile",
        "Runtime",
        "Model",
        "Options"
    )
    Assert-AgentContractProperties `
        -Object $Request `
        -Required $required `
        -Description "Agent Request"

    if ([int]$Request.SchemaVersion -ne $script:AgentContractSchemaVersion) {
        throw ("Unsupported Agent Request SchemaVersion: " + $Request.SchemaVersion)
    }
    if ([string]::IsNullOrWhiteSpace([string]$Request.AttemptId)) {
        throw "Agent Request AttemptId must not be empty."
    }
    if ([string]::IsNullOrWhiteSpace([string]$Request.InvocationType)) {
        throw "Agent Request InvocationType must not be empty."
    }

    $expectedRoot = [System.IO.Path]::GetFullPath($ExpectedProjectRoot)
    $requestRoot = Resolve-AgentContractPath `
        -ProjectRoot $expectedRoot `
        -CandidatePath ([string]$Request.ProjectRoot) `
        -Description "Agent Request ProjectRoot" `
        -AllowProjectRoot
    if (-not [string]::Equals(
        $requestRoot.TrimEnd([char[]]@("\", "/")),
        $expectedRoot.TrimEnd([char[]]@("\", "/")),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Agent Request ProjectRoot does not match the expected project."
    }

    foreach ($field in @("TaskFile", "PromptFile", "StdoutFile", "StderrFile")) {
        $value = [string]$Request.$field
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw ("Agent Request {0} must not be empty." -f $field)
        }
        [void](Resolve-AgentContractPath `
            -ProjectRoot $expectedRoot `
            -CandidatePath $value `
            -Description ("Agent Request " + $field))
    }
    foreach ($field in @("TaskFile", "PromptFile")) {
        if (-not (Test-Path -LiteralPath ([string]$Request.$field) -PathType Leaf)) {
            throw ("Agent Request {0} was not found." -f $field)
        }
    }

    Assert-AgentContractObject -Value $Request.Runtime -Description "Agent Request Runtime"
    Assert-AgentContractObject -Value $Request.Model -Description "Agent Request Model"
    Assert-AgentContractObject -Value $Request.Options -Description "Agent Request Options"
    if (-not (Test-AgentContractProperty -Object $Request.Runtime -Name "Name") -or
        [string]::IsNullOrWhiteSpace([string]$Request.Runtime.Name)) {
        throw "Agent Request Runtime.Name must not be empty."
    }

    return $true
}

function Assert-AgentOutputFiles {
    param([Parameter(Mandatory = $true)][object]$Request)

    foreach ($field in @("StdoutFile", "StderrFile")) {
        $path = Resolve-AgentContractPath `
            -ProjectRoot ([string]$Request.ProjectRoot) `
            -CandidatePath ([string]$Request.$field) `
            -Description ("Agent Request " + $field)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw ("Agent Adapter did not create {0}." -f $field)
        }
    }
    return $true
}

function Assert-AgentResultContract {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][object]$Request,
        [Parameter(Mandatory = $true)][int]$AdapterProcessExitCode
    )

    $required = @(
        "SchemaVersion",
        "AttemptId",
        "AdapterStatus",
        "ExitCode",
        "StartedAt",
        "FinishedAt",
        "Runtime",
        "RequestedModel",
        "ResolvedModel",
        "Message"
    )
    Assert-AgentContractProperties `
        -Object $Result `
        -Required $required `
        -Description "Agent Result"

    if ([int]$Result.SchemaVersion -ne $script:AgentContractSchemaVersion) {
        throw ("Unsupported Agent Result SchemaVersion: " + $Result.SchemaVersion)
    }
    if ([string]$Result.AttemptId -ne [string]$Request.AttemptId) {
        throw "Agent Result AttemptId does not match Agent Request."
    }
    if ($script:AgentResultStatuses -notcontains [string]$Result.AdapterStatus) {
        throw ("Unsupported Agent Result AdapterStatus: " + $Result.AdapterStatus)
    }
    if ($null -eq $Result.ExitCode) {
        throw "Agent Result ExitCode must not be null."
    }
    try {
        $resultExitCode = [int]$Result.ExitCode
    }
    catch {
        throw "Agent Result ExitCode must be an integer."
    }
    if ($resultExitCode -ne $AdapterProcessExitCode) {
        throw (
            "Agent Adapter process exit code does not match Agent Result ExitCode: " +
            $AdapterProcessExitCode + " vs " + $resultExitCode
        )
    }
    if (($Result.AdapterStatus -eq "completed") -and ($resultExitCode -ne 0)) {
        throw "Agent Result status completed requires ExitCode 0."
    }
    if (($Result.AdapterStatus -ne "completed") -and ($resultExitCode -eq 0)) {
        throw "A failed Agent Result status requires a non-zero ExitCode."
    }

    $startedAt = [DateTimeOffset]::MinValue
    $finishedAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Result.StartedAt, [ref]$startedAt)) {
        throw "Agent Result StartedAt is not a valid timestamp."
    }
    if (-not [DateTimeOffset]::TryParse([string]$Result.FinishedAt, [ref]$finishedAt)) {
        throw "Agent Result FinishedAt is not a valid timestamp."
    }
    if ($finishedAt -lt $startedAt) {
        throw "Agent Result FinishedAt is earlier than StartedAt."
    }

    if (-not (Test-AgentContractValueEquivalent `
        -Left $Request.Runtime `
        -Right $Result.Runtime)) {
        throw "Agent Result Runtime does not match Agent Request."
    }
    if (-not (Test-AgentContractValueEquivalent `
        -Left $Request.Model `
        -Right $Result.RequestedModel)) {
        throw "Agent Result RequestedModel does not match Agent Request."
    }
    if ($null -ne $Result.ResolvedModel) {
        Assert-AgentContractObject `
            -Value $Result.ResolvedModel `
            -Description "Agent Result ResolvedModel"
    }

    return $true
}
