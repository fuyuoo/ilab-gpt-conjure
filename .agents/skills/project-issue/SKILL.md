---
name: project-issue
description: 从动态 Parent 队列交付或恢复一张 GitHub issue。
---

# Project Issue

每次运行只处理一个明确执行对象。`begin_issue.ps1` 决定动态 Parent、原生关系、owner、恢复边界和 WorkContext；skill 在 WorkContext 内直接完成 TDD、实现、验证、单一 commit 与最终双轴 review；`complete_issue.ps1` 执行唯一交付门禁、发布结构化证据、关闭或转人工并返回下一目标。

## 1. 解析输入

从用户提示读取：

- 必填：`CONFIG=<仓库内 JSON 配置路径>`、`MODE=dry-run|run`。
- `PARENT=<number>` 与 `ISSUE=<number>` 至少提供一个；两者同时提供时必须匹配同一原生 Parent。

缺失、重复或无法解析时返回 `PAUSED`，不得猜测执行对象。

## 2. 加载规则

完整读取平台入口规则、其要求的技术规范与 `docs/agents/issue-tracker.md`。`MODE=run` 还必须完整读取 [执行协议](references/protocol.md)；准备最终验证记录时完整读取 [验证记录模板](references/verification-template.md)。

## 3. 进入公开开始入口

只调用一次：

```powershell
[hashtable]$beginArgs = @{
    Config = $CONFIG
    Mode = $MODE
}
if ([int]$PARENT -gt 0) { $beginArgs.Parent = [int]$PARENT }
if ([int]$ISSUE -gt 0) { $beginArgs.Issue = [int]$ISSUE }
& ".agents/skills/project-issue/scripts/begin_issue.ps1" @beginArgs
```

`dry-run` 只报告目标、下一状态与 `metrics`，不得修改 Git、GitHub、文件、Unity 或 Codex task。

`run` 只有返回 `status=begun` 和完整 WorkContext 才能修改代码。`locked` 的重复空 task 按协议归档；`paused`、`input_error`、`invalid_relationship`、`no_issue` 均停止且不改选其它票。

## 4. 交付

严格执行协议：直接实现当前 WorkContext，生成最终验证 JSON，再调用一次 `complete_issue.ps1`。不从全局队列重复选票，不在 skill 内嵌其它实现工作流，不预先 claim 下一票。

只有 `complete_issue.ps1` 返回 `status=completed` 才能按其 `nextTarget` 创建下一张 local Codex task；新 prompt 必须包含明确的 `ISSUE`。Parent 自身作为最终目标时同样通过 `ISSUE=<Parent number>` 交接。

## 启动 prompt

人工从 Parent 启动：

```text
使用 $project-issue。

CONFIG=.agents/project-issue.json
MODE=run
PARENT=<number>
```

人工直接指定一票时把 `PARENT` 换成 `ISSUE`。自动交接始终只传 `ISSUE`，不创建 worktree 或周期自动化。
