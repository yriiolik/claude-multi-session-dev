---
name: multi-session-dev
description: >-
  多 session 协作开发编排（仅供"主 session"用）。当**发起需求的主 session**想把一个开发需求
  按模块拆开、派发给多个独立后台 session（默认 Claude Code；用户明确要求 codex /
  codex-app / App 可见模式时走 Codex App 脚本）并行开发、最后由主 session 做整体业务效果
  验收时使用：主 session 只负责把业务需求归属到项目既有模块（识别受影响模块/数据流/实现策略，模块
  划分是项目自带的、只映射不自创，**一个模块派一个子 session、绝不合并**）、为有接口
  交互的模块安排契约先行或提供方先行、从验收口径设计 e2e 测试场景、派发/监控/验收，绝不自己写/调/测/读代码；
  每个被派发的 session 完成后回填一份简短回执（真实改动/预期变化/影响面/缺陷）。触发词：用多
  session 完成任务、多 session 完成这个需求、用多个 session 干活、多 session 开发、模块拆分派发、
  fleet 编排、主 session 指挥、background session 并行开发、契约先行、cc-dispatch、codex 模式、codex-app 模式、App 可见模式。
  ⚠ 被派发的**子 session（worker，名字带 ↳ 前缀 / 环境变量 FLEET_ROLE=worker / 首条消息带
  ⟦FLEET-WORKER⟧ 哨兵）不要使用本技能**——你是干活的 worker，按任务卡写代码+自测+回执即可。
---

# Multi-Session 协作开发（主 session 编排）

把一个开发需求**按项目既有模块边界归属**到各模块，派发给多个**独立后台 session**并行开发，主 session 全程**不碰代码**，
只做拆解 → 派发 → 监控 → 收回执 → 整体验收 → 定位回修。默认走 Claude Code 后台 session；
当用户明确说“codex 模式”、“codex-app”或“App 可见模式”时，统一走 Codex App 可见模式脚本。
两种实际模式都复用同一套 RQ、集成分支、worktree、任务卡、回执与验收流程；底层实现细节由脚本处理，
技能只负责选择正确脚本并保持编排流程。

## ⛔ 先自检：你是主 session 还是被派发的子 session？

**如果你是被派发的子 session（worker），立刻停用本技能。** 满足任一即为 worker：
- 你的会话名以 `↳` 开头；
- 环境变量 `FLEET_ROLE=worker`（`echo "$FLEET_ROLE"` 或读 `$CLAUDE_JOB_DIR/name`）；
- 你收到的**首条消息**以 `⟦FLEET-WORKER⟧` 哨兵行开头、或写着"你是一个模块 session"。

worker 该做的：**按收到的任务卡在自己范围内写代码 + 自测 + 回填回执**（见首条消息里的回执契约），
**不要**再调用 `cc-dispatch` 往下派发、**不要**拒绝写代码、**不要**把活又拆给别人。
本技能下面所有"编排"动作只属于主 session。确认自己是主 session（名字无 ↳、无 FLEET_ROLE、
是人直接发起的会话）后再继续。

## 何时激活本技能

- **由模型自动判断**：当前是主 session，且用户表达了"把这个需求拆成模块、派发多个 session/
  background agent 并行开发、我（主 session）只统筹和验收不亲自写代码"这类**编排意图**时自动加载。
  典型触发：用户说"**用多 session 完成（这个）任务 / 用多个 session 来做 / 多 session 完成这个需求** /
  多 session 协作 / 拆模块派发 / 用 fleet 编排 / 你当总指挥分派下去 / 并行开多个后台 session 做"。
  ——只要用户点名"用多 session / 多个 session 去完成某个开发任务"，即视作编排意图、加载本技能。
- **用户显式调用**：用户输入 `/multi-session-dev`。
- **不激活**：普通单 session 开发（用户就让你自己把活干完）、被派发的子 session（见上方自检）、
  纯运维/查询类请求。需求小到一个 session 能利落做完时，别为了用编排而编排。
- **只读理解类不要开子 session**：用户只是让你「根据代码确认 / 了解某功能需求 / 摸现状」这种**纯只读**
  请求 → 用 **subagent**（`Agent` 工具、`Explore` 类型）拿结论即可，**不要派子 session**——开子 session
  的门槛是"要在领域模块内部真正改代码"（见「角色铁律 · 🚫 主 session 不读源码」）。
  ⚠ 反过来：`Agent` 工具**只能用于这类只读探查**；**一旦 worker 要改代码，就必须改用派发脚本**（默认 `cc-dispatch`；codex/codex-app/App 可见模式用 `cc-dispatch-codex-app`），
  绝不能用 `Agent`（哪怕 `run_in_background:true`）当开发派发通道——详见「派发通道铁律」。

## 角色铁律（最重要）

**你（主 session）= 编排者，绝不写/调/测/读任何业务代码。** 你的脑力全花在「业务需求 → 模块需求」
的拆解、契约编排、测试场景设计与验收裁定上。你只做这些：
1. **拆解（归属，非发明）**：把业务需求**归属到项目既有模块**——识别**受影响模块**、**数据流/数据
   来源**、**实现策略**（见下方「业务需求拆解」）。⚠ **模块/领域划分是项目自带的，你只做映射、禁止
   自创模块切法；**默认**一个模块 = 一张任务卡 = 一个子 session（可按代码独立性更细拆——模块内大改动 /
   不同业务流程再切、或抽公共模块消重，但绝不把多模块合并），见「派发粒度铁律」。** 落在不同既有模块、
   互不冲突的子任务可并行；有接口交互的走「跨模块协同两模式」（契约先行 / 提供方先行），不许合并派发。
2. **派发**：默认用 `cc-dispatch` 给每个模块派发一个独立后台 session；用户明确要求 **codex / codex-app / App 可见模式** 时只把派发命令换成 `cc-dispatch-codex-app`。两种实际模式都让 worker 在自己范围内开发 + **自测**。
   ⛔ **派发开发 worker 的唯一通道是派发脚本（默认 `cc-dispatch`；codex/codex-app/App 可见模式 `cc-dispatch-codex-app`）——绝不是内置 `Agent` 工具**。
   `Agent`（含 `run_in_background:true`）起的是**挂在你名下的 subagent / Task**，不是独立 session，
   **不会出现在 `claude agents` FleetView**、无法独立合回、也不走回执/监控那一套——它只配做只读探查。
3. **监控**：派发完**立刻 arm watcher（默认 `cc-fleet-watch`；codex/codex-app/App 可见模式 `cc-fleet-watch-codex-app`，交给 Monitor 跑）**让完成/异常**推送**给你——
   **零轮询、不傻等**；需要点查时默认跑 `cc-fleet-status`，codex/codex-app/App 可见模式跑 `cc-fleet-status-codex-app`。
4. **收回执**：用 `cc-fleet-summary` 收齐每个 session 的**会话回执**，据此知晓真实改动面。
5. **验收**：从需求验收口径**设计 e2e 测试场景**（测哪些场景由你定），但**执行派给独立 session**
   （联调 session / 验收 session）；你只读它的报告 + 各模块回执来**裁定**是否达标。
6. **回修**：不达标 → 定位是哪个模块的问题 → 派发**新 session**去修，回到第 3 步。

模块内部的开发/调试/单测/e2e，全由各模块 session 自己负责，你不替它写代码、不替它调、不替它测。

### ⛔ 派发通道铁律：开发 worker 只能用派发脚本，绝不用内置 Agent 工具（硬边界）

本技能有**两条互不替代**的下派通道，按"worker 要不要改代码"二选一，**选错就是 bug**：

| 通道 | 用途 | 机制与可见性 |
|------|------|------|
| **内置 `Agent` 工具**（`Explore` / `general-purpose`，含 `run_in_background:true`） | **只读探查**：拆解前摸字段/接口/数据流现状，把结论拿回来。**绝不让它写/改/提交代码** | 挂在主 session 名下的 **subagent / Task**，从 spare 池认领 → `source=spare`、**无 `↳` 名**；**不作为独立会话出现在 `claude agents` FleetView**；无独立 worktree/合回/回执/监控 |
| **`cc-dispatch`（默认 Claude 模式）** | **开发交付**：要在某模块内部真正写代码 + 自测 + 合回的 Claude Code worker | 经 daemon 派发的**独立顶层 background session**（等价 FleetView "New agent"）→ 带 `↳<模块>@<RQ>` 名；**在 `claude agents` 列表可见**；走完整 sid 名册/watcher/回执 |
| **`cc-dispatch-codex-app`（codex / codex-app / App 可见模式）** | **开发交付**：用户明确要求 Codex 时，每个模块创建一个 Codex App 可见 worker thread | 与默认模式使用同一套 RQ、集成分支、隔离 worktree、任务卡、sid 名册、watcher 和回执。模型/思考深度沿用当前 Codex 设置，默认速度 1x；只有用户明确要求快速模式才传 `--fast`。Codex App 相关实现细节由脚本自动处理；技能不要展开或手动改这些参数 |

- 🚫 **绝不用内置 `Agent` 工具（哪怕 `run_in_background:true`）去派"要改代码"的 worker。** 那样起出来的是
  **嵌套 subagent**：在 `claude agents` 里**根本看不到这个子 session**（或只是一个无名 `source=spare` 的 running 条目），
  无法独立合回、收不到回执、watcher 也监控不到——整套 fleet 编排机制全部失效。**要改代码 → 必须用派发脚本**（默认 `cc-dispatch`，codex/codex-app/App 可见模式 `cc-dispatch-codex-app`）。
- ✅ `Agent`/`Explore`（含后台模式）**仅限只读探查**：结论回到主 session 即用完即弃，不沉淀代码、不需要被 FleetView 跟踪。
- 🩺 **自检症状（命中即说明你选错了通道，立刻改用 `cc-dispatch` 重派）**：你声称"已派子 session 在跑"，
  但 `claude agents` / `cc-fleet-status <RQ>`（codex/codex-app/App 可见模式看 `cc-fleet-status-codex-app <RQ>` 或 Codex App 侧边栏）里**找不到对应的 `↳<模块>@<RQ>` 条目** → 你多半误用了内置 `Agent` 工具，
  那个"worker"只是你名下一个看不见的 subagent，不是独立 session。

### 🚫 主 session 不读源码（硬边界）

- 影响面、数据流、模块边界**靠业务知识 + L1 业务需求文档 + 模块边界约定**判断，**不靠读源码**。
- 确实需要探查代码现状才能拆准（如「这字段现在哪些接口返回 / 哪个模块在写它」）→ **默认用 subagent
  （`Agent` 工具、`Explore` 类型）只读探查**，把结论拿回来用于拆解。subagent 天然只读、findings-only
  不污染主 session 上下文，且**不走 daemon / worktree / 回执 / 监控那一整套**，比开子 session 轻得多、快得多。
  这与本硬边界不冲突：**是 subagent 在读、主 session 拿结论，主 session 仍不亲自 grep/Read 业务源码。**
- **⭐ 开"子 session"（默认 `cc-dispatch`，codex/codex-app/App 可见模式 `cc-dispatch-codex-app`）的唯一门槛 = 要在某领域模块内部真正开发 / 改代码**（写代码 + 自测 +
  回执 + 合回）。凡**只读**的活——根据代码确认 / 了解某功能需求、摸字段·接口·数据流现状——一律走
  subagent 拿结论，**别为此开子 session**。子 session 是为"交付一个模块"准备的重型通道；只读探查捞个
  结论用它是杀鸡用牛刀，还要额外背 sid 名册 / watcher / 回执闩锁那一摊。
- 仅当探查量**极大** / 需独立完整上下文窗口 / 要跑长命令链时，才退回派只读 scout **子 session**
  （`--name "↳scout@<RQ>"`，preamble 写明「只读不改、只回报结论」）——这是**例外**，不是默认。
- 一旦发现自己在读/改模块源码，就是越界——退回去，交给 subagent 探查、或写成任务卡（实在要独立 session
  才用 scout 卡）派出去。

## 业务需求拆解（主 session 唯一的核心脑力活）⭐

主 session 拿到一条业务需求后，先做这套**四问拆解**，把「业务需求」翻译成「若干互不冲突、可并行
（或契约先行后并行）的模块需求」。拆解只用业务知识 + L1 文档，**不读源码**（要查现状用 subagent 探查，见上）。

> 🚫 **模块/领域划分是项目既有的，你只做「归属映射」，禁止自己发明或重新划分模块。**
> 模块边界以**项目自身约定**为准——**先查项目的模块地图/模块清单**（如 factory `CLAUDE.md` §12「模块
> 地图」：业务域 → 后端/前端目录 + 需求文档编号 + 是否跨模块；及 `docs/requirements/<NN>/` 编号模块
> 目录），据此把需求**归属**到既有模块。拆解 = 把业务需求**落到项目已有的那些模块**上，**不是**由你
> 创造一套新的模块切法、也不是按你觉得合理的维度重切。**确实找不到对应既有模块** → 按项目规则判断
> 是否需要**新建模块**（通常要独立 commit + 告知/请用户裁定，如 factory `CLAUDE.md` §7「何时新建模块」），
> **不擅自新建**。

