$acceptanceState = Join-Path $PSScriptRoot "..\acceptance_state.ps1"
. $acceptanceState

Describe "Get-ProjectIssueAcceptanceState" {
    It "treats a missing section as not provided" {
        [object]$result = Get-ProjectIssueAcceptanceState -Body "Implement the requested behavior."

        $result.valid | Should Be $true
        $result.provided | Should Be $false
        $result.status | Should Be "not_provided"
        $result.total | Should Be 0
        $result.fingerprint | Should Be ""
    }

    It "rejects an explicit section without checklist items" {
        [object]$result = Get-ProjectIssueAcceptanceState -Body @"
## Acceptance criteria

Works correctly.
"@

        $result.valid | Should Be $false
        $result.provided | Should Be $true
        $result.status | Should Be "malformed"
    }

    It "keeps the fingerprint stable when only checkbox marks change" {
        [object]$unchecked = Get-ProjectIssueAcceptanceState -Body @"
## Acceptance criteria

- [ ] first
- [x] second
"@
        [object]$checked = Get-ProjectIssueAcceptanceState -Body @"
## Acceptance criteria

- [x] first
- [x] second
"@

        $unchecked.valid | Should Be $true
        $unchecked.provided | Should Be $true
        $unchecked.status | Should Be "unchecked"
        $checked.status | Should Be "all_checked"
        $unchecked.fingerprint | Should Be $checked.fingerprint
        $checked.fingerprint.Length | Should Be 64
    }

    It "classifies automatic manual and mixed acceptance items" {
        [object]$result = Get-ProjectIssueAcceptanceState -Body @"
## Acceptance criteria

- [x] Pester regression tests pass.
- [ ] [manual] Verify the final Unity presentation.
- [ ] 先通过 EditMode 自动测试，再进行人工验证并截图。
- [ ] 手测确认旧存档能够正常载入。
- [ ] Human verification requires a screen recording.
- [ ] Attach a recording of the final interaction.
"@

        @($result.items | ForEach-Object { $_.classification }) -join "," |
            Should Be "automatic,manual,mixed,manual,manual,manual"
        $result.automaticCount | Should Be 1
        $result.manualCount | Should Be 4
        $result.mixedCount | Should Be 1
        @($result.pendingManualItems | ForEach-Object { $_.index }) -join "," |
            Should Be "2,3,4,5,6"
    }

    It "keeps ambiguous recording wording automatic" {
        [object]$result = Get-ProjectIssueAcceptanceState -Body @"
## Acceptance criteria

- [ ] Recording metrics remain available after completion.
"@

        $result.items[0].classification | Should Be "automatic"
        $result.pendingManualItems.Count | Should Be 0
    }
}
