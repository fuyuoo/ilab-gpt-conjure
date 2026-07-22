[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Config,

    [Parameter(Mandatory = $true)]
    [ValidateSet("dry-run", "run")]
    [string]$Mode,

    [int]$Parent = 0,

    [int]$Issue = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[System.Diagnostics.Stopwatch]$beginStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
[int]$githubCallCount = 0
[long]$githubElapsedMs = 0
[string]$repository = ""
. (Join-Path $PSScriptRoot "owner_state.ps1")

# 输出 begin_issue 的稳定只读结果，并集中计算公开性能指标。
function Write-BeginResult
{
    param(
        [string]$Status,
        [int]$ResolvedParent = 0,
        [AllowNull()] [object]$IssueData = $null,
        [string]$TargetKind = "",
        [string]$NextState = "",
        [string]$Reason = "",
        [int]$CandidateCount = 0,
        [int]$CheckedCount = 0,
        [int]$HitPosition = 0
    )

    $beginStopwatch.Stop()
    [ordered]@{
        status = $Status
        repository = if ([string]::IsNullOrWhiteSpace($repository)) { $null } else { $repository }
        parent = if ($ResolvedParent -gt 0) { $ResolvedParent } else { $null }
        issue = if ($null -eq $IssueData) { $null } else { [int]$IssueData.number }
        title = if ($null -eq $IssueData) { $null } else { [string]$IssueData.title }
        url = if ($null -eq $IssueData) { $null } else { [string]$IssueData.html_url }
        targetKind = if ([string]::IsNullOrWhiteSpace($TargetKind)) { $null } else { $TargetKind }
        nextState = if ([string]::IsNullOrWhiteSpace($NextState)) { $null } else { $NextState }
        dryRun = $Mode -eq "dry-run"
        metrics = [ordered]@{
            phase = "begin"
            candidateCount = $CandidateCount
            checkedCount = $CheckedCount
            hitPosition = if ($HitPosition -gt 0) { $HitPosition } else { $null }
            githubCalls = $githubCallCount
            githubElapsedMs = $githubElapsedMs
            elapsedMs = [long]$beginStopwatch.ElapsedMilliseconds
        }
        reason = $Reason
    } | ConvertTo-Json -Depth 8 -Compress
}

# 输出正式 begin 的稳定 WorkContext，供实现阶段和后续 complete seam 复用同一 owner 与 BASE。
function Write-WorkContext
{
    param(
        [int]$ResolvedParent,
        [object]$IssueData,
        [string]$TargetKind,
        [object]$Owner,
        [string]$Base,
        [string]$Workspace,
        [string]$Checkpoint,
        [bool]$Recovered
    )

    $beginStopwatch.Stop()
    [ordered]@{
        status = "begun"
        repository = $repository
        parent = $ResolvedParent
        issue = [int]$IssueData.number
        title = [string]$IssueData.title
        url = [string]$IssueData.html_url
        targetKind = $TargetKind
        nextState = "IMPLEMENT"
        dryRun = $false
        owner = [ordered]@{
            token = [string]$Owner.token
            commentId = [long]$Owner.commentId
            leaseExpiresAt = [string]$Owner.leaseExpiresAt
        }
        base = $Base
        workspace = $Workspace
        checkpoint = if ([string]::IsNullOrWhiteSpace($Checkpoint)) { $null } else { $Checkpoint }
        recovered = $Recovered
        completion = [ordered]@{
            repository = $repository
            parent = $ResolvedParent
            issue = [int]$IssueData.number
            ownerToken = [string]$Owner.token
            ownerCommentId = [long]$Owner.commentId
            base = $Base
        }
        metrics = [ordered]@{
            phase = "begin"
            githubCalls = $githubCallCount
            githubElapsedMs = $githubElapsedMs
            elapsedMs = [long]$beginStopwatch.ElapsedMilliseconds
        }
        reason = if ($Recovered) { "Recovered the expired owner BASE." } else { "Owner acquired." }
    } | ConvertTo-Json -Depth 8 -Compress
}

# 读取 Git 仓库身份；该命令不修改工作区、索引或分支。
function Get-RepositoryFromConfig
{
    param([string]$ConfigPath)

    [string]$configDirectory = Split-Path -Parent $ConfigPath
    [string[]]$outputLines = @(& git -C $configDirectory remote get-url origin)
    if ($LASTEXITCODE -ne 0)
    {
        throw "git remote lookup failed for CONFIG."
    }
    [string]$originUrl = ($outputLines -join "`n").Trim() -replace "\.git$", ""
    [System.Text.RegularExpressions.Match]$match = [regex]::Match(
        $originUrl, "github\.com[/:](?<repository>[^/\s]+/[^/\s]+)$")
    if (!$match.Success)
    {
        throw "origin must be a GitHub repository URL."
    }
    return $match.Groups["repository"].Value
}

# 调用只读 GitHub API，并把调用耗时纳入公开指标。
function Invoke-GhJson
{
    param([string[]]$Arguments)

    [System.Diagnostics.Stopwatch]$githubStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:githubCallCount++
    try
    {
        [string[]]$outputLines = @(& gh @Arguments)
        if ($LASTEXITCODE -ne 0)
        {
            throw "gh command failed: gh $($Arguments -join ' ')"
        }
        [string]$json = $outputLines -join "`n"
        if ([string]::IsNullOrWhiteSpace($json))
        {
            return $null
        }
        return $json | ConvertFrom-Json
    }
    finally
    {
        $githubStopwatch.Stop()
        $script:githubElapsedMs += $githubStopwatch.ElapsedMilliseconds
    }
}

# 执行 Git 命令并把非零退出显式提升为 begin 失败，避免用不完整状态继续。
function Invoke-GitText
{
    param([string]$WorkingDirectory, [string[]]$Arguments)

    [object[]]$output = @(& git -C $WorkingDirectory @Arguments 2>&1)
    [string]$text = ($output | ForEach-Object { [string]$_ }) -join "`n"
    if ($LASTEXITCODE -ne 0)
    {
        throw "git command failed: git -C $WorkingDirectory $($Arguments -join ' ')`n$text"
    }
    return $text.Trim()
}

# 读取可不存在的 Git ref；非零退出只表示该可选边界当前不可用。
function Get-OptionalGitText
{
    param([string]$WorkingDirectory, [string[]]$Arguments)

    [object[]]$output = @(& git -C $WorkingDirectory @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0)
    {
        return $null
    }
    return (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

# 判断一个提交是否为另一个提交的祖先，用于识别已完成的安全 fast-forward 边界。
function Test-GitAncestor
{
    param([string]$WorkingDirectory, [string]$Ancestor, [string]$Descendant)

    & git -C $WorkingDirectory merge-base --is-ancestor $Ancestor $Descendant *> $null
    return $LASTEXITCODE -eq 0
}

# 读取可不存在的原生 Parent；只把 GitHub 明确的 404 解释为“没有 Parent”。
function Get-OptionalNativeParent
{
    param([int]$IssueNumber)

    [System.Diagnostics.Stopwatch]$githubStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:githubCallCount++
    try
    {
        [object[]]$output = @(& gh api "repos/$repository/issues/$IssueNumber/parent" 2>&1)
        [string]$text = ($output | ForEach-Object { [string]$_ }) -join "`n"
        if ($LASTEXITCODE -ne 0)
        {
            if ($text -match "(?i)(HTTP\s*404|Not Found)")
            {
                return $null
            }
            throw "gh command failed while reading native parent for issue #$IssueNumber."
        }
        if ([string]::IsNullOrWhiteSpace($text) -or $text.Trim() -eq "null")
        {
            return $null
        }
        return $text | ConvertFrom-Json
    }
    finally
    {
        $githubStopwatch.Stop()
        $script:githubElapsedMs += $githubStopwatch.ElapsedMilliseconds
    }
}

# 展开 gh --slurp 返回的分页数组，同时兼容 Pester 中的单页 fake。
function Get-PagedItems
{
    param([string]$Endpoint)

    [object]$data = Invoke-GhJson -Arguments @("api", "--paginate", "--slurp", $Endpoint)
    [System.Collections.Generic.List[object]]$items = [System.Collections.Generic.List[object]]::new()
    foreach ($page in @($data))
    {
        if ($page -is [System.Array])
        {
            foreach ($item in @($page))
            {
                $items.Add($item)
            }
        }
        elseif ($null -ne $page)
        {
            $items.Add($page)
        }
    }
    return $items.ToArray()
}

# 判断 REST Issue 的 label 集合是否包含指定名称。
function Test-HasLabel
{
    param([object]$IssueData, [string]$LabelName)

    return @($IssueData.labels | ForEach-Object {
        if ($_ -is [string]) { [string]$_ } else { [string]$_.name }
    }) -contains $LabelName
}

# 返回 Parent 上当前有效的最小 comment id owner；过期或损坏 marker 不占用队列。
function Get-ActiveOwner
{
    param([int]$ParentNumber)

    [object[]]$comments = @(Get-PagedItems -Endpoint "repos/$repository/issues/$ParentNumber/comments?per_page=100")
    [System.Collections.Generic.List[object]]$owners = [System.Collections.Generic.List[object]]::new()
    foreach ($comment in $comments)
    {
        [object]$owner = ConvertFrom-ProjectIssueOwnerComment `
            -Body ([string]$comment.body) -CommentId ([long]$comment.id) -UpdatedAt ([string]$comment.updated_at)
        if ($null -ne $owner -and [int]$owner.parent -eq $ParentNumber -and
            !(Test-ProjectIssueOwnerExpired -Owner $owner))
        {
            $owners.Add($owner)
            continue
        }

    }
    return @($owners | Sort-Object commentId | Select-Object -First 1)
}

# 一次读取 Parent 评论并返回每张 issue 最新的过期 owner；新恢复 owner 覆盖同 issue 的旧边界。
function Get-ExpiredOwners
{
    param([int]$ParentNumber)

    [object[]]$comments = @(Get-PagedItems -Endpoint "repos/$repository/issues/$ParentNumber/comments?per_page=100")
    [object[]]$expiredOwners = @($comments | ForEach-Object {
        [object]$owner = ConvertFrom-ProjectIssueOwnerComment `
            -Body ([string]$_.body) -CommentId ([long]$_.id) -UpdatedAt ([string]$_.updated_at)
        if ($null -ne $owner -and [int]$owner.parent -eq $ParentNumber -and
            (Test-ProjectIssueOwnerExpired -Owner $owner))
        {
            $owner
        }
    })
    [System.Collections.Generic.List[object]]$latestOwners = [System.Collections.Generic.List[object]]::new()
    foreach ($issueGroup in @($expiredOwners | Group-Object issue))
    {
        $latestOwners.Add(
            ($issueGroup.Group | Sort-Object commentId -Descending | Select-Object -First 1))
    }
    return $latestOwners.ToArray()
}

# 查找同一执行对象的过期 owner，供显式 ISSUE 恢复使用。
function Get-ExpiredOwner
{
    param([int]$ParentNumber, [int]$IssueNumber)

    return @(Get-ExpiredOwners -ParentNumber $ParentNumber | Where-Object {
        [int]$_.issue -eq $IssueNumber
    }) | Select-Object -First 1
}

# 为新工作安全同步并复用既有 checkpoint 脚本，然后把同步后的 HEAD 固定为 BASE。
function Initialize-NewWorkspace
{
    param([string]$Workspace)

    [string]$branch = Invoke-GitText -WorkingDirectory $Workspace -Arguments @("branch", "--show-current")
    if ([string]::IsNullOrWhiteSpace($branch))
    {
        throw "HEAD must be attached to a branch before begin."
    }
    Invoke-GitText -WorkingDirectory $Workspace -Arguments @("fetch", "origin", $branch) | Out-Null
    Invoke-GitText -WorkingDirectory $Workspace -Arguments @("merge", "--ff-only", "origin/$branch") | Out-Null

    [object]$prepared = (& (Join-Path $PSScriptRoot "prepare_workspace.ps1") -Workspace $Workspace) |
        ConvertFrom-Json
    if ([string]$prepared.status -notin @("clean", "checkpointed"))
    {
        throw "Workspace preparation did not return clean or checkpointed."
    }
    return [pscustomobject]@{
        workspace = [string]$prepared.workspace
        base = [string]$prepared.head
        checkpoint = if ($null -eq $prepared.commit) { "" } else { [string]$prepared.commit }
    }
}

# 证明恢复仍在原分支提交边界内；脏文件允许作为中断中的 issue 改动保留，但冲突状态不允许猜测。
function Get-SafeRecoveryWorkspace
{
    param(
        [string]$Workspace,
        [string]$Base,
        [int]$IssueNumber,
        [bool]$AllowRemoteBaseAdvance
    )

    [string]$branch = Invoke-GitText -WorkingDirectory $Workspace -Arguments @("branch", "--show-current")
    if ([string]::IsNullOrWhiteSpace($branch))
    {
        throw "Recovery requires an attached branch."
    }
    Invoke-GitText -WorkingDirectory $Workspace -Arguments @("cat-file", "-e", "$Base^{commit}") | Out-Null
    Invoke-GitText -WorkingDirectory $Workspace -Arguments @("merge-base", "--is-ancestor", $Base, "HEAD") | Out-Null
    [string]$unmerged = Invoke-GitText -WorkingDirectory $Workspace `
        -Arguments @("diff", "--name-only", "--diff-filter=U")
    if (![string]::IsNullOrWhiteSpace($unmerged))
    {
        throw "Recovery workspace has unresolved merge conflicts."
    }
    [string]$boundaryBase = $Base
    [string]$remoteHead = Get-OptionalGitText -WorkingDirectory $Workspace `
        -Arguments @("rev-parse", "--verify", "origin/$branch")
    if ($AllowRemoteBaseAdvance -and ![string]::IsNullOrWhiteSpace($remoteHead) -and
        (Test-GitAncestor -WorkingDirectory $Workspace -Ancestor $Base -Descendant $remoteHead) -and
        (Test-GitAncestor -WorkingDirectory $Workspace -Ancestor $remoteHead -Descendant "HEAD"))
    {
        $boundaryBase = $remoteHead
    }

    [string[]]$commits = @((Invoke-GitText -WorkingDirectory $Workspace `
        -Arguments @("rev-list", "--reverse", "$boundaryBase..HEAD")) -split "`r?`n" |
        Where-Object { ![string]::IsNullOrWhiteSpace($_) })
    [string]$checkpoint = ""
    if ($commits.Count -gt 0)
    {
        [string]$firstSubject = Invoke-GitText -WorkingDirectory $Workspace `
            -Arguments @("show", "-s", "--format=%s", $commits[0])
        if ($firstSubject -eq "chore: checkpoint workspace before project issue")
        {
            $checkpoint = $commits[0]
            $boundaryBase = $checkpoint
            $commits = @($commits | Select-Object -Skip 1)
        }
    }
    if ($commits.Count -gt 1)
    {
        throw "Recovery has more than one commit after BASE."
    }
    if ($commits.Count -eq 1)
    {
        [string]$subject = Invoke-GitText -WorkingDirectory $Workspace `
            -Arguments @("show", "-s", "--format=%s", $commits[0])
        if (!$subject.StartsWith("#$IssueNumber ", [System.StringComparison]::Ordinal))
        {
            throw "Recovery HEAD commit does not belong to issue #$IssueNumber."
        }
    }
    return [pscustomobject]@{
        workspace = [System.IO.Path]::GetFullPath($Workspace)
        base = $boundaryBase
        checkpoint = $checkpoint
    }
}

# 创建单执行者 owner；POST 响应丢失时仍按本轮 token 回读同一条评论。
function New-Owner
{
    param(
        [int]$ParentNumber,
        [int]$IssueNumber,
        [string]$Base,
        [string]$Checkpoint
    )

    [string]$token = [guid]::NewGuid().ToString()
    [string]$leaseExpiresAt = [datetime]::UtcNow.AddMinutes(180).ToString("o")
    [string]$body = New-ProjectIssueOwnerComment -Parent $ParentNumber `
        -Issue $IssueNumber -Token $token -Base $Base -Checkpoint $Checkpoint `
        -LeaseExpiresAt $leaseExpiresAt
    [object]$created = $null
    try
    {
        $created = Invoke-GhJson -Arguments @(
            "api", "--method", "POST", "repos/$repository/issues/$ParentNumber/comments", "-f", "body=$body")
    }
    catch
    {
        # POST 响应可能丢失；以唯一 token 回读实际创建结果，避免留下无法定位的 owner。
        [object[]]$comments = @(Get-PagedItems `
            -Endpoint "repos/$repository/issues/$ParentNumber/comments?per_page=100")
        [object[]]$matchingOwners = @($comments | ForEach-Object {
            [object]$owner = ConvertFrom-ProjectIssueOwnerComment `
                -Body ([string]$_.body) -CommentId ([long]$_.id) -UpdatedAt ([string]$_.updated_at)
            if ($null -ne $owner -and [string]$owner.token -eq $token)
            {
                [pscustomobject]@{ id = [long]$owner.commentId }
            }
        })
        if ($matchingOwners.Count -ne 1)
        {
            throw
        }
        $created = $matchingOwners[0]
    }
    return ConvertFrom-ProjectIssueOwnerComment `
        -Body $body -CommentId ([long]$created.id) -UpdatedAt ([datetime]::UtcNow.ToString("o"))
}

# 把 owner 评论更新为最终 BASE/检查点。
function Update-Owner
{
    param(
        [int]$ParentNumber,
        [int]$IssueNumber,
        [object]$Owner,
        [string]$Base,
        [string]$Checkpoint
    )

    [string]$leaseExpiresAt = [datetime]::UtcNow.AddMinutes(180).ToString("o")
    [string]$body = New-ProjectIssueOwnerComment -Parent $ParentNumber -Issue $IssueNumber `
        -Token ([string]$Owner.token) -Base $Base -Checkpoint $Checkpoint `
        -LeaseExpiresAt $leaseExpiresAt
    Invoke-GhJson -Arguments @(
        "api", "--method", "PATCH", "repos/$repository/issues/comments/$([long]$Owner.commentId)",
        "-f", "body=$body") | Out-Null
    return ConvertFrom-ProjectIssueOwnerComment `
        -Body $body -CommentId ([long]$Owner.commentId) -UpdatedAt ([datetime]::UtcNow.ToString("o"))
}

# 在 begin 无法进入实现时立即终止当前 owner 租约；失败则由调用方显式报告 PAUSED。
function Stop-OwnerLease
{
    param(
        [int]$ParentNumber,
        [object]$IssueData,
        [object]$Owner
    )

    [string]$expiredBody = New-ProjectIssueOwnerComment `
        -Parent $ParentNumber -Issue ([int]$IssueData.number) `
        -Token ([string]$Owner.token) -Base ([string]$Owner.base) `
        -Checkpoint ([string]$Owner.checkpoint) `
        -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(-1).ToString("o"))
    Invoke-GhJson -Arguments @(
        "api", "--method", "PATCH", "repos/$repository/issues/comments/$([long]$Owner.commentId)",
        "-f", "body=$expiredBody") | Out-Null
}

# 新建 owner 后统一按最小有效 comment id 决胜；loser 必须在任何共享状态写入前退休。
function Test-NewOwnerWon
{
    param(
        [int]$ParentNumber,
        [object]$IssueData,
        [object]$Owner
    )

    [object]$winner = @(Get-ActiveOwner -ParentNumber $ParentNumber) | Select-Object -First 1
    if ($null -ne $winner -and [long]$winner.commentId -eq [long]$Owner.commentId -and
        [string]$winner.token -eq [string]$Owner.token)
    {
        return $true
    }

    try
    {
        Invoke-GhJson -Arguments @(
            "api", "--method", "DELETE", "repos/$repository/issues/comments/$([long]$Owner.commentId)") |
            Out-Null
    }
    catch
    {
        try
        {
            Stop-OwnerLease -ParentNumber $ParentNumber -IssueData $IssueData -Owner $Owner
        }
        catch
        {
            throw "Lost owner competition and could not retire owner comment #$([long]$Owner.commentId)."
        }
    }
    return $false
}

# 新工作先创建 owner，再同步、checkpoint 和添加共享 in-progress 标签。
function Acquire-NewOwner
{
    param(
        [int]$ParentNumber,
        [object]$IssueData,
        [string]$TargetKind,
        [string]$ClaimLabel
    )

    [string]$workspace = [System.IO.Path]::GetFullPath(
        (Split-Path -Parent (Split-Path -Parent $resolvedConfig)))
    [string]$branch = Invoke-GitText -WorkingDirectory $workspace -Arguments @("branch", "--show-current")
    if ([string]::IsNullOrWhiteSpace($branch))
    {
        Write-BeginResult -Status "paused" -ResolvedParent $ParentNumber -IssueData $IssueData `
            -TargetKind $TargetKind -NextState "PAUSED" -Reason "HEAD must be attached to a branch before begin."
        return
    }
    [string]$initialBase = Invoke-GitText -WorkingDirectory $workspace -Arguments @("rev-parse", "HEAD")
    [object]$owner = $null
    try
    {
        $owner = New-Owner -ParentNumber $ParentNumber `
            -IssueNumber ([int]$IssueData.number) -Base $initialBase -Checkpoint ""
        if (!(Test-NewOwnerWon -ParentNumber $ParentNumber -IssueData $IssueData -Owner $owner))
        {
            Write-BeginResult -Status "locked" -ResolvedParent $ParentNumber -IssueData $IssueData `
                -TargetKind $TargetKind -NextState "LOCKED" `
                -Reason "Another task owns the smallest active owner comment." `
                -CandidateCount 1 -CheckedCount 1
            return
        }
    }
    catch
    {
        [string]$reason = [string]$_.Exception.Message
        if ($null -ne $owner)
        {
            try
            {
                Stop-OwnerLease -ParentNumber $ParentNumber -IssueData $IssueData -Owner $owner
            }
            catch
            {
                $reason += " Owner lease cleanup also failed: $([string]$_.Exception.Message)"
            }
        }
        Write-BeginResult -Status "paused" -ResolvedParent $ParentNumber -IssueData $IssueData `
            -TargetKind $TargetKind -NextState "PAUSED" -Reason $reason
        return
    }

    try
    {
        [object]$prepared = Initialize-NewWorkspace -Workspace $workspace
        [object]$finalOwner = Update-Owner -ParentNumber $ParentNumber `
            -IssueNumber ([int]$IssueData.number) -Owner $owner `
            -Base ([string]$prepared.base) -Checkpoint ([string]$prepared.checkpoint)
    }
    catch
    {
        [string]$reason = [string]$_.Exception.Message
        try
        {
            Stop-OwnerLease -ParentNumber $ParentNumber -IssueData $IssueData -Owner $owner
        }
        catch
        {
            $reason += " Owner lease cleanup also failed: $([string]$_.Exception.Message)"
        }
        Write-BeginResult -Status "paused" -ResolvedParent $ParentNumber -IssueData $IssueData `
            -TargetKind $TargetKind -NextState "PAUSED" -Reason $reason
        return
    }

    try
    {
        Invoke-GhJson -Arguments @(
            "api", "--method", "POST", "repos/$repository/issues/$([int]$IssueData.number)/labels",
            "-f", "labels[]=$ClaimLabel") | Out-Null
    }
    catch
    {
        [string]$reason = [string]$_.Exception.Message
        try
        {
            Stop-OwnerLease -ParentNumber $ParentNumber -IssueData $IssueData -Owner $finalOwner
        }
        catch
        {
            $reason += " Owner lease cleanup also failed: $([string]$_.Exception.Message)"
        }
        Write-BeginResult -Status "paused" -ResolvedParent $ParentNumber -IssueData $IssueData `
            -TargetKind $TargetKind -NextState "PAUSED" -Reason $reason
        return
    }
    Write-WorkContext -ResolvedParent $ParentNumber -IssueData $IssueData -TargetKind $TargetKind `
        -Owner $finalOwner -Base ([string]$prepared.base) -Workspace ([string]$prepared.workspace) `
        -Checkpoint ([string]$prepared.checkpoint) -Recovered $false
}

# 单执行者从过期 owner 保存的 BASE 恢复，并用新 comment 重新竞争执行权。
function Resume-Owner
{
    param(
        [int]$ParentNumber,
        [object]$IssueData,
        [string]$TargetKind,
        [object]$Owner
    )

    [string]$workspace = [System.IO.Path]::GetFullPath(
        (Split-Path -Parent (Split-Path -Parent $resolvedConfig)))
    try
    {
        [bool]$hasInProgress = Test-HasLabel -IssueData $IssueData -LabelName $claimLabel
        [object]$recovery = Get-SafeRecoveryWorkspace -Workspace $workspace -Base ([string]$Owner.base) `
            -IssueNumber ([int]$IssueData.number) -AllowRemoteBaseAdvance (!$hasInProgress)
    }
    catch
    {
        Write-BeginResult -Status "paused" -ResolvedParent $ParentNumber -IssueData $IssueData `
            -TargetKind $TargetKind -NextState "PAUSED" -Reason ([string]$_.Exception.Message) `
            -CandidateCount 1 -CheckedCount 1
        return
    }

    [object]$currentOwner = $Owner
    [bool]$createdRecoveryOwner = $false
    if (Test-ProjectIssueOwnerExpired -Owner $Owner)
    {
        try
        {
            $currentOwner = New-Owner -ParentNumber $ParentNumber `
                -IssueNumber ([int]$IssueData.number) -Base ([string]$recovery.base) `
                -Checkpoint ([string]$recovery.checkpoint)
            $createdRecoveryOwner = $true
            if (!(Test-NewOwnerWon -ParentNumber $ParentNumber -IssueData $IssueData -Owner $currentOwner))
            {
                Write-BeginResult -Status "locked" -ResolvedParent $ParentNumber -IssueData $IssueData `
                    -TargetKind $TargetKind -NextState "LOCKED" `
                    -Reason "Another task won expired-owner recovery." `
                    -CandidateCount 1 -CheckedCount 1
                return
            }
        }
        catch
        {
            [string]$reason = [string]$_.Exception.Message
            if ($createdRecoveryOwner)
            {
                try
                {
                    Stop-OwnerLease -ParentNumber $ParentNumber -IssueData $IssueData -Owner $currentOwner
                }
                catch
                {
                    $reason += " Recovery owner cleanup also failed: $([string]$_.Exception.Message)"
                }
            }
            Write-BeginResult -Status "paused" -ResolvedParent $ParentNumber -IssueData $IssueData `
                -TargetKind $TargetKind -NextState "PAUSED" -Reason $reason
            return
        }
    }
    elseif ([string]$Owner.base -ne [string]$recovery.base -or
        [string]$Owner.checkpoint -ne [string]$recovery.checkpoint)
    {
        try
        {
            $currentOwner = Update-Owner -ParentNumber $ParentNumber `
                -IssueNumber ([int]$IssueData.number) -Owner $Owner `
                -Base ([string]$recovery.base) -Checkpoint ([string]$recovery.checkpoint)
        }
        catch
        {
            [string]$reason = [string]$_.Exception.Message
            try
            {
                Stop-OwnerLease -ParentNumber $ParentNumber -IssueData $IssueData -Owner $currentOwner
            }
            catch
            {
                $reason += " Recovery owner cleanup also failed: $([string]$_.Exception.Message)"
            }
            Write-BeginResult -Status "paused" -ResolvedParent $ParentNumber -IssueData $IssueData `
                -TargetKind $TargetKind -NextState "PAUSED" -Reason $reason
            return
        }
    }

    if (!(Test-HasLabel -IssueData $IssueData -LabelName $claimLabel))
    {
        try
        {
            Invoke-GhJson -Arguments @(
                "api", "--method", "POST", "repos/$repository/issues/$([int]$IssueData.number)/labels",
                "-f", "labels[]=$claimLabel") | Out-Null
        }
        catch
        {
            [string]$reason = [string]$_.Exception.Message
            try
            {
                Stop-OwnerLease -ParentNumber $ParentNumber -IssueData $IssueData -Owner $currentOwner
            }
            catch
            {
                $reason += " Recovery owner cleanup also failed: $([string]$_.Exception.Message)"
            }
            Write-BeginResult -Status "paused" -ResolvedParent $ParentNumber -IssueData $IssueData `
                -TargetKind $TargetKind -NextState "PAUSED" -Reason $reason
            return
        }
    }

    Write-WorkContext -ResolvedParent $ParentNumber -IssueData $IssueData -TargetKind $TargetKind `
        -Owner $currentOwner -Base ([string]$recovery.base) -Workspace ([string]$recovery.workspace) `
        -Checkpoint ([string]$recovery.checkpoint) -Recovered $true
}

# dry-run 只报告选票；run 则在同一选中对象上建立 owner 和 WorkContext。
function Complete-SelectedIssue
{
    param(
        [int]$ResolvedParent,
        [object]$IssueData,
        [string]$TargetKind,
        [string]$Reason,
        [int]$CandidateCount,
        [int]$CheckedCount,
        [int]$HitPosition,
        [string]$ClaimLabel
    )

    if ($Mode -eq "dry-run")
    {
        Write-BeginResult -Status "selected" -ResolvedParent $ResolvedParent -IssueData $IssueData `
            -TargetKind $TargetKind -NextState "CLAIM" -Reason $Reason `
            -CandidateCount $CandidateCount -CheckedCount $CheckedCount -HitPosition $HitPosition
        return
    }
    Acquire-NewOwner -ParentNumber $ResolvedParent -IssueData $IssueData `
        -TargetKind $TargetKind -ClaimLabel $ClaimLabel
}

# 通过原生 dependency 与标签判断单个执行对象是否满足自动队列资格。
function Get-Eligibility
{
    param(
        [object]$IssueData,
        [string]$ReadyLabel,
        [string]$HumanLabel,
        [string]$ClaimLabel,
        [switch]$AllowClaimLabel
    )

    if ([string]$IssueData.state -ne "open")
    {
        return [pscustomobject]@{ eligible = $false; reason = "issue is not open" }
    }
    if (!(Test-HasLabel -IssueData $IssueData -LabelName $ReadyLabel))
    {
        return [pscustomobject]@{ eligible = $false; reason = "ready label is missing" }
    }
    if (Test-HasLabel -IssueData $IssueData -LabelName $HumanLabel)
    {
        return [pscustomobject]@{ eligible = $false; reason = "issue is routed to a human" }
    }
    if (!$AllowClaimLabel -and (Test-HasLabel -IssueData $IssueData -LabelName $ClaimLabel))
    {
        return [pscustomobject]@{ eligible = $false; reason = "issue is already in progress" }
    }

    [object]$blockedByData = Invoke-GhJson -Arguments @(
        "api", "repos/$repository/issues/$([int]$IssueData.number)/dependencies/blocked_by?per_page=100")
    [object[]]$openBlockers = @(@($blockedByData) | Where-Object { [string]$_.state -ne "closed" })
    if ($openBlockers.Count -gt 0)
    {
        return [pscustomobject]@{
            eligible = $false
            reason = "native dependencies are still open: $(@($openBlockers.number) -join ', ')"
        }
    }
    return [pscustomobject]@{ eligible = $true; reason = "eligible" }
}

# 恢复前统一重验当前资格，再由单一入口复用或重建 owner。
function Resume-EligibleOwner
{
    param(
        [int]$ParentNumber,
        [object]$IssueData,
        [string]$TargetKind,
        [object]$Owner,
        [int]$CandidateCount
    )

    [object]$eligibility = Get-Eligibility -IssueData $IssueData -ReadyLabel $readyLabel `
        -HumanLabel $humanLabel -ClaimLabel $claimLabel -AllowClaimLabel
    if (!$eligibility.eligible)
    {
        Write-BeginResult -Status "ineligible" -ResolvedParent $ParentNumber -IssueData $IssueData `
            -TargetKind $TargetKind -NextState "PAUSED" -Reason ([string]$eligibility.reason) `
            -CandidateCount $CandidateCount -CheckedCount 1
        return
    }
    Resume-Owner -ParentNumber $ParentNumber -IssueData $IssueData `
        -TargetKind $TargetKind -Owner $Owner
}

# 输入缺失是公开、可读的 dry-run 结果，不触发任何 GitHub 调用。
if ($Parent -le 0 -and $Issue -le 0)
{
    Write-BeginResult -Status "input_error" -NextState "PAUSED" `
        -Reason "At least one of PARENT or ISSUE is required."
    return
}

[string]$resolvedConfig = (Resolve-Path -LiteralPath $Config).Path
[object]$configData = Get-Content -Raw -LiteralPath $resolvedConfig | ConvertFrom-Json
[string[]]$configFields = @($configData.PSObject.Properties.Name)
if ($configFields.Count -ne 1 -or $configFields[0] -ne "labels")
{
    throw "CONFIG must contain only labels."
}
[string[]]$labelFields = @($configData.labels.PSObject.Properties.Name)
if (@($labelFields | Sort-Object) -join "," -ne "claim,human,manual,ready")
{
    throw "CONFIG labels must contain exactly ready, human, claim, and manual."
}
foreach ($requiredLabel in @("ready", "human", "claim", "manual"))
{
    if ($labelFields -notcontains $requiredLabel -or
        [string]::IsNullOrWhiteSpace([string]$configData.labels.$requiredLabel))
    {
        throw "labels.$requiredLabel is required in CONFIG."
    }
}
[string[]]$labelValues = @(
    [string]$configData.labels.ready,
    [string]$configData.labels.human,
    [string]$configData.labels.claim,
    [string]$configData.labels.manual)
if (@($labelValues | Select-Object -Unique).Count -ne 4)
{
    throw "CONFIG workflow labels must be distinct."
}
[string]$readyLabel = [string]$configData.labels.ready
[string]$humanLabel = [string]$configData.labels.human
[string]$claimLabel = [string]$configData.labels.claim
$repository = Get-RepositoryFromConfig -ConfigPath $resolvedConfig

if ($Issue -gt 0)
{
    [object]$issueData = Invoke-GhJson -Arguments @("api", "repos/$repository/issues/$Issue")
    [object]$nativeParent = Get-OptionalNativeParent -IssueNumber $Issue
    [int]$resolvedParent = 0
    [string]$targetKind = "child"

    if ($null -ne $nativeParent)
    {
        $resolvedParent = [int]$nativeParent.number
        if ($Parent -gt 0 -and $Parent -ne $resolvedParent)
        {
            Write-BeginResult -Status "invalid_relationship" -ResolvedParent $Parent -IssueData $issueData `
                -NextState "PAUSED" -Reason "Issue #$Issue is not a native child of Parent #$Parent."
            return
        }
    }
    else
    {
        if ($Parent -gt 0 -and $Parent -ne $Issue)
        {
            Write-BeginResult -Status "invalid_relationship" -ResolvedParent $Parent -IssueData $issueData `
                -NextState "PAUSED" -Reason "Issue #$Issue has no matching native Parent #$Parent."
            return
        }
        [object[]]$children = @(Get-PagedItems -Endpoint "repos/$repository/issues/$Issue/sub_issues?per_page=100")
        if ($children.Count -eq 0 -or @($children | Where-Object { [string]$_.state -ne "closed" }).Count -gt 0)
        {
            Write-BeginResult -Status "ineligible" -ResolvedParent $Issue -IssueData $issueData `
                -NextState "PAUSED" -Reason "Issue #$Issue is not a child and is not an eligible final Parent." `
                -CandidateCount 1 -CheckedCount 1
            return
        }
        $resolvedParent = $Issue
        $targetKind = "parent"
    }

    [object]$owner = @(Get-ActiveOwner -ParentNumber $resolvedParent) | Select-Object -First 1
    if ($null -ne $owner)
    {
        [object]$ownedIssue = [pscustomobject]@{
            number = [int]$owner.issue; title = $null; html_url = $null
        }
        Write-BeginResult -Status "locked" -ResolvedParent $resolvedParent -IssueData $ownedIssue `
            -NextState "LOCKED" -Reason "Parent #$resolvedParent already has an active owner." `
            -CandidateCount 1
        return
    }

    if ($Mode -eq "run")
    {
        try
        {
            [object]$expiredOwner = Get-ExpiredOwner -ParentNumber $resolvedParent -IssueNumber $Issue
        }
        catch
        {
            Write-BeginResult -Status "paused" -ResolvedParent $resolvedParent -IssueData $issueData `
                -TargetKind $targetKind -NextState "PAUSED" -Reason ([string]$_.Exception.Message) `
                -CandidateCount 1 -CheckedCount 1
            return
        }
        if ($null -ne $expiredOwner)
        {
            Resume-EligibleOwner -ParentNumber $resolvedParent -IssueData $issueData `
                -TargetKind $targetKind -Owner $expiredOwner -CandidateCount 1
            return
        }
        if (Test-HasLabel -IssueData $issueData -LabelName $claimLabel)
        {
            Write-BeginResult -Status "paused" -ResolvedParent $resolvedParent -IssueData $issueData `
                -TargetKind $targetKind -NextState "PAUSED" `
                -Reason "The in-progress issue has no recoverable owner BASE." `
                -CandidateCount 1 -CheckedCount 1
            return
        }
    }

    [object]$eligibility = Get-Eligibility -IssueData $issueData -ReadyLabel $readyLabel `
        -HumanLabel $humanLabel -ClaimLabel $claimLabel
    if (!$eligibility.eligible)
    {
        Write-BeginResult -Status "ineligible" -ResolvedParent $resolvedParent -IssueData $issueData `
            -TargetKind $targetKind -NextState "PAUSED" -Reason ([string]$eligibility.reason) `
            -CandidateCount 1 -CheckedCount 1
        return
    }
    Complete-SelectedIssue -ResolvedParent $resolvedParent -IssueData $issueData `
        -TargetKind $targetKind -Reason "Explicit issue is eligible." `
        -CandidateCount 1 -CheckedCount 1 -HitPosition 1 -ClaimLabel $claimLabel
    return
}

[object[]]$nativeChildren = @(Get-PagedItems -Endpoint "repos/$repository/issues/$Parent/sub_issues?per_page=100")
[object[]]$openChildren = @($nativeChildren | Where-Object { [string]$_.state -ne "closed" })
[int[]]$openChildNumbers = @($openChildren | ForEach-Object { [int]$_.number })

[object]$activeOwner = @(Get-ActiveOwner -ParentNumber $Parent) | Select-Object -First 1
if ($null -ne $activeOwner)
{
    [bool]$ownsFinalParent = $openChildren.Count -eq 0 -and [int]$activeOwner.issue -eq $Parent
    [object]$ownedIssue = [pscustomobject]@{
        number = [int]$activeOwner.issue; title = $null; html_url = $null
    }
    Write-BeginResult -Status "locked" -ResolvedParent $Parent -IssueData $ownedIssue `
        -NextState "LOCKED" -Reason "Parent #$Parent already has an active owner." `
        -CandidateCount $openChildren.Count
    return
}

# Parent 启动时先恢复唯一的 in-progress 子票，避免普通排名越过已开始的执行链。
if ($Mode -eq "run")
{
    try
    {
        [object[]]$expiredOpenOwners = @(Get-ExpiredOwners -ParentNumber $Parent | Where-Object {
            $openChildNumbers -contains [int]$_.issue -or
                ($openChildren.Count -eq 0 -and [int]$_.issue -eq $Parent)
        })
    }
    catch
    {
        Write-BeginResult -Status "paused" -ResolvedParent $Parent -NextState "PAUSED" `
            -Reason ([string]$_.Exception.Message) -CandidateCount $openChildren.Count
        return
    }
    if ($expiredOpenOwners.Count -gt 1)
    {
        Write-BeginResult -Status "paused" -ResolvedParent $Parent -NextState "PAUSED" `
            -Reason "Multiple open issues have expired owners." -CandidateCount $openChildren.Count
        return
    }
    if ($expiredOpenOwners.Count -eq 1)
    {
        [object]$expiredIssue = Invoke-GhJson -Arguments @(
            "api", "repos/$repository/issues/$([int]$expiredOpenOwners[0].issue)")
        [string]$expiredTargetKind = if ([int]$expiredOpenOwners[0].issue -eq $Parent) { "parent" } else { "child" }
        Resume-EligibleOwner -ParentNumber $Parent -IssueData $expiredIssue `
            -TargetKind $expiredTargetKind -Owner $expiredOpenOwners[0] `
            -CandidateCount ([Math]::Max(1, $openChildren.Count))
        return
    }

    [object[]]$inProgressChildren = @($openChildren | Where-Object {
        Test-HasLabel -IssueData $_ -LabelName $claimLabel
    })
    if ($inProgressChildren.Count -gt 1)
    {
        Write-BeginResult -Status "paused" -ResolvedParent $Parent -NextState "PAUSED" `
            -Reason "Multiple open children carry the in-progress label." `
            -CandidateCount $openChildren.Count
        return
    }
    if ($inProgressChildren.Count -eq 1)
    {
        [int]$recoveryIssueNumber = [int]$inProgressChildren[0].number
        [object]$recoveryIssue = Invoke-GhJson -Arguments @(
            "api", "repos/$repository/issues/$recoveryIssueNumber")
        try
        {
            [object]$expiredOwner = Get-ExpiredOwner `
                -ParentNumber $Parent -IssueNumber $recoveryIssueNumber
        }
        catch
        {
            Write-BeginResult -Status "paused" -ResolvedParent $Parent -IssueData $recoveryIssue `
                -TargetKind "child" -NextState "PAUSED" -Reason ([string]$_.Exception.Message) `
                -CandidateCount $openChildren.Count
            return
        }
        if ($null -ne $expiredOwner)
        {
            Resume-EligibleOwner -ParentNumber $Parent -IssueData $recoveryIssue `
                -TargetKind "child" -Owner $expiredOwner -CandidateCount $openChildren.Count
            return
        }
    }
}
if ($Mode -eq "run" -and $inProgressChildren.Count -eq 1)
{
    Write-BeginResult -Status "paused" -ResolvedParent $Parent `
        -IssueData $recoveryIssue -TargetKind "child" -NextState "PAUSED" `
        -Reason "The in-progress issue has no recoverable owner BASE." `
        -CandidateCount $openChildren.Count
    return
}

if ($openChildren.Count -eq 0)
{
    [object]$parentData = Invoke-GhJson -Arguments @("api", "repos/$repository/issues/$Parent")
    [object]$parentEligibility = Get-Eligibility -IssueData $parentData -ReadyLabel $readyLabel `
        -HumanLabel $humanLabel -ClaimLabel $claimLabel
    if ($parentEligibility.eligible)
    {
        Complete-SelectedIssue -ResolvedParent $Parent -IssueData $parentData `
            -TargetKind "parent" -Reason "All native children are closed; Parent is the final target." `
            -CandidateCount 1 -CheckedCount 1 -HitPosition 1 -ClaimLabel $claimLabel
    }
    else
    {
        Write-BeginResult -Status "no_issue" -ResolvedParent $Parent -NextState "STOP" `
            -Reason ([string]$parentEligibility.reason) -CandidateCount 1 -CheckedCount 1
    }
    return
}

[int]$checkedCount = 0
foreach ($childSummary in $openChildren)
{
    $checkedCount++
    [object]$childData = Invoke-GhJson -Arguments @(
        "api", "repos/$repository/issues/$([int]$childSummary.number)")
    [object]$eligibility = Get-Eligibility -IssueData $childData -ReadyLabel $readyLabel `
        -HumanLabel $humanLabel -ClaimLabel $claimLabel
    if ($eligibility.eligible)
    {
        Complete-SelectedIssue -ResolvedParent $Parent -IssueData $childData `
            -TargetKind "child" -Reason "Selected the first eligible native child." `
            -CandidateCount $openChildren.Count -CheckedCount $checkedCount -HitPosition $checkedCount `
            -ClaimLabel $claimLabel
        return
    }
}

Write-BeginResult -Status "no_issue" -ResolvedParent $Parent -NextState "STOP" `
    -Reason "No open native child is currently eligible." `
    -CandidateCount $openChildren.Count -CheckedCount $checkedCount