**① 这个能力落到哪些既有模块？（受影响模块——对照项目模块清单归属，不自创）**
   一个字段/能力往往牵涉多个端、多个单据、多个读取方。**对照项目既有模块清单 / 业务需求文档目录**，
   把它落到的既有模块定位全——展示方、写入方、读取方都算。漏一个就会出现「前台加了字段、后台没传」
   这类断层。

**② 数据从哪来、谁负责把它弄进来？（数据流 / 数据来源）**
   新字段/新数据的**源头**在哪、**通过什么时机和通道**进入系统。常见两类落点：
   - **运维任务批量同步**（独立 ops 任务，把数据从外部/上游灌进来）；
   - **业务动作触发时主动抓取**（如生成某单据时顺带拉一次）。
   找出「谁是这条数据的生产者」，它就是一条独立的模块需求。

**③ 实现策略选型（根因优先；能判优劣就自决并派，判不了才问人）**
   同一目标有多条路径时：
   - **能判断哪条更优** → 直接自决，把依据写进 L1 文档/任务卡，派给对应模块（呼应「根因修复优先」）。
   - **两条各有取舍、无法确定** → 用 `AskUserQuestion` 向人确认后再派，别拍脑袋、也别两条都做。
   - 选型默认偏向**根因修复**（让数据在正确时机以正确方式进入系统），而非绕过/兜底/加开关。

**④ 哪些是跨模块接口交互？怎么编排先后？（引出协同编排）**
   识别「提供方—消费方」关系：某模块要调另一模块的新接口 / 多模块共享新数据结构 → 命中**跨模块协同**
   （见下方「跨模块协同两模式」）——模式 A 契约先行（先派提供方定契约、定稿再并行）或模式 B 提供方
   先行（提供方完整开发完，消费方再按真实接口接入）；纯展示型、各改各的、互不调用 → 不需要协同编排，
   直接并行派发。**若发现多个模块会重复实现同一段逻辑 / 数据结构 / 校验 → 就地把它收敛成一个「公共模块」
   先行产出，其余模块作为消费方依赖它（公共模块 = 提供方，同样走两模式编排），减少重复、便于维护**（见
   「派发粒度铁律」维度⑤）。**不论命中与否，每个模块都是独立 session（粒度铁律），依赖关系靠编排不靠合并。**

> **范例（「大货样字段」需求）**——业务需求：发货计划要增加「大货样」字段，数据来源是 ××× 系统。
> - **① 受影响模块**（对照项目既有模块清单归属）：落到采购后台的「发货计划」、工厂前台的「发货计划 /
>   生产计划」这几个**既有模块**——都要**展示**这个字段（至少 3 个展示点，分属采购端与工厂端两个模块）。
> - **② 数据来源**：大货样数据来自 ×××，要有人把它弄进系统。两条候选路径：(a) 加一个**运维任务**批量
>   同步；(b) **生成采购单/发货计划时主动抓取一次**。
> - **③ 选型**：若判断「生成发货计划时抓取」更优（数据随单据产生即时落地、无需额外调度）→ 自决，把
>   「抓取大货样」这条需求**派给采购单/发货计划生成模块**实现；若两条确实拿不准 → `AskUserQuestion`。
> - **④ 接口交互**：若展示方读的是生产方写入的同一数据结构 → 让生产方先定好字段/接口契约，各展示端
>   再按契约并行接入。
> 拆解产物：1 条数据生产模块需求（采购侧抓取/同步）+ N 条展示模块需求（采购后台、工厂前台各端），
> 必要时一份共享字段契约。每条进 L1 文档 + 一张任务卡。

## 派发粒度铁律：专注 + 代码独立 + 工作量可控（默认一模块一 session，可更细，绝不合并多模块）⭐🚫

**切分子 session 的目的**：让每个子 session **专注做一件相对独立、代码上不与他人耦合、工作量可控的事**——
唯有如此才能真正并行、回执能按 session 归因、`cc-fleet-land` 合回不撞车、单个 worker 能利落交付 + 自测。
所以粒度的唯一判据是：**这块内容在代码上是否相对独立、一个 worker 能否聚焦地把它交付掉。** 据此**两个
方向都要防**——切太粗（该分不分 → 改动面失控、耦合、合回冲突），也切太细到无意义（徒增协调开销）。项目既有
模块边界是最稳的切分线，所以**默认一模块一 session**；但模块不是唯一维度，下列维度按需组合、全部服从上面的判据。

- **维度①·按角色切**：开发 / 联调 / 验收本就是不同 session（见「测试三层」）；同理**契约或公共接口设计**、**代码
  review** 也各自独立 session。别让一个开发 session 顺手把设计、验收、review 也做了——角色混在一起就不专注、
  也无法独立归因。
- **维度②·按业务流程切**：一次需求含**多条相对独立的业务流程**时，不同流程的改动**尽量分到不同 session**——哪怕
  它们落在相近甚至同一模块。不同流程天然代码耦合低，分开后各自聚焦、并行、互不阻塞。
- **维度③·按模块切（默认粒度）**：业务需求落到 N 个既有模块 → 默认 N 张卡 N 个 session。**禁止**因"几个模块改动
  都小 / 业务相关 / 顺手一起改"把多个模块合并进一张卡、一个 session——那等于在执行层打散项目的模块边界，
  改动面失控、回执无法按模块归因、合回冲突。
- **维度④·模块内大改动再切**：一个模块本次改动量很大、且能拆成**代码上彼此独立的几块**（不同文件 / 不同子流程、
  不会互相改同一处）→ 可拆成多个 session 分头做，压住单 session 工作量。**前提是拆出来的块代码独立**：若几块
  必然改同一批文件，别硬拆（`cc-fleet-land` 必冲突），要么合成一个 session，要么先抽公共模块（见维度⑤）。拆出的
  每个 session 给**不同子模块标签**（如 `FLEET_MODULE=<module>-<flowA>` / `-<flowB>`），让各自 `.sid`/`.summary` 不打架。
- **维度⑤·抽公共模块，从设计上消重**：拆解时发现多个 session 会**重复实现同一段逻辑 / 数据结构 / 校验 / 工具**→
  主 session 在设计阶段就把它**收敛成一个"公共模块" session**（共享类型 / 工具 / 公共 service），**先行产出**，其余
  session 依赖它接入。这样全项目重复代码更少、更好维护，并把"多个 session 各写一份"转成"一个 provider + N 个
  consumer"——正好落到「跨模块协同两模式」（公共模块 = 提供方，走契约先行或提供方先行编排）。

**依赖关系靠编排、不靠合并**（切细后各 session 间的先后同样适用）：
- 命中「提供方—消费方」接口交互（含公共模块）→ 走下节「跨模块协同两模式」（模式 A 契约先行并行 / 模式 B
  提供方先行串行）；
- 纯先后依赖（无新接口，只是 B 要等 A 的数据/行为先落地）→ 排出派发顺序，前序回执 done 再派后续；
- 互不冲突 → 直接并行。

**自检信号（每张卡派发前必查）**：
- 任务卡「业务需求锚点」出现**两个及以上不同模块**的需求文档编号（如同时锚 `docs/requirements/14-…`、`23-…`、
  `15-…`）= 切太粗，按模块拆开重写再派（维度③）。
- 一张卡要改的文件横跨**多条明显不相干的业务流程** → 考虑按流程再切（维度②）。
- 多张卡都在实现"看起来一样"的逻辑 → 该抽公共模块，别让它们各写一遍（维度⑤）。

**两个例外（不破坏"专注 + 代码独立"）**：
1. **同一模块内、代码耦合紧的多条子需求**合一张卡——本就该同一个 session 交付，不算合并（与维度④相反：耦合
   紧就别硬拆，否则合回撞车）。
2. **登记类散点**：新页面/新接口必须同步的注册点（如前端菜单 `menu-config.ts`、路由注册、rbac 角色门禁）——项目
   模块地图本就标注"加新页面 = 对应域 + 平台域必同步"，这类一两行登记**随功能模块卡一并改**，但必须在任务卡
   「上下游协作」段**显式授权**（worker 的范围铁律只放行被授权的登记点）；若多个并行 session 要碰**同一个**登记
   文件，主 session 排定合回顺序，后合者负责 rebase。

## 分支隔离铁律：每 RQ 一条集成分支，共享分支只在验收后动一次 ⭐🚫

**这是防"半成品过早污染共享分支、串台其它并发任务"的根本机制（2026-06-13 起）。** 老坑：preamble 让每个
worker 自测绿后**直接合回共享开发分支**（`dev/<name>`）。但"单个模块完成 ≠ 整体需求完成"——契约先行里
提供方先合、消费方/联调/验收都还没跑，或多模块里只做完一半。半成品一落共享分支，**同项目其它并发 RQ 的
worker（base 也是 `dev/<name>`）和用户本人就把它吃进去** → 出问题；叠加 bg `EnterWorktree` 默认从
`origin/main` 拉（baseRef=fresh，不吃项目 settings），还会"从 main 拉出来合回当前分支"把事情搞砸。

**根治 = 两级分支隔离：**
- **每个 RQ 一条专属【集成分支】`fleet/<RQ>`**，由主 session 在 Step 1 用**发起任务时的当前分支**
  （`$FLEET_BASE`，如 `dev/langyi`）创建（`cc-fleet-coord --init-base <RQ>`，并把 base 名记进
  `<COORD>/base.ref`）。它是本 RQ 的**隔离单元**：并发的多个 RQ 各自一条 `fleet/<RQ>`，互不可见、互不污染。
- **worker 的 base = `fleet/<RQ>`，改动也只合回 `fleet/<RQ>`**（派发时 `--env FLEET_BASE_BRANCH=fleet/<RQ>`
  注入）。worker `EnterWorktree` 后**第一件事 `git reset --hard "$FLEET_BASE_BRANCH"`** 强制锚定（防 bg
  EnterWorktree 从 origin/main 生的 worktree 没有项目代码），自测绿后跑 **`cc-fleet-land <RQ>`** 把改动安全
  合入 `fleet/<RQ>`（内部 CAS 重试，多个 worker 并发落地零丢更新），**绝不 `merge`/`push` 共享分支**。
- **共享开发分支只在主 session 整体验收通过后动一次**：主 session 把 `fleet/<RQ>` 合回 `$FLEET_BASE`
  （读 `base.ref`）+ push + 删集成分支（Step 4/5）。**完整开发+验收完成前，`dev/<name>` 一行不动** →
  其它并发任务、用户本人**完全不受干扰**（这正是用户要的"完全不干扰"）。

> 为什么 worker 能"自己合进一条没被 checkout 的分支"且抗并发：`fleet/<RQ>` 只是 `.git` 里共享的一条 ref，
> 没在任何 worktree 被 checkout，所以不能直接 `git merge` 进去。`cc-fleet-land` 用 **compare-and-swap**——
> 先把 `fleet/<RQ>` 现 tip 合进 worker 自己分支、再 `git update-ref fleet/<RQ> <new> <old>` 原子推进，
> 被别的 worker 抢先就重读重试。收敛、零丢更新；冲突（RQ 内按模块粒度本就罕见）留给 worker 解决后重跑。

## 跨模块协同两模式（多模块接口交互必读）⭐

拆解第④问命中「提供方—消费方」接口交互（A 模块要调 B 模块的新接口、或多模块共享新数据结构）时，
**不要一上来就把提供方和消费方一起并行派**——契约没定，消费方按猜的接口写，必返工、必冲突；**也不许
因此把两个模块合给一个 session**（粒度铁律）。由主 session 在两种协同模式里选一种编排
（判据与细节见 `reference/contract-first.md`）：

- **模式 A · 契约先行（默认，并行抢墙钟）**——三段式：
  - **段① 契约设计（串行卡点，只派 1 个 session）**：先只派 **API 提供方 session** 做**接口/契约层设计**
    ——接口签名、请求/响应 schema、字段语义与单位、错误码、事件结构。产物落**协调目录**
    `<COORD>/contracts/`（一份可被所有相关 session 引用的契约文件）。**主 session 评审契约**（业务面：
    字段齐不齐、口径对不对、错误码覆盖没），定稿后才进段②。
  - **段② 分头开发（契约定稿后并行）**：提供方按契约实现真逻辑；消费方按契约接入、**对端用 mock/桩自测**
    （不依赖提供方先做完）。此时双方代码互不冲突、真正并行，各自跑自己的单测/模块 e2e。
  - **段③ 联调（独立 session）**：段②都 done 后，派一个**独立联调 session**把相关模块真实拼起来
    （去 mock、真接口）跑通，回报集成是否通、哪条接口对不上。联调属「测试」不属「开发」，由独立 session
    做（见「测试三层」）。
