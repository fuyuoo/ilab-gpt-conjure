[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Config,

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
    [string]$Base,

    [Parameter(Mandatory = $true)]
    [string]$VerificationPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[System.Diagnostics.Stopwatch]$completionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
[int]$githubCallCount = 0
[long]$githubElapsedMs = 0
. (Join-Path $PSScriptRoot "owner_state.ps1")
. (Join-Path $PSScriptRoot "acceptance_state.ps1")

# 执行 Git 命令并把非零退出提升为明确失败，避免门禁基于不完整状态继续。
function Invoke-CompletionGit
{
    param([string[]]$Arguments)

    [object[]]$output = @(& git @Arguments 2>&1)
    [string]$text = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0)
    {
        throw "git command failed: git $($Arguments -join ' ')`n$text"
    }
    return $text
}

# 调用 GitHub API，并让公开结果携带真实调用数量与耗时。
function Invoke-CompletionGh
{
    param([string[]]$Arguments)

    [System.Diagnostics.Stopwatch]$githubStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:githubCallCount++
    try
    {
        [string[]]$output = @(& gh @Arguments)
        if ($LASTEXITCODE -ne 0)
        {
            throw "gh command failed: gh $($Arguments -join ' ')"
        }
        [string]$json = ($output -join "`n").Trim()
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

# 展开 gh --slurp 的分页结果，同时兼容测试替身返回的单页数组。
function Get-CompletionPagedItems
{
    param([string]$Endpoint)

    [object]$data = Invoke-CompletionGh -Arguments @("api", "--paginate", "--slurp", $Endpoint)
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

# 判断下一目标是否携带指定 label；这里只读取权威 GitHub 状态，不修改下一票。
function Test-CompletionHasLabel
{
    param([object]$IssueData, [string]$LabelName)

    return @($IssueData.labels | ForEach-Object { [string]$_.name }) -contains $LabelName
}

# 关闭当前票后只读选择下一目标；开放子票永远优先，全部关闭后 Parent 才能成为最终目标。
function Get-NextCompletionTarget
{
    param(
        [string]$ReadyLabel,
        [string]$HumanLabel,
        [string]$ClaimLabel
    )

    if ($Issue -eq $Parent)
    {
        return [ordered]@{
            status = "parent_complete"
            targetKind = "terminal"
            parent = $Parent
            issue = $null
            title = $null
            url = $null
            reason = "The final Parent is closed; no next task is required."
        }
    }

    [object[]]$nativeChildren = @(Get-CompletionPagedItems `
        -Endpoint "repos/$Repository/issues/$Parent/sub_issues?per_page=100")
    [object[]]$openChildren = @($nativeChildren | Where-Object { [string]$_.state -ne "closed" })
    foreach ($childSummary in $openChildren)
    {
        [object]$child = Invoke-CompletionGh -Arguments @(
            "api", "repos/$Repository/issues/$([int]$childSummary.number)")
        if ([string]$child.state -ne "open" -or
            !(Test-CompletionHasLabel -IssueData $child -LabelName $ReadyLabel) -or
            (Test-CompletionHasLabel -IssueData $child -LabelName $HumanLabel) -or
            (Test-CompletionHasLabel -IssueData $child -LabelName $ClaimLabel))
        {
            continue
        }
        [object]$blockedBy = Invoke-CompletionGh -Arguments @(
            "api", "repos/$Repository/issues/$([int]$child.number)/dependencies/blocked_by?per_page=100")
        if (@(@($blockedBy) | Where-Object { [string]$_.state -ne "closed" }).Count -gt 0)
        {
            continue
        }
        return [ordered]@{
            status = "selected"
            targetKind = "child"
            parent = $Parent
            issue = [int]$child.number
            title = [string]$child.title
            url = [string]$child.html_url
            reason = "Selected the first eligible native child after completion."
        }
    }

    if ($openChildren.Count -gt 0)
    {
        return [ordered]@{
            status = "no_issue"
            targetKind = "terminal"
            parent = $Parent
            issue = $null
            title = $null
            url = $null
            reason = "Open native children remain, but none is currently eligible."
        }
    }

    [object]$parentData = Invoke-CompletionGh -Arguments @("api", "repos/$Repository/issues/$Parent")
    if ([string]$parentData.state -eq "closed")
    {
        return [ordered]@{
            status = "parent_complete"
            targetKind = "terminal"
            parent = $Parent
            issue = $null
            title = $null
            url = $null
            reason = "The Parent is already closed."
        }
    }
    if (!(Test-CompletionHasLabel -IssueData $parentData -LabelName $ReadyLabel) -or
        (Test-CompletionHasLabel -IssueData $parentData -LabelName $HumanLabel) -or
        (Test-CompletionHasLabel -IssueData $parentData -LabelName $ClaimLabel))
    {
        return [ordered]@{
            status = "no_issue"
            targetKind = "terminal"
            parent = $Parent
            issue = $null
            title = $null
            url = $null
            reason = "Every native child is closed, but the Parent is not eligible."
        }
    }
    [object]$parentBlockedBy = Invoke-CompletionGh -Arguments @(
        "api", "repos/$Repository/issues/$Parent/dependencies/blocked_by?per_page=100")
    if (@(@($parentBlockedBy) | Where-Object { [string]$_.state -ne "closed" }).Count -gt 0)
    {
        return [ordered]@{
            status = "no_issue"
            targetKind = "terminal"
            parent = $Parent
            issue = $null
            title = $null
            url = $null
            reason = "Every native child is closed, but the Parent has an open native blocker."
        }
    }
    return [ordered]@{
        status = "selected"
        targetKind = "parent"
        parent = $Parent
        issue = $Parent
        title = [string]$parentData.title
        url = [string]$parentData.html_url
        reason = "Every native child is closed; the Parent is the final target."
    }
}

# 查找与当前 WorkContext 和 HEAD 完整绑定的 delivery marker，供中断后的幂等续跑复用。
function Get-MatchingDelivery
{
    param([string]$Head)

    [object[]]$comments = @(Get-CompletionPagedItems `
        -Endpoint "repos/$Repository/issues/$Issue/comments?per_page=100")
    foreach ($comment in $comments)
    {
        [System.Text.RegularExpressions.Match]$deliveryMatch = [regex]::Match(
            [string]$comment.body,
            "(?m)^<!-- project-issue-automation:delivery-v1 (?<json>\{.*\}) -->\r?$")
        if (!$deliveryMatch.Success)
        {
            continue
        }
        try
        {
            [object]$delivery = $deliveryMatch.Groups["json"].Value | ConvertFrom-Json
        }
        catch
        {
            continue
        }
        if ([int]$delivery.parent -eq $Parent -and [int]$delivery.issue -eq $Issue -and
            [string]$delivery.base -eq $Base -and [string]$delivery.head -eq $Head -and
            [string]$delivery.owner_token -eq $OwnerToken)
        {
            return [pscustomobject]@{
                payload = $delivery
                url = [string]$comment.html_url
            }
        }
    }
    return $null
}

# 输出 complete_issue 的稳定结果；终态只由这一处生成。
function Write-CompletionResult
{
    param(
        [string]$Status,
        [string]$Head = "",
        [int]$ReviewRepairCount = 0,
        [string]$EvidenceUrl = "",
        [bool]$AlreadyCompleted = $false,
        [int]$PendingManualCount = 0,
        [AllowNull()] [object]$NextTarget = $null,
        [string]$Reason = ""
    )

    $completionStopwatch.Stop()
    [ordered]@{
        status = $Status
        repository = $Repository
        parent = $Parent
        issue = $Issue
        head = if ([string]::IsNullOrWhiteSpace($Head)) { $null } else { $Head }
        reviewRepairCount = $ReviewRepairCount
        evidenceUrl = if ([string]::IsNullOrWhiteSpace($EvidenceUrl)) { $null } else { $EvidenceUrl }
        alreadyCompleted = $AlreadyCompleted
        pendingManualCount = $PendingManualCount
        nextTarget = $NextTarget
        metrics = [ordered]@{
            phase = "complete"
            githubCalls = $githubCallCount
            githubElapsedMs = $githubElapsedMs
            elapsedMs = [long]$completionStopwatch.ElapsedMilliseconds
        }
        reason = $Reason
    } | ConvertTo-Json -Depth 10 -Compress
}

# 只允许自动证据豁免混合 AC 的自动部分；纯自动项仍必须勾选。
function Get-PendingManualAcceptance
{
    param(
        [object]$AcceptanceState,
        [object]$Verification
    )

    [object[]]$automatedSatisfied = @()
    if ($Verification.acceptance.PSObject.Properties.Name -contains "automatedSatisfied")
    {
        $automatedSatisfied = @($Verification.acceptance.automatedSatisfied)
    }
    foreach ($entry in $automatedSatisfied)
    {
        [string[]]$properties = @($entry.PSObject.Properties.Name)
        if (@("index", "testRunId", "evidence" | Where-Object { $properties -notcontains $_ }).Count -gt 0 -or
            [int]$entry.index -le 0 -or
            [string]::IsNullOrWhiteSpace([string]$entry.testRunId) -or
            [string]::IsNullOrWhiteSpace([string]$entry.evidence))
        {
            throw "Mixed acceptance automation evidence must include index, testRunId, and evidence."
        }
    }
    [int[]]$automatedSatisfiedIndexes = @($automatedSatisfied | ForEach-Object { [int]$_.index })
    if (@($automatedSatisfiedIndexes | Select-Object -Unique).Count -ne $automatedSatisfiedIndexes.Count)
    {
        throw "Mixed acceptance automation evidence contains duplicate item indexes."
    }

    [object[]]$mixedItems = @($AcceptanceState.items | Where-Object {
        [string]$_.classification -eq "mixed"
    })
    [int[]]$mixedIndexes = @($mixedItems | ForEach-Object { [int]$_.index })
    if (@($automatedSatisfiedIndexes | Where-Object { $mixedIndexes -notcontains $_ }).Count -gt 0)
    {
        throw "Mixed acceptance automation evidence references a non-mixed item."
    }
    foreach ($entry in $automatedSatisfied)
    {
        [object[]]$matchingTests = @($Verification.tests | Where-Object {
            [string]$_.runId -eq [string]$entry.testRunId -and
            [string]$_.head -eq [string]$Verification.head -and
            [int]$_.exitCode -eq 0 -and [int]$_.failed -eq 0 -and
            [int]$_.total -gt 0 -and [int]$_.passed -gt 0
        })
        if ($matchingTests.Count -ne 1)
        {
            throw "Mixed acceptance automation evidence must reference one passing current-HEAD test run."
        }
    }

    [object[]]$uncheckedAutomatic = @($AcceptanceState.items | Where-Object {
        ![bool]$_.checked -and [string]$_.classification -eq "automatic"
    })
    if ($uncheckedAutomatic.Count -gt 0)
    {
        throw "All automated acceptance criteria must be checked before completion."
    }

    [object[]]$uncheckedMixed = @($mixedItems | Where-Object { ![bool]$_.checked })
    [object[]]$unverifiedMixed = @($uncheckedMixed | Where-Object {
        $automatedSatisfiedIndexes -notcontains [int]$_.index
    })
    if ($unverifiedMixed.Count -gt 0)
    {
        throw "Every unchecked mixed acceptance item requires passing automated evidence."
    }

    return @($AcceptanceState.items | Where-Object {
        ![bool]$_.checked -and [string]$_.classification -in @("manual", "mixed")
    })
}

# 验证当前 token 仍是 Parent 上 comment id 最小的有效 owner。
function Get-VerifiedOwner
{
    [object[]]$comments = @(Get-CompletionPagedItems `
        -Endpoint "repos/$Repository/issues/$Parent/comments?per_page=100")
    [object[]]$activeOwners = @($comments | ForEach-Object {
        [object]$parsedOwner = ConvertFrom-ProjectIssueOwnerComment `
            -Body ([string]$_.body) -CommentId ([long]$_.id) -UpdatedAt ([string]$_.updated_at)
        if ($null -ne $parsedOwner -and [int]$parsedOwner.parent -eq $Parent -and
            !(Test-ProjectIssueOwnerExpired -Owner $parsedOwner))
        {
            $parsedOwner
        }
    } | Sort-Object commentId)
    if ($activeOwners.Count -eq 0)
    {
        throw "No active owner remains for Parent #$Parent."
    }
    [object]$currentOwner = $activeOwners[0]
    if ([long]$currentOwner.commentId -ne $OwnerCommentId -or
        [string]$currentOwner.token -ne $OwnerToken -or
        [int]$currentOwner.issue -ne $Issue -or
        [string]$currentOwner.base -ne $Base)
    {
        throw "The supplied WorkContext is not the active owner."
    }
    return $currentOwner
}

# 验证最终自动化记录已经通过，且 review 修复历史没有越过公开上限。
function Assert-VerificationPassed
{
    param(
        [object]$Verification,
        [string]$Head,
        [object]$AcceptanceState
    )

    if ([int]$Verification.parent -ne $Parent -or [int]$Verification.issue -ne $Issue -or
        [string]$Verification.base -ne $Base -or [string]$Verification.head -ne $Head)
    {
        throw "Verification record is not bound to the current WorkContext and HEAD."
    }
    if ([bool]$Verification.acceptance.provided -ne [bool]$AcceptanceState.provided -or
        [int]$Verification.acceptance.total -ne [int]$AcceptanceState.total -or
        [int]$Verification.acceptance.checked -ne [int]$AcceptanceState.checked -or
        [int]$Verification.acceptance.unchecked -ne [int]$AcceptanceState.unchecked -or
        [string]$Verification.acceptance.fingerprint -ne [string]$AcceptanceState.fingerprint)
    {
        throw "Verification acceptance evidence does not match the current Issue AC."
    }

    [object[]]$tests = @($Verification.tests)
    if ($tests.Count -eq 0)
    {
        throw "At least one automated test result is required."
    }
    [int]$currentHeadTestCount = 0
    foreach ($test in $tests)
    {
        if ([int]$test.exitCode -ne 0 -or [int]$test.failed -ne 0 -or
            [int]$test.total -le 0 -or [int]$test.passed -le 0 -or
            [string]::IsNullOrWhiteSpace([string]$test.command) -or
            [string]::IsNullOrWhiteSpace([string]$test.reportPath) -or
            [string]::IsNullOrWhiteSpace([string]$test.runId) -or
            [string]$test.head -notmatch "^[0-9a-f]{40}$")
        {
            throw "Automated verification contains a failed or incomplete test result."
        }
        if ([string]$test.head -eq $Head)
        {
            $currentHeadTestCount++
        }
    }
    if ($currentHeadTestCount -eq 0)
    {
        throw "Automated verification has no passing test result bound to the current HEAD."
    }

    [object[]]$repairRounds = @($Verification.reviews.repairRounds)
    if ($repairRounds.Count -gt 5)
    {
        throw "Review repair count exceeds the five-round limit."
    }
    if ([string]$Verification.reviews.head -ne $Head -or
        [string]$Verification.reviews.initialHead -notmatch "^[0-9a-f]{40}$" -or
        [string]$Verification.reviews.initialStandards -notin @("PASS", "BLOCKER") -or
        [string]$Verification.reviews.initialSpec -notin @("PASS", "BLOCKER"))
    {
        throw "Initial review evidence is incomplete or not bound to the current review history."
    }

    foreach ($repairRound in $repairRounds)
    {
        [string[]]$roundProperties = @($repairRound.PSObject.Properties.Name)
        [string[]]$requiredRoundProperties = @(
            "round", "amended", "beforeHead", "afterHead", "codeChanged", "testsChanged",
            "testRunId", "standards", "spec", "remainingFindings")
        if (@($requiredRoundProperties | Where-Object { $roundProperties -notcontains $_ }).Count -gt 0 -or
            !($repairRound.amended -is [bool]) -or !($repairRound.codeChanged -is [bool]) -or
            !($repairRound.testsChanged -is [bool]))
        {
            throw "Every review repair round must record amend, changes, retest, dual-review, and remaining findings."
        }
    }

    # 连续两轮没有任何代码/测试变化且 finding 集合相同，说明继续复审只会空转。
    for ([int]$index = 1; $index -lt $repairRounds.Count; $index++)
    {
        [object]$previousRound = $repairRounds[$index - 1]
        [object]$currentRound = $repairRounds[$index]
        [string]$previousFindings = @($previousRound.remainingFindings) | ConvertTo-Json -Compress
        [string]$currentFindings = @($currentRound.remainingFindings) | ConvertTo-Json -Compress
        if (![bool]$previousRound.codeChanged -and ![bool]$previousRound.testsChanged -and
            ![bool]$currentRound.codeChanged -and ![bool]$currentRound.testsChanged -and
            $previousFindings -eq $currentFindings)
        {
            throw "Review repair stalled for two unchanged rounds with the same findings."
        }
    }

    [string]$expectedBeforeHead = [string]$Verification.reviews.initialHead
    for ([int]$index = 0; $index -lt $repairRounds.Count; $index++)
    {
        [object]$repairRound = $repairRounds[$index]
        [object[]]$matchingTestRuns = @($tests | Where-Object {
            [string]$_.runId -eq [string]$repairRound.testRunId -and
            [string]$_.head -eq [string]$repairRound.afterHead
        })
        if ([int]$repairRound.round -ne ($index + 1) -or ![bool]$repairRound.amended -or
            [string]$repairRound.beforeHead -ne $expectedBeforeHead -or
            [string]$repairRound.beforeHead -notmatch "^[0-9a-f]{40}$" -or
            [string]$repairRound.afterHead -notmatch "^[0-9a-f]{40}$" -or
            [string]$repairRound.standards -notin @("PASS", "BLOCKER") -or
            [string]$repairRound.spec -notin @("PASS", "BLOCKER") -or
            [string]::IsNullOrWhiteSpace([string]$repairRound.testRunId) -or
            $matchingTestRuns.Count -ne 1)
        {
            throw "Review repair round $($index + 1) lacks amend, retest, dual-review, or HEAD evidence."
        }
        if ([string]$repairRound.beforeHead -eq [string]$repairRound.afterHead)
        {
            throw "Review repair round $($index + 1) must have different before and after HEADs."
        }
        $expectedBeforeHead = [string]$repairRound.afterHead
    }
    if (($repairRounds.Count -eq 0 -and [string]$Verification.reviews.initialHead -ne $Head) -or
        ($repairRounds.Count -gt 0 -and $expectedBeforeHead -ne $Head))
    {
        throw "Review history does not terminate at the current HEAD."
    }

    [string]$expectedFinalStandards = if ($repairRounds.Count -eq 0) {
        [string]$Verification.reviews.initialStandards
    } else {
        [string]$repairRounds[-1].standards
    }
    [string]$expectedFinalSpec = if ($repairRounds.Count -eq 0) {
        [string]$Verification.reviews.initialSpec
    } else {
        [string]$repairRounds[-1].spec
    }
    if ([string]$Verification.reviews.finalStandards -ne $expectedFinalStandards -or
        [string]$Verification.reviews.finalSpec -ne $expectedFinalSpec)
    {
        throw "Final review conclusions do not match the last recorded dual-axis review."
    }

    if ([string]$Verification.reviews.finalStandards -ne "PASS" -or
        [string]$Verification.reviews.finalSpec -ne "PASS")
    {
        throw "Standards and Spec reviews must both finish with PASS."
    }
}

# 把 owner 已确认后的自动化失败转为可诊断的人工作业，并按安全顺序释放占用。
function Stop-CompletionForAutomationFailure
{
    param(
        [string]$ClaimLabel,
        [string]$HumanLabel,
        [string]$Reason,
        [string]$Head = "",
        [int]$ReviewRepairCount = 0
    )

    [System.Collections.Specialized.OrderedDictionary]$failurePayload = [ordered]@{
        version = 1
        parent = $Parent
        issue = $Issue
        base = $Base
        head = $Head
        reason = $Reason
    }
    [string]$failureBody = @"
<!-- project-issue-automation:failure-v1 $($failurePayload | ConvertTo-Json -Compress) -->

### Project Issue Automation Failure

- Reason：$Reason
- Result：routed to human; no next issue will be dispatched
"@
    Invoke-CompletionGh -Arguments @(
        "api", "--method", "POST", "repos/$Repository/issues/$Issue/comments", "-f", "body=$failureBody") |
        Out-Null
    Invoke-CompletionGh -Arguments @(
        "api", "--method", "POST", "repos/$Repository/issues/$Issue/labels", "-f", "labels[]=$HumanLabel") |
        Out-Null
    Invoke-CompletionGh -Arguments @(
        "api", "--method", "DELETE", "repos/$Repository/issues/$Issue/labels/$ClaimLabel") |
        Out-Null
    Invoke-CompletionGh -Arguments @(
        "api", "--method", "DELETE", "repos/$Repository/issues/comments/$OwnerCommentId") |
        Out-Null
    Write-CompletionResult -Status "blocked" -Head $Head `
        -ReviewRepairCount $ReviewRepairCount -Reason $Reason
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
    if ([string]::IsNullOrWhiteSpace([string]$configData.labels.$requiredLabel))
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
[string]$claimLabel = [string]$configData.labels.claim
[string]$readyLabel = [string]$configData.labels.ready
[string]$humanLabel = [string]$configData.labels.human
[string]$manualLabel = [string]$configData.labels.manual
[object]$verification = Get-Content -Raw -LiteralPath $VerificationPath | ConvertFrom-Json

[object]$initialIssueData = Invoke-CompletionGh -Arguments @("api", "repos/$Repository/issues/$Issue")
[string]$initialHead = Invoke-CompletionGit -Arguments @("rev-parse", "HEAD")
[object]$recordedDelivery = Get-MatchingDelivery -Head $initialHead
if ([string]$initialIssueData.state -eq "closed")
{
    if ($null -eq $recordedDelivery)
    {
        throw "Issue #$Issue is closed without a delivery record matching this WorkContext."
    }

    # 关闭后的重试只续完标签与 owner 清理，不重复 push、证据或 close。
    if (@($initialIssueData.labels | ForEach-Object { [string]$_.name }) -contains $claimLabel)
    {
        Invoke-CompletionGh -Arguments @(
            "api", "--method", "DELETE", "repos/$Repository/issues/$Issue/labels/$claimLabel") |
            Out-Null
    }
    [object[]]$recordedPendingManual = @($recordedDelivery.payload.pending_manual)
    if ($recordedPendingManual.Count -gt 0 -and
        @($initialIssueData.labels | ForEach-Object { [string]$_.name }) -notcontains $manualLabel)
    {
        Invoke-CompletionGh -Arguments @(
            "api", "--method", "POST", "repos/$Repository/issues/$Issue/labels",
            "-f", "labels[]=$manualLabel") | Out-Null
    }
    [object[]]$parentComments = @(Get-CompletionPagedItems `
        -Endpoint "repos/$Repository/issues/$Parent/comments?per_page=100")
    [object[]]$matchingOwners = @($parentComments | Where-Object { [long]$_.id -eq $OwnerCommentId } |
        ForEach-Object {
            ConvertFrom-ProjectIssueOwnerComment `
                -Body ([string]$_.body) -CommentId ([long]$_.id) -UpdatedAt ([string]$_.updated_at)
        } | Where-Object { $null -ne $_ -and [string]$_.token -eq $OwnerToken })
    if ($matchingOwners.Count -eq 1)
    {
        Invoke-CompletionGh -Arguments @(
            "api", "--method", "DELETE", "repos/$Repository/issues/comments/$OwnerCommentId") |
            Out-Null
    }
    [object]$nextTarget = Get-NextCompletionTarget -ReadyLabel $readyLabel `
        -HumanLabel $humanLabel -ClaimLabel $claimLabel
    Write-CompletionResult -Status "completed" -Head $initialHead `
        -ReviewRepairCount @($recordedDelivery.payload.reviews.repairRounds).Count `
        -EvidenceUrl ([string]$recordedDelivery.url) -AlreadyCompleted $true `
        -PendingManualCount $recordedPendingManual.Count -NextTarget $nextTarget `
        -Reason "Recorded completion already exists; pending cleanup was reconciled."
    return
}

Get-VerifiedOwner | Out-Null
[object]$issueData = $null
[string]$branch = ""
[string]$head = ""
[object]$acceptanceState = $null
[object[]]$pendingManualAcceptance = @()
[object[]]$automatedSatisfiedEvidence = @()
try
{
    [object]$issueData = $initialIssueData
    if ([string]$issueData.state -ne "open")
    {
        throw "Issue #$Issue must be open before completion."
    }
    if (@($issueData.labels | ForEach-Object { [string]$_.name }) -notcontains $claimLabel)
    {
        throw "Issue #$Issue does not carry the in-progress label."
    }

    # 关闭门禁先固定分支、工作区、HEAD 和唯一 Issue commit，再检查自动化与 AC。
    $branch = Invoke-CompletionGit -Arguments @("branch", "--show-current")
    if ([string]::IsNullOrWhiteSpace($branch))
    {
        throw "HEAD must be attached to a branch."
    }
    if (![string]::IsNullOrWhiteSpace((Invoke-CompletionGit -Arguments @("status", "--porcelain"))))
    {
        throw "Worktree must be clean before completion."
    }
    $head = Invoke-CompletionGit -Arguments @("rev-parse", "HEAD")
    [string[]]$commitLines = @((Invoke-CompletionGit `
        -Arguments @("log", "--format=%H%x09%s", "$Base..$head")) -split "`r?`n" |
        Where-Object { ![string]::IsNullOrWhiteSpace($_) })
    [string]$expectedSubject = "#$Issue $([string]$issueData.title)"
    if ($commitLines.Count -ne 1 -or $commitLines[0] -ne "$head`t$expectedSubject")
    {
        throw "Completion requires exactly one Issue commit with subject '$expectedSubject'."
    }
    $acceptanceState = Get-ProjectIssueAcceptanceState -Body ([string]$issueData.body)
    if (![bool]$acceptanceState.valid)
    {
        throw "The Acceptance criteria section is malformed."
    }
    $pendingManualAcceptance = @(Get-PendingManualAcceptance `
        -AcceptanceState $acceptanceState -Verification $verification)
    if ($verification.acceptance.PSObject.Properties.Name -contains "automatedSatisfied")
    {
        $automatedSatisfiedEvidence = @($verification.acceptance.automatedSatisfied)
    }
    Assert-VerificationPassed -Verification $verification -Head $head -AcceptanceState $acceptanceState
}
catch
{
    Stop-CompletionForAutomationFailure -ClaimLabel $claimLabel -HumanLabel $humanLabel `
        -Reason ([string]$_.Exception.Message) -Head $head `
        -ReviewRepairCount @($verification.reviews.repairRounds).Count
    return
}

# 唯一权威门禁通过后才允许 push；随后以远端祖先关系回读确认。
try
{
    if ($null -eq $recordedDelivery)
    {
        Invoke-CompletionGit -Arguments @("push", "origin", $branch) | Out-Null
    }
    Invoke-CompletionGit -Arguments @("fetch", "origin", $branch) | Out-Null
    Invoke-CompletionGit -Arguments @("merge-base", "--is-ancestor", $head, "origin/$branch") | Out-Null
}
catch
{
    Stop-CompletionForAutomationFailure -ClaimLabel $claimLabel -HumanLabel $humanLabel `
        -Reason ([string]$_.Exception.Message) -Head $head `
        -ReviewRepairCount @($verification.reviews.repairRounds).Count
    return
}

[System.Collections.Specialized.OrderedDictionary]$evidencePayload = [ordered]@{
    version = 1
    parent = $Parent
    issue = $Issue
    base = $Base
    head = $head
    owner_token = $OwnerToken
    tests = @($verification.tests)
    reviews = $verification.reviews
    acceptance = [ordered]@{
        provided = [bool]$acceptanceState.provided
        total = [int]$acceptanceState.total
        checked = [int]$acceptanceState.checked
        unchecked = [int]$acceptanceState.unchecked
        fingerprint = [string]$acceptanceState.fingerprint
        automated_satisfied = @($automatedSatisfiedEvidence)
    }
    pending_manual = @($pendingManualAcceptance | ForEach-Object {
        [ordered]@{
            index = [int]$_.index
            classification = [string]$_.classification
            text = [string]$_.text
        }
    })
    unexecuted = @($verification.unexecuted)
    risks = @($verification.risks)
}
[string]$evidenceBody = @"
<!-- project-issue-automation:delivery-v1 $($evidencePayload | ConvertTo-Json -Depth 12 -Compress) -->

### Project Issue Delivery

- Commit：$head
- Automated tests：$(@($verification.tests).Count) passed run(s)
- Standards review：$([string]$verification.reviews.finalStandards)
- Spec review：$([string]$verification.reviews.finalSpec)
- Review repair rounds：$(@($verification.reviews.repairRounds).Count)
"@
[object]$evidenceComment = $recordedDelivery
if ($null -eq $evidenceComment)
{
    $evidenceComment = Invoke-CompletionGh -Arguments @(
        "api", "--method", "POST", "repos/$Repository/issues/$Issue/comments", "-f", "body=$evidenceBody")
}

if ($pendingManualAcceptance.Count -gt 0)
{
    Invoke-CompletionGh -Arguments @(
        "api", "--method", "POST", "repos/$Repository/issues/$Issue/labels",
        "-f", "labels[]=$manualLabel") | Out-Null
}

# 先关闭并权威回读，再移除共享标签和 owner，避免产生 open 且可重选窗口。
Invoke-CompletionGh -Arguments @(
    "api", "--method", "PATCH", "repos/$Repository/issues/$Issue", "-f", "state=closed") | Out-Null
[object]$closedIssue = Invoke-CompletionGh -Arguments @("api", "repos/$Repository/issues/$Issue")
if ([string]$closedIssue.state -ne "closed")
{
    throw "Issue #$Issue was not closed after the completion write."
}
Invoke-CompletionGh -Arguments @(
    "api", "--method", "DELETE", "repos/$Repository/issues/$Issue/labels/$claimLabel") | Out-Null
Invoke-CompletionGh -Arguments @(
    "api", "--method", "DELETE", "repos/$Repository/issues/comments/$OwnerCommentId") | Out-Null

[object]$nextTarget = Get-NextCompletionTarget -ReadyLabel $readyLabel `
    -HumanLabel $humanLabel -ClaimLabel $claimLabel
Write-CompletionResult -Status "completed" -Head $head `
    -ReviewRepairCount @($verification.reviews.repairRounds).Count `
    -EvidenceUrl $(if ($null -ne $recordedDelivery) { [string]$recordedDelivery.url } else { [string]$evidenceComment.html_url }) `
    -PendingManualCount $pendingManualAcceptance.Count -NextTarget $nextTarget `
    -Reason "Issue closed through the authoritative completion gate."
