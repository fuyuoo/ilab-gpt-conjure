$skillRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$workspace = [System.IO.Path]::GetFullPath((Join-Path $skillRoot "..\..\.."))

Describe "project-issue production protocol contract" {
    It "uses only begin WorkContext complete in the production instructions" {
        [string]$instructions = @(
            Get-Content -Raw -LiteralPath (Join-Path $skillRoot "SKILL.md")
            Get-Content -Raw -LiteralPath (Join-Path $skillRoot "references\protocol.md")
        ) -join "`n"

        $instructions | Should Match "begin_issue\.ps1"
        $instructions | Should Match "WorkContext"
        $instructions | Should Match "complete_issue\.ps1"
        $instructions | Should Not Match "select_next_issue|update_claim|release_claim|preclose_guard"
        $instructions | Should Not Match '\$implement|claim-v2|RequireRecordedGuard|receipt'
        $instructions | Should Not Match "正文.*## Parent|正文.*## Blocked by"
        $instructions | Should Match "最多五轮合适的修复"
        $instructions | Should Match "finding 的根因"
        $instructions | Should Not Match "五轮最小修复"
    }

    It "keeps exactly the four new-protocol labels in repository config" {
        [object]$config = Get-Content -Raw -LiteralPath (Join-Path $workspace ".agents\project-issue.json") |
            ConvertFrom-Json

        @($config.PSObject.Properties.Name) | Should Be @("labels")
        @($config.labels.PSObject.Properties.Name | Sort-Object) |
            Should Be @("claim", "human", "manual", "ready")
    }

    It "removes legacy production scripts and their state-machine tests" {
        foreach ($relativePath in @(
            "references\evidence-template.md",
            "scripts\claim_state.ps1",
            "scripts\evidence_state.ps1",
            "scripts\inspect_acceptance.ps1",
            "scripts\preclose_guard.ps1",
            "scripts\release_claim.ps1",
            "scripts\select_next_issue.ps1",
            "scripts\update_claim.ps1",
            "scripts\validate_config.ps1",
            "scripts\tests\claim_state.Tests.ps1",
            "scripts\tests\claim_transitions.Tests.ps1",
            "scripts\tests\evidence_state.Tests.ps1",
            "scripts\tests\inspect_acceptance.Tests.ps1",
            "scripts\tests\preclose_guard.Tests.ps1",
            "scripts\tests\select_next_issue.Tests.ps1",
            "scripts\tests\validate_config.Tests.ps1"
        )) {
            Test-Path -LiteralPath (Join-Path $skillRoot $relativePath) | Should Be $false
        }
    }
}