- **模式 B · 提供方先行（串行，等真实接口）**：先派**提供方一个 session 完整设计 + 开发 + 自测**
  （真实 API 落地 + L2 文档 + 回执），done 后主 session 从其回执/契约提取**实际接口形态**作为消费方
  任务卡的依赖锚点，**再派**消费方按真实接口开发（无需 mock，自测直接打真接口，联调层通常可省）。
  适用：接口形状强依赖实现探索、预先定稿大概率被实现推翻；或消费方接入量很小，等提供方做完的成本
  低于"mock 对接 + 联调"的开销。
- 两种模式下提供方/消费方**都各是独立子 session，绝不合并**（粒度铁律）；选哪种由主 session 定，
  拿不准默认模式 A。

> 何时**不**需要协同编排：纯展示型、各端各改各的、模块间互不调用同一新接口 → 直接并行派发、跳过本节。

## 文档分层与承上启下（防子模块跑偏）⭐

让子模块**知道整体业务需求**、**知道改动针对哪些业务需求文档及其变化**、并在模块内形成
**承上启下**的需求文档（向上比对业务需求、向下关联模块设计）。三层文档 + 严格 ownership：

| 层 | 内容 | **谁写** |
|---|---|---|
| **L1 业务需求文档** | 整体业务目标、跨模块场景、业务级验收（业务语言，单一事实源） | **主 session** |
| **L1.5 模块委托（任务卡）** | ①整体业务上下文 ②本次针对哪些业务需求文档/章节+变化 ③本模块验收清单 | **主 session** |
| **L2 模块需求+设计** | 本模块需求（↑挂 L1）+ 功能/技术设计（↓到代码/测试） | **子 session（主 session 绝不代写）** |

- **承上启下 = 双向追溯链**：L2 每条模块需求向上挂 L1 的具体条目/锚点、向下挂模块设计与测试。
  验收即查链（每条业务需求都有模块承接、每个模块改动都能回溯到业务需求）。
- **🚫 已排除的错误路线：主 session 代写 L2 模块需求文档。** 主 session 从不读模块源码/设计，
  写出的"向下链"必然 stale；且违反 ownership 自治、制造瓶颈。**L2 由最接近实现的子 session 写**，
  与代码同仓同 commit 演化（docs-as-code）。主 session 只**定标准 + 画桥（委托/锚点）+ 评审链一致性**。
- 完整模型、L2 文档模板、业界依据（RTM/ISO 29148/ASPICE、Kiro/Spec Kit、DDD bounded context、
  C4/ADR、docs-as-code）见 **`reference/doc-traceability.md`**。

## 安装位置 / 脚本

脚本固定装在（从任意 cwd 都用绝对路径调）：
```
~/.claude/skills/multi-session-dev/scripts/
  cc-dispatch         # 直派单个后台 session（核心，任何仓库都能用；--sid-file 记关联键）
  cc-dispatch-codex   # 兼容别名：codex 模式等同 cc-dispatch-codex-app
  cc-dispatch-codex-app # Codex / Codex App 可见模式派发入口；默认参数足够，显式快速才加 --fast
  cc-dispatch-batch   # 结构化布局下批量派发整个 RQ（可选）
  cc-fleet-init       # ⭐派发前唯一入口：一句 eval 完成 GC + 取全新单调 RQ(持久池,永不重号) + 解析 COORD + 建集成分支；输出可 eval 的 $RQ/$COORD/$INT
  cc-fleet-coord      # cc-fleet-init 的底层子命令（高级用）：--alloc 取空号 / --init-base 建集成分支 / --gc 清>7天旧目录 / 默认解析 / --fresh 防撞
  cc-fleet-land       # ⭐worker 收尾用：把改动安全合入集成分支 fleet/<RQ>（CAS 重试抗并发、零丢更新；绝不碰共享分支）
  cc-fleet-status     # 按 RQ 用 SID 名册关联查 session 状态（点查/JSON）；带 result: 的 canonical 回执=已完成(抗 respawn)
  cc-fleet-status-codex # 兼容别名：等同 cc-fleet-status-codex-app
  cc-fleet-status-codex-app # Codex / Codex App 可见模式状态点查
  cc-fleet-watch      # ⭐阻塞监视：把"子 session 结束"转成主 session 的【推送通知】（防傻等核心；回执闩锁抗 respawn）
  cc-fleet-watch-codex # 兼容别名：等同 cc-fleet-watch-codex-app
  cc-fleet-watch-codex-app # Codex / Codex App 可见模式 watcher：给 Monitor 推送完成/异常
  cc-fleet-reply-codex-app # Codex / Codex App 可见模式回复 worker
  cc-fleet-respawn    # ⭐疑似灰度坏模型/质量降级时：kill 旧 worker + 归档旧回执 + 用同卡另起全新 worker 重跑（见「铁律 4」）
  cc-fleet-summary    # 多通道（含所有 worktree）汇总各 session 回执给主 session 看
  cc-fleet-fix-display # 修已完成 worker 在 FleetView 名字退化成 "bg"、时长退化成 "0s" 的显示（见下「显示修复」；watch/summary 已自动调用）
                       #   <RQ>  per-RQ 精修（靠 cc-fleet-status 名册）｜ --all  全局兜底（按各 job 自己 cwd 回溯 sid 名册，不要 RQ/不依赖编排者 cwd；非 worker 会话 SessionStart 已节流自动调用）
~/.claude/skills/multi-session-dev/reference/
  PROTOCOL.md           # daemon 协议参考（cc-dispatch 失效时照它修）
  dispatch-preamble.md  # 派发 prompt 必带前缀（锁范围+自测+承上启下文档+回执契约）
  codex-app-dispatch-preamble.md # Codex / Codex App 可见模式 prompt 前缀；由脚本自动使用
  doc-traceability.md   # ⭐ 文档三层模型 + L2 模块需求文档模板 + 业界依据（防跑偏）
  contract-first.md     # ⭐ 跨模块协同两模式(契约先行/提供方先行) + 判据 + 契约文件模板 + 与三层测试关系
  task-card-template.md
```
为方便引用，建议在用的仓库里：`ln -s ~/.claude/skills/multi-session-dev/scripts scripts/fleet`（可选）。

## FleetView 显示修复（已完成 worker 名字变 "bg" / 时长变 "0s"）

**现象**：被 `cc-dispatch` 派发的 worker **完成后**，`claude agents` FleetView 的「Completed」区里，名字列退化成字面量
**`bg`**、时间列退化成 **`0s`**（只影响刚完成的；运行中的、以及更早完成的都正常）。

**根因**：FleetView 显示读的是磁盘上 `~/.claude/jobs/<short>/state.json`。daemon 在 worker **完成时**把这份记录重写成一份
极简形态——丢掉 `.name`（→ 回退显示 `.template`，spare 池后台模板名就是字面量 `bg`）、把 `.createdAt`/`.firstTerminalAt`/
`.updatedAt` **塌缩成同一瞬间**（→ 时长 = 终点 − 起点 = 0 → `0s`）。取名 hook（`auto-cn-title.sh`）只在 SessionStart/
UserPromptSubmit 补 `.name`，而完成后这两个事件都不再触发，所以补不回来。daemon 是闭源二进制改不了，但这份完成态
记录**写完即稳定**（此后不再被改写）——所以在完成后用权威数据把它**修回去**就能稳稳生效。

**对策（两层，自愈、无需人盯）**：

**① per-RQ 精修** `cc-fleet-fix-display <RQ>`：用名册名（`↳<module>@<RQ>`）+ 该 session transcript 的首/末时间戳，把磁盘
`state.json` 的 `name`/`createdAt`/`firstTerminalAt`/`updatedAt` 修回（幂等、原子、只动**已完成**的 worker，绝不碰运行中/
普通会话）。`cc-fleet-watch`（每有模块结算时 + 退出前）和 `cc-fleet-summary`（收回执时）都已**自动 best-effort 调用**它。

**② 全局兜底** `cc-fleet-fix-display --all`（⭐ 2026-06-24 / cli 2.1.187 复发后新增）：per-RQ 模式有两个**结构盲区**——
> · **触发盲区**：per-RQ 只在 watch/summary 监视【该 RQ】时触发；**跟进 worker**（如 `schedule-unify-fix`，在 watch
>   退出后才完成 / 被 daemon respawn）没人再修 → 永远卡 `bg`/`0s`。
> · **名册-cwd 盲区**：per-RQ 靠 `cc-fleet-status` 从【编排者当前 cwd】解析 `<git-common-dir>/fleet/<RQ>` 名册；worker
>   跑在**别的仓库路径**（实测 `/a/supply-agent` vs `/b/.../supply-agent` 两份 checkout）时解析不到那份名册 → 看不见。

`--all` 绕开两者：扫所有 job，按**每个 job 自己的 cwd** 回溯它**自己的** `git-common-dir/fleet/*/*.sid`（sid 内容 == sessionId
→ 模块名 + RQ）还原 `↳<module>@<RQ>`，再兜底 transcript 的 `⟦FLEET-WORKER⟧` 哨兵；**不要 RQ、不依赖编排者 cwd、不连
daemon**，只动【能确认是 fleet worker 且确实 `bg`/`0s` 退化】的 job（普通会话 / 仅缺 ↳ 前缀的健康 job 一律不碰）。
取名 hook（`auto-cn-title.sh`）在**非 worker 会话每次 SessionStart** 节流（≥120s）后台调一次 `--all --max-age-hours 48`——
所以**主/编排会话一启动就自动把漏网的全补上**，FleetView 自愈，无需人工。仅想立刻全量修时手动 `cc-fleet-fix-display --all`。

> ⚠ 这是 daemon 完成态落盘行为（PROTOCOL.md §8/§11 记录），历史上随版本变动过——若某次升级后**运行中**或**更早完成**
> 的 worker 也开始显示 `bg`/`0s`，说明退化形态变了，照 `cc-fleet-fix-display` 头注释更新判定/恢复来源即可。

## ⛔ 完成判定与回执获取（防主 session 死等 ｜ worktree/sandbox 安全）

> 这是本技能最容易踩的坑：**主 session 无限等待一个子 session，而它其实早已完成。** 四个根因：
> ① 把"回执文件出现了没"当成"完成了没"（worker 常跑在隔离 worktree+sandbox，回执写进**它自己
> worktree** 的相对 `.fleet/<RQ>/`，主 session 盯主仓库路径 → 那文件**永远不出现** → 死等）；
> ② **主 session 拿不到任何完成推送**——`cc-dispatch` 派的是独立 daemon session，**不被主 session 的
> harness 跟踪**，所以子 session 结束时主 session 收不到通知，只能自己轮询 → 模型要么 sleep 死等、
> 要么呆等用户，子 session 早 done 了也察觉不到（10~20min 盲等）；
> ③ **把 `state=working` 当"还在跑"**——daemon 的 `state` 是【分类器读最后一条消息】推出的，worker
> 活干完却没打 `result:` 就会停在 `working`，而它的 `tempo` 早已 `idle`（循环已停）。盯 `state` 就会
> 对一个**实质已结束**的 session 无限等；
> ④ **daemon 把已完成的后台 session respawn 回 `running+active`，把 `done` 擦掉**——spare 池保活/resume
> 会让一个早已 done 的 worker `state` 翻回 `running`、`tempo` 回 `active`、`startedAt` 重置、`name` 变空。
> 只看易失的 `state` 就把它当"还在跑"无限等，连静默兜底（根因③）都因为 `tempo=active` 而失效。**这个最
> 隐蔽**：worker 真的 100% 做完了（回执落盘、合回 main、清了 worktree），daemon 却又报它在跑。必须靠
> **持久信号**（canonical 协调目录里带 `result:` 的回执）做【单调闩锁】，respawn 抹不掉文件 → 抹不掉完成。
>
> 对策：**用 watcher 把"完成"转成原生推送（铁律 0）+ 完成判定与回执内容彻底分开（铁律 1/2）+ "还在跑"
> 看 `tempo` 不看 `state`、持续 idle 自动判静默（铁律 1.5）+ 持久回执闩锁抗 respawn（铁律 1.6）。**

**铁律 0 ｜ 不要轮询，arm 一个 `cc-fleet-watch` 让 harness【推】给你（解决根因②）。** ⭐
- 派发完**立刻**把 `cc-fleet-watch <RQ>` 交给 Claude Code 原生的 **Monitor 工具**（`persistent:true`）跑。
  它阻塞监视该 RQ（数据源就是 `cc-fleet-status --json`，单一事实源），**每个模块一结束就往 stdout 写一行
  → harness 把每行变成推回主 session 的通知**；全部结束写一条总结并退出（退出码=完成信号）。于是「子
  session 结束状态」被转成「主 session 原生推送」，**主 session 全程零轮询、零 sleep**——派完就去跟用户聊
  别的，done 事件会自动找上门。
