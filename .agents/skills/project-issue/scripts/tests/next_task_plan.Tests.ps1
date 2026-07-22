$scriptUnderTest = Join-Path $PSScriptRoot "..\next_task_plan.ps1"

Describe "next_task_plan.ps1 explicit one-shot handoff" {
    It "plans one local task with only the explicit next ISSUE" {
        [object]$result = (& $scriptUnderTest -TerminalState DONE -SelectionStatus selected `
            -Issue 291 -Config ".agents/project-issue.json") | ConvertFrom-Json

        $result.action | Should Be "dispatch"
        ($result.retryDelaysSeconds -join ",") | Should Be "0,5,15"
        $result.issue | Should Be 291
        $result.prompt | Should Be "使用 `$project-issue。`n`nCONFIG=.agents/project-issue.json`nMODE=run`nISSUE=291"
        $result.prompt | Should Not Match "PARENT="
    }

    It "rejects a selected handoff without an explicit ISSUE" {
        [bool]$threw = $false
        try {
            & $scriptUnderTest -TerminalState DONE -SelectionStatus selected `
                -Config ".agents/project-issue.json" | Out-Null
        } catch { $threw = $true }
        $threw | Should Be $true
    }

    foreach ($case in @(
        @{ selection = "parent_complete"; terminal = "DONE_PARENT_COMPLETE" },
        @{ selection = "no_issue"; terminal = "NO_ISSUE" }
    )) {
        It "maps completion $($case.selection) to $($case.terminal)" {
            [object]$result = (& $scriptUnderTest -TerminalState DONE `
                -SelectionStatus $case.selection -Config ".agents/project-issue.json") | ConvertFrom-Json
            $result.action | Should Be "stop"
            $result.terminalState | Should Be $case.terminal
        }
    }

    It "archives a duplicate task that loses owner competition" {
        [object]$result = (& $scriptUnderTest -TerminalState LOCKED `
            -Config ".agents/project-issue.json") | ConvertFrom-Json
        $result.action | Should Be "archive"
        $result.terminalState | Should Be "LOCKED"
    }

    foreach ($terminalState in @("BLOCKED", "PAUSED")) {
        It "stops without dispatch from terminal state $terminalState" {
            [object]$result = (& $scriptUnderTest -TerminalState $terminalState `
                -Config ".agents/project-issue.json") | ConvertFrom-Json
            $result.action | Should Be "stop"
            $result.terminalState | Should Be $terminalState
        }
    }

    It "stops on the first returned thread id" {
        [object]$result = (& $scriptUnderTest -TerminalState DONE -SelectionStatus selected `
            -Issue 291 -Config ".agents/project-issue.json" `
            -ThreadId "019f794e-41e4-74a0-97a2-1ae1781139bc") | ConvertFrom-Json
        $result.terminalState | Should Be "DONE_NEXT_DISPATCHED"
        $result.threadId | Should Be "019f794e-41e4-74a0-97a2-1ae1781139bc"
    }

    It "returns a copyable explicit ISSUE prompt after exhausted dispatch" {
        [object]$result = (& $scriptUnderTest -TerminalState DONE -SelectionStatus selected `
            -Issue 291 -Config ".agents/project-issue.json" -DispatchFailed) | ConvertFrom-Json
        $result.terminalState | Should Be "DONE_NEXT_DISPATCH_FAILED"
        $result.prompt | Should Match "ISSUE=291"
        $result.prompt | Should Not Match "PARENT="
    }
}
