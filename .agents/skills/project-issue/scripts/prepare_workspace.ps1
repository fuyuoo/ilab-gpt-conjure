[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Workspace
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[string]$CheckpointSubject = "chore: checkpoint workspace before project issue"
[string]$resolvedWorkspace = (Resolve-Path -LiteralPath $Workspace).Path
[string]$gitCommandRoot = $resolvedWorkspace

function Invoke-Git
{
    param([string[]]$Arguments)

    [string[]]$outputLines = @(& git -C $gitCommandRoot @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0)
    {
        throw "git command failed: git -C $gitCommandRoot $($Arguments -join ' ')`n$($outputLines -join "`n")"
    }
    return ($outputLines -join "`n").Trim()
}

[string]$gitRoot = [System.IO.Path]::GetFullPath((Invoke-Git -Arguments @("rev-parse", "--show-toplevel")))
[string]$relativeWorkspace = [System.IO.Path]::GetRelativePath($gitRoot, $resolvedWorkspace)
if ($relativeWorkspace.StartsWith(".."))
{
    throw "Workspace must be inside the Git repository."
}
$gitCommandRoot = $gitRoot

[string]$branch = Invoke-Git -Arguments @("branch", "--show-current")
if ([string]::IsNullOrWhiteSpace($branch))
{
    throw "HEAD must be attached to a branch before preparing the workspace."
}

foreach ($operationRef in @("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"))
{
    & git -C $gitRoot rev-parse --quiet --verify $operationRef *> $null
    if ($LASTEXITCODE -eq 0)
    {
        throw "Cannot checkpoint while $operationRef exists."
    }
}
[string]$gitDirectory = Invoke-Git -Arguments @("rev-parse", "--git-dir")
if (![System.IO.Path]::IsPathRooted($gitDirectory))
{
    $gitDirectory = [System.IO.Path]::GetFullPath((Join-Path $gitRoot $gitDirectory))
}
foreach ($rebaseDirectory in @("rebase-apply", "rebase-merge"))
{
    if (Test-Path -LiteralPath (Join-Path $gitDirectory $rebaseDirectory))
    {
        throw "Cannot checkpoint while a rebase is in progress."
    }
}

[string]$unmerged = Invoke-Git -Arguments @("diff", "--name-only", "--diff-filter=U")
if (![string]::IsNullOrWhiteSpace($unmerged))
{
    throw "Cannot checkpoint a workspace with unresolved merge conflicts."
}

[string]$previousHead = Invoke-Git -Arguments @("rev-parse", "HEAD")
[string[]]$statusLines = @((Invoke-Git -Arguments @("status", "--porcelain=v1")) -split "`r?`n" |
    Where-Object { ![string]::IsNullOrWhiteSpace($_) })
if ($statusLines.Count -eq 0)
{
    [ordered]@{
        status = "clean"
        workspace = $resolvedWorkspace
        gitRoot = $gitRoot
        branch = $branch
        previousHead = $previousHead
        head = $previousHead
        commit = $null
        subject = $null
        paths = @()
    } | ConvertTo-Json -Depth 5 -Compress
    exit 0
}

Invoke-Git -Arguments @("add", "--all") | Out-Null
[string]$stagedNames = Invoke-Git -Arguments @("diff", "--cached", "--name-only")
if ([string]::IsNullOrWhiteSpace($stagedNames))
{
    throw "Workspace was dirty but no checkpoint changes were staged."
}

Invoke-Git -Arguments @("commit", "--message", $CheckpointSubject) | Out-Null
[string]$head = Invoke-Git -Arguments @("rev-parse", "HEAD")
[string]$remainingStatus = Invoke-Git -Arguments @("status", "--porcelain=v1")
if (![string]::IsNullOrWhiteSpace($remainingStatus))
{
    throw "Workspace is still dirty after checkpoint commit."
}

[ordered]@{
    status = "checkpointed"
    workspace = $resolvedWorkspace
    gitRoot = $gitRoot
    branch = $branch
    previousHead = $previousHead
    head = $head
    commit = $head
    subject = $CheckpointSubject
    paths = @($stagedNames -split "`r?`n" | Where-Object { $_ })
} | ConvertTo-Json -Depth 5 -Compress
