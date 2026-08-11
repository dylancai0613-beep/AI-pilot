Set-StrictMode -Version 2.0

function Get-Sha256HexFromBytes {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $algorithm.ComputeHash($Bytes) }
    finally { $algorithm.Dispose() }
    return (($hash | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Get-Sha256HexFromText {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    return Get-Sha256HexFromBytes ([System.Text.Encoding]::UTF8.GetBytes($Text))
}

function Invoke-WorkspaceGitText {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $LASTEXITCODE = 0
    $previousErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $lines = @(
            & git -c core.safecrlf=false -C $ProjectRoot @Arguments 2>&1 |
                ForEach-Object { $_.ToString() }
        )
    }
    finally { $ErrorActionPreference = $previousErrorPreference }
    if ($LASTEXITCODE -ne 0) {
        throw ("git {0} failed: {1}" -f ($Arguments -join " "), ($lines -join "`n"))
    }
    return ($lines -join "`n")
}

function Test-WorkspaceFingerprintExcluded {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string[]]$ExcludeRelativePrefixes
    )

    $normalized = $RelativePath.Replace("\", "/").TrimStart("./")
    foreach ($prefixValue in $ExcludeRelativePrefixes) {
        $prefix = $prefixValue.Replace("\", "/").Trim("/")
        if ([string]::IsNullOrWhiteSpace($prefix)) { continue }
        if ([string]::Equals(
            $normalized,
            $prefix,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or $normalized.StartsWith(
            $prefix + "/",
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            return $true
        }
    }
    return $false
}

function Get-WorkspaceFingerprintFromComponents {
    param(
        [Parameter(Mandatory = $true)][string]$Branch,
        [Parameter(Mandatory = $true)][string]$Head,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$UnstagedDiff,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$StagedDiff,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$UntrackedFiles
    )

    $records = New-Object "System.Collections.Generic.List[string]"
    [void]$records.Add("branch=" + $Branch)
    [void]$records.Add("head=" + $Head)
    [void]$records.Add("unstaged=" + (Get-Sha256HexFromText $UnstagedDiff))
    [void]$records.Add("staged=" + (Get-Sha256HexFromText $StagedDiff))
    foreach ($file in @($UntrackedFiles | Sort-Object -Property Path -CaseSensitive)) {
        [void]$records.Add(
            "untracked=" + [string]$file.Path + ":" + [string]$file.Sha256
        )
    }
    return Get-Sha256HexFromText ($records -join "`n")
}

function Get-WorkspaceFingerprint {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [string[]]$ExcludeRelativePrefixes = @()
    )

    $root = [System.IO.Path]::GetFullPath($ProjectRoot)
    $prefix = $root.TrimEnd([char[]]@("\", "/")) +
        [System.IO.Path]::DirectorySeparatorChar
    $branch = (Invoke-WorkspaceGitText $root @("rev-parse", "--abbrev-ref", "HEAD")).Trim()
    $head = (Invoke-WorkspaceGitText $root @("rev-parse", "HEAD")).Trim()
    $unstaged = Invoke-WorkspaceGitText $root @("diff", "--binary", "--no-ext-diff", "--")
    $staged = Invoke-WorkspaceGitText $root @("diff", "--cached", "--binary", "--no-ext-diff", "--")
    $untrackedPaths = @(
        Invoke-WorkspaceGitText $root @("ls-files", "--others", "--exclude-standard") |
            ForEach-Object { $_ -split "`n" } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -CaseSensitive
    )
    $untracked = @()
    foreach ($relative in $untrackedPaths) {
        $normalized = $relative.Replace("\", "/")
        if (Test-WorkspaceFingerprintExcluded $normalized $ExcludeRelativePrefixes) {
            continue
        }
        $full = [System.IO.Path]::GetFullPath((Join-Path $root $relative))
        if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Untracked workspace path escaped ProjectRoot."
        }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $untracked += [PSCustomObject]@{
            Path = $normalized
            Sha256 = Get-Sha256HexFromBytes ([System.IO.File]::ReadAllBytes($full))
        }
    }
    $hash = Get-WorkspaceFingerprintFromComponents `
        -Branch $branch `
        -Head $head `
        -UnstagedDiff $unstaged `
        -StagedDiff $staged `
        -UntrackedFiles $untracked
    return [PSCustomObject]@{
        Hash = $hash
        Branch = $branch
        Head = $head
        UntrackedCount = @($untracked).Count
    }
}
