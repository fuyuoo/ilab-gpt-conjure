$scriptUnderTest = Join-Path $PSScriptRoot "..\resolve_manual_verification.ps1"

Describe "resolve_manual_verification.ps1 public manual verification seam" {
    BeforeEach {
        $global:configPath = Join-Path $TestDrive "project-issue.json"
        @{
            labels = @{
                ready = "ready"
                human = "human"
                claim = "in-progress"
                manual = "manual-pending"
            }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $global:configPath
        $global:issueState = "closed"
        $global:labels = [System.Collections.Generic.List[string]]::new()
        $global:labels.Add("manual-pending")
        $global:operations = [System.Collections.Generic.List[string]]::new()
        $global:comments = [System.Collections.Generic.List[string]]::new()

        function global:gh {
            $global:LASTEXITCODE = 0
            [string]$command = $args -join " "
            if ($command -eq "api repos/owner/repo/issues/11") {
                return [ordered]@{
                    number = 11
                    state = $global:issueState
                    labels = @($global:labels | ForEach-Object { [ordered]@{ name = $_ } })
                } | ConvertTo-Json -Depth 8 -Compress
            }
            if ($command -like "api --method POST repos/owner/repo/issues/11/comments -f body=*") {
                $global:operations.Add("comment")
                $global:comments.Add([string]$args[-1].Substring(5))
                return '{"html_url":"https://github.com/owner/repo/issues/11#issuecomment-81"}'
            }
            if ($command -eq "api --method DELETE repos/owner/repo/issues/11/labels/manual-pending") {
                $global:operations.Add("remove-manual")
                $global:labels.Remove("manual-pending") | Out-Null
                return ""
            }
            if ($command -eq "api --method POST repos/owner/repo/issues/11/labels -f labels[]=ready") {
                $global:operations.Add("add-ready")
                if (!$global:labels.Contains("ready")) { $global:labels.Add("ready") }
                return "{}"
            }
            if ($command -eq "api --method PATCH repos/owner/repo/issues/11 -f state=open") {
                $global:operations.Add("reopen")
                $global:issueState = "open"
                return "{}"
            }
            throw "Unexpected gh command: $command"
        }
    }

    AfterEach {
        Remove-Item Function:\gh -ErrorAction SilentlyContinue
        foreach ($name in @("configPath", "issueState", "labels", "operations", "comments")) {
            Remove-Variable $name -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It "records passing evidence and removes the pending label while keeping the issue closed" {
        [object]$result = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Issue 11 -Outcome Passed `
            -Evidence "Verified in Unity build 2026.07.19.") | ConvertFrom-Json

        $result.status | Should Be "verified"
        $global:issueState | Should Be "closed"
        @($global:operations) -join "," | Should Be "comment,remove-manual"
        $global:comments[0] | Should Match "manual-verification-v1"
        $global:comments[0] | Should Match "Verified in Unity build 2026.07.19"
    }

    It "reopens a failed issue with ready state and complete failure evidence" {
        [object]$result = (& $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Issue 11 -Outcome Failed `
            -Evidence "recording://failure-11" -Steps "Open the screen and confirm." `
            -Expected "The confirmation remains visible." -Actual "The confirmation disappears.") |
            ConvertFrom-Json

        $result.status | Should Be "reopened"
        $global:issueState | Should Be "open"
        (@($global:labels) -contains "ready") | Should Be $true
        (@($global:labels) -contains "manual-pending") | Should Be $false
        @($global:operations) -join "," | Should Be "comment,add-ready,remove-manual,reopen"
        $global:comments[0] | Should Match "Open the screen and confirm"
        $global:comments[0] | Should Match "The confirmation remains visible"
        $global:comments[0] | Should Match "The confirmation disappears"
    }

    It "rejects incomplete failure evidence without mutating the issue" {
        { & $scriptUnderTest -Config $global:configPath `
            -Repository "owner/repo" -Issue 11 -Outcome Failed -Evidence "recording://failure-11" } |
            Should Throw "Failed verification requires Steps, Expected, and Actual."

        $global:operations.Count | Should Be 0
        $global:issueState | Should Be "closed"
    }
}