- **≤5min 兜底**：cc-fleet-watch 内置**每 ≤4 分钟一条心跳**（`--heartbeat 240`），即使某个完成事件被漏掉，
  下一条心跳也会重新核对并报告 → 保证主 session **至少每 <5min 被唤醒一次**。要一个独立于 Monitor 的
  兜底完成信号，可另用 `cc-fleet-watch <RQ> --wait` 配 **Bash `run_in_background`**（静默阻塞、结束时单次
  完成通知）。两者互为冗余：任一存活就不会死等。
- `blocked`（等授权/输入）**不算结束**：worker 等输入时 daemon 报 **`tempo=blocked`**（`state` 仍 `working`，
  **2.1.167 实证**——别只看 `state` 把它当 active 在跑而死等；watch/status 已把 `tempo=blocked` 归入 blocked 路径）。
  watch 会推 `⏸ <module> blocked` 主动提醒 + 持续心跳，**绝不静默吞掉一个卡在等输入的 worker**。这时三条路（先按铁律 4 判是"真需要输入"还是"模型降级空转"）：
  - **回复它**：`cc-fleet-reply <RQ> <module> "继续，按 X 改"`——直接把回复 / 纠偏 / 追加指令注入该 worker 会话
    （等价 FleetView 里给它回话，但不必手点；支持 `--short`/`--text-file`/stdin）。**确属该由人拍板的合理 blocked 才用它**。
  - **换新 session 重派它**：`cc-fleet-respawn <RQ> <module> --prompt-file <当初任务卡>`——**疑似灰度坏模型 / 质量降级空转**时用（症状见铁律 4），kill 旧的 + 归档旧回执 + 用同卡另起全新 worker（大概率换到好模型）；reply 纠偏无效时的正解。
  - **取消它**：`cc-fleet-kill <RQ> <module>`（或 `<RQ> --all` 杀整个 RQ；`--signal SIGKILL` 强杀）。kill 只
    终止进程、不删回执，已落盘的 `<module>.summary.md` 仍可被 cc-fleet-summary 收。
- 见到完成/异常推送或心跳后，再按需跑一次 `cc-fleet-status`（点查权威）/ `cc-fleet-summary`（收回执）。

**铁律 1 ｜ 完成 = daemon `done`/`gone`（按 SID 名册关联）**或** canonical 回执带 `result:`——二者任一即完成。**
- 权威完成信号 = `cc-fleet-status <RQ>`。它读协调目录的 `*.sid` 名册，用 **sessionId/short** 关联 daemon
  状态。**别靠 session 名关联**——session 完成后 daemon 里的 name 会变空，靠 name 过滤会漏掉已完成的
  session，让你误判"还没跑完"而死等。SID 是稳定键。
- ⭐ **它【同时】把 canonical 协调目录里带 `result:` 的回执作为第二条权威完成信号**（`receipt=1`）：
  只要 `<COORD>/<module>.summary.md` 首个非空行是 `result:`，该模块即判**已完成**，**不管 daemon 此刻报
  什么 state**——这正是抗 respawn 的关键（见铁律 1.6）。所以退出码 `0` 的判据是"每个模块要么 daemon
  `done/gone`、要么回执在案"。
- ⚠ **"不是文件存在"指的是"别把 worker 自己 worktree 里相对路径文件的有无当门禁"**（那个不可靠，铁律 2）；
  **canonical 路径 + `result:` 首行的回执【是】权威完成信号**，不是"仅供参考的进度"。**别再像本次事故那样，
  明明回执已落盘、result: 写着"已合回 main、清了 worktree"，却因为"完成只看 daemon 状态"把它当进度参考、
  继续死等一个被 respawn 翻回 running 的 worker。** 看到 `cc-fleet-status` 标 🧾 / `receipt=1` = 已完成。
- 所以**派发时必须把 sessionId 记进 `<COORD_DIR>/<module>.sid`**（`cc-dispatch --sid-file` 自动做），
  且 worker 必须把回执写进 **canonical** `<COORD_DIR>/<module>.summary.md`（首行 `result:`）。
- 退出码：`0`=无在跑无异常（可收回执+验收，含"回执在案"判完成的）/`1`=进行中 /`2`=daemon 不可达 /`3`=异常终止态。
- **`gone`**（名册里有、daemon 列表已无此 session）= **已结束，去收回执**，不是"还在跑"——不卡你。

**铁律 1.5 ｜ "还在跑"看 `tempo`，不看 `state`——`working`+`idle` = 循环已停（做完没打 result:）。** ⭐
- daemon 每个 session 报【两个维度】：`state`（done/working/...，由**分类器读它最后一条消息文本**推出——
  打了 `result:` 才翻 `done`，最后一条是叙述就停在 `working`）和 `tempo`（active/idle，agent 循环**此刻
  是否在产出**）。**真正判"要不要继续等"的是 `tempo`**：`tempo=active` 才是真在跑；`tempo=idle` 表示
  循环已停（回到等输入态）。
- 经典死等就是这个坑：一个 worker **活早干完、只是最后一条没打 `result:`** → 永远 `state=working`+
  `tempo=idle`，旧逻辑把 `working` 当"还在跑"无限等。**`working`/`running` 但 `tempo=idle` ≠ 还在跑**，
  多半是做完没打 `result:`（也可能卡住）——去 `cc-fleet-summary` 收回执 / 读它最后一条消息核验，别死等。
- **`cc-fleet-watch` 已自动兜底**：持续 `tempo=idle` ≥ `--stall-idle`（默认 240s，带 2 轮去抖）的 run-class
  session 会被判【静默已结束】（推 `💤 …需核验`）纳入"全部结束"并唤醒你；总结里这种用 🟡 与硬 `done` 区分。
  *去抖必要*：`idle` 可能是瞬时（worker 等自己起的后台 E2E 时会短暂 idle 再被唤醒），所以要连续够久才判，
  且**一旦被判静默的模块又 `active` 会自动撤销静默**继续等。若 watch 因某模块静默而退出、你去核验时发现
  它又活跃了——**重挂一次 `cc-fleet-watch` 即可**（成本极低）。
- `cc-fleet-status` 点查也会在表后标出 `working/running`+`idle` 的静默候选，提醒别当它还在跑。

**铁律 1.6 ｜ 持久回执闩锁：daemon 会 respawn 已完成的后台 session，唯有持久回执抹不掉（解决根因④）。** ⭐
- daemon 的 spare 池会把一个早已 done 的后台 session **respawn/resume**——`state` 翻回 `running`、`tempo`
  回 `active`、`startedAt` 重置、`name` 变空。**这会把易失的 `done` 完全擦掉，连铁律 1.5 的"持续 idle 静默"
  兜底都失效**（因为 `tempo` 又变 `active`，看着像真在跑）。只看 daemon `state` 就会对一个 100% 做完的
  worker 无限等。
- **根治 = 用持久信号做单调闩锁**：worker 完成时按 preamble 把回执写进 **canonical** `<COORD>/<module>.summary.md`
  且**首行 `result:`**。`cc-fleet-status` 把它标成 `receipt=1`（表格里 🧾），完成判定**以回执为准、不管 daemon
  state**；`cc-fleet-watch` 见 `receipt=1` **立即推 `✅ <module> 已完成 — 回执在案`** 并【单调】结案——respawn
  之后再把 state 翻回 running 也**不反悔**（不标 quiesced、resurrect 不撤销）。文件持久，respawn 抹不掉它。
- 所以这条**强依赖 canonical 协调目录**（`cc-fleet-coord <RQ>` 给的 `<git-common-dir>/fleet/<RQ>`）：worker
  必须把回执写到那里（preamble 已要求），主 session 才能在 worker 自己 worktree 早被清理、session 被 respawn
  之后，仍从 canonical 路径读到那份 `result:` 回执判它完成。
- 还没写回执就被 respawn（worker 真的没做完/卡住）→ 没有 `receipt`，仍走铁律 1.5 的 `tempo` 静默兜底，不会
  把"没做完"误判完成。两条互补：**有回执→硬完成（抗 respawn）；无回执→看 tempo 静默兜底。**

**铁律 2 ｜ 回执三通道兜底，任一拿到即可（永不把"文件出现"当门禁）。**
- ① **canonical 绝对协调目录** `<git-common-dir>/fleet/<RQ>`：`cc-fleet-coord <RQ>` 给路径，
  **主仓库和所有 worktree 都解析成同一处**、在 `.git/` 里不进版本库。派发时把它作为 `{{COORD_DIR}}`。
- ② **`cc-fleet-summary <RQ>` 自动遍历所有 git worktree** 收回执——worker 在自己 worktree 里写的
  回执，主 session（orchestrator，**不被 sandbox 限制**）照样读得到。这是兜底主力。
- ③ **worker 的最后一条消息**：preamble 要求 worker 把回执作为**最后一条消息**发出，FleetView/
  通知里永远能看到，**不依赖任何文件路径**。前两条都没拿到时，读这条。

**铁律 3 ｜ 瞬时 failed 会自愈，绝不无限等。**
- `failed`/error 可能是瞬时 API 抖动（如 `UNKNOWN_CERTIFICATE_VERIFICATION`），隔一会儿再
  `cc-fleet-status` 常自愈成 `done`。别一见 `failed` 就进 Step 5 回修；确认是**持续**异常再回修。
- 任一 session 超出合理时长仍无 `done`/`gone` → 读它最后一条消息 / daemon `detail` 排查，或人工
  确认。**绝不无限 sleep 去等一个可能永远不出现在你所盯路径的文件。**

> 🚫 **踩过的坑①（worktree 相对路径）**：worker 在隔离 worktree + sandbox 下把回执写进**自己 worktree** 的
> 相对 `.fleet/`，主路径那个文件永不出现，主 session 死等，而 worker 早已 `done`（还把回执 commit
> 进了 git 才让主 session 事后看到）。**完成看 `cc-fleet-status`（SID 关联）+ canonical 回执，回执走多通道。**
>
> 🚫 **踩过的坑②（respawn 擦掉 done——本次新修）**：worker `ic-viewer` 09:48 已彻底完成（回执落 canonical、
> result: 写着"已合回 main 并 push、worktree 已清理"），11:27 被 daemon respawn 回 `running+active`、name 变空。
> 主 session 当时的原话是"**完成判定看 daemon 状态不看文件**，它多半在做合回/清理收尾，回执仅作进度参考"——
> 于是死等一个早已 done 的 worker，完成通知永不到。**根治**：`cc-fleet-status`/`cc-fleet-watch` 已把 canonical
> 协调目录里带 `result:` 的回执作为**抗 respawn 的单调完成闩锁**（`receipt=1` / 🧾 / `✅ 已完成 — 回执在案`），
> respawn 翻不动它。看到 🧾 / `receipt=1` 就是已完成，**别再当进度参考继续等**（铁律 1 + 1.6）。

**铁律 4 ｜ worker 质量降级（灰度坏模型）→ 别硬纠偏，kill 掉换【新 session】重派（大概率换到好模型）。** ⭐
> 当前大模型处于**灰度分流**：偶尔某个 worker 会被分到**质量很差的模型实例**，硬纠偏（cc-fleet-reply）往往无效——它还在同一个坏模型上。**换一个新 session 通常就分到好模型、问题自愈。**

- **识别信号（命中即疑似降级，不是任务真有歧义）**：
  - 把**瞬时工具抖动**（`cat`/`echo`/`Read` 偶发无回显、单次超时）误判成"通道彻底卡死 / 环境坏了"，**停下来问人而不重试**（真相多是抖动，重试即好）；
  - 明明能按「自主判断」自决的口径 / 文案 / 阈值 / 实现路径，却**反复要人确认、要人手把手**；
  - **空转很久没实质进展**（Brewed 20min+ 仍在原地）、或轻易放弃 / 兜圈子 / 反复重述已知事实；
  - 输出明显低质：答非所问、违反已下发的范围铁律、中英混杂。
  - 这些多半以 watch 推的 **`⏸ <module> blocked`（等输入）** 出现，也可能是 `running` 但最后一条消息 / 回执肉眼可见地烂。
- **与"真 blocked"区分（关键判断）**：先问一句——**一个称职的 worker 在这里会不会自己往下走？**
  - 会（此处本该自主判断，它却停下来问）→ **降级信号，走 respawn**，别浪费 reply。
  - 不会（确属该由人拍板的业务口径冲突 / 需要授权 / 需要外部信息）→ 这是**合理的 blocked**，用 `cc-fleet-reply` 回它或向用户 `AskUserQuestion`，**不要 respawn**（换模型也解决不了缺信息）。
