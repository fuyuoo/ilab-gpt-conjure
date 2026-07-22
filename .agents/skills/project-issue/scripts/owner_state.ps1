Set-StrictMode -Version Latest

# 解析新的最小 owner marker；损坏或字段不完整的评论不参与执行权竞争。
function ConvertFrom-ProjectIssueOwnerComment
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$Body,

        [long]$CommentId = 0,

        [string]$UpdatedAt = ""
    )

    [System.Text.RegularExpressions.Match]$match = [regex]::Match(
        $Body,
        "(?m)^<!-- project-issue-automation:owner-v1 (?<json>\{.*\}) -->\r?$")
    if (!$match.Success)
    {
        return $null
    }

    try
    {
        [object]$payload = $match.Groups["json"].Value | ConvertFrom-Json
    }
    catch
    {
        return $null
    }

    [string[]]$requiredProperties = @(
        "parent", "issue", "token", "base", "checkpoint", "lease_expires_at")
    [string[]]$propertyNames = @($payload.PSObject.Properties.Name)
    if (@($requiredProperties | Where-Object { $propertyNames -notcontains $_ }).Count -gt 0)
    {
        return $null
    }

    [int]$parent = 0
    [int]$issue = 0
    if (![int]::TryParse([string]$payload.parent, [ref]$parent) -or
        ![int]::TryParse([string]$payload.issue, [ref]$issue) -or
        $parent -le 0 -or $issue -le 0 -or
        [string]::IsNullOrWhiteSpace([string]$payload.token) -or
        [string]::IsNullOrWhiteSpace([string]$payload.base))
    {
        return $null
    }

    return [pscustomobject]@{
        version = 1
        parent = $parent
        issue = $issue
        token = [string]$payload.token
        base = [string]$payload.base
        checkpoint = [string]$payload.checkpoint
        leaseExpiresAt = [string]$payload.lease_expires_at
        commentId = $CommentId
        updatedAt = $UpdatedAt
    }
}

# 创建仅含单执行者恢复所需字段的 owner marker，避免把阶段状态带入远端状态机。
function New-ProjectIssueOwnerComment
{
    param(
        [Parameter(Mandatory = $true)]
        [int]$Parent,

        [Parameter(Mandatory = $true)]
        [int]$Issue,

        [Parameter(Mandatory = $true)]
        [ValidatePattern("^[0-9a-f-]{36}$")]
        [string]$Token,

        [Parameter(Mandatory = $true)]
        [string]$Base,

        [string]$Checkpoint = "",

        [Parameter(Mandatory = $true)]
        [string]$LeaseExpiresAt
    )

    [System.Collections.Specialized.OrderedDictionary]$payload = [ordered]@{
        parent = $Parent
        issue = $Issue
        token = $Token
        base = $Base
        checkpoint = $Checkpoint
        lease_expires_at = $LeaseExpiresAt
    }
    return "<!-- project-issue-automation:owner-v1 $($payload | ConvertTo-Json -Compress) -->"
}

# owner 缺少有效到期时间时按已过期处理，使损坏状态不会形成永久锁。
function Test-ProjectIssueOwnerExpired
{
    param(
        [Parameter(Mandatory = $true)]
        [object]$Owner,

        [datetime]$NowUtc = [datetime]::UtcNow
    )

    [datetime]$leaseExpiresAt = [datetime]::MinValue
    if (![datetime]::TryParse(
        [string]$Owner.leaseExpiresAt,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
            [System.Globalization.DateTimeStyles]::AdjustToUniversal,
        [ref]$leaseExpiresAt))
    {
        return $true
    }
    return $leaseExpiresAt -le $NowUtc
}
