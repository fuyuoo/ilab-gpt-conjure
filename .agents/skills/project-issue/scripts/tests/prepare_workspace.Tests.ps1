$scriptUnderTest = Join-Path $PSScriptRoot "..\prepare_workspace.ps1"

Describe "prepare_workspace.ps1" {
    BeforeEach {
        $workspace = Join-Path $TestDrive ([Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $workspace -Force | Out-Null
        & git init $workspace | Out-Null
        & git -C $workspace config user.name "Project Issue Test"
        & git -C $workspace config user.email "project-issue@example.invalid"
        Set-Content -LiteralPath (Join-Path $workspace "tracked.txt") -Value "baseline"
        & git -C $workspace add --all
        & git -C $workspace commit --message "baseline" | Out-Null
        $baseline = (& git -C $workspace rev-parse HEAD).Trim()
    }

    It "leaves an already clean workspace unchanged" {
        [object]$result = (& $scriptUnderTest -Workspace $workspace) | ConvertFrom-Json

        $result.status | Should Be "clean"
        $result.head | Should Be $baseline
        $result.commit | Should Be $null
        (& git -C $workspace rev-list --count HEAD).Trim() | Should Be "1"
    }

    It "commits all existing changes as one checkpoint" {
        Set-Content -LiteralPath (Join-Path $workspace "tracked.txt") -Value "changed"
        Set-Content -LiteralPath (Join-Path $workspace "untracked.txt") -Value "new"

        [object]$result = (& $scriptUnderTest -Workspace $workspace) | ConvertFrom-Json

        $result.status | Should Be "checkpointed"
        $result.previousHead | Should Be $baseline
        $result.subject | Should Be "chore: checkpoint workspace before project issue"
        @($result.paths).Count | Should Be 2
        (& git -C $workspace status --porcelain) | Should BeNullOrEmpty
        (& git -C $workspace rev-list --count HEAD).Trim() | Should Be "2"
        (& git -C $workspace log -1 --format=%s).Trim() | Should Be $result.subject
    }

    It "derives the Git root from a nested workspace and checkpoints the whole repository" {
        [string]$nestedWorkspace = Join-Path $workspace "Client\GameClient"
        New-Item -ItemType Directory -Path $nestedWorkspace -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $nestedWorkspace "project.txt") -Value "project"
        Set-Content -LiteralPath (Join-Path $workspace "root.txt") -Value "root"

        [object]$result = (& $scriptUnderTest -Workspace $nestedWorkspace) | ConvertFrom-Json

        $result.status | Should Be "checkpointed"
        $result.workspace | Should Be ([System.IO.Path]::GetFullPath($nestedWorkspace))
        $result.gitRoot | Should Be ([System.IO.Path]::GetFullPath($workspace))
        @($result.paths).Count | Should Be 2
        (& git -C $workspace status --porcelain) | Should BeNullOrEmpty
    }

    It "rejects a detached HEAD" {
        & git -C $workspace checkout --detach HEAD | Out-Null

        { & $scriptUnderTest -Workspace $workspace } |
            Should Throw "HEAD must be attached to a branch before preparing the workspace."
    }
}
