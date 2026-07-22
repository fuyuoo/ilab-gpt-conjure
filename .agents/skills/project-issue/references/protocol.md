# Project Issue 执行协议

## 1. 硬边界

- 一次只处理 WorkContext 中的一张 Issue；所有 diff、测试、commit、review 与证据必须唯一归属它。
- 配置只包含 `labels.ready/human/claim/manual`，四个 label 必须非空且互不相同。Parent 不存入配置。
- Parent/Sub-issue 与 blocker 只读取 GitHub 原生关系；Issue 正文仅提供需求和 AC，不参与关系判定。
- owner 评论只保存 Parent、Issue、token、BASE、checkpoint 和 180 分钟到期时间。多个有效 owner 以最小 REST comment id 为唯一执行者，loser 在代码或共享 label 写入前返回 `LOCKED`。
- 中断恢复必须复用 owner BASE。无法证明当前分支、提交和工作区属于该 Issue 时返回 `PAUSED`，不得建立新基线。
- 一张 Issue 恰有一个 commit：`#<ISSUE> <ISSUE_TITLE>`。不混入前后票、自动化基础设施外改动或用户既有改动。
- 自动验证与 Standards/Spec 双轴 review 不得绕过。明确的人工 AC 保持未勾选，由完成入口加 `manual-verification-pending` 后关闭；自动或混合 AC 的自动部分必须先满足。

## 2. BEGIN

按 SKILL 的公开参数调用 `begin_issue.ps1`，原样保存 JSON 与 `metrics.elapsedMs/githubCalls/githubElapsedMs`。

- `selected`（dry-run）：报告目标与正式运行将进入的状态，不做写入。
- `begun`：保存整个 WorkContext，后续只使用其中的 repository、parent、issue、owner、BASE、workspace 与 completion 参数。
- `locked`：未修改代码的重复 task 自动归档；其它调用正常结束为 `LOCKED`。
- `paused`、`input_error`、`invalid_relationship`：结束为 `PAUSED`。
- `no_issue`：有开放子票但当前无合格票时结束为 `NO_ISSUE`；不得提前处理 Parent。

`begun` 后完整读取当前 Issue 与 Parent 需求。没有足够信息形成可验证目标时，不猜测实现；准备失败记录交给完成入口转 `BLOCKED`。

## 3. IMPLEMENT 与 VERIFY

1. 先根据 Issue/AC、规范或已批准设计，确定本次改动的可观察目标和公共 seam；无法确定时停止并转人工。
2. 按照用户在规范或工单中描述的工作进行实施。
3. 新增或改变可观察行为时使用 /tdd；Issue/AC、规范或已批准设计中的公共接口视为已约定 seam，无法确定时停止并转人工。纯文档、机械迁移或不改变行为的重构不要求 TDD。
4. 定期运行类型检查，定期运行单个测试文件，并在最后运行一次完整的测试套件。
5. 直接实现当前 Issue；本阶段不 commit、不 review，不修改全局技能。
6. 保留仍有效的故障、安全、恢复与人工 AC 场景。仅服务已废弃内部状态的测试与其生产代码一起删除，不机械改写成无意义断言。
7. 运行当前技术栈适用的解析/静态检查、目标测试与完整测试套件。每次记录命令、mode、exitCode、total/passed/failed、skipped 明细、reportPath、runId 和绑定 HEAD。
8. 预计长操作所需安全窗口超过 owner 剩余时间时，先调用 `renew_owner.ps1`，传入 WorkContext owner 与 `RequiredMinutes`。返回 `unchanged|renewed` 后原样记录 metrics；续租失败立即停止，旧任务不得继续修改共享状态。
9. Unity 验证仅在当前 Issue 涉及 Unity 生产代码时执行；其它 Issue 使用其技术栈对应的验证方式。

## 4. COMMIT 与最终 REVIEW

1. `git diff --check` 和所需测试通过后，只暂存当前 Issue 文件，检查 staged 清单并创建唯一 commit：`#<ISSUE> <ISSUE_TITLE>`。
2. 固定对 `BASE...HEAD` 执行完成后，使用 /code-review 来审查代码。
3. blocker 可执行最多五轮合适的修复。修复必须针对 finding 的根因并补充必要的回归验证；改动可以覆盖解决该 blocker 所必需的代码与测试，但必须唯一归属当前 Issue，不得借机扩展无关范围。每轮必须 amend 同一个 commit、记录 before/after HEAD 与实际代码/测试变化、重跑相关测试并重新执行 /code-review。
4. 连续两轮没有代码或测试变化且 finding 相同，立即停止；五轮后仍有 blocker 也停止。不得用 standalone PASS 覆盖未修复 blocker。

## 5. 验证记录与 COMPLETE

完整读取 `verification-template.md`，生成仓库外临时 JSON。记录必须绑定 WorkContext 的 parent、issue、BASE 和最终 HEAD，并包含：

- 至少一条当前 HEAD 上通过的最终自动测试；
- 初始与最终 Standards/Spec、每轮 amend/复验/复审轨迹；
- 当前 AC 数量、勾选状态、文本指纹，以及混合 AC 自动部分的测试证据；
- 未执行项及其影响、剩余风险。

确认 worktree clean 后调用：

```powershell
& ".agents/skills/project-issue/scripts/complete_issue.ps1" `
    -Config $CONFIG `
    -Repository $WorkContext.repository `
    -Parent $WorkContext.parent `
    -Issue $WorkContext.issue `
    -OwnerToken $WorkContext.owner.token `
    -OwnerCommentId $WorkContext.owner.commentId `
    -Base $WorkContext.base `
    -VerificationPath $VerificationPath
```

该入口是唯一交付门禁：校验 owner、clean worktree、唯一 commit、测试、review、AC 和风险；通过后 push、发布一次结构化 delivery 证据、按需添加人工待验 label、关闭并回读 Issue，然后移除 in-progress、释放 owner并只读返回 `nextTarget`。任何自动门禁失败会记录诊断、把开放 Issue 转 `ready-for-human`、释放 owner并返回 `blocked`，不得派发下一票。

## 6. 单次交接

`complete_issue.ps1` 返回 `completed` 后：

- `nextTarget.status=selected`：把其明确 `issue` 传给 `next_task_plan.ps1`。严格使用返回的 `0/5/15` 秒尝试节奏；每次按 WorkContext.workspace 精确解析 local project，创建无 worktree task。prompt 只包含 CONFIG、MODE=run 和 ISSUE。
- 收到首个非空 threadId 立即停止重试，并再次调用 planner 取得 `DONE_NEXT_DISPATCHED`。
- 三次均失败时传 `-DispatchFailed`，返回 `DONE_NEXT_DISPATCH_FAILED`，并保留可复制的明确 ISSUE prompt。
- `nextTarget.status=no_issue`：返回 `NO_ISSUE`。只要仍有开放原生子票，就不得启动 Parent。
- `nextTarget.status=parent_complete`：最终 Parent 已关闭，返回 `DONE_PARENT_COMPLETE`，不再创建 task。

旧 task 不预占下一票、不写交接持久状态。响应丢失造成的重复 task 由新 task 的最小 owner 竞争在改代码前收敛。

## 7. 终态

- `DONE_NEXT_DISPATCHED`
- `DONE_NEXT_DISPATCH_FAILED`
- `DONE_PARENT_COMPLETE`
- `NO_ISSUE`
- `LOCKED`
- `PAUSED`
- `BLOCKED`

只有当前 Issue 经完成入口权威回读为 closed 才能返回 `DONE_*`。
