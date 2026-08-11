[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$projectRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
. (Join-Path $projectRoot "automation\core\WorkspaceFingerprint.ps1")
$script:Passed=0
function Check([bool]$Condition,[string]$Name){if(-not $Condition){throw $Name};$script:Passed++;Write-Output("PASS: "+$Name)}
$base=@{Branch="branch";Head="head";UnstagedDiff="";StagedDiff="";UntrackedFiles=@()}
$a=Get-WorkspaceFingerprintFromComponents @base
$b=Get-WorkspaceFingerprintFromComponents @base
Check ($a -eq $b) "same workspace is deterministic"
$changed=Get-WorkspaceFingerprintFromComponents "branch" "head" "diff" "" @()
Check ($a -ne $changed) "tracked unstaged diff changes fingerprint"
$changed=Get-WorkspaceFingerprintFromComponents "branch" "head" "" "staged" @()
Check ($a -ne $changed) "staged diff changes fingerprint"
$changed=Get-WorkspaceFingerprintFromComponents "branch" "head" "" "" @(
    [PSCustomObject]@{Path="new.txt";Sha256=("a"*64)})
Check ($a -ne $changed) "untracked path/content changes fingerprint"
$changed2=Get-WorkspaceFingerprintFromComponents "branch" "head" "" "" @(
    [PSCustomObject]@{Path="new.txt";Sha256=("b"*64)})
Check ($changed -ne $changed2) "untracked content hash changes fingerprint"
Check ((Get-WorkspaceFingerprintFromComponents "b" "head" "" "" @()) -ne $a) `
    "branch changes fingerprint"
Check ((Get-WorkspaceFingerprintFromComponents "branch" "other" "" "" @()) -ne $a) `
    "HEAD changes fingerprint"

$temporary=Join-Path $PSScriptRoot ("fingerprint-test-"+[Guid]::NewGuid().ToString("N")+".tmp")
try {
    $before=Get-WorkspaceFingerprint $projectRoot @("automation/runs","automation/reports")
    [System.IO.File]::WriteAllText($temporary,"one")
    $one=Get-WorkspaceFingerprint $projectRoot @("automation/runs","automation/reports")
    [System.IO.File]::WriteAllText($temporary,"two")
    $two=Get-WorkspaceFingerprint $projectRoot @("automation/runs","automation/reports")
    Check ($before.Hash -ne $one.Hash) "actual untracked file is included"
    Check ($one.Hash -ne $two.Hash) "actual untracked content is included"
}
finally { if(Test-Path $temporary){Remove-Item -LiteralPath $temporary} }
Write-Output("WORKSPACE FINGERPRINT TESTS PASSED: "+$script:Passed)
