[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("DONE", "BLOCKED", "LOCKED", "PAUSED")]
    [string]$TerminalState,

    [ValidateSet("not_checked", "selected", "parent_complete", "no_issue")]
    [string]$SelectionStatus = "not_checked",

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Config,

    [int]$Issue = 0,

    [string]$ThreadId = "",

    [switch]$DispatchFailed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (![string]::IsNullOrWhiteSpace($ThreadId) -and $DispatchFailed)
{
    throw "ThreadId and DispatchFailed are mutually exclusive."
}

[bool]$hasDispatchResult = ![string]::IsNullOrWhiteSpace($ThreadId) -or $DispatchFailed
if ($TerminalState -eq "LOCKED")
{
    if ($hasDispatchResult) { throw "LOCKED cannot carry a dispatch result." }
    [ordered]@{
        action = "archive"
        terminalState = "LOCKED"
        retryDelaysSeconds = @()
        prompt = ""
        threadId = ""
        reason = "Another task owns the active WorkContext."
    } | ConvertTo-Json -Depth 4 -Compress
    return
}

if ($TerminalState -ne "DONE")
{
    if ($hasDispatchResult) { throw "$TerminalState cannot carry a dispatch result." }
    [ordered]@{
        action = "stop"
        terminalState = $TerminalState
        retryDelaysSeconds = @()
        prompt = ""
        threadId = ""
        reason = "Terminal state $TerminalState is not eligible for dispatch."
    } | ConvertTo-Json -Depth 4 -Compress
    return
}

if ($SelectionStatus -eq "not_checked")
{
    throw "DONE requires the nextTarget status returned by complete_issue."
}
if ($SelectionStatus -eq "selected" -and $Issue -le 0)
{
    throw "A selected next target requires an explicit ISSUE."
}
if ($SelectionStatus -ne "selected" -and $hasDispatchResult)
{
    throw "Selection status $SelectionStatus cannot carry a dispatch result."
}

if ($SelectionStatus -eq "selected")
{
    [string]$prompt = "使用 `$project-issue。`n`nCONFIG=$Config`nMODE=run`nISSUE=$Issue"
    if (![string]::IsNullOrWhiteSpace($ThreadId))
    {
        [ordered]@{
            action = "stop"
            terminalState = "DONE_NEXT_DISPATCHED"
            retryDelaysSeconds = @()
            prompt = ""
            issue = $Issue
            threadId = $ThreadId
            reason = "The next local Codex task was created."
        } | ConvertTo-Json -Depth 4 -Compress
        return
    }
    if ($DispatchFailed)
    {
        [ordered]@{
            action = "stop"
            terminalState = "DONE_NEXT_DISPATCH_FAILED"
            retryDelaysSeconds = @()
            prompt = $prompt
            issue = $Issue
            threadId = ""
            reason = "Project resolution or task creation failed after all attempts."
        } | ConvertTo-Json -Depth 4 -Compress
        return
    }
    [ordered]@{
        action = "dispatch"
        terminalState = "PENDING"
        retryDelaysSeconds = @(0, 5, 15)
        prompt = $prompt
        issue = $Issue
        threadId = ""
        reason = "The completion seam returned one explicit next target."
    } | ConvertTo-Json -Depth 4 -Compress
    return
}

[string]$terminal = if ($SelectionStatus -eq "parent_complete") {
    "DONE_PARENT_COMPLETE"
} else {
    "NO_ISSUE"
}
[ordered]@{
    action = "stop"
    terminalState = $terminal
    retryDelaysSeconds = @()
    prompt = ""
    threadId = ""
    reason = "Completion returned $SelectionStatus."
} | ConvertTo-Json -Depth 4 -Compress
