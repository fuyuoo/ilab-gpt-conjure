# Issue tracker: GitHub

Issues and PRDs for this repo live as GitHub issues in `fuyuoo/ilab-gpt-conjure`. Use the `gh` CLI for all operations.

## Conventions

- Create: `gh issue create --title "..." --body "..."`
- Read: `gh issue view <number> --comments`
- List: `gh issue list --state open --json number,title,body,labels,comments`
- Comment: `gh issue comment <number> --body "..."`
- Label: `gh issue edit <number> --add-label "..."` or `--remove-label "..."`
- Close: `gh issue close <number> --comment "..."`

Infer the repository from `git remote -v` when commands run inside this clone.

## Pull requests as a triage surface

**PRs as a request surface: no.**

External pull requests do not enter the issue triage state machine. Pull requests can still be reviewed through PR-specific workflows.

## Skill mappings

- “Publish to the issue tracker” means create a GitHub issue.
- “Fetch the relevant ticket” means run `gh issue view <number> --comments`.
- GitHub issues are the source of truth for specs and tickets.

## Wayfinding operations

A wayfinder map is a GitHub issue labelled `wayfinder:map`, with child issues used as investigation tickets.

Use native GitHub sub-issues and issue dependencies when available. If unavailable:

- Put `Part of #<map>` in child issues.
- Record blockers as `Blocked by: #<number>`.
- A ticket is ready when every blocker is closed and it has no assignee.
- Claim a ticket with `gh issue edit <number> --add-assignee @me`.
