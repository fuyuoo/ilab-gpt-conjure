$scriptUnderTest = Join-Path $PSScriptRoot "..\complete_issue.ps1"
$ownerState = Join-Path $PSScriptRoot "..\owner_state.ps1"
$acceptanceState = Join-Path $PSScriptRoot "..\acceptance_state.ps1"
. $ownerState
. $acceptanceState

Describe "complete_issue.ps1 authoritative completion seam" {
    BeforeEach {
        $global:configDirectory = Join-Path $TestDrive ".agents"
        New-Item -ItemType Directory -Path $global:configDirectory -Force | Out-Null
        $global:configPath = Join-Path $global:configDirectory "project-issue.json"
        @{
            labels = @{
                ready = "ready"
                human = "human"
                claim = "in-progress"
                manual = "manual-pending"
            }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $global:configPath

        $global:base = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        $global:head = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        $global:branch = "master"
        $global:parentNumber = 100
        [string]$acceptanceBody = "## Acceptance criteria`n`n- [x] automatic delivery passes"
        [object]$currentAcceptance = Get-ProjectIssueAcceptanceState -Body $acceptanceBody
        $global:verificationPath = Join-Path $TestDrive "verification.json"
        @{
            parent = $global:parentNumber
            issue = 11
            base = $global:base
            head = $global:head
            tests = @(@{
                name = "complete issue Pester"
                command = "Invoke-Pester complete_issue.Tests.ps1"
                mode = "CLI"
                exitCode = 0
                total = 1
                passed = 1
                failed = 0
                skipped = @()
                reportPath = "pester://complete_issue"
                runId = "run-1"
                head = $global:head
            })
            reviews = @{
                head = $global:head
                initialHead = $global:head
                initialStandards = "PASS"
                initialSpec = "PASS"
                finalStandards = "PASS"
                finalSpec = "PASS"
                repairRounds = @()
            }
            acceptance = @{
                provided = $currentAcceptance.provided
                total = $currentAcceptance.total
                checked = $currentAcceptance.checked
                unchecked = $currentAcceptance.unchecked
                fingerprint = $currentAcceptance.fingerprint
            }
            unexecuted = @()
            risks = @("none")
        } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $global:verificationPath

        $global:ownerToken = "00000000-0000-0000-0000-000000000001"
        $global:ownerCommentId = 51
        $global:ownerBody = New-ProjectIssueOwnerComment `
            -Parent $global:parentNumber -Issue 11 -Token $global:ownerToken -Base $global:base `
            -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(30).ToString("o"))
        $global:additionalParentComments = @()
        $global:issue = [ordered]@{
            number = 11
            title = "Build complete seam"
            state = "open"
            body = $acceptanceBody
            labels = @([ordered]@{ name = "ready" }, [ordered]@{ name = "in-progress" })
            html_url = "https://github.com/owner/repo/issues/11"
        }
        $global:nativeChildren = @([ordered]@{
            number = 12
            title = "Build next seam"
            state = "open"
            html_url = "https://github.com/owner/repo/issues/12"
        })
        $global:nextIssue = [ordered]@{
            number = 12
            title = "Build next seam"
            state = "open"
            body = ""
            labels = @([ordered]@{ name = "ready" })
            html_url = "https://github.com/owner/repo/issues/12"
        }
        $global:parentIssue = [ordered]@{
            number = 100
            title = "Complete parent"
            state = "open"
            body = ""
            labels = @([ordered]@{ name = "ready" })
            html_url = "https://github.com/owner/repo/issues/100"
        }
        $global:remoteContainsHead = $false
        $global:pushFails = $false
        $global:ownerDeleted = $false
        $global:issueClosed = $false
        $global:failCloseOnce = $false
        $global:closeAttempts = 0
        $global:claimRemoved = $false
        $global:failClaimRemovalOnce = $false
        $global:claimRemovalAttempts = 0
        $global:humanAdded = $false
        $global:manualAdded = $false
        $global:manualRemoved = $false
        $global:evidenceComments = [System.Collections.Generic.List[string]]::new()
        $global:operations = [System.Collections.Generic.List[string]]::new()

        function global:git {
            $global:LASTEXITCODE = 0
            [string]$command = $args -join " "
            switch -Regex ($command) {
                "^branch --show-current$" { return $global:branch }
                "^status --porcelain$" { return "" }
                "^rev-parse HEAD$" { return $global:head }
                "^log --format=%H%x09%s .+\.\..+$" {
                    return "$($global:head)`t#11 Build complete seam"
                }
                "^push origin master$" {
                    $global:operations.Add("push")
                    if ($global:pushFails) {
                        $global:LASTEXITCODE = 1
                        return "push rejected"
                    }
                    $global:remoteContainsHead = $true
                    return ""
                }
                "^fetch origin master$" { return "" }
                "^merge-base --is-ancestor .+ origin/master$" {
                    if ($global:remoteContainsHead) { return "" }
                    $global:LASTEXITCODE = 1
                    return ""
                }
                default { throw "Unexpected git command: $command" }
            }
        }

        function global:gh {
            $global:LASTEXITCODE = 0
            [string]$command = $args -join " "
            if ($command -eq "api --paginate --slurp repos/owner/repo/issues/$global:parentNumber/comments?per_page=100") {
                [object[]]$comments = if ($global:ownerDeleted) { @() } else { @([ordered]@{
                    id = $global:ownerCommentId
                    body = $global:ownerBody
                    updated_at = [datetime]::UtcNow.ToString("o")
                }) }
                $comments = @($global:additionalParentComments) + @($comments)
                return ConvertTo-Json -InputObject @($comments) -Depth 8 -Compress
            }
            if ($command -eq "api repos/owner/repo/issues/11") {
                [object]$copy = $global:issue | ConvertTo-Json -Depth 8 | ConvertFrom-Json
                $copy.state = if ($global:issueClosed) { "closed" } else { "open" }
                if ($global:claimRemoved) {
                    $copy.labels = @($copy.labels | Where-Object { $_.name -ne "in-progress" })
                }
                if ($global:manualAdded -and !$global:manualRemoved -and
                    @($copy.labels | Where-Object { $_.name -eq "manual-pending" }).Count -eq 0) {
                    $copy.labels = @($copy.labels) + @([ordered]@{ name = "manual-pending" })
                }
                return $copy | ConvertTo-Json -Depth 8 -Compress
            }
            if ($command -eq "api --paginate --slurp repos/owner/repo/issues/100/sub_issues?per_page=100") {
                return ConvertTo-Json -InputObject @($global:nativeChildren) -Depth 8 -Compress
            }
            if ($command -eq "api repos/owner/repo/issues/12") {
                return $global:nextIssue | ConvertTo-Json -Depth 8 -Compress
            }
            if ($command -eq "api repos/owner/repo/issues/100") {
                return $global:parentIssue | ConvertTo-Json -Depth 8 -Compress
            }
            if ($command -in @(
                "api repos/owner/repo/issues/12/dependencies/blocked_by?per_page=100",
                "api repos/owner/repo/issues/100/dependencies/blocked_by?per_page=100")) {
                return "[]"
            }
            if ($command -eq "api --paginate --slurp repos/owner/repo/issues/11/comments?per_page=100") {
                [object[]]$comments = @($global:evidenceComments | ForEach-Object {
                    [ordered]@{
                        id = 71
                        body = [string]$_
                        html_url = "https://github.com/owner/repo/issues/11#issuecomment-71"
                    }
                })
                return ConvertTo-Json -InputObject @($comments) -Depth 12 -Compress
            }
            if ($command -like "api --method POST repos/owner/repo/issues/11/comments -f body=*") {
                [string]$body = [string]$args[-1].Substring(5)
                if ($body -match "project-issue-automation:failure-v1") {
                    $global:operations.Add("diagnostic")
                }
                else {
                    $global:operations.Add("evidence")
                    $global:evidenceComments.Add($body)
                }
                return @{ id = 71; html_url = "https://github.com/owner/repo/issues/11#issuecomment-71" } |
                    ConvertTo-Json -Compress
            }
            if ($command -eq "api --method PATCH repos/owner/repo/issues/11 -f state=closed") {
                $global:operations.Add("close")
                $global:closeAttempts++
                if ($global:failCloseOnce -and $global:closeAttempts -eq 1) {
                    $global:LASTEXITCODE = 1
                    return "close interrupted"
                }
                $global:issueClosed = $true
                return $global:issue | ConvertTo-Json -Depth 8 -Compress
            }
            if ($command -eq "api --method DELETE repos/owner/repo/issues/11/labels/in-progress") {
                $global:operations.Add("remove-claim")
                $global:claimRemovalAttempts++
                if ($global:failClaimRemovalOnce -and $global:claimRemovalAttempts -eq 1) {
                    $global:LASTEXITCODE = 1
                    return "label removal interrupted"
                }
                $global:claimRemoved = $true
                return ""
            }
            if ($command -eq "api --method POST repos/owner/repo/issues/11/labels -f labels[]=human") {
                $global:operations.Add("add-human")
                $global:humanAdded = $true
                return "{}"
            }
            if ($command -eq "api --method POST repos/owner/repo/issues/11/labels -f labels[]=manual-pending") {
                $global:operations.Add("add-manual")
                $global:manualAdded = $true
                return "{}"
            }
            if ($command -eq "api --method DELETE repos/owner/repo/issues/11/labels/manual-pending") {
                $global:operations.Add("remove-manual")
                $global:manualRemoved = $true
                return ""
            }
            if ($command -eq "api --method DELETE repos/owner/repo/issues/comments/51") {
                $global:operations.Add("release-owner")
                $global:ownerDeleted = $true
                return ""
            }
            throw "Unexpected gh command: $command"
        }
    }

    AfterEach {
        Remove-Item Function:\git -ErrorAction SilentlyContinue
        Remove-Item Function:\gh -ErrorAction SilentlyContinue
        foreach ($name in @(
            "configDirectory", "configPath", "verificationPath", "base", "head", "branch", "parentNumber",
            "ownerToken", "ownerCommentId", "ownerBody", "issue", "remoteContainsHead", "pushFails",
            "ownerDeleted", "issueClosed", "failCloseOnce", "closeAttempts", "claimRemoved", "failClaimRemovalOnce",
            "claimRemovalAttempts", "humanAdded", "manualAdded", "manualRemoved",
            "evidenceComments", "operations", "nativeChildren", "nextIssue", "parentIssue",
            "additionalParentComments")) {
            Remove-Variable $name -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It "completes one automatic issue through one gate and releases ownership after close" {
        [object]$result = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json

        $result.status | Should Be "completed"
        $result.issue | Should Be 11
        $result.head | Should Be $global:head
        $result.reviewRepairCount | Should Be 0
        $result.metrics.phase | Should Be "complete"
        $result.metrics.githubCalls | Should BeGreaterThan 0
        $result.metrics.githubElapsedMs | Should Not BeNullOrEmpty
        $result.metrics.elapsedMs | Should Not BeNullOrEmpty
        $result.nextTarget.status | Should Be "selected"
        $result.nextTarget.targetKind | Should Be "child"
        $result.nextTarget.issue | Should Be 12
        @($global:operations) -join "," | Should Be "push,evidence,close,remove-claim,release-owner"
        $global:evidenceComments.Count | Should Be 1
        $global:evidenceComments[0] | Should Match "project-issue-automation:delivery-v1"
        $global:evidenceComments[0] | Should Match '"acceptance":'
        $global:evidenceComments[0] | Should Not Match "receipt|RequireRecordedGuard|preflight"
    }

    It "does not let an old WorkContext mutate labels after a smaller owner takes over" {
        [string]$winnerBody = New-ProjectIssueOwnerComment `
            -Parent 100 -Issue 11 -Token "00000000-0000-0000-0000-000000000099" `
            -Base $global:base -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(30).ToString("o"))
        $global:additionalParentComments = @([ordered]@{
            id = 40; body = $winnerBody; updated_at = [datetime]::UtcNow.ToString("o")
        })

        [bool]$threw = $false
        try {
            & $scriptUnderTest -Config $global:configPath -Repository "owner/repo" `
                -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
                -OwnerCommentId $global:ownerCommentId -Base $global:base `
                -VerificationPath $global:verificationPath | Out-Null
        } catch { $threw = $true }

        $threw | Should Be $true
        @($global:operations).Count | Should Be 0
        $global:humanAdded | Should Be $false
        $global:claimRemoved | Should Be $false
    }

    It "returns no_issue when open native children exist but none is eligible" {
        $global:nextIssue.labels = @()

        [object]$result = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json

        $result.status | Should Be "completed"
        $result.nextTarget.status | Should Be "no_issue"
        $result.nextTarget.issue | Should Be $null
    }

    It "selects the parent as the explicit final target only after every child is closed" {
        $global:nativeChildren = @()

        [object]$result = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json

        $result.status | Should Be "completed"
        $result.nextTarget.status | Should Be "selected"
        $result.nextTarget.targetKind | Should Be "parent"
        $result.nextTarget.issue | Should Be 100
    }

    It "terminates without another target after the final parent closes" {
        $global:parentNumber = 11
        $global:ownerBody = New-ProjectIssueOwnerComment `
            -Parent 11 -Issue 11 -Token $global:ownerToken -Base $global:base `
            -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(30).ToString("o"))
        [object]$verification = Get-Content -Raw -LiteralPath $global:verificationPath | ConvertFrom-Json
        $verification.parent = 11
        $verification | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $global:verificationPath

        [object]$result = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 11 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json

        $result.status | Should Be "completed"
        $result.nextTarget.status | Should Be "parent_complete"
        $result.nextTarget.issue | Should Be $null
    }

    It "routes a final automated gate failure to a human without push close or dispatch" {
        [object]$verification = Get-Content -Raw -LiteralPath $global:verificationPath | ConvertFrom-Json
        $verification.reviews.finalSpec = "BLOCKER"
        $verification | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $global:verificationPath

        [object]$result = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json

        $result.status | Should Be "blocked"
        $result.reason | Should Match "Final review conclusions|Standards and Spec"
        @($global:operations) -join "," |
            Should Be "diagnostic,add-human,remove-claim,release-owner"
        $global:issueClosed | Should Be $false
        $global:remoteContainsHead | Should Be $false
    }

    It "accepts five changing repair rounds when both final review axes pass" {
        [object]$verification = Get-Content -Raw -LiteralPath $global:verificationPath | ConvertFrom-Json
        [string[]]$heads = @(
            ("c" * 40), ("d" * 40), ("e" * 40), ("f" * 40), ("1" * 40), $global:head)
        $verification.reviews.initialHead = $heads[0]
        $verification.tests = @(1..5 | ForEach-Object {
            [ordered]@{
                name = "repair round $_ Pester"
                command = "Invoke-Pester complete_issue.Tests.ps1"
                mode = "CLI"
                exitCode = 0
                total = 1
                passed = 1
                failed = 0
                skipped = @()
                reportPath = "pester://repair-$_"
                runId = "repair-$_"
                head = $heads[$_]
            }
        })
        $verification.reviews.repairRounds = @(1..5 | ForEach-Object {
            [ordered]@{
                round = $_
                amended = $true
                beforeHead = $heads[$_ - 1]
                afterHead = $heads[$_]
                codeChanged = $true
                testsChanged = $false
                testRunId = "repair-$_"
                standards = if ($_ -eq 5) { "PASS" } else { "BLOCKER" }
                spec = if ($_ -eq 5) { "PASS" } else { "BLOCKER" }
                remainingFindings = @("finding-$_")
            }
        })
        $verification | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $global:verificationPath

        [object]$result = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json

        $result.status | Should Be "completed"
        $result.reviewRepairCount | Should Be 5
    }

    It "stops two unchanged review rounds with the same finding instead of spinning" {
        [object]$verification = Get-Content -Raw -LiteralPath $global:verificationPath | ConvertFrom-Json
        $verification.reviews.finalStandards = "BLOCKER"
        [string]$firstHead = "c" * 40
        [string]$secondHead = "d" * 40
        $verification.reviews.initialHead = $firstHead
        $verification.reviews.repairRounds = @(
            [ordered]@{
                round = 1
                amended = $true
                beforeHead = $firstHead
                afterHead = $secondHead
                codeChanged = $false
                testsChanged = $false
                testRunId = "run-1"
                standards = "BLOCKER"
                spec = "PASS"
                remainingFindings = @("same blocker")
            },
            [ordered]@{
                round = 2
                amended = $true
                beforeHead = $secondHead
                afterHead = $global:head
                codeChanged = $false
                testsChanged = $false
                testRunId = "run-1"
                standards = "BLOCKER"
                spec = "PASS"
                remainingFindings = @("same blocker")
            }
        )
        $verification | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $global:verificationPath

        [object]$result = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json

        $result.status | Should Be "blocked"
        $result.reason | Should Match "stalled"
        @($global:operations) -join "," |
            Should Be "diagnostic,add-human,remove-claim,release-owner"
    }

    It "returns the recorded completion on retry without a second completion side effect" {
        [object]$first = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json
        [int]$operationCount = $global:operations.Count

        [object]$retry = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json

        $first.status | Should Be "completed"
        $retry.status | Should Be "completed"
        $retry.alreadyCompleted | Should Be $true
        $retry.evidenceUrl | Should Be "https://github.com/owner/repo/issues/11#issuecomment-71"
        $global:operations.Count | Should Be $operationCount
        $global:evidenceComments.Count | Should Be 1
    }

    It "resumes cleanup after close without repeating push evidence or close" {
        $global:failClaimRemovalOnce = $true
        [bool]$interrupted = $false
        try {
            & $scriptUnderTest -Config $global:configPath `
                -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
                -OwnerCommentId $global:ownerCommentId -Base $global:base `
                -VerificationPath $global:verificationPath | Out-Null
        }
        catch {
            $interrupted = $true
        }

        [object]$retry = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json

        $interrupted | Should Be $true
        $retry.status | Should Be "completed"
        $retry.alreadyCompleted | Should Be $true
        @($global:operations) -join "," |
            Should Be "push,evidence,close,remove-claim,remove-claim,release-owner"
        $global:evidenceComments.Count | Should Be 1
    }

    It "reuses recorded evidence after a close interruption without a second push or comment" {
        $global:failCloseOnce = $true
        [bool]$interrupted = $false
        try {
            & $scriptUnderTest -Config $global:configPath `
                -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
                -OwnerCommentId $global:ownerCommentId -Base $global:base `
                -VerificationPath $global:verificationPath | Out-Null
        }
        catch {
            $interrupted = $true
        }

        [object]$retry = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json

        $interrupted | Should Be $true
        $retry.status | Should Be "completed"
        @($global:operations) -join "," |
            Should Be "push,evidence,close,close,remove-claim,release-owner"
        $global:evidenceComments.Count | Should Be 1
    }

    It "rejects a PASS record that is not bound to the current HEAD" {
        [object]$verification = Get-Content -Raw -LiteralPath $global:verificationPath | ConvertFrom-Json
        $verification.head = "c" * 40
        $verification | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $global:verificationPath

        [object]$result = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json

        $result.status | Should Be "blocked"
        $result.reason | Should Match "current WorkContext and HEAD"
    }

    It "rejects a repair round without amend retest and dual-review evidence" {
        [object]$verification = Get-Content -Raw -LiteralPath $global:verificationPath | ConvertFrom-Json
        [string]$beforeHead = "c" * 40
        $verification.reviews.initialHead = $beforeHead
        $verification.reviews.repairRounds = @([ordered]@{
            round = 1
            amended = $false
            beforeHead = $beforeHead
            afterHead = $global:head
            codeChanged = $true
            testsChanged = $false
            testRunId = "run-1"
            standards = "PASS"
            spec = "PASS"
            remainingFindings = @()
        })
        $verification | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $global:verificationPath

        [object]$result = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json

        $result.status | Should Be "blocked"
        $result.reason | Should Match "lacks amend, retest, dual-review, or HEAD evidence"
    }

    It "does not let a standalone final PASS hide an unrepaired initial blocker" {
        [object]$verification = Get-Content -Raw -LiteralPath $global:verificationPath | ConvertFrom-Json
        $verification.reviews.initialStandards = "BLOCKER"
        $verification | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $global:verificationPath

        [object]$result = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json

        $result.status | Should Be "blocked"
        $result.reason | Should Match "Final review conclusions do not match"
    }

    It "rejects an amend record whose before and after HEAD are identical" {
        [object]$verification = Get-Content -Raw -LiteralPath $global:verificationPath | ConvertFrom-Json
        $verification.reviews.repairRounds = @([ordered]@{
            round = 1
            amended = $true
            beforeHead = $global:head
            afterHead = $global:head
            codeChanged = $true
            testsChanged = $false
            testRunId = "run-1"
            standards = "PASS"
            spec = "PASS"
            remainingFindings = @()
        })
        $verification | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $global:verificationPath

        [object]$result = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json

        $result.status | Should Be "blocked"
        $result.reason | Should Match "different before and after HEADs"
    }

    It "does not let final PASS contradict the last repair review" {
        [object]$verification = Get-Content -Raw -LiteralPath $global:verificationPath | ConvertFrom-Json
        [string]$beforeHead = "c" * 40
        $verification.reviews.initialHead = $beforeHead
        $verification.reviews.repairRounds = @([ordered]@{
            round = 1
            amended = $true
            beforeHead = $beforeHead
            afterHead = $global:head
            codeChanged = $true
            testsChanged = $false
            testRunId = "run-1"
            standards = "BLOCKER"
            spec = "PASS"
            remainingFindings = @("standards blocker")
        })
        $verification | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $global:verificationPath

        [object]$result = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json

        $result.status | Should Be "blocked"
        $result.reason | Should Match "Final review conclusions do not match"
    }

    It "routes a failed automated test result to a human before push" {
        [object]$verification = Get-Content -Raw -LiteralPath $global:verificationPath | ConvertFrom-Json
        $verification.tests[0].exitCode = 1
        $verification.tests[0].passed = 0
        $verification.tests[0].failed = 1
        $verification | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $global:verificationPath

        [object]$result = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json

        $result.status | Should Be "blocked"
        $result.reason | Should Match "test result"
        @($global:operations) -join "," |
            Should Be "diagnostic,add-human,remove-claim,release-owner"
    }

    It "routes an unchecked automated acceptance item to a human before push" {
        $global:issue.body = "## Acceptance criteria`n`n- [ ] automatic delivery passes"

        [object]$result = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json

        $result.status | Should Be "blocked"
        $result.reason | Should Match "acceptance criteria"
        @($global:operations) -join "," |
            Should Be "diagnostic,add-human,remove-claim,release-owner"
    }

    It "closes an issue with only unchecked manual acceptance and preserves the checkbox" {
        $global:issue.body = "## Acceptance criteria`n`n- [ ] [manual] Verify the final presentation."
        [object]$acceptance = Get-ProjectIssueAcceptanceState -Body $global:issue.body
        [object]$verification = Get-Content -Raw -LiteralPath $global:verificationPath | ConvertFrom-Json
        $verification.acceptance = @{
            provided = $acceptance.provided
            total = $acceptance.total
            checked = $acceptance.checked
            unchecked = $acceptance.unchecked
            fingerprint = $acceptance.fingerprint
            automatedSatisfied = @()
        }
        $verification | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $global:verificationPath

        [object]$result = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json

        $result.status | Should Be "completed"
        @($global:operations) -join "," |
            Should Be "push,evidence,add-manual,close,remove-claim,release-owner"
        $global:issue.body | Should Match "- \[ \] \[manual\] Verify the final presentation\."
        $global:evidenceComments[0] | Should Match '"pending_manual":\[\{'
    }

    It "requires the automated portion of an unchecked mixed acceptance item" {
        $global:issue.body = "## Acceptance criteria`n`n- [ ] EditMode tests pass, then capture a manual screenshot."
        [object]$acceptance = Get-ProjectIssueAcceptanceState -Body $global:issue.body
        [object]$verification = Get-Content -Raw -LiteralPath $global:verificationPath | ConvertFrom-Json
        $verification.acceptance = @{
            provided = $acceptance.provided
            total = $acceptance.total
            checked = $acceptance.checked
            unchecked = $acceptance.unchecked
            fingerprint = $acceptance.fingerprint
            automatedSatisfied = @()
        }
        $verification | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $global:verificationPath

        [object]$result = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json

        $result.status | Should Be "blocked"
        $result.reason | Should Match "mixed acceptance"
        $global:issueClosed | Should Be $false
    }

    It "closes an unchecked mixed acceptance item after its automated portion passes" {
        $global:issue.body = "## Acceptance criteria`n`n- [ ] EditMode tests pass, then capture a manual screenshot."
        [object]$acceptance = Get-ProjectIssueAcceptanceState -Body $global:issue.body
        [object]$verification = Get-Content -Raw -LiteralPath $global:verificationPath | ConvertFrom-Json
        $verification.acceptance = @{
            provided = $acceptance.provided
            total = $acceptance.total
            checked = $acceptance.checked
            unchecked = $acceptance.unchecked
            fingerprint = $acceptance.fingerprint
            automatedSatisfied = @([ordered]@{
                index = 1
                testRunId = "run-1"
                evidence = "The final Pester run covers the automated portion."
            })
        }
        $verification | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $global:verificationPath

        [object]$result = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json

        $result.status | Should Be "completed"
        $global:manualAdded | Should Be $true
        $global:issueClosed | Should Be $true
        $global:evidenceComments[0] | Should Match '"automated_satisfied":\[\{'
    }

    It "allows an issue without an acceptance section through the normal gate" {
        $global:issue.body = "Implement the behavior described by the Issue and Parent."
        [object]$acceptance = Get-ProjectIssueAcceptanceState -Body $global:issue.body
        [object]$verification = Get-Content -Raw -LiteralPath $global:verificationPath | ConvertFrom-Json
        $verification.acceptance = @{
            provided = $acceptance.provided
            total = $acceptance.total
            checked = $acceptance.checked
            unchecked = $acceptance.unchecked
            fingerprint = $acceptance.fingerprint
        }
        $verification | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $global:verificationPath

        [object]$result = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json

        $result.status | Should Be "completed"
        $global:manualAdded | Should Be $false
        $global:issueClosed | Should Be $true
    }

    It "routes a push failure to a human and does not close the issue" {
        $global:pushFails = $true

        [object]$result = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Parent 100 -Issue 11 -OwnerToken $global:ownerToken `
            -OwnerCommentId $global:ownerCommentId -Base $global:base `
            -VerificationPath $global:verificationPath) | ConvertFrom-Json

        $result.status | Should Be "blocked"
        $result.reason | Should Match "git push"
        @($global:operations) -join "," |
            Should Be "push,diagnostic,add-human,remove-claim,release-owner"
        $global:issueClosed | Should Be $false
    }
}