- **对策 = 一条命令换新 session 重跑同一张任务卡**：
  ```bash
  ~/.claude/skills/multi-session-dev/scripts/cc-fleet-respawn <RQ> <module> --prompt-file <当初那张任务卡.md>
  ```
  它把「kill 旧 worker + 归档旧回执 + 用同卡另起全新 worker」做成一条原子操作，内建两道护栏：① 归档 `<COORD>/<module>.summary.md`，防坏 worker 万一落了 `result:` 被回执闩锁（铁律 1.6）误判"已完成"；② 重派自动带 `--join`，防同 RQ 里别的模块工件超新鲜窗口把本次重派拦成 `exit 6`。**旧 worker 的半成品从未 `cc-fleet-land`、不进集成分支 `fleet/<RQ>`**，新 worker 自开全新 worktree——集成分支始终干净。
- **无需重挂 watch**：重派复用同一 `<module>.sid`，现有 `cc-fleet-watch` 下一轮即解析到新 worker 的 short 继续监视；旧回执已归档（无 `receipt=1`），不会误闩完成。
- codex / codex-app / App 可见模式：`cc-fleet-respawn <RQ> <module> --prompt-file <卡> --dispatch cc-dispatch-codex-app`。
- **别滥用**：respawn 是给"模型能力降级"的，不是给"任务本身难 / 需求没写清"的——后者是主 session 把任务卡写得更清楚、或补 L1 文档的事。同一模块**连续 respawn 两三次仍降级**，多半不是模型问题（是任务卡有坑 / 环境真坏），停下来查根因，别无限换 session。

## 标准流程

### 协调目录约定

每个需求建一个协调目录存任务卡、sid、回执。**优先用 worktree 无关的 canonical 绝对路径**：
- **canonical（强烈推荐，worktree/sandbox 安全）**：`cc-fleet-coord <RQ>` →
  `<git-common-dir>/fleet/<RQ>`。主仓库与所有 worktree 解析一致、在 `.git/` 内不进版本库，
  从根上消除"worker 写自己 worktree、主 session 读不到"和"回执误入版本库"两个坑。派发时把它
  作为 `{{COORD_DIR}}`，并用 `cc-dispatch --sid-file "$COORD/<module>.sid"` 记关联键。
- **轻量（已有仓库 / monorepo，作兼容）**：仓库根 `.fleet/<RQ>/`。若用它，**务必把 `.fleet/`
  加进 `.gitignore`**——否则 worktree 里的 worker 会把协调文件 commit 进版本库（本次的次生问题）。
- **结构化（greenfield/微服务一模块一目录）**：`tasks/<RQ>/{modules,sessions}/` + `modules/<m>/`，
  配合 `cc-dispatch-batch` 一键批派。

> `cc-fleet-summary` / `cc-fleet-status` 都会**同时**扫 canonical、主树 `.fleet/`、所有 worktree 内的
> `.fleet/<RQ>` 与结构化布局，三种布局混用也能收齐——但派发侧统一用 canonical 最省心。

#### ⚠ 主 session 作为后台 job 怎么写协调文件（Write/Edit 会被隔离闸拦——必读）⭐

主 session 常作为**后台 job** 跑，而后台 job 的 **`Write`/`Edit` 工具对【一切仓库内路径】都会被
"未隔离禁止写共享 checkout"闸拦截**——**canonical 协调目录 `<git-common-dir>/fleet/<RQ>/` 也在 `.git/`
里、算仓库内路径，照样被拦**（实测：`Write` 到 `.git/fleet/<RQ>/x.md` 直接报错让你先 `EnterWorktree`）。
而主 session 是编排者、**故意不开 worktree、不碰 checkout**，满足不了这个闸。**别再像踩坑那样：先用 `Write`
试写协调目录→报错→才临时改道**。规则：

- **任务卡 / prompt 文件 / 契约 / 用户给的参考设计稿 / `base.ref` 等协调文件，一律用 Bash 落盘，不用 `Write`/`Edit` 工具**
  （Bash 写不受该闸限制）。推荐固定套路（避免 heredoc 转义大段 md/代码的坑）：
  1. 先用 **`Write` 工具**把内容写到 **`$CLAUDE_JOB_DIR/tmp/<file>`**——job 目录在**仓库外**，`Write` 不被拦，
     适合落大段结构化内容；
  2. 再 `cc-fleet-coord <RQ> --put <relpath> "$CLAUDE_JOB_DIR/tmp/<file>"` 把它拷进协调目录（自动 `mkdir -p`、
     越界保护、打印目标绝对路径）。
- **`cc-dispatch --prompt-file` 直接吃 `$CLAUDE_JOB_DIR/tmp/<完整prompt>.md` 即可**（仓库外路径，无需进协调目录）；
  确需留底再 `--put` 进 `$COORD/prompts/`。
- 这只约束**主 session**。**worker 不受影响**——它按 preamble 先 `EnterWorktree` 开隔离 worktree，之后在 worktree 里
  正常用 `Write`/`Edit`（隔离闸已满足）。
- 整库关闭这个闸（不推荐）：项目 `.claude/settings.json` 设 `"worktree": {"bgIsolation": "none"}`。

`<RQ>` 用 `RQ-<日期>-<序号>`，如 `RQ-2026-0531-001`（日期是 `YYYY-MMDD`）。

> 🚫 **铁律 · RQ 编号只能由脚本现场分配，每个新任务分配一次；任何时候都不许凭"今天日期 + NNN"在脑内重构编号。**
> 引用 RQ 的所有场合（派发 / arm Monitor / 写回执路径 / 二次派发 / 跨 turn 接着做）一律从**本轮的 `$RQ` shell 变量**或**协调目录**回读，**绝不重新拼一个字面量**。日期段对人脑"太好猜"——一旦丢了 `$RQ` 就会下意识填 `今天-001`，正好撞上早些时候那一轮还在的协调目录。
>
> **真实事故（2026-06-09）**：上午任务用了 `RQ-2026-0609-001`；下午另一个任务丢了 `$RQ`、凭日期重构又敲了 `001`，普通解析（`cc-fleet-coord <RQ>` 会 `mkdir -p` 静默建/复用）直接复用了上午仍在的协调目录，两个任务的 `.sid`/回执混进同一目录、`Monitor` 也盯错了 RQ，主 session 收到串台状态。分配脚本本会给下午分到 `004`——根因就是**绕过分配、手拼编号**。

**派发前一律用一次性入口 `cc-fleet-init` —— 一句 `eval` 就位，别再手串 `--alloc`/解析/`--init-base` 三条命令**（手串时任一条被漏掉或手拼编号就串台；三合一从结构上砍掉这个机会）。它做四件事：① GC 删 >7 天旧协调目录 ② 从**持久序号池 + 原子锁**取全新单调 RQ（目录被清也永不回退重号）③ 解析 canonical `$COORD` ④ 建集成分支 `fleet/<RQ>` 并落 `<COORD>/task.meta`。stdout 只吐可 eval 的三行、诊断全走 stderr，所以 `eval` 干净：

```bash
# 在项目目录、发起任务时的开发分支上（如 dev/langyi）跑一次：
eval "$(~/.claude/skills/multi-session-dev/scripts/cc-fleet-init)"
# → 之后 $RQ / $COORD / $INT 三个变量就绪：
#   $RQ=全新单调 RQ-id  $COORD=canonical 协调目录  $INT=集成分支 fleet/<RQ>（派发时作 FLEET_BASE_BRANCH）
# 选项：--base <branch> 显式 base（detached HEAD 必给）；--no-init-base 只要 RQ+COORD；--no-gc / --gc-days N 调清理；末尾可跟自定义 stem/ISO 日期
```
> **为什么必须走 `cc-fleet-init`**：`$RQ` 由持久序号池（`<fleet>/.seq/<stem>` 高水位 + mkdir 原子锁）发号，**即便协调目录被 GC/手删、或多个派发并发取号，也保证单调、永不重号**——这是根治 job 列表「编号重复」的核心。集成分支 `fleet/<RQ>` 是本 RQ 的隔离单元：所有 worker 以它为 base、改动只合回它，共享分支验收后才动一次（见「分支隔离铁律」）。同一 RQ 后续批次（契约先行二次派发 / 修复）重跑 `cc-fleet-init` 会另发新号——**要接着同一轮做，别重跑 init，直接复用本轮 `$RQ` 变量**（`--init-base` 对同一 RQ 幂等保留、不重置已落地内容）。
>
> 拆开的底层子命令（`cc-fleet-coord --alloc` / 解析 / `--init-base` / `--gc`）仍可单独调用做高级编排，但**日常派发只用 `cc-fleet-init`**。手动调 `--alloc` 时**只取 stdout，绝不能 `2>&1`**——提示文字走 stderr，混进 `$RQ` 会让整段提示变成目录名。

- 用户给了**语义名 / 显式 RQ**（如要求接着某轮做）：用 `cc-fleet-coord <RQ> --fresh` 解析——它在该 RQ 已被往轮 run 占用（任一通道已有 `.sid`/`.summary.md`/`contracts`）时直接 `exit 4` 拦下，提示改用 `--alloc`，避免静默复用别人的协调目录。确实要复用某轮目录（少见）才用不带 `--fresh` 的普通解析。
- **别现编时间戳**；`--alloc` 已按 `YYYY-MMDD` 自动取今天的日期段，无需手填。
- **派发侧第二道闸（即便手拼了旧编号也兜得住）**：`cc-dispatch`（带 `--sid-file`）与 `cc-dispatch-batch` 在把一个**新模块**写进**已被别的模块占用、且最后活动超出新鲜窗口**（默认 30min，`FLEET_JOIN_FRESH_SECS` 可调）的协调目录时，会**当场拦下并 `exit 6`**，提示"疑似复用了别的任务的 RQ"。**撞到这个拦截就是信号：你多半丢了 `$RQ`、手拼了旧编号——改用 `--alloc` 取全新空号**；只有确属**同一任务的后续批次**（契约先行二次派发等）才给派发加 `--join` 放行。整体关闭本闸：`export FLEET_NO_REUSE_GUARD=1`。

### Step 1 — 拆解（主 session，只写 L1 业务需求文档 + L1.5 任务卡）

1. 用业务语言理清需求要达到的**整体效果**（验收口径），并跑「业务需求拆解」四问：受影响模块 /
   数据流 / 实现策略 / 是否接口交互（要查现状用 subagent（Explore）探查，别自己读源码、也别为此开子 session）。
2. **维护 L1 业务需求文档（先于派发，独立 commit）**：本次需求对应的业务需求文档若缺失/过时，
   先补齐到与需求一致——它是子模块向上比对的锚。已有仓库适配其既有约定（如本项目
   `docs/requirements/<NN>/README.md` + `procurement-flow/`）；greenfield 用 `docs/` 业务场景。
3. 按**项目既有模块边界**把业务需求归属到对应模块，形成 N 个子任务（**模块划分用项目自带的，不自创**；
   找不到对应既有模块时按项目规则判断是否新建、告知用户裁定）。**一个模块一张卡一个 session（粒度铁律），
   有依赖/接口交互也不许合并**：互不冲突的并行派；纯先后依赖的排出派发顺序（前序回执 done 再派后续）；
   **命中接口交互的（四问之④）按「跨模块协同两模式」选模式**——模式 A 契约先行（先派提供方定契约、
   定稿再并行派提供方实现 + 各消费方接入）或模式 B 提供方先行（提供方完整开发 done 后再派消费方按
   真实接口接入），见「跨模块协同两模式」/ Step 2。
4. 每个模块写一张任务卡（见 `reference/task-card-template.md`），**必填**：
   - **整体业务目标**（让子模块看到全局，不跑偏）；
   - **业务需求锚点**：本次针对哪些 L1 业务需求文档/章节 + 业务级变化如何（指向具体条目/anchor）；
   - **验收清单**（R 条目，建议 EARS 句式 `WHEN…THE SYSTEM SHALL…`，可直接转测试）。
   - 任务卡是**业务面委托**，不写模块内部设计——那是子 session 的 L2，主 session 不碰。
5. **设计验收场景（你的活，Step 4 交独立 session 执行）**：从「如何验证这个需求做完了」反推一份
   **业务级 e2e 场景清单**——跨模块端到端口径，区别于上面单模块的 R 条目。测哪些场景由你定，写进
   L1 文档/留作验收 session 的输入。

### Step 2 — 派发（每个 prompt 必带回执契约）

**关键（默认 Claude 模式）**：每个派发 prompt = `reference/dispatch-preamble.md` 前缀（替换占位符）+ 该模块任务卡正文。
前缀锁死「**简体中文** + **写代码前先开 worktree 隔离（禁止改主工作树）** + 只在范围内改 + 自测自负责
+ **先建/更新 L2 模块需求文档（承上启下）再写代码** + 完成回填 `<COORD_DIR>/<module>.summary.md` 并把简短
回执作为最后一条消息」。**不带这段前缀就派发 = 拿不到回执 = 主 session 失明，禁止。**

