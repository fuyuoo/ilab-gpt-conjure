$scriptUnderTest = Join-Path $PSScriptRoot "..\begin_issue.ps1"
$ownerState = Join-Path $PSScriptRoot "..\owner_state.ps1"
. $ownerState

Describe "begin_issue.ps1 dry-run selection" {
    BeforeEach {
        $global:configDirectory = Join-Path $TestDrive ".agents"
        New-Item -ItemType Directory -Path $global:configDirectory -Force | Out-Null
        $global:configPath = Join-Path $global:configDirectory "project-issue.json"
        @{
            labels = @{ ready = "ready"; human = "human"; claim = "in-progress"; manual = "manual-pending" }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $global:configPath

        $global:parent = [ordered]@{
            number = 100; title = "Parent"; body = "body parent markers are ignored"; state = "open"
            labels = @([ordered]@{ name = "ready" }); html_url = "https://github.com/owner/repo/issues/100"
        }
        $global:child11 = [ordered]@{
            number = 11; title = "Child 11"; body = "## Blocked by`n`n#99"; state = "open"
            labels = @([ordered]@{ name = "ready" }); html_url = "https://github.com/owner/repo/issues/11"
        }
        $global:child12 = [ordered]@{
            number = 12; title = "Child 12"; body = "## Parent`n`n#999"; state = "open"
            labels = @([ordered]@{ name = "ready" }); html_url = "https://github.com/owner/repo/issues/12"
        }
        $global:nativeChildren = @($global:child11, $global:child12)
        $global:nativeParents = @{ 11 = $global:parent; 12 = $global:parent }
        $global:blockers = @{ 11 = @(); 12 = @(); 100 = @() }
        $global:parentComments = @()
        $global:ghCommands = [System.Collections.Generic.List[string]]::new()

        function global:git {
            $global:LASTEXITCODE = 0
            [string]$command = $args -join " "
            if ($command -like "-C * remote get-url origin") {
                return "https://github.com/owner/repo.git"
            }
            throw "Unexpected git command: $command"
        }

        function global:gh {
            $global:LASTEXITCODE = 0
            [string]$command = $args -join " "
            $global:ghCommands.Add($command)

            if ($command -eq "api --paginate --slurp repos/owner/repo/issues/100/sub_issues?per_page=100") {
                return ConvertTo-Json -InputObject @($global:nativeChildren) -Depth 8 -Compress
            }
            if ($command -eq "api --paginate --slurp repos/owner/repo/issues/100/comments?per_page=100") {
                return ConvertTo-Json -InputObject @($global:parentComments) -Depth 8 -Compress
            }
            if ($command -match "^api repos/owner/repo/issues/(?<number>\d+)/dependencies/blocked_by\?per_page=100$") {
                [int]$number = [int]$Matches.number
                return ConvertTo-Json -InputObject @($global:blockers[$number]) -Depth 8 -Compress
            }
            if ($command -match "^api repos/owner/repo/issues/(?<number>\d+)/parent$") {
                [int]$number = [int]$Matches.number
                if ($global:nativeParents.ContainsKey($number)) {
                    return $global:nativeParents[$number] | ConvertTo-Json -Depth 8 -Compress
                }
                return "null"
            }
            if ($command -match "^api repos/owner/repo/issues/(?<number>\d+)$") {
                [int]$number = [int]$Matches.number
                switch ($number) {
                    11 { return $global:child11 | ConvertTo-Json -Depth 8 -Compress }
                    12 { return $global:child12 | ConvertTo-Json -Depth 8 -Compress }
                    100 { return $global:parent | ConvertTo-Json -Depth 8 -Compress }
                    default { throw "Unexpected issue: $number" }
                }
            }
            throw "Unexpected gh command: $command"
        }
    }

    AfterEach {
        Remove-Item Function:\git -ErrorAction SilentlyContinue
        Remove-Item Function:\gh -ErrorAction SilentlyContinue
        foreach ($name in @(
            "configDirectory", "configPath", "parent", "child11", "child12", "nativeChildren",
            "nativeParents", "blockers", "parentComments", "ghCommands")) {
            Remove-Variable $name -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It "selects the first eligible child in native parent order and stops scanning" {
        $global:nativeChildren = @($global:child12, $global:child11)

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode dry-run -Parent 100) |
            ConvertFrom-Json

        $result.status | Should Be "selected"
        $result.parent | Should Be 100
        $result.issue | Should Be 12
        $result.targetKind | Should Be "child"
        $result.nextState | Should Be "CLAIM"
        $result.metrics.candidateCount | Should Be 2
        $result.metrics.checkedCount | Should Be 1
        $result.metrics.hitPosition | Should Be 1
        @($global:ghCommands | Where-Object { $_ -eq "api repos/owner/repo/issues/11" }).Count | Should Be 0
    }

    It "uses native dependencies and ignores body relationship sections" {
        $global:blockers[11] = @([ordered]@{ number = 99; state = "open" })

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode dry-run -Parent 100) |
            ConvertFrom-Json

        $result.status | Should Be "selected"
        $result.issue | Should Be 12
        $result.metrics.checkedCount | Should Be 2
        $result.metrics.hitPosition | Should Be 2
    }

    It "validates an explicit issue through its native parent without scanning siblings" {
        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode dry-run -Issue 12) |
            ConvertFrom-Json

        $result.status | Should Be "selected"
        $result.parent | Should Be 100
        $result.issue | Should Be 12
        $result.metrics.candidateCount | Should Be 1
        $result.metrics.checkedCount | Should Be 1
        $result.metrics.hitPosition | Should Be 1
        @($global:ghCommands | Where-Object { $_ -like "*sub_issues*" }).Count | Should Be 0
    }

    It "accepts matching parent and issue inputs after native relationship validation" {
        [object]$result = (& $scriptUnderTest `
            -Config $global:configPath -Mode dry-run -Parent 100 -Issue 12) | ConvertFrom-Json

        $result.status | Should Be "selected"
        $result.parent | Should Be 100
        $result.issue | Should Be 12
        $result.nextState | Should Be "CLAIM"
        $result.metrics.checkedCount | Should Be 1
        @($global:ghCommands | Where-Object { $_ -like "*sub_issues*" }).Count | Should Be 0
    }

    It "rejects an explicit issue whose native parent does not match without selecting another issue" {
        [object]$result = (& $scriptUnderTest `
            -Config $global:configPath -Mode dry-run -Parent 101 -Issue 12) | ConvertFrom-Json

        $result.status | Should Be "invalid_relationship"
        $result.issue | Should Be 12
        $result.parent | Should Be 101
        $result.metrics.checkedCount | Should Be 0
        @($global:ghCommands | Where-Object { $_ -like "*sub_issues*" }).Count | Should Be 0
    }

    It "returns an input error when neither parent nor issue is supplied" {
        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode dry-run) | ConvertFrom-Json

        $result.status | Should Be "input_error"
        $result.metrics.githubCalls | Should Be 0
    }

    It "rejects duplicate workflow labels before reading GitHub" {
        @{
            labels = @{ ready = "same"; human = "same"; claim = "in-progress"; manual = "manual-pending" }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $global:configPath
        [bool]$threw = $false
        try {
            & $scriptUnderTest -Config $global:configPath -Mode dry-run -Parent 100 | Out-Null
        } catch { $threw = $true }

        $threw | Should Be $true
        $global:ghCommands.Count | Should Be 0
    }

    It "does not require parent_issue in config and keeps all dry-run calls read-only" {
        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode dry-run -Parent 100) |
            ConvertFrom-Json

        $result.status | Should Be "selected"
        $result.metrics.githubCalls | Should Be $global:ghCommands.Count
        $result.metrics.githubElapsedMs | Should Not BeNullOrEmpty
        $result.metrics.elapsedMs | Should Not BeNullOrEmpty
        @($global:ghCommands | Where-Object {
            $_ -match "--method|POST|PATCH|DELETE|issue edit|issue comment|issue close"
        }).Count | Should Be 0
    }

    It "reports locked when a live parent owner already occupies the queue" {
        [string]$ownerBody = New-ProjectIssueOwnerComment `
            -Parent 100 -Issue 11 -Token "00000000-0000-0000-0000-000000000001" `
            -Base "abc" -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(30).ToString("o"))
        $global:parentComments = @([ordered]@{
            id = 51; body = $ownerBody; updated_at = [datetime]::UtcNow.ToString("o")
        })

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode dry-run -Parent 100) |
            ConvertFrom-Json

        $result.status | Should Be "locked"
        $result.issue | Should Be 11
        $result.nextState | Should Be "LOCKED"
        $result.metrics.candidateCount | Should Be 2
        $result.metrics.checkedCount | Should Be 0
    }

    It "does not select the parent while any native child remains open" {
        $global:child11.labels = @()
        $global:child12.labels = @()

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode dry-run -Parent 100) |
            ConvertFrom-Json

        $result.status | Should Be "no_issue"
        $result.issue | Should BeNullOrEmpty
        $result.targetKind | Should BeNullOrEmpty
    }

    It "selects the parent as the final target only after every native child is closed" {
        $global:child11.state = "closed"
        $global:child12.state = "closed"

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode dry-run -Parent 100) |
            ConvertFrom-Json

        $result.status | Should Be "selected"
        $result.parent | Should Be 100
        $result.issue | Should Be 100
        $result.targetKind | Should Be "parent"
        $result.metrics.candidateCount | Should Be 1
        $result.metrics.checkedCount | Should Be 1
        $result.metrics.hitPosition | Should Be 1
    }
}

