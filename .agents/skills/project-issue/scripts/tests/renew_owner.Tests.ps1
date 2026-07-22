$scriptUnderTest = Join-Path $PSScriptRoot "..\renew_owner.ps1"
$ownerState = Join-Path $PSScriptRoot "..\owner_state.ps1"
. $ownerState

Describe "renew_owner.ps1 minimal lease renewal" {
    BeforeEach {
        $global:token = "00000000-0000-0000-0000-000000000001"
        $global:commentId = 51
        $global:parent = 100
        $global:issue = 11
        $global:base = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        $global:leaseExpiresAt = [datetime]::UtcNow.AddMinutes(4).ToString("o")
        $global:patchCount = 0
        $global:ownerBody = New-ProjectIssueOwnerComment -Parent $global:parent -Issue $global:issue `
            -Token $global:token -Base $global:base -LeaseExpiresAt $global:leaseExpiresAt

        function global:gh {
            $global:LASTEXITCODE = 0
            [string]$command = $args -join " "
            if ($command -eq "api --paginate --slurp repos/owner/repo/issues/100/comments?per_page=100") {
                return ConvertTo-Json -InputObject @(@{
                    id = $global:commentId
                    body = $global:ownerBody
                    updated_at = [datetime]::UtcNow.ToString("o")
                }) -Depth 8 -Compress
            }
            if ($command -eq "api --method PATCH repos/owner/repo/issues/comments/51 -f body=$global:ownerBody") {
                throw "renewal must replace the lease in the owner body"
            }
            if ($command -like "api --method PATCH repos/owner/repo/issues/comments/51 -f body=*") {
                $global:patchCount++
                $global:ownerBody = [string]$args[-1].Substring(5)
                return "{}"
            }
            throw "Unexpected gh command: $command"
        }
    }

    AfterEach {
        Remove-Item Function:\gh -ErrorAction SilentlyContinue
        foreach ($name in @("token", "commentId", "parent", "issue", "base", "leaseExpiresAt", "patchCount", "ownerBody")) {
            Remove-Variable $name -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It "renews only when the requested safety window exceeds the remaining lease" {
        [object]$result = (& $scriptUnderTest -Repository "owner/repo" -Parent 100 -Issue 11 `
            -OwnerToken $global:token -OwnerCommentId 51 -RequiredMinutes 10) | ConvertFrom-Json

        $result.status | Should Be "renewed"
        $global:patchCount | Should Be 1
        ([datetime]$result.leaseExpiresAt) | Should BeGreaterThan ([datetime]::UtcNow.AddMinutes(175))
        $result.metrics.githubCalls | Should Be 3
    }

    It "keeps a sufficiently long lease without a PATCH" {
        $global:leaseExpiresAt = [datetime]::UtcNow.AddMinutes(30).ToString("o")
        $global:ownerBody = New-ProjectIssueOwnerComment -Parent $global:parent -Issue $global:issue `
            -Token $global:token -Base $global:base -LeaseExpiresAt $global:leaseExpiresAt

        [object]$result = (& $scriptUnderTest -Repository "owner/repo" -Parent 100 -Issue 11 `
            -OwnerToken $global:token -OwnerCommentId 51 -RequiredMinutes 10) | ConvertFrom-Json

        $result.status | Should Be "unchanged"
        $global:patchCount | Should Be 0
        $result.metrics.githubCalls | Should Be 1
    }

    It "rejects a stale owner after another active comment takes priority" {
        [string]$global:winnerBody = New-ProjectIssueOwnerComment -Parent 100 -Issue 11 `
            -Token "00000000-0000-0000-0000-000000000099" -Base $global:base `
            -LeaseExpiresAt ([datetime]::UtcNow.AddMinutes(30).ToString("o"))
        $originalGh = Get-Item Function:\gh
        function global:gh {
            $global:LASTEXITCODE = 0
            [string]$command = $args -join " "
            if ($command -eq "api --paginate --slurp repos/owner/repo/issues/100/comments?per_page=100") {
                return ConvertTo-Json -InputObject @(
                    @{ id = 40; body = $global:winnerBody; updated_at = [datetime]::UtcNow.ToString("o") },
                    @{ id = 51; body = $global:ownerBody; updated_at = [datetime]::UtcNow.ToString("o") }
                ) -Depth 8 -Compress
            }
            throw "Unexpected gh command: $command"
        }

        [bool]$threw = $false
        try {
            & $scriptUnderTest -Repository "owner/repo" -Parent 100 -Issue 11 `
                -OwnerToken $global:token -OwnerCommentId 51 -RequiredMinutes 10 | Out-Null
        } catch { $threw = $true }
        $threw | Should Be $true
        Remove-Variable winnerBody -Scope Global -ErrorAction SilentlyContinue
    }
}