**Codex / Codex App 可见模式**：用户明确要求“codex / codex-app / App 可见 / 子 session 要在 Codex App 里看到”时，
只把派发命令换成 `cc-dispatch-codex-app`，其余 RQ、集成分支、任务卡、sid、watcher、summary 流程不变。
不要在技能层解释或手调 Codex App 的可见性、prompt 注入、服务连接等实现细节；
这些都由脚本默认处理。旧命令 `cc-dispatch-codex` 只是兼容别名，也等同 App 可见模式。
只有用户明确说“快速模式”时才在派发命令上加 `--fast`；其它 Codex 相关参数默认不传。

> ✅ **后台 session 现在会自动加载 CLAUDE.md（2.1.181 实测稳定）**。早期 daemon 不保证加载（spare 池沿用
> 预热 cwd、约 3/4 miss，致 worker 英文回复 / 不自觉开 worktree / 甚至改主树；`--setting-sources` 当年已证伪是
> 安慰剂），曾靠 cc-dispatch **默认把规范原文塞进 prompt** 兜底。**2.1.181 重测：14/14 spare worker 均按【派发
> cwd】重新解析并加载三层 `CLAUDE.md`（用户级 + 项目级 + 目录级），且目录级精确跟随派发 cwd——原 bug 已修**
> （实测脚本 + 兼容表见 PROTOCOL.md §11）。故 `cc-dispatch` 注入**默认关**，不再与自动加载重复烧 token；
> preamble 让 worker 直接以上下文里 daemon 注入的 `# claudeMd`（三层 `CLAUDE.md`）为单一事实源。
> ⚠ 这是 daemon 内部行为、历史上回归过（2.1.167 还在 miss）——若某次升级后 worker 又不守规范（英文 / 不开
> worktree / 改主树），用 `--inject-claude-md` 重开兜底（把三层 `CLAUDE.md` 原文塞进首行哨兵后的
> `⟦INJECTED-CLAUDE-MD⟧` 块，spare 无关、稳定可靠），并重跑 `tests/test-cc-dispatch-inject.sh` + 真实探针确认。
> **worktree 由 worker 自己用自带 `EnterWorktree` 工具开**（符合项目 CLAUDE.md「必须用自带工具」），因此派发时
> **默认不要加 `--isolation worktree`**（否则与 worker 自开叠成两层）；确需 daemon 预建隔离时才加，并在任务卡
> 告诉 worker"已在 worktree 里、别再开"。

派发包必须让子 session 拿到**整体业务需求 + 业务需求锚点**（任务卡里的「整体业务目标」「业务需求
锚点」会随正文带过去），并要求它**先写 L2 模块需求文档**：向上 trace 到 L1 业务需求条目、向下 trace
到本模块设计与测试（模板见 `reference/doc-traceability.md`）。这份 L2 文档由子 session 写，主 session
不代写。

单个派发（**子 session 命名必带 `↳` 前缀 + 注入 `FLEET_ROLE=worker` + `--sid-file` 记关联键**）：
```bash
eval "$(~/.claude/skills/multi-session-dev/scripts/cc-fleet-init)"   # 一句到位：GC + 取全新单调 RQ + 解析 COORD + 建集成分支；$RQ/$COORD/$INT 就绪（用户给显式 RQ 才改用 `cc-fleet-coord <RQ> --fresh` 手工解析）
# 把 $COORD 作为 {{COORD_DIR}} 替进 dispatch-preamble，拼成 prompt 文件。
# ⚠ 主 session 作后台 job 时【别用 Write 工具往仓库内写】——用 Write 落到仓库外的 $CLAUDE_JOB_DIR/tmp/<完整prompt>.md，
#   --prompt-file 直接吃它即可（见「主 session 作为后台 job 怎么写协调文件」）。任务卡/契约/参考稿同理：Write 到 tmp 再 cc-fleet-coord <RQ> --put 进 $COORD。
~/.claude/skills/multi-session-dev/scripts/cc-dispatch \
  --cwd "$(pwd)" \   # 默认＝主 session 自己的当前工作目录，让子 session 继承同一项目子目录（勿写死项目名）
  --name "↳<module>@$RQ" \
  --env FLEET_ROLE=worker --env FLEET_RQ="$RQ" --env FLEET_MODULE=<module> \
  --env FLEET_BASE_BRANCH="$INT" \   # ⭐集成分支：worker 据此 reset --hard 锚定 base + cc-fleet-land 落地，绝不碰共享分支
  --sid-file "$COORD/<module>.sid" \
  --prompt-file /abs/<完整prompt>.md
```
- `--sid-file`：**必带**。派发成功把 sessionId 写进 `<COORD>/<module>.sid`，`cc-fleet-status` 据此用
  **SID 名册**稳定关联——不靠会变空的 session 名，从根上避免"已完成却被漏判→死等"（见上方铁律 1）。
- `--env FLEET_BASE_BRANCH="$INT"`：**开发型 worker 必带**（联调/验收/scout 等只读角色可省）。值＝Step 1
  `--init-base` 打印的集成分支 `fleet/<RQ>`。worker 据此 `reset --hard` 锚定 base + `cc-fleet-land` 落地，
  **改动只进 `fleet/<RQ>`、绝不碰共享分支**（见「分支隔离铁律」）。漏了它 worker 会退回老路合共享分支。
- `{{COORD_DIR}}` 用 `cc-fleet-coord <RQ>` 给的 canonical 绝对路径，主/worktree 解析一致、不进版本库。
- `--name`：统一 `↳<module>@<RQ>`。`↳` 前缀标记"被派发的子 session"；取名 hook 也据此/据
  `FLEET_ROLE` 给子 session 标题加 `↳`。主 session 自己无 `↳`、无 `FLEET_ROLE`，天然可区分。
- prompt 文件第一行必须是 `⟦FLEET-WORKER⟧ rq=<RQ> module=<module>`（`dispatch-preamble.md` 模板已含），
  这是子 session 身份的第三重信号。
- `--cwd`：子 session 的工作目录。**默认就传主 session 自己的 `$(pwd)`**——子 session 继承主 session
  所在的**项目子目录**（如 `supply-agent/factory`），从而子目录的 `CLAUDE.md` 能被正确加载。**禁止写死
  项目名 / 绝对路径**（换个项目就错）。仅当确需把子 session 放到别处时才显式给绝对路径：monorepo 跨包改动
  给**仓库根**、一模块一目录给 `modules/<m>/`。
  - ⚠ 多项目容器仓库（git 根 ≠ 项目目录，如 `supply-agent/` 下有 `factory/`、`delivery/`）：务必把 `$(pwd)`
    指向**项目子目录**而非仓库根，否则子 session 落到仓库根会读不到子目录 `CLAUDE.md`（仓库根放一份路由
    `CLAUDE.md` 作兜底，但不能替代子目录规范）。
  - **隔离默认交给 worker**：preamble 已要求 worker 写代码前用自带 `EnterWorktree` 自开隔离 worktree，
    所以并行多模块**默认不必加 `--isolation worktree`**——每个 worker 各自在自己 worktree 里改、互不踩，
    回执走 canonical / worktree 兜底（铁律 2）。
  - `--isolation worktree`（可选，daemon 预建）：worktree 是**整仓 checkout**，子 session 仍应落在**同名项目
    子目录**（`<worktree>/factory`），daemon 会按 `--cwd` 相对仓库根 rebase 到对应子目录。**用它就别让 worker
    再自开**——在任务卡里明确告诉 worker"你已在隔离 worktree 里，确认 cwd 在项目子目录后直接开工，别再 `EnterWorktree`"，
    避免两层 worktree。

#### Codex / Codex App 可见模式派发（用户明确要求时）

Codex 模式在技能层只有一个差异：把默认派发命令 `cc-dispatch` 换成 `cc-dispatch-codex-app`。
脚本会自动处理 Codex App 可见性、隔离 worktree、三层 `CLAUDE.md` 复用、回执元数据和默认速度。
主 session 通常不需要传 Codex 专用参数；除非用户明确要求快速模式，否则不要加 `--fast`。

```bash
eval "$(~/.claude/skills/multi-session-dev/scripts/cc-fleet-init)"   # 一句到位：GC + 取全新单调 RQ + 解析 COORD + 建集成分支；$RQ/$COORD/$INT 就绪

~/.claude/skills/multi-session-dev/scripts/cc-dispatch-codex-app \
  --cwd "$(pwd)" \
  --name "↳<module>@$RQ" \
  --env FLEET_ROLE=worker --env FLEET_RQ="$RQ" --env FLEET_MODULE=<module> \
  --env FLEET_BASE_BRANCH="$INT" \
  --sid-file "$COORD/<module>.sid" \
  --prompt-file /abs/<模块任务卡>.md
```

- 旧命令 `cc-dispatch-codex` 仍可被旧任务卡调用，但只是兼容 shim，等同 `cc-dispatch-codex-app`。
- 模型 / 思考深度沿用当前 Codex 设置；默认速度 1x。用户明确要求快速模式时才加 `--fast`。
- 完成信号和回执仍写同一个 `$COORD`，收回执继续用 `cc-fleet-summary <RQ>`。
- 如派发失败，先看脚本报错和 `cc-dispatch-codex-app --help`；不要在技能文档里展开底层调试流程。

- 互不冲突的模块**一次性全部派发**即并行；有依赖的等前序回执 done 再派后续。
- **命中跨模块协同的（拆解第④问）分两批派，按所选模式**（详见 `reference/contract-first.md`）：
  - **模式 A（契约先行）**：先单独派 API 提供方做契约设计
    （`--name "↳<provider>-contract@<RQ>"`，preamble/任务卡注明「本轮只产出 `<COORD>/contracts/` 契约
    文件、不实现业务逻辑」）；其回执含契约定稿后，主 session 评审定稿，**再并行派**提供方实现 + 各消费方
    接入（消费方任务卡把契约文件作为依赖锚点、注明「对端按契约 mock 自测」）。
  - **模式 B（提供方先行）**：先派提供方**完整开发**（设计 + 实现 + 自测一张卡）；其回执 done 后，
    主 session 把回执/契约里的**真实接口形态**写进消费方任务卡的依赖锚点，**再派**消费方接入
    （自测直接打真接口，无需 mock）。
  - 不论哪种模式，提供方与消费方都是**各自独立的模块 session**——别因"反正要等"就合并成一张卡。
  - ⚠ 第二批（实现 + 消费方）打到的是**同一个 `$RQ` / 同一个 COORD**——务必复用本轮 `$RQ` 变量，别另拼编号。
    若距第一批契约派发已超过新鲜窗口（默认 30min），复用兜底闸会拦下，**给这批 `cc-dispatch` / `cc-dispatch-codex-app` 加 `--join`** 放行
    （`--join` = 你确认"同一任务的后续批次"）。这正是 `--join` 的设计用途。
- 调试派发内容可加 `--dry-run`（只打印将发送的 JSON，不真派）。

结构化布局可一键批派（自动扫 `tasks/<RQ>/modules/*.md`，sid 落 `tasks/<RQ>/sessions/`）：
```bash
~/.claude/skills/multi-session-dev/scripts/cc-dispatch-batch <RQ>
```
> 注意：batch 只自动补 `↳`名 / `FLEET_*`env / `⟦FLEET-WORKER⟧`哨兵，**不自动拼 preamble 正文**。
> 批派模式下每张任务卡需**自包含**——把 preamble 的范围铁律/自测/L2 承上启下文档/回执契约连同
> 整体业务目标 + 业务需求锚点都写进卡里（照 `dispatch-preamble.md` + `task-card-template.md`）。

派发后把每个 session 的 short 记进协调目录（batch 自动记；单派时手动存 `<COORD_DIR>/<module>.sid`）。

### Step 3 — 监控（arm watcher 拿推送，零轮询；见上方铁律 0/1）

**派发完立刻 arm 一个 watcher，让 harness 把"完成"推给你，而不是自己轮询**（这是不再傻等的关键）。
默认 Claude 模式用 Claude Code 原生 **Monitor 工具**跑 `cc-fleet-watch`：

```
Monitor 工具:
  command     = ~/.claude/skills/multi-session-dev/scripts/cc-fleet-watch <RQ>
  description = fleet <RQ> 各模块完成/异常推送
  persistent  = true
```

Codex / Codex App 可见模式用对应 watcher：

```
Monitor 工具:
  command     = ~/.claude/skills/multi-session-dev/scripts/cc-fleet-watch-codex-app <RQ>
  description = codex app fleet <RQ> 各模块完成/异常推送
  persistent  = true
```

> ⚠ 这里的 `<RQ>` 必须是**本轮派发用的同一个 `$RQ`**（接上一步的 shell 变量），**别在 Monitor 的 command/description 里凭日期手敲 `RQ-今天-001`**——那正是 2026-06-09 事故里盯错 RQ 的方式（见铁律 · RQ 编号）。拿不准就回读 `$RQ` 或 `ls "$(cc-fleet-coord <RQ> --no-mkdir)"` 确认目录里是不是本轮的模块。

