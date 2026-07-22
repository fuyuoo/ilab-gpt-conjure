[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Config,

    [Parameter(Mandatory = $true)]
    [string]$Repository,

    [Parameter(Mandatory = $true)]
    [int]$Issue,

    [Parameter(Mandatory = $true)]
    [ValidateSet("Passed", "Failed")]
    [string]$Outcome,

    [Parameter(Mandatory = $true)]
    [string]$Evidence,

    [string]$Steps = "",
    [string]$Expected = "",
    [string]$Actual = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[System.Diagnostics.Stopwatch]$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
[int]$githubCalls = 0
[long]$githubElapsedMs = 0

if ([string]::IsNullOrWhiteSpace($Evidence))
{
    throw "Evidence is required."
}
if ($Outcome -eq "Failed" -and
    ([string]::IsNullOrWhiteSpace($Steps) -or
     [string]::IsNullOrWhiteSpace($Expected) -or
     [string]::IsNullOrWhiteSpace($Actual)))
{
    throw "Failed verification requires Steps, Expected, and Actual."
}

function Invoke-ManualVerificationGh
{
    param([string[]]$Arguments)

    [System.Diagnostics.Stopwatch]$githubStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:githubCalls++
    try
    {
        [string[]]$output = @(& gh @Arguments)
        if ($LASTEXITCODE -ne 0)
        {
            throw "gh command failed: gh $($Arguments -join ' ')"
        }
        [string]$text = ($output -join "`n").Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return $text | ConvertFrom-Json
    }
    finally
    {
        $githubStopwatch.Stop()
        $script:githubElapsedMs += $githubStopwatch.ElapsedMilliseconds
    }
}

[object]$configData = Get-Content -Raw -LiteralPath (Resolve-Path -LiteralPath $Config).Path |
    ConvertFrom-Json
[string]$readyLabel = [string]$configData.labels.ready
[string]$manualLabel = if ($configData.labels.PSObject.Properties.Name -contains "manual") {
    [string]$configData.labels.manual
} else {
    "manual-verification-pending"
}

[object]$issueData = Invoke-ManualVerificationGh -Arguments @(
    "api", "repos/$Repository/issues/$Issue")
[string[]]$labels = @($issueData.labels | ForEach-Object { [string]$_.name })
if ([string]$issueData.state -ne "closed" -or $labels -notcontains $manualLabel)
{
    throw "Issue #$Issue must be closed with label '$manualLabel' before manual verification is resolved."
}

[System.Collections.Specialized.OrderedDictionary]$marker = [ordered]@{
    version = 1
    issue = $Issue
    outcome = $Outcome.ToLowerInvariant()
}
[string]$details = if ($Outcome -eq "Passed") {
    @"
- Evidence：$Evidence
"@
} else {
    @"
- Steps：$Steps
- Expected：$Expected
- Actual：$Actual
- Evidence：$Evidence
"@
}
[string]$commentBody = @"
<!-- project-issue-automation:manual-verification-v1 $($marker | ConvertTo-Json -Compress) -->

### Manual Verification $Outcome

$details
"@
[object]$comment = Invoke-ManualVerificationGh -Arguments @(
    "api", "--method", "POST", "repos/$Repository/issues/$Issue/comments",
    "-f", "body=$commentBody")

if ($Outcome -eq "Passed")
{
    Invoke-ManualVerificationGh -Arguments @(
        "api", "--method", "DELETE", "repos/$Repository/issues/$Issue/labels/$manualLabel") |
        Out-Null
}
else
{
    # Issue 尚处于 closed，先恢复 ready 并清除人工待验标签，最后 reopen，避免开放态中间窗口。
    Invoke-ManualVerificationGh -Arguments @(
        "api", "--method", "POST", "repos/$Repository/issues/$Issue/labels",
        "-f", "labels[]=$readyLabel") | Out-Null
    Invoke-ManualVerificationGh -Arguments @(
        "api", "--method", "DELETE", "repos/$Repository/issues/$Issue/labels/$manualLabel") |
        Out-Null
    Invoke-ManualVerificationGh -Arguments @(
        "api", "--method", "PATCH", "repos/$Repository/issues/$Issue", "-f", "state=open") |
        Out-Null
}

[object]$finalIssue = Invoke-ManualVerificationGh -Arguments @(
    "api", "repos/$Repository/issues/$Issue")
[string[]]$finalLabels = @($finalIssue.labels | ForEach-Object { [string]$_.name })
if ($Outcome -eq "Passed" -and
    ([string]$finalIssue.state -ne "closed" -or $finalLabels -contains $manualLabel))
{
    throw "Passed manual verification did not leave the Issue closed without the pending label."
}
if ($Outcome -eq "Failed" -and
    ([string]$finalIssue.state -ne "open" -or $finalLabels -notcontains $readyLabel -or
     $finalLabels -contains $manualLabel))
{
    throw "Failed manual verification did not restore the Issue to the automatic queue."
}

$stopwatch.Stop()
[ordered]@{
    status = if ($Outcome -eq "Passed") { "verified" } else { "reopened" }
    repository = $Repository
    issue = $Issue
    evidenceUrl = [string]$comment.html_url
    metrics = [ordered]@{
        phase = "manual-verification"
        githubCalls = $githubCalls
        githubElapsedMs = $githubElapsedMs
        elapsedMs = [long]$stopwatch.ElapsedMilliseconds
    }
} | ConvertTo-Json -Depth 8 -Compress
