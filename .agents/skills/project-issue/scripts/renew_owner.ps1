[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repository,

    [Parameter(Mandatory = $true)]
    [int]$Parent,

    [Parameter(Mandatory = $true)]
    [int]$Issue,

    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[0-9a-f-]{36}$")]
    [string]$OwnerToken,

    [Parameter(Mandatory = $true)]
    [long]$OwnerCommentId,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 179)]
    [int]$RequiredMinutes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[System.Diagnostics.Stopwatch]$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
[int]$githubCalls = 0
[long]$githubElapsedMs = 0
. (Join-Path $PSScriptRoot "owner_state.ps1")

function Invoke-OwnerGh
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
        [string]$json = ($output -join "`n").Trim()
        if ([string]::IsNullOrWhiteSpace($json)) { return $null }
        return $json | ConvertFrom-Json
    }
    finally
    {
        $githubStopwatch.Stop()
        $script:githubElapsedMs += $githubStopwatch.ElapsedMilliseconds
    }
}

function Get-ActiveOwners
{
    [object]$pages = Invoke-OwnerGh -Arguments @(
        "api", "--paginate", "--slurp", "repos/$Repository/issues/$Parent/comments?per_page=100")
    [System.Collections.Generic.List[object]]$owners = [System.Collections.Generic.List[object]]::new()
    foreach ($page in @($pages))
    {
        [object[]]$comments = if ($page -is [System.Array]) { @($page) } else { @($page) }
        foreach ($comment in $comments)
        {
            if ($null -eq $comment) { continue }
            [object]$owner = ConvertFrom-ProjectIssueOwnerComment `
                -Body ([string]$comment.body) -CommentId ([long]$comment.id) `
                -UpdatedAt ([string]$comment.updated_at)
            if ($null -ne $owner -and [int]$owner.parent -eq $Parent -and
                !(Test-ProjectIssueOwnerExpired -Owner $owner))
            {
                $owners.Add($owner)
            }
        }
    }
    return @($owners | Sort-Object commentId)
}

function Get-CurrentOwner
{
    [object[]]$owners = @(Get-ActiveOwners)
    if ($owners.Count -eq 0)
    {
        throw "Parent #$Parent has no active owner."
    }
    [object]$winner = $owners[0]
    if ([long]$winner.commentId -ne $OwnerCommentId -or
        [string]$winner.token -ne $OwnerToken -or [int]$winner.issue -ne $Issue)
    {
        throw "The supplied WorkContext is not the smallest active owner."
    }
    return $winner
}

function Write-RenewalResult
{
    param([string]$Status, [string]$LeaseExpiresAt)

    $stopwatch.Stop()
    [ordered]@{
        status = $Status
        repository = $Repository
        parent = $Parent
        issue = $Issue
        ownerCommentId = $OwnerCommentId
        leaseExpiresAt = $LeaseExpiresAt
        metrics = [ordered]@{
            phase = "renew-owner"
            githubCalls = $githubCalls
            githubElapsedMs = $githubElapsedMs
            elapsedMs = [long]$stopwatch.ElapsedMilliseconds
        }
    } | ConvertTo-Json -Depth 6 -Compress
}

[object]$owner = Get-CurrentOwner
[datetime]$leaseExpiresAt = [datetime]::Parse(
    [string]$owner.leaseExpiresAt,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
        [System.Globalization.DateTimeStyles]::AdjustToUniversal)
if ($leaseExpiresAt -gt [datetime]::UtcNow.AddMinutes($RequiredMinutes))
{
    Write-RenewalResult -Status "unchanged" -LeaseExpiresAt $leaseExpiresAt.ToString("o")
    return
}

[string]$renewedLease = [datetime]::UtcNow.AddMinutes(180).ToString("o")
[string]$body = New-ProjectIssueOwnerComment -Parent $Parent -Issue $Issue `
    -Token $OwnerToken -Base ([string]$owner.base) -Checkpoint ([string]$owner.checkpoint) `
    -LeaseExpiresAt $renewedLease
Invoke-OwnerGh -Arguments @(
    "api", "--method", "PATCH", "repos/$Repository/issues/comments/$OwnerCommentId", "-f", "body=$body") |
    Out-Null

[object]$confirmed = Get-CurrentOwner
[datetime]$confirmedLease = [datetime]::Parse(
    [string]$confirmed.leaseExpiresAt,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
        [System.Globalization.DateTimeStyles]::AdjustToUniversal)
if ($confirmedLease -le [datetime]::UtcNow.AddMinutes($RequiredMinutes))
{
    throw "Owner renewal could not be confirmed."
}
Write-RenewalResult -Status "renewed" -LeaseExpiresAt $confirmedLease.ToString("o")