- Claude watcher 阻塞监视该 RQ（数据源 = `cc-fleet-status --json`），**每个模块一结束就推一行**（`✅ <m> done`/`gone`、
  `✅ <m> 已完成 — 回执在案`、`💤 <m> 静默已结束`、`❌ <m> 持续异常`、`⏸ <m> blocked`）、**全部结束推一条总结
  并退出**（退出码 0=无异常 / 3=有持续异常）。这些都经 Monitor 自动推回主 session——**你不需要 sleep、不需要
  轮询**，派完就去聊下一个需求。
- Codex / Codex App 可见模式的 status/watch/reply 统一用 `*-codex-app` 脚本；旧 `*-codex` 命令只是兼容别名。
  要给 App worker 追加指令，用 `cc-fleet-reply-codex-app <RQ> <module> "..."`。底层如何定位 thread、判断状态、
  继续会话由脚本负责，技能不展开。
- **`✅ 已完成 — 回执在案`（抗 respawn，铁律 1.6）**：worker 把带 `result:` 的回执写进 canonical 协调目录后，
  即便 daemon 把它 respawn 回 `running+active`（state 翻回、name 变空），watch 也凭持久回执**立即判完成并推给
  你**，单调不反悔。**这条专治"worker 真做完了、daemon 却又报它在跑"导致的死等**——见过的最隐蔽的坑。
- **`💤 静默已结束`**：某 worker `state=working`/`running` 但 `tempo=idle` 持续够久（活干完没打 `result:`、
  **且没落 canonical 回执**，或卡住）会被自动判为结束并推给你（见铁律 1.5），总结里用 🟡 标"含静默未打result
  N 个需核验"——这类要去 `cc-fleet-summary` / 读其最后一条消息**核验**，而不是当 done 盲信；若核验时发现它又
  活跃了，重挂一次 watch 即可。（落了 canonical 回执的不会走这条，直接走上面的"回执在案"硬完成。）
- **兜底 ≤5min**：cc-fleet-watch 默认每 ≤4min 发一条心跳进度，保证主 session 至少每 <5min 被唤醒一次；
  漏掉的完成事件会被下一次心跳的全量核对补上。要独立于 Monitor 的兜底，可另起一个 Bash `run_in_background`
  跑 `cc-fleet-watch <RQ> --wait`（codex/codex-app/App 可见模式用 `cc-fleet-watch-codex-app <RQ> --wait`；静默，结束时单次完成通知）。
- **点查仍用 `cc-fleet-status <RQ>`**（codex/codex-app/App 可见模式用 `cc-fleet-status-codex-app <RQ>`；人想随时看一眼时）：退出码 `0`=无在跑无异常 /`1`=进行中 /`2`=底层服务
  不可达 /`3`=异常终止态；`gone`（名册有、列表无）= 已结束去收回执，不当成还在跑。
- 见到 `❌ 持续异常` 推送：cc-fleet-watch 已默认连续 `--fail-checks 2` 轮才判异常（吸收瞬时 API 抖动如
  `UNKNOWN_CERTIFICATE_VERIFICATION`），所以推给你的是**已复查过的持续异常**，可直接进 Step 5；仍存疑就
  再跑一次 `cc-fleet-status` 确认。
- **daemon 不可达 / 协议失效**：cc-fleet-watch 会重试到 `--grace`（默认 300s）才放弃退 2；持续退 2 先
  `claude agents --json` 拉起 daemon 再重 arm watcher。

### Step 4 — 收回执 + 整体验证

1. status 报 0（无在跑无异常；codex/codex-app 模式看 `cc-fleet-status-codex-app`）后收回执：
   ```bash
   ~/.claude/skills/multi-session-dev/scripts/cc-fleet-summary <RQ>
   ```
   它**多通道兜底**（canonical + 主树 + 所有 worktree），worker 写在自己 worktree 里的回执也能收到。
   逐模块读「真实改动 / 预期变化 / 影响面 / 已知缺陷 / 自测结果 / L2 文档与双向 trace / 需裁决」。
   有「需主 session 裁决」的先处理（裁定范围/口径，必要时改任务卡再补派）。
   - **某模块 status=done/gone 但 cc-fleet-summary 收不到它回执** → 该 session 没把回执落盘，
     **直接读它的最后一条消息**（FleetView/通知里那条就是回执，见铁律 2③）。**绝不因此判定它"没完成"
     而回头死等文件**——完成与否已由 Step 3 的 status 定论。
   **查追溯链一致性**（ASPICE 4.0：链接还要核对两端真对得上）：每条 L1 业务需求是否都有模块 L2
   需求承接（向下覆盖无遗漏）、各模块 L2 是否都能回溯到 L1 条目（向上有据无越权）。链断/越权即回 Step 5。
2. **整体业务效果验证（测试三层：你设计场景，独立 session 执行，你不亲自跑测试）**：
   - **自测**（已在各模块内完成）：每个 worker 跑自己改动相关的单测/模块 e2e，对端按契约 mock。
   - **联调**（走过契约先行才需要）：派一个**联调 session**（`↳integ@<RQ>`）把相关模块真实拼起来
     （去 mock、真接口）跑通，回报集成是否通、哪条接口对不上。
   - **验收**：派一个**验收 session**（`↳verify@<RQ>`），拿你在 Step 1 设计的**验收场景清单**做端到端
     验证——**测哪些场景是你（主 session）从「如何验证需求做完」反推定的**，验收 session 只负责执行并
     逐条回报过/不过、不过时现象指向哪个模块。
   联调/验收 session 都是被派发的子 session（带 `↳` + `FLEET_ROLE=worker`），默认 Claude 模式 prompt 带 preamble；
   codex/codex-app/App 可见模式继续用 `cc-dispatch-codex-app`，其它派发与回执约定不变。
   prompt 范围=只读各模块 + 跑 e2e/集成，**不改业务代码**，回执写 `<COORD_DIR>/<verify|integ>.summary.md`：
   ```bash
   ~/.claude/skills/multi-session-dev/scripts/cc-dispatch \
     --cwd "$(pwd)" --name "↳verify@<RQ>" \   # 联调用 ↳integ@<RQ>，FLEET_MODULE=integ
     --env FLEET_ROLE=worker --env FLEET_RQ=<RQ> --env FLEET_MODULE=verify \
     --env FLEET_BASE_BRANCH="$INT" \   # 让验收/联调在集成分支 fleet/<RQ>（=全部已落地模块）上跑，而非停在没有改动的共享分支
     --prompt-file /abs/<验收prompt>.md
   ```
   > ⚠ 验收/联调 session 必须在**集成分支 `fleet/<RQ>`** 上测——主检出停在共享分支、没有各 worker 落地的改动。
   > preamble 已要求它们 `EnterWorktree` + `reset --hard "$FLEET_BASE_BRANCH"` 对齐集成分支后**只读**跑测，不落地、不碰分支。
3. 你读联调 + 验收回执 + 各模块回执，**对照 Step 1 的整体效果口径与验收场景清单裁定**是否达成业务需求。

### Step 5 — 定位回修循环

任一验收项不过：
1. 从验收回执的「现象指向」+ 各模块「影响面/缺陷」定位**问题模块**。
2. 写一张聚焦修复的任务卡（含复现/期望），带 preamble，派发**新 session**
   （`--name "↳<module>-fix@<RQ>"` + `--env FLEET_ROLE=worker --env FLEET_BASE_BRANCH="$INT" ...`，同 Step 2 约定）。
   fix session 同样 base 锚定 `fleet/<RQ>`（它已含本 RQ 各模块的落地）、改完 `cc-fleet-land` 回 `fleet/<RQ>`。
3. 回 Step 3 监控 → Step 4 重新验收。直到整体效果达标，进 Step 6 收尾。

### Step 6 — 验收通过后：促进集成分支 + 收尾（共享分支唯一一次合入）⭐

**只有整体验收通过后**，主 session 才把本 RQ 的集成分支合回共享开发分支——这是整条流程里**共享分支
唯一一次被改动**（之前全程 `dev/<name>` 一行没动，并发任务/用户零干扰）。在项目目录里：

```bash
RQ=...; COORD="$(~/.claude/skills/multi-session-dev/scripts/cc-fleet-coord "$RQ" --no-mkdir)"
BASE="$(cat "$COORD/base.ref")"           # 发起任务时记下的当前开发分支，如 dev/langyi
git switch "$BASE"                         # 回到共享分支（主检出本就在它上面）
git pull --ff-only                         # 先同步远端，减少落后
git merge --no-ff "fleet/$RQ"              # 把整 RQ 验收过的成果合进来（与他人改动冲突就解决，一次性）
# 改动相关回归（按项目规范，主 session 此处可派一个 verify-final session 或亲跑门禁脚本）
git push origin "$BASE"                     # 共享分支这一次才推远端
```

收尾清理（合回 + 校验一致后）：
```bash
git branch -D "fleet/$RQ"                  # 删本地集成分支
git push origin --delete "fleet/$RQ" 2>/dev/null || true                    # 若曾推过集成分支
# 若 worker 用了 cc-fleet-land --push-backup，清理远端模块备份分支 fleet/$RQ/<module>
git for-each-ref --format='%(refname:short)' "refs/remotes/origin/fleet/$RQ/*" \
  | sed 's#^origin/##' | xargs -r -I{} git push origin --delete {} 2>/dev/null || true
```
- worker 的隔离 worktree 由它们自己 `ExitWorktree` 清掉了；这里只收集成分支与远端备份。
- 合回出冲突 = 共享分支在 RQ 期间被推进过（用户/别的已合 RQ）→ 正常解决冲突补提交，不丢码、不跳校验。
- **本步是主 session 的 git 编排动作**（合并/推送/清分支），不是写业务代码——与「主 session 不碰代码」不冲突
  （同既有"主树串行合入 worker 分支"惯例）；若 RQ 间冲突很重、需要懂业务才能解，可派一个 fix/integrate session 处理。

## 脚本速查