Describe "begin_issue.ps1 run owner acquisition" {
    BeforeEach {
        $global:repositoryRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString("N"))
        $global:workspace = Join-Path $global:repositoryRoot "Client\GameClient"
        $global:configDirectory = Join-Path $global:workspace ".agents"
        New-Item -ItemType Directory -Path $global:configDirectory -Force | Out-Null
        $global:configPath = Join-Path $global:configDirectory "project-issue.json"
        @{
            labels = @{ ready = "ready"; human = "human"; claim = "in-progress"; manual = "manual-pending" }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $global:configPath

        & git.exe init $global:repositoryRoot | Out-Null
        & git.exe -C $global:repositoryRoot config user.name "Project Issue Test"
        & git.exe -C $global:repositoryRoot config user.email "project-issue@example.invalid"
        & git.exe -C $global:repositoryRoot remote add origin "https://github.com/owner/repo.git"
        Set-Content -LiteralPath (Join-Path $global:workspace "tracked.txt") -Value "baseline"
        & git.exe -C $global:repositoryRoot add --all
        & git.exe -C $global:repositoryRoot commit --message "baseline" | Out-Null
        $global:baseline = (& git.exe -C $global:repositoryRoot rev-parse HEAD).Trim()

        $global:parent = [ordered]@{
            number = 100; title = "Parent"; state = "open"
            labels = @([ordered]@{ name = "ready" }); html_url = "https://github.com/owner/repo/issues/100"
        }
        $global:child = [ordered]@{
            number = 11; title = "Child"; state = "open"
            labels = @([ordered]@{ name = "ready" }); html_url = "https://github.com/owner/repo/issues/11"
        }
        $global:parentComments = [System.Collections.Generic.List[object]]::new()
        $global:blockers = @()
        $global:ghCommands = [System.Collections.Generic.List[string]]::new()
        $global:gitCommands = [System.Collections.Generic.List[string]]::new()
        $global:createdOwnerBody = ""
        $global:nextCommentId = 51
        $global:failFinalPatchOnce = $false
        $global:failLabelOnce = $false
        $global:loseOwnerPostResponseOnce = $false
        $global:competingOwnerOnPost = $false
        $global:deletedOwnerIds = [System.Collections.Generic.List[long]]::new()
        $global:failOwnerDelete = $false
        $global:failOwnerExpire = $false

        function global:git {
            [string]$command = $args -join " "
            $global:gitCommands.Add($command)
            if ($command -match " fetch origin " -or $command -match " merge --ff-only origin/") {
                $global:LASTEXITCODE = 0
                return
            }
            [object[]]$output = @(& git.exe @args 2>&1)
            $global:LASTEXITCODE = $LASTEXITCODE
            return $output
        }

        function global:gh {
            $global:LASTEXITCODE = 0
            [string]$command = $args -join " "
            $global:ghCommands.Add($command)

            if ($command -eq "api repos/owner/repo/issues/11") {
                return $global:child | ConvertTo-Json -Depth 8 -Compress
            }
            if ($command -eq "api repos/owner/repo/issues/100") {
                return $global:parent | ConvertTo-Json -Depth 8 -Compress
            }
            if ($command -eq "api repos/owner/repo/issues/11/parent") {
                return $global:parent | ConvertTo-Json -Depth 8 -Compress
            }
            if ($command -match "^api repos/owner/repo/issues/(?<number>11|100)/dependencies/blocked_by\?per_page=100$") {
                if ([int]$Matches.number -eq 11 -and @($global:blockers).Count -gt 0) {
                    return ConvertTo-Json -InputObject @($global:blockers) -Depth 8 -Compress
                }
                return "[]"
            }
            if ($command -eq "api --paginate --slurp repos/owner/repo/issues/100/comments?per_page=100") {
                return ConvertTo-Json -InputObject @($global:parentComments) -Depth 10 -Compress
            }
            if ($command -eq "api --paginate --slurp repos/owner/repo/issues/100/sub_issues?per_page=100") {
                return ConvertTo-Json -InputObject @($global:child) -Depth 10 -Compress
            }
            if ($command -like "api --method POST repos/owner/repo/issues/100/comments*") {
                [string]$bodyArgument = @($args | Where-Object { [string]$_ -like "body=*" })[0]
                $global:createdOwnerBody = $bodyArgument.Substring("body=".Length)
                [object]$comment = [ordered]@{
                    id = $global:nextCommentId; body = $global:createdOwnerBody; updated_at = [datetime]::UtcNow.ToString("o")
                }
                $global:nextCommentId++
                $global:parentComments.Add($comment)
                if ($global:competingOwnerOnPost) {
                    $global:competingOwnerOnPost = $false
                    [string]$competingBody = New-ProjectIssueOwnerComment `
                        -Parent 100 -Issue 11 -Token "00000000-0000-0000-0000-000000000099" `
                        -Base $global:baseline -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(30).ToString("o"))
                    $global:parentComments.Insert(0, [ordered]@{
                        id = 50; body = $competingBody; updated_at = [datetime]::UtcNow.ToString("o")
                    })
                }
                if ($global:loseOwnerPostResponseOnce) {
                    $global:loseOwnerPostResponseOnce = $false
                    $global:LASTEXITCODE = 1
                    return "response lost"
                }
                return $comment | ConvertTo-Json -Depth 10 -Compress
            }
            if ($command -match "^api --method PATCH repos/owner/repo/issues/comments/(?<id>\d+)") {
                [string]$bodyArgument = @($args | Where-Object { [string]$_ -like "body=*" })[0]
                if ($global:failOwnerExpire -and $bodyArgument -match 'lease_expires_at[^0-9]*(?<year>\d{4})') {
                    [System.Text.RegularExpressions.Match]$marker = [regex]::Match(
                        $bodyArgument.Substring("body=".Length),
                        "(?m)^<!-- project-issue-automation:owner-v1 (?<json>\{.*\}) -->$")
                    [object]$payload = $marker.Groups["json"].Value | ConvertFrom-Json
                    if ([datetime]$payload.lease_expires_at -lt [datetime]::UtcNow) {
                        $global:LASTEXITCODE = 1
                        return "expire failed"
                    }
                }
                if ($global:failFinalPatchOnce) {
                    $global:failFinalPatchOnce = $false
                    $global:LASTEXITCODE = 1
                    return "patch failed"
                }
                $global:createdOwnerBody = $bodyArgument.Substring("body=".Length)
                [long]$commentId = [long]$Matches.id
                [object]$comment = @($global:parentComments | Where-Object { [long]$_.id -eq $commentId })[0]
                $comment.body = $global:createdOwnerBody
                $comment.updated_at = [datetime]::UtcNow.ToString("o")
                return $comment | ConvertTo-Json -Depth 10 -Compress
            }
            if ($command -match "^api --method POST repos/owner/repo/issues/(?<number>11|100)/labels") {
                if ($global:failLabelOnce) {
                    $global:failLabelOnce = $false
                    $global:LASTEXITCODE = 1
                    return "label failed"
                }
                [object]$targetIssue = if ([int]$Matches.number -eq 11) { $global:child } else { $global:parent }
                $targetIssue.labels += [ordered]@{ name = "in-progress" }
                return $targetIssue.labels | ConvertTo-Json -Depth 8 -Compress
            }
            if ($command -match "^api --method DELETE repos/owner/repo/issues/comments/(?<id>\d+)$") {
                if ($global:failOwnerDelete) {
                    $global:LASTEXITCODE = 1
                    return "delete failed"
                }
                [long]$commentId = [long]$Matches.id
                $global:deletedOwnerIds.Add($commentId)
                [object[]]$remaining = @($global:parentComments | Where-Object { [long]$_.id -ne $commentId })
                $global:parentComments.Clear()
                foreach ($remainingComment in $remaining) { $global:parentComments.Add($remainingComment) }
                return ""
            }
            throw "Unexpected gh command: $command"
        }
    }

    AfterEach {
        Remove-Item Function:\git -ErrorAction SilentlyContinue
        Remove-Item Function:\gh -ErrorAction SilentlyContinue
        foreach ($name in @(
            "repositoryRoot", "workspace", "configDirectory", "configPath", "baseline", "parent",
            "child", "parentComments", "blockers", "ghCommands", "gitCommands", "createdOwnerBody",
            "nextCommentId", "failFinalPatchOnce", "failLabelOnce",
            "loseOwnerPostResponseOnce", "competingOwnerOnPost", "deletedOwnerIds",
            "failOwnerDelete", "failOwnerExpire")) {
            Remove-Variable $name -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It "acquires a minimal owner before adding in-progress and returns WorkContext" {
        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json

        $result.status | Should Be "begun"
        $result.parent | Should Be 100
        $result.issue | Should Be 11
        $result.owner.commentId | Should Be 51
        $result.base | Should Be $global:baseline
        $result.workspace | Should Be ([System.IO.Path]::GetFullPath($global:workspace))
        $result.recovered | Should Be $false
        $result.nextState | Should Be "IMPLEMENT"
        (@($global:child.labels.name) -contains "in-progress") | Should Be $true

        [System.Text.RegularExpressions.Match]$marker = [regex]::Match(
            $global:createdOwnerBody,
            "(?m)^<!-- project-issue-automation:owner-v1 (?<json>\{.*\}) -->$")
        $marker.Success | Should Be $true
        [object]$payload = $marker.Groups["json"].Value | ConvertFrom-Json
        @($payload.PSObject.Properties.Name) | Should Be @(
            "parent", "issue", "token", "base", "checkpoint", "lease_expires_at")
        $payload.parent | Should Be 100
        $payload.issue | Should Be 11
        $payload.base | Should Be $global:baseline
        ([datetime]$payload.lease_expires_at) | Should BeGreaterThan ([datetime]::UtcNow.AddMinutes(175))

        [int]$ownerPost = $global:ghCommands.FindIndex([Predicate[string]]{
            param([string]$value) $value -like "api --method POST repos/owner/repo/issues/100/comments*"
        })
        [int]$labelPost = $global:ghCommands.FindIndex([Predicate[string]]{
            param([string]$value) $value -like "api --method POST repos/owner/repo/issues/11/labels*"
        })
        $ownerPost | Should BeLessThan $labelPost
    }

    It "recovers an expired owner with the original BASE" {
        $global:child.labels += [ordered]@{ name = "in-progress" }
        Set-Content -LiteralPath (Join-Path $global:workspace "tracked.txt") -Value "interrupted change"
        [string]$expiredBody = New-ProjectIssueOwnerComment `
            -Parent 100 -Issue 11 -Token "00000000-0000-0000-0000-000000000001" `
            -Base $global:baseline -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(-1).ToString("o"))
        $global:parentComments.Add([ordered]@{
            id = 40; body = $expiredBody; updated_at = [datetime]::UtcNow.AddMinutes(-1).ToString("o")
        })

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json

        $result.status | Should Be "begun"
        $result.owner.commentId | Should Be 51
        $result.base | Should Be $global:baseline
        $result.recovered | Should Be $true
        $result.checkpoint | Should BeNullOrEmpty
        (& git.exe -C $global:repositoryRoot status --porcelain) | Should Not BeNullOrEmpty
        @($global:ghCommands | Where-Object {
            $_ -like "api --method POST repos/owner/repo/issues/11/labels*"
        }).Count | Should Be 0
    }

    It "pauses when another issue already owns the parent" {
        [string]$expiredBody = New-ProjectIssueOwnerComment `
            -Parent 100 -Issue 11 -Token "00000000-0000-0000-0000-000000000002" `
            -Base $global:baseline -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(-1).ToString("o"))
        [string]$otherOwnerBody = New-ProjectIssueOwnerComment `
            -Parent 100 -Issue 12 -Token "00000000-0000-0000-0000-000000000001" `
            -Base $global:baseline -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(30).ToString("o"))
        $global:parentComments.Add([ordered]@{
            id = 40; body = $expiredBody; updated_at = [datetime]::UtcNow.AddMinutes(-1).ToString("o")
        })
        $global:parentComments.Add([ordered]@{
            id = 50; body = $otherOwnerBody; updated_at = [datetime]::UtcNow.ToString("o")
        })

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json

        $result.status | Should Be "locked"
        $result.nextState | Should Be "LOCKED"
        (@($global:child.labels.name) -contains "in-progress") | Should Be $false
        @($global:ghCommands | Where-Object {
            $_ -like "api --method POST repos/owner/repo/issues/11/labels*"
        }).Count | Should Be 0
        @($global:gitCommands | Where-Object {
            $_ -match " fetch | merge | add | commit "
        }).Count | Should Be 0
    }

    It "lets only the smallest active owner comment proceed after a concurrent POST" {
        $global:competingOwnerOnPost = $true

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json

        $result.status | Should Be "locked"
        $result.nextState | Should Be "LOCKED"
        @($global:deletedOwnerIds) | Should Be @(51)
        (@($global:child.labels.name) -contains "in-progress") | Should Be $false
        @($global:gitCommands | Where-Object { $_ -match " fetch | merge | add | commit " }).Count | Should Be 0
    }

    It "pauses visibly when a losing owner cannot be deleted or expired" {
        $global:competingOwnerOnPost = $true
        $global:failOwnerDelete = $true
        $global:failOwnerExpire = $true

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json

        $result.status | Should Be "paused"
        $result.reason | Should Match "could not retire owner comment"
        (@($global:child.labels.name) -contains "in-progress") | Should Be $false
        @($global:gitCommands | Where-Object { $_ -match " fetch | merge | add | commit " }).Count | Should Be 0
    }

    It "locks a duplicate task even when it targets the same active issue" {
        [object]$first = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json
        [int]$mutatingGitCount = @($global:gitCommands | Where-Object {
            $_ -match " fetch | merge | add | commit "
        }).Count
        [object]$second = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json

        $first.status | Should Be "begun"
        $second.status | Should Be "locked"
        $second.nextState | Should Be "LOCKED"
        @($global:parentComments).Count | Should Be 1
        @($global:gitCommands | Where-Object {
            $_ -match " fetch | merge | add | commit "
        }).Count | Should Be $mutatingGitCount
    }

    It "does not recover an expired owner after the issue is routed to a human" {
        $global:child.labels += [ordered]@{ name = "human" }
        [string]$expiredBody = New-ProjectIssueOwnerComment `
            -Parent 100 -Issue 11 -Token "00000000-0000-0000-0000-000000000001" `
            -Base $global:baseline -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(-1).ToString("o"))
        $global:parentComments.Add([ordered]@{
            id = 40; body = $expiredBody; updated_at = [datetime]::UtcNow.AddMinutes(-1).ToString("o")
        })

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json

        $result.status | Should Be "ineligible"
        $result.reason | Should Match "routed to a human"
        @($global:ghCommands | Where-Object {
            $_ -like "api --method POST repos/owner/repo/issues/100/comments*"
        }).Count | Should Be 0
    }

    It "rejects a fresh explicit issue already routed to a human" {
        $global:child.labels += [ordered]@{ name = "human" }

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json

        $result.status | Should Be "ineligible"
        $result.reason | Should Match "routed to a human"
        @($global:parentComments).Count | Should Be 0
    }

    It "does not recover an expired owner while a native dependency is open" {
        $global:blockers = @([ordered]@{ number = 9; state = "open" })
        [string]$expiredBody = New-ProjectIssueOwnerComment `
            -Parent 100 -Issue 11 -Token "00000000-0000-0000-0000-000000000001" `
            -Base $global:baseline -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(-1).ToString("o"))
        $global:parentComments.Add([ordered]@{
            id = 40; body = $expiredBody; updated_at = [datetime]::UtcNow.AddMinutes(-1).ToString("o")
        })

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json

        $result.status | Should Be "ineligible"
        $result.reason | Should Match "dependencies are still open: 9"
        @($global:ghCommands | Where-Object {
            $_ -like "api --method POST repos/owner/repo/issues/100/comments*"
        }).Count | Should Be 0
    }

    It "rejects a fresh explicit issue while a native dependency is open" {
        $global:blockers = @([ordered]@{ number = 9; state = "open" })

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json

        $result.status | Should Be "ineligible"
        $result.reason | Should Match "dependencies are still open: 9"
        @($global:parentComments).Count | Should Be 0
    }

    It "recovers the owner by token when the POST response is lost" {
        $global:loseOwnerPostResponseOnce = $true

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json

        $result.status | Should Be "begun"
        $result.owner.commentId | Should Be 51
        (@($global:child.labels.name) -contains "in-progress") | Should Be $true
        @($global:parentComments | Where-Object {
            [long]$_.id -eq 51
        }).Count | Should Be 1
    }

    It "checkpoints a dirty new workspace and fixes the checkpoint as BASE" {
        Set-Content -LiteralPath (Join-Path $global:workspace "tracked.txt") -Value "pre-existing change"

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json

        $result.status | Should Be "begun"
        $result.base | Should Not Be $global:baseline
        $result.checkpoint | Should Be $result.base
        (& git.exe -C $global:repositoryRoot status --porcelain) | Should BeNullOrEmpty
        (& git.exe -C $global:repositoryRoot log -1 --format=%s).Trim() |
            Should Be "chore: checkpoint workspace before project issue"
    }

    It "keeps a failed final owner PATCH recoverable across the checkpoint boundary" {
        Set-Content -LiteralPath (Join-Path $global:workspace "tracked.txt") -Value "pre-existing change"
        $global:failFinalPatchOnce = $true

        [object]$failed = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json
        [object]$resumed = (& $scriptUnderTest -Config $global:configPath -Mode run -Parent 100) |
            ConvertFrom-Json

        $failed.status | Should Be "paused"
        $resumed.status | Should Be "begun"
        $resumed.recovered | Should Be $true
        $resumed.checkpoint | Should Be $resumed.base
        $resumed.owner.commentId | Should Be 52

        [object]$secondOwner = @($global:parentComments | Where-Object { [long]$_.id -eq 52 })[0]
        $secondOwner.body = New-ProjectIssueOwnerComment `
            -Parent 100 -Issue 11 -Token ([string]$resumed.owner.token) `
            -Base ([string]$resumed.base) -Checkpoint ([string]$resumed.checkpoint) `
            -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(-1).ToString("o"))
        [object]$repeated = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json
        $repeated.status | Should Be "begun"
        $repeated.recovered | Should Be $true
        $repeated.owner.commentId | Should Be 53
    }

    It "expires and recovers the owner when in-progress label creation fails" {
        $global:failLabelOnce = $true

        [object]$failed = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json
        [object]$resumed = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json

        $failed.status | Should Be "paused"
        $resumed.status | Should Be "begun"
        $resumed.recovered | Should Be $true
        (@($global:child.labels.name) -contains "in-progress") | Should Be $true
        $resumed.owner.commentId | Should Be 52
        @($global:parentComments | Where-Object {
            [string]$_.body -match "project-issue-automation:owner-v1"
        }).Count | Should Be 2
    }

    It "expires a new recovery owner when its in-progress label write fails" {
        [string]$expiredBody = New-ProjectIssueOwnerComment `
            -Parent 100 -Issue 11 -Token "00000000-0000-0000-0000-000000000001" `
            -Base $global:baseline -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(-1).ToString("o"))
        $global:parentComments.Add([ordered]@{
            id = 40; body = $expiredBody; updated_at = [datetime]::UtcNow.AddMinutes(-1).ToString("o")
        })
        $global:failLabelOnce = $true

        [object]$failed = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json
        [object]$failedOwner = ConvertFrom-ProjectIssueOwnerComment `
            -Body ([string]$global:parentComments[1].body) -CommentId 51
        [object]$resumed = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json

        $failed.status | Should Be "paused"
        (Test-ProjectIssueOwnerExpired -Owner $failedOwner) | Should Be $true
        $resumed.status | Should Be "begun"
        $resumed.owner.commentId | Should Be 52
    }

    It "pauses unsafe recovery without creating a new owner" {
        $global:child.labels += [ordered]@{ name = "in-progress" }
        [string]$expiredBody = New-ProjectIssueOwnerComment `
            -Parent 100 -Issue 11 -Token "00000000-0000-0000-0000-000000000001" `
            -Base "0000000000000000000000000000000000000000" `
            -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(-1).ToString("o"))
        $global:parentComments.Add([ordered]@{
            id = 40; body = $expiredBody; updated_at = [datetime]::UtcNow.AddMinutes(-1).ToString("o")
        })

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json

        $result.status | Should Be "paused"
        $result.nextState | Should Be "PAUSED"
        $result.reason | Should Match "cat-file"
        @($global:ghCommands | Where-Object {
            $_ -like "api --method POST repos/owner/repo/issues/100/comments*"
        }).Count | Should Be 0
    }

    It "pauses an orphan in-progress label instead of inventing a recovery BASE" {
        $global:child.labels += [ordered]@{ name = "in-progress" }

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json

        $result.status | Should Be "paused"
        $result.nextState | Should Be "PAUSED"
        $result.reason | Should Match "recoverable owner"
        @($global:ghCommands | Where-Object {
            $_ -like "api --method POST repos/owner/repo/issues/100/comments*"
        }).Count | Should Be 0
    }

    It "pauses recovery when the commit after BASE does not belong to the issue" {
        $global:child.labels += [ordered]@{ name = "in-progress" }
        Set-Content -LiteralPath (Join-Path $global:workspace "tracked.txt") -Value "unrelated"
        & git.exe -C $global:repositoryRoot add --all
        & git.exe -C $global:repositoryRoot commit --message "unrelated commit" | Out-Null
        [string]$expiredBody = New-ProjectIssueOwnerComment `
            -Parent 100 -Issue 11 -Token "00000000-0000-0000-0000-000000000001" `
            -Base $global:baseline -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(-1).ToString("o"))
        $global:parentComments.Add([ordered]@{
            id = 40; body = $expiredBody; updated_at = [datetime]::UtcNow.AddMinutes(-1).ToString("o")
        })

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json

        $result.status | Should Be "paused"
        $result.reason | Should Match "does not belong"
        @($global:ghCommands | Where-Object {
            $_ -like "api --method POST repos/owner/repo/issues/100/comments*"
        }).Count | Should Be 0
    }

    It "recovers after the issue commit while amend changes are still dirty" {
        $global:child.labels += [ordered]@{ name = "in-progress" }
        Set-Content -LiteralPath (Join-Path $global:workspace "tracked.txt") -Value "issue commit"
        & git.exe -C $global:repositoryRoot add --all
        & git.exe -C $global:repositoryRoot commit --message "#11 Child" | Out-Null
        Set-Content -LiteralPath (Join-Path $global:workspace "tracked.txt") -Value "pending amend"
        [string]$expiredBody = New-ProjectIssueOwnerComment `
            -Parent 100 -Issue 11 -Token "00000000-0000-0000-0000-000000000001" `
            -Base $global:baseline -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(-1).ToString("o"))
        $global:parentComments.Add([ordered]@{
            id = 40; body = $expiredBody; updated_at = [datetime]::UtcNow.AddMinutes(-1).ToString("o")
        })

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json

        $result.status | Should Be "begun"
        $result.recovered | Should Be $true
        $result.base | Should Be $global:baseline
        (& git.exe -C $global:repositoryRoot status --porcelain) | Should Not BeNullOrEmpty
    }

    It "recovers after the issue commit has been amended" {
        $global:child.labels += [ordered]@{ name = "in-progress" }
        Set-Content -LiteralPath (Join-Path $global:workspace "tracked.txt") -Value "issue commit"
        & git.exe -C $global:repositoryRoot add --all
        & git.exe -C $global:repositoryRoot commit --message "#11 Child" | Out-Null
        Set-Content -LiteralPath (Join-Path $global:workspace "tracked.txt") -Value "amended issue commit"
        & git.exe -C $global:repositoryRoot add --all
        & git.exe -C $global:repositoryRoot commit --amend --no-edit | Out-Null
        [string]$expiredBody = New-ProjectIssueOwnerComment `
            -Parent 100 -Issue 11 -Token "00000000-0000-0000-0000-000000000001" `
            -Base $global:baseline -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(-1).ToString("o"))
        $global:parentComments.Add([ordered]@{
            id = 40; body = $expiredBody; updated_at = [datetime]::UtcNow.AddMinutes(-1).ToString("o")
        })

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json

        $result.status | Should Be "begun"
        $result.recovered | Should Be $true
        $result.base | Should Be $global:baseline
        (& git.exe -C $global:repositoryRoot status --porcelain) | Should BeNullOrEmpty
    }

    It "recovers the same issue commit after it has been pushed" {
        $global:child.labels += [ordered]@{ name = "in-progress" }
        Set-Content -LiteralPath (Join-Path $global:workspace "tracked.txt") -Value "pushed issue commit"
        & git.exe -C $global:repositoryRoot add --all
        & git.exe -C $global:repositoryRoot commit --message "#11 Child" | Out-Null
        [string]$pushedHead = (& git.exe -C $global:repositoryRoot rev-parse HEAD).Trim()
        & git.exe -C $global:repositoryRoot update-ref refs/remotes/origin/master $pushedHead
        [string]$expiredBody = New-ProjectIssueOwnerComment `
            -Parent 100 -Issue 11 -Token "00000000-0000-0000-0000-000000000001" `
            -Base $global:baseline -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(-1).ToString("o"))
        $global:parentComments.Add([ordered]@{
            id = 40; body = $expiredBody; updated_at = [datetime]::UtcNow.AddMinutes(-1).ToString("o")
        })

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode run -Issue 11) |
            ConvertFrom-Json

        $result.status | Should Be "begun"
        $result.recovered | Should Be $true
        $result.base | Should Be $global:baseline
        (& git.exe -C $global:repositoryRoot status --porcelain) | Should BeNullOrEmpty
    }

    It "recovers the in-progress issue before parent ranking" {
        $global:child.labels += [ordered]@{ name = "in-progress" }
        [string]$expiredBody = New-ProjectIssueOwnerComment `
            -Parent 100 -Issue 11 -Token "00000000-0000-0000-0000-000000000001" `
            -Base $global:baseline -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(-1).ToString("o"))
        $global:parentComments.Add([ordered]@{
            id = 40; body = $expiredBody; updated_at = [datetime]::UtcNow.AddMinutes(-1).ToString("o")
        })

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode run -Parent 100) |
            ConvertFrom-Json

        $result.status | Should Be "begun"
        $result.issue | Should Be 11
        $result.base | Should Be $global:baseline
        $result.recovered | Should Be $true
        @($global:ghCommands | Where-Object {
            $_ -eq "api repos/owner/repo/issues/11/dependencies/blocked_by?per_page=100"
        }).Count | Should Be 1
    }

    It "locks parent recovery when an active in-progress owner exists" {
        $global:child.labels += [ordered]@{ name = "in-progress" }
        [string]$expiredBody = New-ProjectIssueOwnerComment `
            -Parent 100 -Issue 11 -Token "00000000-0000-0000-0000-000000000001" `
            -Base $global:baseline -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(-1).ToString("o"))
        [string]$activeBody = New-ProjectIssueOwnerComment `
            -Parent 100 -Issue 11 -Token "00000000-0000-0000-0000-000000000002" `
            -Base $global:baseline -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(30).ToString("o"))
        $global:parentComments.Add([ordered]@{
            id = 40; body = $expiredBody; updated_at = [datetime]::UtcNow.AddMinutes(-1).ToString("o")
        })
        $global:parentComments.Add([ordered]@{
            id = 50; body = $activeBody; updated_at = [datetime]::UtcNow.ToString("o")
        })

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode run -Parent 100) |
            ConvertFrom-Json

        $result.status | Should Be "locked"
        $result.issue | Should Be 11
        @($global:parentComments).Count | Should Be 2
    }

    It "locks a duplicate final Parent task while its owner is active" {
        $global:child.state = "closed"
        $global:parent.labels += [ordered]@{ name = "in-progress" }
        [string]$activeBody = New-ProjectIssueOwnerComment `
            -Parent 100 -Issue 100 -Token "00000000-0000-0000-0000-000000000001" `
            -Base $global:baseline -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(30).ToString("o"))
        $global:parentComments.Add([ordered]@{
            id = 50; body = $activeBody; updated_at = [datetime]::UtcNow.ToString("o")
        })

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode run -Parent 100) |
            ConvertFrom-Json

        $result.status | Should Be "locked"
        $result.issue | Should Be 100
        @($global:parentComments).Count | Should Be 1
    }

    It "recovers an expired final parent owner after all children close" {
        $global:child.state = "closed"
        [string]$expiredBody = New-ProjectIssueOwnerComment `
            -Parent 100 -Issue 100 -Token "00000000-0000-0000-0000-000000000001" `
            -Base $global:baseline -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(-1).ToString("o"))
        $global:parentComments.Add([ordered]@{
            id = 40; body = $expiredBody; updated_at = [datetime]::UtcNow.AddMinutes(-1).ToString("o")
        })

        [object]$result = (& $scriptUnderTest -Config $global:configPath -Mode run -Parent 100) |
            ConvertFrom-Json

        $result.status | Should Be "begun"
        $result.targetKind | Should Be "parent"
        $result.recovered | Should Be $true
        $result.owner.commentId | Should Be 51
    }
}
