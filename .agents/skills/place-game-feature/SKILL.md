---
name: place-game-feature
description: 落位游戏功能代码并执行分层门禁。Use when 新增或修改涉及 Shared/GameLogic、CyStarRoad/Game、UILogic、Adapters、同步恢复或相应测试的游戏功能，或审计已有功能改动的 owner、目录和依赖接缝。
---

# 功能落位门禁

把仓库 `docs/architecture/项目最终目标结构.md` 作为最终落位的单一结构真相源。本 Skill 只规定落位过程，不复制其中的目录树、所有权表或类型矩阵。

## 1. 建立证据边界

从仓库根目录执行：

1. 完整读取 `AI-RULES.md`，并按其读取规则加载本次功能涉及的规范。
2. 完整读取 `docs/architecture/项目最终目标结构.md`。
3. 当实现受当前迁移阶段影响时，读取 `docs/architecture/项目整体规范化重构路线.md` 的相关阶段和 Exit Gate。
4. 当 owner、跨上下文关系或既有决策不清楚时，从 `CONTEXT-MAP.md` 读取对应 `CONTEXT.md` 和 ADR。
5. 检查需求、邻近实现、调用接缝、Git 状态及现有测试，区分已有事实与最终目标。

最终目标决定新产物的目的地；路线图只决定当前是否具备实施条件。目标接缝尚未建立时，标记 `BLOCKED BY MIGRATION`，给出最小前置项并请求决定，不以遗留目录作为静默退路。

选择本次分支：

- 方案分支：完成第 1—3 步，在用户确认落位清单后停止。
- 实现分支：执行全部步骤。
- 审计分支：根据现有 diff 重建落位清单，再执行第 5—6 步；用户未要求修复时保持只读。

**完成标准：** 每项需求行为都已归类为状态、写入、读取、通知、表现、外部转换、生命周期或验证；使用的权威来源和执行分支均已明确。

## 2. 生成落位清单

编码前输出一份落位清单。每个实际产物占一行：

| ID | 需求行为 / 产物职责 | 状态或生命周期 owner | 新建 / 复用 | 精确目标路径 | 入口与对外合同 | 允许依赖与可观察输出 | 验证方式 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P1 | ... | ... | ... | ... | ... | ... | ... |

逐项判定以下职责；不需要的职责写明“不需要”及依据，不创建空槽位：

- 业务真状态、确定性规则和拒绝原因。
- Synced Command、Internal Operation、Plan、Settlement 或 Reaction。
- Query、Snapshot、Data、Event 与对外 Contract。
- CyStarRoad 功能根、ViewData、页面 Host 和封闭 Root Intent Executor。
- Unity-only 页面、UICom、ViewMono、Scene 与资源生命周期。
- 功能内或跨功能的 Pure Presentation。
- 表格、Proto、网络、Unity 服务、同步与恢复 Adapter。
- Composition Root 装配、Kernel 测试、EditMode 测试及资源验证。

以状态所有权确定 Kernel owner，以独立页面入口和生命周期确定 CyStarRoad 功能根。跨 owner 原子行为明确使用 `Prepare / Commit`、Plan 或 Settlement；已提交事实后的独立响应明确使用 Event / Reaction。每个路径精确到目录与文件职责，优先复用现有深模块接缝。

**完成标准：** 每项需求行为至少映射一行；上述每类职责都有结论；每行只有一个 owner、一个目标路径和可验证的接缝；清单中没有 `TBD`、无所有者公共代码或无职责包装层。

## 3. 执行落位门禁

在修改代码、Prefab、Scene、生成物或资源引用前，向用户展示完整落位清单并请求明确确认。需求或架构判断变化时，更新受影响的行并重新确认。

**完成标准：** 用户已明确接受当前版本的落位清单；未确认时不进入实现分支。

## 4. 按清单实现

只创建或修改落位清单中的产物。每出现一个未列出的职责、owner 变化、目标路径变化或新依赖接缝，先更新清单并重新经过门禁。只创建承载真实职责的文件和目录；生成物、Prefab、Scene 与资源引用使用 `AI-RULES.md` 指定的权威流程。

**完成标准：** 每个实际改动文件都能追溯到一个已确认的清单 ID，且没有与需求无关的 diff。

## 5. 执行落位审计

用 Git 状态和 diff 枚举全部新增、修改、删除与生成文件，逐一对照清单，并检查这些通过条件：

| 区域 | 通过条件 |
| --- | --- |
| `Shared/Common` | 只含跨宿主、非玩法的纯 C# 基础合同 |
| `Shared/GameLogic/<Owner>` | 真状态、规则、同步根意图、Query、Event 与持久化都归实际 owner；依赖保持零 Unity、零 CyStarRoad、零生成 Proto / 网络宿主 |
| `Shared/GameLogic/Common/Sync` | 只承载跨功能同步、信封、权威重放、根快照、StateHash 与恢复合同 |
| `CyStarRoad/Game/<Feature>` | 只通过窄 Query、EventBus 和封闭意图端口接触 Kernel；持有表现编排与页面生命周期，不复制业务状态和规则 |
| `CyStarRoad/UILogic` 与 ViewMono | 只消费 ViewData、管理 Unity 对象并上报类型化页面语义；不持有 Kernel 能力或 `GameLogicHandle` |
| `CyStarRoad/Game/**/Presentation` | 只消费已提交的表现输入和受控视觉端口；会话可取消，不保存业务真状态 |
| `CyStarRoad/Adapters/GameLogic` | 只实现 Shared 端口或完成表格、Proto、网络、Unity 服务转换；不解释业务结果、不刷新 UI |
| Composition Root | 显式装配窄端口和生命周期，不向功能对象分发 Service Locator |
| 测试与生成物 | 测试按 Kernel owner 或表现功能镜像；生成物来自权威源与正式生成流程 |

另外核对：只有同步根意图命名为 `*Command`；同一信封内的派生工作使用 Operation、Plan、Settlement 或 Reaction；普通 Event 触发 Query 刷新，一次性不可查询结果才使用 Effect Event；Completion Event 表达根意图终态。

**完成标准：** 实际文件集合与清单逐项一致，所有区域通过条件成立；偏差已在授权范围内修正，或以具体文件、规则和阻塞原因显式报告。

## 6. 回报结果

最终回报包含：

1. 已确认落位清单的版本或变更摘要。
2. `实际文件 → 清单 ID → 落位结果 → 依赖结果` 审计表。
3. 已运行的编译、测试、静态搜索或资源验证及其结果。
4. 仍存在的偏差、`BLOCKED BY MIGRATION` 项和所需决定。

**完成标准：** 每个实际改动文件均已回报；失败和跳过项清晰可见，不以未验证状态宣称完成。