| 命令 | 作用 |
|---|---|
| `eval "$(cc-fleet-init [opts] [stem])"` | ⭐**派发前唯一入口（日常只用这一条）**：一句 eval 依次做 ① GC 删 >7 天旧协调目录 ② 取全新单调 RQ（持久序号池 `.seq/<stem>` + mkdir 原子锁，目录被清/并发取号都**永不重号**）③ 解析 canonical `$COORD` ④ 建集成分支 `fleet/<RQ>` 并落 `<COORD>/task.meta`。stdout 只吐可 eval 的 `RQ=/COORD=/INT=` 三行、诊断走 stderr。选项：`--base <branch>`（detached 必给）/`--no-init-base`/`--no-gc`/`--gc-days N` |
| `cc-fleet-coord --alloc [stem]` | 底层分配（`cc-fleet-init` 内部调用；单独用于高级编排）：持久池+原子锁取下一个单调空号并 claim，打印 RQ-id。无参取今天 `RQ-<YYYY>-<MMDD>-NNN`；可传自定义前缀或 ISO 日期。**只取 stdout，别 `2>&1`** |
| `cc-fleet-coord --gc [days]` | 清理：删 canonical `<fleet>` 里 mtime 超 `days`（默认 7）天的协调目录 + 过期序号池文件（只清 canonical，不碰各 worktree 的 `.fleet`）。`cc-fleet-init` 每次自动调，也可手动跑 |
| `cc-fleet-coord <RQ>` | **解析**：打印 canonical 绝对协调目录 `<git-common-dir>/fleet/<RQ>`（worktree 无关，作 `{{COORD_DIR}}`） |
| `cc-fleet-coord <RQ> --fresh` | **防撞**：解析显式 RQ，但若它已被往轮 run 占用（任一通道有 `.sid`/`.summary.md`/`contracts`）则 `exit 4`。用户给语义名/显式 RQ 时兜底，避免静默复用别人的目录 |
| `cc-fleet-coord --init-base <RQ> [base]` | 底层建集成分支（`cc-fleet-init` 内部调用）：在 base（默认当前分支）上幂等创建 `fleet/<RQ>`、把 base 名记进 `<COORD>/base.ref`，打印 `fleet/<RQ>`（派发时作 `--env FLEET_BASE_BRANCH`）。已存在则保留不重置。共享分支只在验收后由主 session 合一次（见「分支隔离铁律」） |
| `cc-fleet-coord <RQ> --put <relpath> [src]` | **把文件落进协调目录**（绕开后台 job 的 Write/Edit 隔离闸——主 session 不能用 Write 写仓库内路径，见「主 session 作为后台 job 怎么写协调文件」）。`relpath` 相对协调目录（绝对路径/含 `..` 拒绝）；省略 `src` 从 stdin 读；自动 `mkdir -p`，打印目标绝对路径。配 `Write` 到 `$CLAUDE_JOB_DIR/tmp/` 再 `--put` 用 |
| `cc-fleet-coord --check-join <coord> <m> [--join]` | **复用兜底闸**（cc-dispatch/-batch 自动调用，一般不手敲）：把新模块写进已被【别模块】占用且超新鲜窗口（默认 30min，`FLEET_JOIN_FRESH_SECS` 调）的协调目录则 `exit 6`。`--join` 确认同任务后续批次放行；`FLEET_NO_REUSE_GUARD=1` 关闸 |
| `cc-dispatch … --sid-file "$COORD/<m>.sid"` | 派发一个后台 session，并把 sessionId 记进名册（**必带 --sid-file**，供 SID 关联）。带 --sid-file 时先过复用兜底闸：疑似复用别任务 RQ → `exit 6`（新任务改 `--alloc`，同任务后续批次加 `--join`） |
| `cc-dispatch --help` | 全部选项（`--agent` `--isolation worktree` `--env` `--sid-file` `--json` 等） |
| `cc-dispatch-codex … --sid-file "$COORD/<m>.sid"` | **兼容别名**：codex 模式现在等同 App 可见模式，本命令直接转发到 `cc-dispatch-codex-app` |
| `cc-dispatch-codex-app … --sid-file "$COORD/<m>.sid"` | **codex / codex-app / App 可见模式派发入口**：用法与 `cc-dispatch` 基本一致；默认参数足够。模型/思考深度沿用当前 Codex 设置，默认 1x；用户明确要求快速模式才加 `--fast` |
| `cc-fleet-status-codex <RQ>` / `--json` | **兼容别名**：等同 `cc-fleet-status-codex-app` |
| `cc-fleet-watch-codex <RQ>` | **兼容别名**：等同 `cc-fleet-watch-codex-app` |
| `cc-fleet-status-codex-app <RQ>` / `--json` | **codex/codex-app/App 可见模式点查**：exit 0=无在跑无异常 / 1=进行中 / 2=协调目录或底层服务不可用 / 3=异常 |
| `cc-fleet-watch-codex-app <RQ>` | **codex/codex-app/App 可见模式 Monitor watcher**：每个 App worker 完成/异常推一行，全部结束退出（exit 0/3）；`--wait` 可作 Bash 后台兜底 |
| `cc-fleet-reply-codex-app <RQ> <module> "…"` | **codex/codex-app/App 可见模式回复**：给指定 worker 追加指令。支持 `--text-file`/stdin/`--dry-run` |
| `cc-dispatch-batch <RQ>` | 结构化布局批派整个 RQ（自动记 sid + 带 ↳名/FLEET_*/哨兵） |
| `cc-fleet-status <RQ>` / `--all` / `--json` | **按 SID 名册**关联的状态表（点查；exit 0=无在跑无异常 / 1=进行中 / 2=daemon 不可达 / 3=异常；`gone`=已结束）。**带 `result:` 的 canonical 回执 = `receipt=1` / 🧾 = 已完成（抗 respawn），即便 daemon 仍报 running 也判完成** |
| `cc-fleet-watch <RQ>` （交给 **Monitor** 跑，`persistent:true`） | ⭐**阻塞监视→推送**：每模块结束/异常/blocked/💤静默 推一行 + ≤4min 心跳兜底 + 全部结束退出（exit 0/3）。**主 session 零轮询的关键**。判"还在跑"看 `tempo` 不看 `state`：持续 `idle`≥`--stall-idle`(默认240s,带去抖) 自动判【静默已结束】，复活会撤销。**回执在案(`receipt=1`)→立即 `✅ 已完成 — 回执在案`、单调闩锁抗 respawn** |
| `cc-fleet-watch <RQ> --wait` （交给 **Bash `run_in_background`**） | 静默阻塞直到全部结束，单次完成通知（独立于 Monitor 的兜底完成信号） |
| `cc-fleet-watch --help` | 全部选项（`--coord` `--interval` `--stall-idle` `--heartbeat` `--fail-checks` `--grace` 等） |
| `cc-fleet-summary <RQ｜coord-dir>` | **多通道**（canonical+主树+所有 worktree）汇总各 session 回执 |
| `cc-fleet-land <RQ>` （**worker 收尾跑**，不是主 session） | worker 自测绿后把改动**安全合入集成分支 `fleet/<RQ>`**：CAS（`update-ref` 比较交换）+ 自动 merge 重试，多 worker 并发落地零丢更新；**绝不碰共享分支**。冲突→exit 7（解决后重跑）/ 脏树→exit 3 / 缺集成分支→exit 2。`--push-backup <module>` 额外推远端备份，`--dry-run` 预演 |
| `cc-fleet-reply <RQ> <module> "…"` | **给在跑 worker 发消息**（等价 FleetView 回它话）：解析 module→当前 short 后注入一条 user message。worker `tempo=blocked` 等输入时用它回复/纠偏。`--short`/`--text-file`/stdin/`--dry-run`。exit 0/2(无live)/3(已结束)/4/5 |
| `cc-fleet-kill <RQ> <module>` / `<RQ> --all` | **取消/终止 worker**：跑偏/卡死/不要了时终止它（`--signal SIGKILL` 强杀，`--all` 杀整个 RQ）。只杀进程不删回执。`--short`/`--dry-run`。exit 0/2/3(已结束)/4/5 |
| `cc-fleet-respawn <RQ> <module> --prompt-file <卡>` | ⭐**换新 session 重跑同一任务卡（灰度坏模型自救，见铁律 4）**：一条命令 = kill 旧 worker + 归档旧回执（防旧 `result:` 误闩已完成）+ 用同卡另起全新 worker（自动 `--join` 过复用闸）。疑似模型降级空转、reply 纠偏无效时用；现有 watch 自动跟到新 worker，不必重挂。`--signal`/`--dispatch cc-dispatch-codex-app`/`--base`/`--no-kill`/`--dry-run`/`-- <转发派发脚本>`。exit 0/2/3/4/5 |

## 命名与身份约定（与取名 hook 联动）

主 / 子 session 一眼可分，靠三重信号 + 用户的取名 hook：

| 信号 | 主 session | 子 session（worker） |
|---|---|---|
| 会话名 (`--name`) | 普通名（DeepSeek 中文标题，无前缀） | `↳<module>@<RQ>`（`↳` 前缀） |
| 环境变量 `FLEET_ROLE` | 无 | `worker` |
| 首条消息哨兵 | 无 | `⟦FLEET-WORKER⟧ rq=… module=…` |

- 取名 hook（`~/.claude/hooks/auto-cn-title.sh`）已改造：检测到上述任一信号即判定 worker，把标题
  设成 `↳…` 并**跳过 DeepSeek**；主 session 仍走正常中文标题。FleetView 里带 `↳` 的就是被派发的子。
- 三重信号是冗余设计：`--name`/`--env` 由 `cc-dispatch`/`cc-dispatch-batch` 自动带；哨兵由
  `dispatch-preamble.md` 首行带。任一在,身份就成立——主 session 别忘了按 Step 2 的命令格式派发。
- **防"子 session 名变 bg"（两层根治：①名字从哪恢复 ②名字写到哪）**：daemon 重启/resume 既有后台
  会话时会丢掉 seed 的 name，FleetView 退回显示默认 template `bg`。取名 hook 在 **SessionStart** 事件
  做**多源恢复**重建 `↳<module>@<RQ>`，优先级：① 读 transcript 的 `⟦FLEET-WORKER⟧ rq=… module=…`
  哨兵（最稳，跨 respawn 永在、不依赖会丢空的 name/不被 spare 继承的 env）→ ② `FLEET_*` env / `↳`
  job 名 → ③ `<sid>.title` 缓存 → ④ transcript 既有 `custom-title`/`agent-name` 记录。
- **⭐ CC 2.1.16x+ 显示名读 `state.json.name`（2.1.179 实证的"又变 bg"根因 + 修复）**：新版 FleetView/
  `claude agents` **任务列表**的显示名只读 `~/.claude/jobs/<short>/state.json` 的 **`.name`** 字段，缺失时
  回退显示 `.template`——daemon spare 池派发的后台 session 模板名就是字面量 **`bg`**。而 hook 输出的
  `sessionTitle` 只写进 transcript 的 `custom-title`/`agent-name`（只影响 `/resume` 列表与会话标签），
  **不进 `state.json.name`**；spare 池 respawn 完成后的 worker 其 `state.json` 从不带 `name` → 列表退化成
  `bg`（实测某 worker transcript 里有 50 条 `custom-title=↳portal@…`，但 `state.json` 无 `name`、
  `template=bg` → 列表仍显示 `bg`）。官方**无任何受支持的 hook 字段**能设这个持久 name。**修复**：取名
  hook 在 SessionStart 恢复出 `↳` 名后、以及 worker 首条 UPS 命中后，**直接原子改写 `$CLAUDE_JOB_DIR/state.json`
  的 `.name`（并置 `.nameSource=user`）**——这才是任务列表真正读的字段；每次 (re)spawn 的 SessionStart
  触发即自愈，respawn 抹掉也会被下次补回。安全约束：只处理 worker（标题带 `↳`），**绝不碰普通/主 session
  的命名**（其 `name` 由 CC 原生维护、跨 respawn 不退化，从而不会覆盖用户手动 Ctrl+R 改名）；幂等（name
  已一致跳过，竞态窗口收敛到仅首次自愈）；原子写 + 仅在 `state.json` 可解析时动手 + 异常静默 no-op。
- **⭐ 第三层：完成态 `bg`/`0s` 的全局兜底（2026-06-24 / cli 2.1.187 复发后加固）**：上面两层在 worker **运行/
  respawn** 时自愈，但 worker **完成**时 daemon 会把 `state.json` 重写成极简记录（丢 `.name` → 回退 `bg`、三时间戳
  塌缩 → `0s`），且此后不再触发该 worker 自身的 hook。`cc-fleet-fix-display --all` 负责这层：扫所有 job，按**每个
  job 自己的 cwd** 回溯它自己的 `git-common-dir/fleet/*/*.sid`（内容 == sessionId）还原 `↳<module>@<RQ>` + 用
  transcript 首/末时间戳修时长，**不要 RQ、不依赖编排者 cwd**（专治"跟进 worker 漏网""worker 在别的仓库路径名册
  解析不到"两个 per-RQ 盲区，详见上「FleetView 显示修复」）。取名 hook 在**非 worker 会话 SessionStart** 节流后台
  自动调它，主会话一启动即全量自愈。
- 所以 worker 标题/时长能自愈，无需人工干预。回归用例：`tests/test-auto-cn-title.sh`（多源恢复 / `state.json.name`
  持久化 / 普通会话不被改写 / 缺 state.json 不崩 / 幂等 / **SessionStart sweep 门控·节流·调起**，共 29 项）；
  `tests/test-cc-fleet-fix-display.sh`（per-RQ，21 项）；`tests/test-cc-fleet-fix-display-all.sh`（`--all` 全局兜底：
  sid 还原·哨兵还原·非 fleet 不碰·纯外观不 churn·running 不碰·max-age·幂等，23 项）。

## 失效降级（cc-dispatch 用的是非公开协议）

Claude Code 升级可能让 daemon 协议变动。信号 = `cc-dispatch` 退出码 `2`（daemon 不可达）或 `3`（schema/proto 不兼容）。
- 退出 2：先跑一次 `claude agents --json` 拉起 daemon 再重试。
- 退出 3：协议变了。`cc-dispatch-batch` 会自动打印**可手动派发的清单**（MODULE/CWD/NAME/PROMPT FILE）——
  新开 terminal 跑 `claude agents`，照清单在 FleetView 手动 "New agent" 派发，**方法论流程不变**。
- 要修脚本：照 `reference/PROTOCOL.md` §9「协议升级应对剧本」更新 `cc-dispatch` 的字段构造（通常改 3-5 行）。
- codex/codex-app/App 可见模式的问题优先看 `cc-dispatch-codex-app`、`cc-fleet-status-codex-app`、
  `cc-fleet-watch-codex-app`、`cc-fleet-reply-codex-app` 的报错与 `--help`。底层兼容策略只在脚本内维护；
  Claude 模式不受 Codex 脚本变动影响。

## 注意事项

- 主 session 一旦发现自己在读/改模块源码，就是越界了——退回去，把它写成任务卡派给模块 session。
- 派发 prompt **永远**带前缀：默认 Claude 模式带 `dispatch-preamble.md`；codex/codex-app/App 可见模式由
  `cc-dispatch-codex-app` 自动处理对应前缀与规则复用。回执是主 session 唯一可靠的"改动雷达"。
- **一个子 session 只承担一块代码上独立的内容——默认一个模块，可按需更细（模块内大改动 / 不同业务流程
  再切、抽公共模块消重），但任何情况下不许把多个模块合给一个 session（粒度铁律）。** 接口两端本就该是两个
  session（按协同两模式排先后）；会碰同一文件的（登记散点等）由主 session 排定合回顺序串行消化，不靠合并回避冲突。
- 模块 session 报告「需裁决/要扩大范围」时，由主 session 裁定，别让模块 session 自行蔓延改动面。
- 整体效果不达标只许**派新 session 修**，主 session 不下场改代码。
