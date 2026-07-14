---
name: multi-session-dev
description: >-
  多 session 协作开发编排（仅供**发起需求的主 session**用）。用户一旦说「用多 session / 多个 session /
  fleet 编排 来完成某开发任务」，**动手前第一件事就是加载本技能并按它编排，绝不自己直接读/改/跑代码**。
  主 session 只做：把业务需求归属到项目既有模块（只映射不自创，一个模块一个子 session、绝不合并）、为接口
  交互安排契约先行、设计 e2e 验收场景、派发/监控/验收/回修。⚠ 派发开发 worker 只用 `cc-dispatch`
  脚本（codex/App 可见模式 `cc-dispatch-codex-app`），**绝不用内置 `Agent`/Task 工具**（`Agent` 仅限只读
  探查）——这是本技能最高频错误。触发词：用多 session 完成任务、多 session 开发、模块拆分派发、fleet 编排、
  契约先行、cc-dispatch、codex-app 模式。⚠ 被派发的**子 session（worker：名字带 ↳ / `FLEET_ROLE=worker` /
  首条消息带 ⟦FLEET-WORKER⟧）不要用本技能**——你是干活的 worker，按任务卡写代码+自测+回执即可。
---

# Multi-Session 协作开发（主 session 编排）

把一个开发需求**按项目既有模块边界归属**到各模块，派发给多个**独立后台 session**并行开发，主 session 全程
**不碰代码**，只做：拆解 → 派发 → 监控 → 收回执 → 整体验收 → 定位回修。默认走 Claude Code 后台 session；
用户明确说「codex / codex-app / App 可见模式」时统一走 Codex App 脚本（见下「codex 模式总纲」），两种模式复用
同一套 RQ、集成分支、worktree、任务卡、回执与验收流程。

## ⛔ 先自检：你是主 session 还是被派发的 worker？

**如果你是被派发的子 session（worker），立刻停用本技能。** 满足任一即为 worker：
- 会话名以 `↳` 开头；
- 环境变量 `FLEET_ROLE=worker`（`echo "$FLEET_ROLE"` 或读 `$CLAUDE_JOB_DIR/name`）；
- 首条消息以 `⟦FLEET-WORKER⟧` 哨兵行开头、或写着「你是一个模块 session」。

worker 该做的：**按任务卡在自己范围内写代码 + 自测 + 回填回执**（见首条消息里的回执契约），**不要**再
`cc-dispatch` 往下派发、**不要**拒绝写代码、**不要**把活又拆给别人。下面所有「编排」动作只属于主 session。

## ⛔ 两条硬边界（动手前先记牢）

### 边界 A：派发开发 worker = 跑 `cc-dispatch`，永远不是 `Agent`/Task 工具 ⭐

**这是本技能最高频、最致命的错误。** 你被要求「用多 session 完成任务」后，会本能地伸手调内置 `Agent`（Task）
工具并行——因为它是你平时做并行工作的默认工具。**在本技能里这个本能是错的**：`Agent` 起的是挂在你名下、
FleetView（`claude agents`）里根本看不见的 subagent，不是独立 session，无法独立合回、收不到回执、watcher 监控
不到——整套 fleet 编排全部失效。「用多 session」从字面就要求真正的独立 session。

**唯一判据 = worker 要不要改代码：**

| 通道 | 用途 | 机制与可见性 |
|------|------|------|
| **内置 `Agent`**（`Explore`/`general-purpose`，含 `run_in_background:true`） | **只读探查**：拆解前摸字段/接口/数据流现状，拿结论回来。**绝不让它写/改/提交代码** | 主 session 名下的 subagent/Task，`source=spare`、**无 `↳` 名**、**不在 `claude agents` 列表**、无独立 worktree/合回/回执/监控 |
| **`cc-dispatch`** | **开发交付**：某模块内真写代码 + 自测 + 合回 | daemon 派发的**独立顶层 background session**，带 `↳<模块>@<RQ>` 名、**在 `claude agents` 可见**、走完整 sid 名册/watcher/回执 |
| **`cc-dispatch-codex-app`** | 同上，用户明确要求 codex/App 可见时 | 与 `cc-dispatch` 同一套 RQ/集成分支/worktree/名册/回执，仅在 Codex App 可见 |

> ⚠ harness 那句「launch multiple agents in one message for parallel work」**不适用于派发开发 worker**：在本
> 技能里「并行开多个 worker」= 在一条消息里连发多条 `cc-dispatch`，**不是**连发多个 `Agent` 调用。

**派发后立刻机械验证（漏做 = 没派）**：跑 `claude agents` 或 `cc-fleet-status "$RQ"`，逐个模块确认看到对应的
`↳<module>@<RQ>` 条目。看不到（或只有一个无名 `source=spare` 的 running 条目）→ **你刚才误用了 `Agent`**，那个
「worker」只是你名下一个隐形 subagent，**立刻停手改用 `cc-dispatch` 重派**。

### 边界 B：主 session 绝不写/调/测/读业务代码 ⭐

你是**编排者**，脑力全花在「业务需求 → 模块需求」的拆解、契约编排、验收场景设计与裁定上。

- 影响面、数据流、模块边界**靠业务知识 + L1 业务需求文档 + 项目模块地图**判断，**不靠读源码**。
- 确需探查代码现状才能拆准（如「这字段现在哪些接口返回 / 哪个模块在写它」）→ **用 subagent（`Agent` 工具、
  `Explore` 类型）只读探查**拿结论。subagent 天然只读、findings-only 不污染主上下文，且不走 daemon/worktree/
  回执/监控那一套，比开子 session 轻得多。**是 subagent 在读、主 session 拿结论，主 session 仍不亲自 grep/Read。**
- **开「子 session」（`cc-dispatch`）的唯一门槛 = 要在某领域模块内部真正开发/改代码**（写代码 + 自测 + 回执 +
  合回）。凡**只读**的活（确认/了解某功能、摸字段·接口·数据流现状）一律走 subagent，**别为此开子 session**。
- 仅当探查量**极大** / 需独立完整上下文 / 要跑长命令链时，才退回派只读 scout 子 session
  （`--name "↳scout@<RQ>"`，preamble 写明「只读不改、只回报结论」）——这是例外，不是默认。
- 一旦发现自己在读/改模块源码，就是越界——退回去，交给 subagent 探查或写成任务卡派出去。

## 何时激活本技能

- **自动判断**：当前是主 session，且用户表达「把需求拆成模块、派发多个 session 并行开发、我只统筹验收不亲自
  写代码」这类**编排意图**时自动加载（如「用多 session 完成这个需求 / 拆模块派发 / 用 fleet 编排 / 你当总指挥
  分派下去」）。
- **显式调用**：用户输入 `/multi-session-dev`。
- **不激活**：普通单 session 开发、被派发的 worker（见上自检）、纯运维/查询、需求小到一个 session 能利落做完时。
- **只读理解类不开子 session**：用户只让你「根据代码确认 / 了解某功能 / 摸现状」这种纯只读请求 → 用 subagent
  拿结论即可（见边界 B）。

## codex / App 可见模式总纲（用户明确要求时）

**唯一差异：把所有 `cc-dispatch` / `cc-fleet-status` / `cc-fleet-watch` / `cc-fleet-reply` 换成对应的
`-codex-app` 变体**，其余 RQ、集成分支、任务卡、sid、回执、验收流程**全不变**。下文正文只写默认 Claude 模式命令，
不再逐处并列——需要 codex 模式时按本条替换即可。

- 触发：用户明确说「codex / codex-app / App 可见 / 子 session 要在 Codex App 里看到」。
- 旧命令 `cc-dispatch-codex` / `cc-fleet-status-codex` / `cc-fleet-watch-codex` 只是兼容别名，等同 `-codex-app`。
- 模型/思考深度沿用当前 Codex 设置，默认速度 1x；**只有用户明确要求「快速模式」才加 `--fast`**，其它 Codex 专用
  参数默认不传。Codex App 的可见性/prompt 注入/服务连接等实现细节由脚本自动处理，技能层不展开、不手调。

## 主 session 的六步职责

1. **拆解（归属，非发明）**：把业务需求**归属到项目既有模块**——识别受影响模块、数据流/数据来源、实现策略
   （见「业务需求拆解」）。模块划分是项目自带的，只映射、禁止自创；默认**一模块=一卡=一 session**（见「派发
   粒度铁律」）。
2. **派发**：用 `cc-dispatch` 给每个模块派一个独立后台 session，让 worker 在自己范围内开发 + **自测**。
3. **监控**：派完**立刻 arm `cc-fleet-watch`**（交给 Monitor 跑）让完成/异常**推送**给你——零轮询、不傻等。
4. **收回执**：用 `cc-fleet-summary` 收齐每个 session 的会话回执。
5. **验收**：从验收口径**设计 e2e 场景**（测哪些由你定），但执行**派给独立 session**（联调/验收 session）；你只
   读它的报告 + 各模块回执来**裁定**。
6. **回修**：不达标 → 定位问题模块 → 派**新 session**去修，回到第 3 步。

模块内部的开发/调试/单测/e2e 全由各模块 session 自己负责，你不替它写、不替它调、不替它测。

## 业务需求拆解（主 session 唯一的核心脑力活）⭐

拿到需求先做**四问拆解**，把「业务需求」翻译成若干互不冲突、可并行（或契约先行后并行）的模块需求。只用业务
知识 + L1 文档，**不读源码**（要查现状用 subagent 探查）。

> 🚫 **模块/领域划分是项目既有的，你只做「归属映射」，禁止发明或重新划分。** 先查项目的模块地图/清单（如
> factory `CLAUDE.md` §8「模块地图」、`docs/requirements/<NN>/` 编号目录），据此把需求归属到既有模块。**确实找
> 不到对应既有模块** → 按项目规则判断是否新建（通常独立 commit + 告知/请用户裁定），**不擅自新建**。

**① 落到哪些既有模块？（受影响模块）** 一个字段/能力常牵涉多端、多单据、多读取方——对照模块清单把展示方、
写入方、读取方都定位全，漏一个就出现「前台加了字段、后台没传」的断层。

**② 数据从哪来、谁负责弄进来？（数据流/数据来源）** 新数据的源头在哪、通过什么时机和通道进入系统。两类常见
落点：运维任务批量同步 / 业务动作触发时主动抓取。找出「谁是这条数据的生产者」——它就是一条独立模块需求。

**③ 实现策略选型（根因优先）**：能判断哪条更优 → 直接自决，把依据写进 L1 文档/任务卡；两条各有取舍无法确定
→ 用 `AskUserQuestion` 确认后再派，别拍脑袋也别两条都做。选型默认偏向**根因修复**（数据在正确时机以正确方式
进入系统），而非绕过/兜底/加开关。

**④ 哪些是跨模块接口交互？（引出协同编排）** 识别「提供方—消费方」关系：某模块要调另一模块新接口 / 多模块共享
新数据结构 → 命中**跨模块协同**（走「协同两模式」）；纯展示型、各改各的、互不调用 → 直接并行派发。**若发现多个
模块会重复实现同一段逻辑/数据结构/校验 → 就地收敛成一个「公共模块」先行产出，其余作消费方依赖它**（公共模块=
提供方，同走两模式）。**不论命中与否，每个模块都是独立 session，依赖靠编排不靠合并。**

> **范例（「大货样字段」需求）**：发货计划要加「大货样」字段，数据来源是 ××× 系统。
> - ① 受影响模块：采购后台「发货计划」、工厂前台「发货计划/生产计划」都要展示（≥3 个展示点，分属采购端与工厂端）。
> - ② 数据来源：来自 ×××，两条候选——(a) 加运维任务批量同步；(b) 生成采购单/发货计划时主动抓取一次。
> - ③ 选型：若判断「生成时抓取」更优（随单据即时落地、无需额外调度）→ 自决派给生成模块；拿不准 → `AskUserQuestion`。
> - ④ 接口交互：展示方读的是生产方写入的同一数据结构 → 生产方先定字段/接口契约，各展示端按契约并行接入。
>
> 产物：1 条数据生产模块需求 + N 条展示模块需求，必要时一份共享字段契约，每条进 L1 文档 + 一张任务卡。

## 派发粒度铁律：默认一模块一 session，可更细，绝不合并多模块 ⭐🚫

**唯一判据**：这块内容在代码上是否相对独立、一个 worker 能否聚焦地把它交付掉 + 自测。据此两个方向都要防——切太
粗（改动面失控、耦合、合回冲突）也别切太细到无意义。项目既有模块边界是最稳的切分线，故**默认一模块一 session**；
下列维度按需组合、都服从上面判据：

- **①按角色切**：开发/联调/验收本就是不同 session；契约设计、代码 review 也各自独立 session。别让一个开发 session
  顺手把设计、验收、review 也做了。
- **②按业务流程切**：一次需求含多条相对独立的业务流程时，不同流程尽量分到不同 session（哪怕落在同一模块）。
- **③按模块切（默认粒度）**：需求落到 N 个既有模块 → 默认 N 卡 N session。**禁止**因「改动都小/业务相关/顺手」把
  多模块合进一张卡——那等于在执行层打散项目模块边界，改动面失控、回执无法按模块归因、合回冲突。
- **④模块内大改动再切**：一个模块本次改动量很大、且能拆成**代码上彼此独立的几块**（不同文件/子流程、不互改同一处）
  → 拆成多 session 分头做。**前提是拆出的块代码独立**：若必然改同一批文件别硬拆（`cc-fleet-land` 必冲突），要么合成
  一个 session，要么先抽公共模块（维度⑤）。拆出的每个 session 给不同子模块标签（`FLEET_MODULE=<m>-<flowA>` 等）。
- **⑤抽公共模块，从设计上消重**：多个 session 会重复实现同一段逻辑/数据结构/校验/工具 → 主 session 在设计阶段收敛
  成一个「公共模块」session 先行产出，其余依赖它接入（公共模块=提供方，走协同两模式）。

**依赖关系靠编排、不靠合并**：命中接口交互（含公共模块）走「协同两模式」；纯先后依赖排派发顺序（前序回执 done
再派后续）；互不冲突直接并行。

**自检信号（每张卡派发前必查）**：
- 任务卡「业务需求锚点」出现**两个及以上不同模块**的需求文档编号 = 切太粗，按模块拆开重写（维度③）。
- 一张卡要改的文件横跨多条明显不相干的业务流程 → 按流程再切（维度②）。
- 多张卡都在实现「看起来一样」的逻辑 → 该抽公共模块（维度⑤）。

**两个例外（不破坏「专注+代码独立」）**：
1. **同模块内、代码耦合紧的多条子需求**合一张卡——本就该同一 session 交付，不算合并（与维度④相反：耦合紧别硬拆）。
2. **登记类散点**：新页面/新接口必须同步的注册点（前端菜单 `menu-config.ts`、路由注册、rbac 门禁）——这类一两行
   登记**随功能模块卡一并改**，但必须在任务卡「上下游协作」段**显式授权**；若多个并行 session 要碰**同一个**登记
   文件，主 session 排定合回顺序，后合者负责 rebase。

## 跨模块协同两模式（多模块接口交互必读）⭐

拆解第④问命中「提供方—消费方」时，**不要一上来把提供方和消费方一起并行派**（契约没定，消费方按猜的接口写必
返工），**也不许因此把两模块合给一个 session**。由主 session 选一种模式（判据与契约模板见 `reference/contract-first.md`）：

- **模式 A · 契约先行（默认，并行抢墙钟）**——三段式：
  - **段① 契约设计（串行卡点，只派 1 个 session）**：先派 API 提供方做接口/契约层设计（签名、请求/响应 schema、
    字段语义与单位、错误码、事件结构），产物落 `<COORD>/contracts/`。**主 session 评审契约**（业务面：字段齐不齐、
    口径对不对、错误码覆盖没），定稿后进段②。
  - **段② 分头开发（契约定稿后并行）**：提供方按契约实现真逻辑；消费方按契约接入、对端用 mock/桩自测。双方代码
    互不冲突、真正并行，各跑自己的单测/模块 e2e。
  - **段③ 联调（独立 session）**：段②都 done 后派一个独立联调 session（`↳integ@<RQ>`）把相关模块真实拼起来（去
    mock、真接口）跑通，回报集成是否通。联调属「测试」不属「开发」。
- **模式 B · 提供方先行（串行，等真实接口）**：先派提供方**完整设计+开发+自测**一张卡，done 后主 session 从其回执/
  契约提取**实际接口形态**作消费方任务卡的依赖锚点，**再派**消费方按真实接口接入（无需 mock）。适用：接口形状强
  依赖实现探索，预先定稿大概率被推翻；或消费方接入量很小。
- 两模式下提供方/消费方**都各是独立 session、绝不合并**；拿不准默认模式 A。纯展示型互不调用则跳过本节直接并行。

## 分支隔离铁律：每 RQ 一条集成分支，共享分支只在验收后动一次 ⭐🚫

防「半成品过早污染共享分支、串台其它并发任务」的根本机制。**两级分支隔离：**

- **每个 RQ 一条专属集成分支 `fleet/<RQ>`**，主 session 在 Step 1 用**发起任务时的当前分支**（`$FLEET_BASE`，如
  `dev/langyi`）创建（`cc-fleet-init` 自动做，base 名记进 `<COORD>/base.ref`）。它是本 RQ 的隔离单元：并发的多个
  RQ 各自一条，互不污染。
- **worker 的 base = `fleet/<RQ>`，改动也只合回 `fleet/<RQ>`**（派发时 `--env FLEET_BASE_BRANCH="$INT"` 注入）。
  worker `EnterWorktree` 后**第一件事 `git reset --hard "$FLEET_BASE_BRANCH"`** 强制锚定（防 bg EnterWorktree 从
  origin/main 生的 worktree 没有项目代码），自测绿后跑 **`cc-fleet-land <RQ>`** 把改动安全合入 `fleet/<RQ>`（内部
  CAS 重试、多 worker 并发落地零丢更新），**绝不 merge/push 共享分支**。
- **共享分支只在主 session 整体验收通过后动一次**：把 `fleet/<RQ>` 合回 `$FLEET_BASE`（读 `base.ref`）+ push + 删
  集成分支（Step 6）。**验收完成前 `dev/<name>` 一行不动** → 其它并发任务、用户本人完全不受干扰。

> 为什么 worker 能「自己合进一条没被 checkout 的分支」且抗并发：`fleet/<RQ>` 只是 `.git` 里一条共享 ref，没在任何
> worktree 被 checkout。`cc-fleet-land` 用 compare-and-swap——先把 `fleet/<RQ>` 现 tip 合进 worker 自己分支、再
> `git update-ref fleet/<RQ> <new> <old>` 原子推进，被抢先就重读重试。零丢更新；冲突（RQ 内按模块粒度本就罕见）
> 留给 worker 解决后重跑。

## 文档分层与承上启下（防子模块跑偏）⭐

让子模块知道整体业务需求、知道改动针对哪些业务需求文档及其变化，并在模块内形成承上启下的文档。三层 + 严格
ownership（完整模型、L2 模板、业界依据见 `reference/doc-traceability.md`）：

| 层 | 内容 | 谁写 |
|---|---|---|
| **L1 业务需求文档** | 整体业务目标、跨模块场景、业务级验收（业务语言，单一事实源） | **主 session** |
| **L1.5 模块委托（任务卡）** | ①整体业务上下文 ②针对哪些业务需求文档/章节+变化 ③本模块验收清单 | **主 session** |
| **L2 模块需求+设计** | 本模块需求（↑挂 L1）+ 功能/技术设计（↓到代码/测试） | **子 session（主 session 绝不代写）** |

- **承上启下 = 双向追溯链**：L2 每条模块需求向上挂 L1 具体条目/锚点、向下挂模块设计与测试。验收即查链。
- 🚫 **主 session 从不代写 L2**（它不读模块源码，写出的「向下链」必然 stale，且违反 ownership、制造瓶颈）。L2 由
  最接近实现的子 session 写，与代码同仓同 commit（docs-as-code）。主 session 只定标准 + 画桥（委托/锚点）+ 评审链一致性。

## ⛔ 完成判定与回执获取（防主 session 死等）

> 本技能最容易踩的坑：主 session 无限等一个早已完成的子 session。四个根因（把「回执文件出现」当完成 / 拿不到完成
> 推送而轮询死等 / 把 `state=working` 当在跑 / daemon respawn 擦掉 `done`）与两次真实踩坑的复盘见
> **`reference/pitfalls.md`**。对策是下面五条铁律，日常照做即可。

**铁律 0 ｜ 不轮询，arm 一个 `cc-fleet-watch` 让 harness【推】给你。** ⭐
- 派发完**立刻**把 `cc-fleet-watch <RQ>` 交给 Claude Code 原生 **Monitor 工具**（`persistent:true`）跑。它阻塞监视
  该 RQ（数据源 = `cc-fleet-status --json`），**每个模块一结束就往 stdout 写一行 → harness 变成推回主 session 的
  通知**；全部结束写一条总结并退出（退出码=完成信号）。于是「子 session 结束」被转成「主 session 原生推送」，全程
  零轮询、零 sleep——派完就去跟用户聊别的，done 事件自动找上门。
- **≤5min 兜底**：cc-fleet-watch 内置每 ≤4 分钟一条心跳（`--heartbeat 240`），漏掉的完成事件被下条心跳补上，保证
  至少每 <5min 被唤醒一次。要独立于 Monitor 的兜底，可另用 `cc-fleet-watch <RQ> --wait` 配 Bash `run_in_background`。
- **`blocked`（等授权/输入）不算结束**：worker 等输入时 daemon 报 `tempo=blocked`，watch 会推 `⏸ <module> blocked`。
  先按铁律 4 判「真需要输入」还是「模型降级空转」，再走三条路之一：
  - **回复它**：`cc-fleet-reply <RQ> <module> "继续，按 X 改"`——把回复/纠偏注入该 worker（确属该由人拍板的合理 blocked 才用）。
  - **换新 session 重派**：`cc-fleet-respawn <RQ> <module> --prompt-file <当初任务卡>`——疑似灰度坏模型/质量降级空转时用（见铁律 4）。
  - **取消它**：`cc-fleet-kill <RQ> <module>`（或 `<RQ> --all`；`--signal SIGKILL` 强杀）。只终止进程、不删已落盘回执。

**铁律 1 ｜ 完成 = daemon `done`/`gone`（按 SID 名册关联）** 或 **canonical 回执带 `result:`——二者任一即完成。**
- 权威完成信号 = `cc-fleet-status <RQ>`。它读协调目录 `*.sid` 名册，用 **sessionId/short** 关联 daemon 状态。**别靠
  session 名关联**——完成后 daemon 里 name 会变空，靠 name 过滤会漏掉已完成的 session 而死等。SID 是稳定键。
- ⭐ 它**同时**把 canonical 目录里带 `result:` 的回执作为第二条权威完成信号（`receipt=1` / 表格 🧾）：只要
  `<COORD>/<module>.summary.md` 首个非空行是 `result:`，该模块即判**已完成**，**不管 daemon 此刻报什么 state**——
  这是抗 respawn 的关键（铁律 1.6）。看到 🧾 / `receipt=1` = 已完成，**别再当进度参考继续等**。
- 退出码：`0`=无在跑无异常（含回执在案的）/`1`=进行中 /`2`=daemon 不可达 /`3`=异常终止态。`gone`（名册有、daemon
  列表无）= 已结束去收回执，不是「还在跑」。

**铁律 1.5 ｜「还在跑」看 `tempo`，不看 `state`。** ⭐ daemon 报两个维度：`state`（分类器读最后一条消息文本推出，
打了 `result:` 才翻 `done`）和 `tempo`（agent 循环此刻是否在产出）。**判「要不要继续等」看 `tempo`**：`active` 才是
真在跑；`working`/`running` 但 `tempo=idle` = 循环已停（多半做完没打 `result:`，也可能卡住）→ 去 `cc-fleet-summary`
收回执 / 读最后一条消息核验，别死等。`cc-fleet-watch` 已自动兜底：持续 `tempo=idle` ≥ `--stall-idle`（默认 240s，
带 2 轮去抖）判【静默已结束】（推 `💤 …需核验`），一旦又 `active` 自动撤销。

**铁律 1.6 ｜ 持久回执闩锁：daemon 会 respawn 已完成的后台 session，唯有持久回执抹不掉。** ⭐ spare 池会把一个早已
done 的 session respawn（`state` 翻回 `running`、`tempo` 回 `active`、`name` 变空），把易失的 `done` 完全擦掉，连铁律
1.5 的静默兜底都失效。**根治 = 用持久信号做单调闩锁**：worker 完成时把回执写进 canonical `<COORD>/<module>.summary.md`
且**首行 `result:`**。`cc-fleet-status` 标 `receipt=1`、完成判定以回执为准；`cc-fleet-watch` 见 `receipt=1` 立即推
`✅ <module> 已完成 — 回执在案` 并【单调】结案，respawn 之后翻回 running 也**不反悔**。文件持久，respawn 抹不掉。
所以这条**强依赖 canonical 协调目录**——worker 必须把回执写到那里（preamble 已要求）。

**铁律 2 ｜ 回执三通道兜底，任一拿到即可（永不把「文件出现」当门禁）。**
- ① **canonical 绝对协调目录** `<git-common-dir>/fleet/<RQ>`（`cc-fleet-coord <RQ>` 给路径，主仓库和所有 worktree
  解析成同一处、在 `.git/` 里不进版本库）——派发时作 `{{COORD_DIR}}`。
- ② **`cc-fleet-summary <RQ>` 自动遍历所有 git worktree** 收回执——worker 在自己 worktree 里写的回执，主 session
  （不被 sandbox 限制）照样读得到。兜底主力。
- ③ **worker 的最后一条消息**：preamble 要求 worker 把回执作为最后一条消息发出，FleetView/通知里永远看得到，不依赖
  任何文件路径。前两条都没拿到时读这条。

**铁律 3 ｜ 瞬时 failed 会自愈，绝不无限等。** `failed`/error 可能是瞬时 API 抖动（如
`UNKNOWN_CERTIFICATE_VERIFICATION`），隔一会儿再 `cc-fleet-status` 常自愈成 `done`。确认是**持续**异常再进 Step 5。
任一 session 超合理时长仍无 `done`/`gone` → 读最后一条消息 / daemon `detail` 排查，**绝不无限 sleep 等一个可能永远
不出现在你所盯路径的文件**。

**铁律 4 ｜ worker 质量降级（灰度坏模型）→ 别硬纠偏，kill 掉换【新 session】重派。** ⭐ 当前大模型灰度分流，偶尔某
worker 被分到质量很差的模型实例，硬纠偏（reply）往往无效——换个新 session 通常就分到好模型、自愈。识别信号、与
「真 blocked」的区分、别滥用的边界见 **`reference/pitfalls.md`**。对策一条命令：
```bash
~/.claude/skills/multi-session-dev/scripts/cc-fleet-respawn <RQ> <module> --prompt-file <当初那张任务卡.md>
```
它把「kill 旧 worker + 归档旧回执（防坏 worker 落了 `result:` 被回执闩锁误判完成）+ 用同卡另起全新 worker（自动
`--join` 过复用闸）」做成一条原子操作。旧 worker 半成品从未 `cc-fleet-land`、不进集成分支，新 worker 自开全新
worktree——集成分支始终干净。**无需重挂 watch**（复用同一 `.sid`，watch 下一轮解析到新 worker）。codex 模式加
`--dispatch cc-dispatch-codex-app`。

## 标准流程

### 协调目录约定

每个需求建一个协调目录存任务卡、sid、回执。**优先用 worktree 无关的 canonical 绝对路径**：
- **canonical（强烈推荐，worktree/sandbox 安全）**：`cc-fleet-coord <RQ>` → `<git-common-dir>/fleet/<RQ>`。主仓库与
  所有 worktree 解析一致、在 `.git/` 内不进版本库，从根上消除「worker 写自己 worktree、主 session 读不到」和「回执误
  入版本库」两个坑。派发时作 `{{COORD_DIR}}`，用 `cc-dispatch --sid-file "$COORD/<module>.sid"` 记关联键。
- **轻量（兼容）**：仓库根 `.fleet/<RQ>/`。用它**务必把 `.fleet/` 加进 `.gitignore`**，否则 worktree 里的 worker 会
  把协调文件 commit 进版本库。
- **结构化（greenfield/微服务一模块一目录）**：`tasks/<RQ>/{modules,sessions}/`，配合 `cc-dispatch-batch` 批派。

`cc-fleet-summary`/`cc-fleet-status` 都会同时扫三种布局，混用也能收齐；派发侧统一用 canonical 最省心。

#### ⚠ 主 session 作为后台 job 怎么写协调文件（Write/Edit 会被隔离闸拦）⭐

主 session 常作为**后台 job** 跑，而后台 job 的 `Write`/`Edit` 对**一切仓库内路径**都会被「未隔离禁止写共享 checkout」
闸拦截——**canonical 协调目录 `<git-common-dir>/fleet/<RQ>/` 也在 `.git/` 里、算仓库内路径，照样被拦**。而主 session
是编排者、故意不开 worktree。规则：
- **任务卡 / prompt 文件 / 契约 / 参考稿 / `base.ref` 等协调文件，一律用 Bash 落盘，不用 `Write`/`Edit` 工具**。推荐
  固定套路：① 先用 **`Write` 工具**把内容写到 **`$CLAUDE_JOB_DIR/tmp/<file>`**（job 目录在仓库外、`Write` 不被拦）；
  ② 再 `cc-fleet-coord <RQ> --put <relpath> "$CLAUDE_JOB_DIR/tmp/<file>"` 拷进协调目录（自动 `mkdir -p`、越界保护、
  打印目标绝对路径）。
- **`cc-dispatch --prompt-file` 直接吃 `$CLAUDE_JOB_DIR/tmp/<完整prompt>.md` 即可**（仓库外路径，无需进协调目录）。
- 这只约束**主 session**；worker 按 preamble 先 `EnterWorktree` 后在 worktree 里正常用 `Write`/`Edit`。

### Step 1 — 拆解（主 session，只写 L1 业务需求文档 + L1.5 任务卡）

1. 用业务语言理清整体效果（验收口径），跑「业务需求拆解」四问（要查现状用 subagent 探查，别自己读源码）。
2. **维护 L1 业务需求文档（先于派发，独立 commit）**：缺失/过时先补齐到与需求一致——它是子模块向上比对的锚。适配
   项目既有约定（如 `docs/requirements/<NN>/README.md` + `procurement-flow/`）。
3. 按**项目既有模块边界**归属出 N 个子任务（模块划分用项目自带的，不自创；找不到时按项目规则判断是否新建、告知用户）。
   **一模块一卡一 session，有依赖/接口交互也不合并**：互不冲突并行派；纯先后依赖排派发顺序；命中接口交互按「协同两模式」。
4. 每个模块写一张任务卡（`reference/task-card-template.md`），**必填**：整体业务目标（看到全局不跑偏）、业务需求锚点
   （针对哪些 L1 条目/anchor + 变化）、验收清单（R 条目，建议 EARS 句式 `WHEN…THE SYSTEM SHALL…`，可直接转测试）。任务
   卡是**业务面委托**，不写模块内部设计（那是 L2）。
5. **设计验收场景（你的活，Step 4 交独立 session 执行）**：从「如何验证需求做完」反推一份**业务级 e2e 场景清单**（跨
   模块端到端口径），写进 L1 文档/留作验收 session 输入。

**派发前一律用一次性入口 `cc-fleet-init`**——一句 `eval` 做四件事：① GC 删 >7 天旧协调目录 ② 从**持久序号池 + 原子锁**
取全新单调 RQ（目录被清/并发取号都**永不重号**）③ 解析 canonical `$COORD` ④ 建集成分支 `fleet/<RQ>` 并落 `task.meta`。
stdout 只吐可 eval 的三行、诊断走 stderr：

```bash
# 在项目目录、发起任务时的开发分支上（如 dev/langyi）跑一次：
eval "$(~/.claude/skills/multi-session-dev/scripts/cc-fleet-init)"
# → $RQ / $COORD / $INT 就绪：$RQ=全新单调 RQ-id  $COORD=canonical 协调目录  $INT=集成分支 fleet/<RQ>（派发时作 FLEET_BASE_BRANCH）
# 选项：--base <branch>（detached HEAD 必给）；--no-init-base 只要 RQ+COORD；--no-gc / --gc-days N
```

> 🚫 **RQ 编号只能由脚本现场分配，绝不凭「今天日期 + NNN」在脑内重构**（真实串台事故见 `reference/pitfalls.md`）。引用
> RQ 的所有场合（派发 / arm Monitor / 回执路径 / 二次派发 / 跨 turn）一律从本轮 `$RQ` 变量或协调目录回读。
> - 用户给**显式 RQ / 语义名**：用 `cc-fleet-coord <RQ> --fresh` 解析（该 RQ 已被往轮占用则 `exit 4` 拦下，避免静默复用）。
> - 同一 RQ 后续批次（契约先行二次派发/修复）**别重跑 init，直接复用本轮 `$RQ`**（`cc-fleet-init` 会另发新号）。
> - **派发侧第二道闸**：`cc-dispatch`（带 `--sid-file`）把新模块写进已被别模块占用且超新鲜窗口（默认 30min）的目录时
>   `exit 6`——撞到就是「你多半手拼了旧编号」的信号，改用 `cc-fleet-init` 取新号；确属同任务后续批次才给派发加 `--join`。

### Step 2 — 派发（每个 prompt 必带回执契约）

**每个派发 prompt = `reference/dispatch-preamble.md` 前缀（替换占位符）+ 该模块任务卡正文。** 前缀锁死「简体中文 +
写代码前先开 worktree 隔离（禁止改主工作树）+ 只在范围内改 + 自测自负责 + 先建/更新 L2 模块需求文档（承上启下）再写
代码 + 完成回填 `<COORD_DIR>/<module>.summary.md`（首行 `result:`）并把简短回执作为最后一条消息」。**不带前缀就派发
= 拿不到回执 = 主 session 失明，禁止。**

```bash
eval "$(~/.claude/skills/multi-session-dev/scripts/cc-fleet-init)"   # $RQ/$COORD/$INT 就绪（用户给显式 RQ 才改用 cc-fleet-coord <RQ> --fresh）
# 把 $COORD 作为 {{COORD_DIR}} 替进 dispatch-preamble 拼成 prompt。⚠ 主 session 作后台 job 时别用 Write 往仓库内写：
#   Write 到仓库外的 $CLAUDE_JOB_DIR/tmp/<完整prompt>.md，--prompt-file 直接吃它；任务卡/契约同理 Write 到 tmp 再 --put。
~/.claude/skills/multi-session-dev/scripts/cc-dispatch \
  --cwd "$(pwd)" \                                  # 默认＝主 session 自己的 cwd，让子 session 继承同一项目子目录（勿写死项目名）
  --name "↳<module>@$RQ" \                          # ↳ 前缀标记被派发的子 session
  --env FLEET_ROLE=worker --env FLEET_RQ="$RQ" --env FLEET_MODULE=<module> \
  --env FLEET_BASE_BRANCH="$INT" \                  # ⭐集成分支：worker 据此 reset --hard 锚定 + cc-fleet-land 落地，绝不碰共享分支
  --sid-file "$COORD/<module>.sid" \                # 必带：记 sessionId 供 SID 名册稳定关联
  --prompt-file /abs/<完整prompt>.md
```

- `--sid-file`：**必带**。不带就没有 SID 名册，`cc-fleet-status` 只能靠会变空的 session 名关联 → 已完成却被漏判→死等。
- `--env FLEET_BASE_BRANCH="$INT"`：**开发型 worker 必带**（联调/验收/scout 等只读角色可省）。漏了 worker 会退回老路合共享分支。
- `--cwd`：**默认传主 session 自己的 `$(pwd)`**，子 session 继承主 session 所在的项目子目录（如 `supply-agent/factory`），
  从而子目录 `CLAUDE.md` 被正确加载。**禁止写死项目名/绝对路径**。⚠ 多项目容器仓库（git 根 ≠ 项目目录）务必把 `$(pwd)`
  指向**项目子目录**而非仓库根，否则子 session 读不到子目录 `CLAUDE.md`。
- prompt 文件**第一行必须是** `⟦FLEET-WORKER⟧ rq=<RQ> module=<module>`（`dispatch-preamble.md` 模板已含）——worker 身份第三重信号。
- **隔离默认交给 worker**：preamble 已要求 worker 写代码前用自带 `EnterWorktree` 自开隔离 worktree，所以并行多模块**默认
  不加 `--isolation worktree`**（否则与 worker 自开叠成两层）。确需 daemon 预建隔离时才加，并在任务卡告诉 worker「你已在
  worktree 里、确认 cwd 在项目子目录后直接开工、别再 `EnterWorktree`」。
- 调试派发内容可加 `--dry-run`（只打印将发的 JSON，不真派）。

派发编排：
- 互不冲突的模块**一次性全部派发**即并行；有依赖的等前序回执 done 再派后续。
- **命中跨模块协同的分两批派**（详见 `reference/contract-first.md`）：模式 A 先单独派提供方做契约设计（`--name
  "↳<provider>-contract@$RQ"`，任务卡注明「本轮只产出 `<COORD>/contracts/` 契约、不实现业务逻辑」），主 session 评审
  定稿后**再并行派**提供方实现 + 各消费方接入（消费方任务卡把契约作依赖锚点、注明「对端按契约 mock 自测」）；模式 B 先
  派提供方完整开发，done 后把真实接口形态写进消费方任务卡再派。⚠ 第二批打到**同一个 `$RQ`/COORD**——复用本轮 `$RQ`
  变量，超新鲜窗口就给 `cc-dispatch` 加 `--join` 放行。
- **结构化布局可一键批派**：`cc-dispatch-batch <RQ>`（自动扫 `tasks/<RQ>/modules/*.md`、记 sid、带 ↳名/FLEET_*/哨兵）。
  但 **batch 不自动拼 preamble 正文**——每张任务卡需**自包含**（把 preamble 的范围铁律/自测/L2 承上启下/回执契约连同整体
  业务目标 + 业务需求锚点都写进卡里）。

### Step 3 — 监控（arm watcher 拿推送，零轮询；见铁律 0/1）

**派发完立刻 arm 一个 watcher 让 harness 把「完成」推给你**（不再傻等的关键）。用 Claude Code 原生 **Monitor 工具**跑：

```
Monitor 工具:
  command     = ~/.claude/skills/multi-session-dev/scripts/cc-fleet-watch <RQ>
  description = fleet <RQ> 各模块完成/异常推送
  persistent  = true
```

> ⚠ 这里的 `<RQ>` 必须是**本轮派发用的同一个 `$RQ`**，别在 Monitor 的 command/description 里凭日期手敲
> `RQ-今天-001`（2026-06-09 事故就是盯错 RQ，见 `reference/pitfalls.md`）。拿不准回读 `$RQ` 或
> `ls "$(cc-fleet-coord <RQ> --no-mkdir)"` 确认。

- watcher 阻塞监视该 RQ（数据源 = `cc-fleet-status --json`），**每模块一结束推一行**（`✅ <m> done`/`gone`、
  `✅ <m> 已完成 — 回执在案`、`💤 <m> 静默已结束`、`❌ <m> 持续异常`、`⏸ <m> blocked`），**全部结束推一条总结并退出**
  （退出码 0=无异常 / 3=有持续异常）。经 Monitor 自动推回主 session——你不 sleep、不轮询，派完就去聊下一个需求。
- **`✅ 已完成 — 回执在案`（抗 respawn，铁律 1.6）**：worker 把带 `result:` 的回执写进 canonical 后，即便 daemon 把它
  respawn 回 `running+active`，watch 也凭持久回执立即判完成并推给你，单调不反悔。专治「worker 真做完了、daemon 却又报它
  在跑」的死等。
- **`💤 静默已结束`**：worker `working`/`running` 但 `tempo=idle` 持续够久（活干完没打 `result:` 且没落 canonical 回执，
  或卡住）自动判结束并推给你（铁律 1.5），总结里用 🟡 标「含静默未打result N 个需核验」——这类要去 `cc-fleet-summary` /
  读最后一条消息**核验**，别当 done 盲信；核验时发现它又活跃了，重挂一次 watch 即可。
- **兜底 ≤5min**：watch 默认每 ≤4min 一条心跳，保证至少每 <5min 被唤醒一次；漏掉的完成事件被下次心跳全量核对补上。要独立
  于 Monitor 的兜底，可另起 Bash `run_in_background` 跑 `cc-fleet-watch <RQ> --wait`（静默，结束时单次完成通知）。
- **点查仍用 `cc-fleet-status <RQ>`**（人想随时看一眼）：退出码 0=无在跑无异常 / 1=进行中 / 2=底层服务不可达 / 3=异常终止态；
  `gone`（名册有、列表无）= 已结束去收回执。
- 见 `❌ 持续异常` 推送：watch 已默认连续 `--fail-checks 2` 轮才判异常（吸收瞬时 API 抖动），推给你的是已复查过的持续异常，
  可直接进 Step 5；仍存疑再跑一次 `cc-fleet-status`。
- **daemon 不可达 / 协议失效**：watch 重试到 `--grace`（默认 300s）才放弃退 2；持续退 2 先 `claude agents --json` 拉起
  daemon 再重 arm watcher。

### Step 4 — 收回执 + 整体验证

1. status 报 0 后收回执：
   ```bash
   ~/.claude/skills/multi-session-dev/scripts/cc-fleet-summary <RQ>
   ```
   它**多通道兜底**（canonical + 主树 + 所有 worktree）。逐模块读「真实改动 / 预期变化 / 影响面 / 已知缺陷 / 自测结果 / L2
   文档与双向 trace / 需裁决」。有「需主 session 裁决」的先处理（裁定范围/口径，必要时改任务卡再补派）。
   - 某模块 status=done/gone 但 summary 收不到它回执 → 该 session 没把回执落盘，**直接读它最后一条消息**（FleetView/通知里
     那条就是回执，铁律 2③）。**绝不因此判它「没完成」而回头死等文件**——完成与否已由 Step 3 的 status 定论。
   - **查追溯链一致性**（ASPICE 4.0）：每条 L1 业务需求是否都有模块 L2 承接（向下覆盖无遗漏）、各模块 L2 是否都能回溯到 L1
     条目（向上有据无越权）。链断/越权即回 Step 5。
2. **整体业务效果验证（测试三层：你设计场景，独立 session 执行，你不亲自跑测试）**：
   - **自测**（已在各模块内完成）：每个 worker 跑自己改动相关的单测/模块 e2e，对端按契约 mock。
   - **联调**（走过契约先行才需要）：派一个联调 session（`↳integ@<RQ>`）把相关模块真实拼起来（去 mock、真接口）跑通。
   - **验收**：派一个验收 session（`↳verify@<RQ>`），拿你在 Step 1 设计的**验收场景清单**做端到端验证——测哪些场景是你定的，
     验收 session 只执行并逐条回报过/不过、不过时现象指向哪个模块。
   联调/验收 session 都是被派发的子 session（带 `↳` + `FLEET_ROLE=worker`），prompt 带 preamble，范围=只读各模块 + 跑
   e2e/集成，**不改业务代码**，回执写 `<COORD_DIR>/<verify|integ>.summary.md`：
   ```bash
   ~/.claude/skills/multi-session-dev/scripts/cc-dispatch \
     --cwd "$(pwd)" --name "↳verify@$RQ" \          # 联调用 ↳integ@$RQ，FLEET_MODULE=integ
     --env FLEET_ROLE=worker --env FLEET_RQ="$RQ" --env FLEET_MODULE=verify \
     --env FLEET_BASE_BRANCH="$INT" \               # 让验收/联调在集成分支 fleet/<RQ>（=全部已落地模块）上跑
     --prompt-file /abs/<验收prompt>.md
   ```
   > ⚠ 验收/联调必须在**集成分支 `fleet/<RQ>`** 上测——主检出停在共享分支、没有各 worker 落地的改动。preamble 已要求它们
   > `EnterWorktree` + `reset --hard "$FLEET_BASE_BRANCH"` 对齐后**只读**跑测，不落地、不碰分支。
3. 你读联调 + 验收 + 各模块回执，**对照 Step 1 的整体效果口径与验收场景清单裁定**是否达成业务需求。

### Step 5 — 定位回修循环

任一验收项不过：
1. 从验收回执的「现象指向」+ 各模块「影响面/缺陷」定位**问题模块**。
2. 写一张聚焦修复的任务卡（含复现/期望），带 preamble，派发**新 session**（`--name "↳<module>-fix@$RQ"` + `--env
   FLEET_ROLE=worker --env FLEET_BASE_BRANCH="$INT" ...`，同 Step 2）。fix session 同样 base 锚定 `fleet/<RQ>`（已含本 RQ 各
   模块的落地）、改完 `cc-fleet-land` 回 `fleet/<RQ>`。
3. 回 Step 3 监控 → Step 4 重新验收。直到整体效果达标，进 Step 6。

### Step 6 — 验收通过后：合集成分支回共享分支 + 收尾（共享分支唯一一次合入）⭐

**只有整体验收通过后**，主 session 才把本 RQ 集成分支合回共享开发分支——这是整条流程里**共享分支唯一一次被改动**（之前
全程 `dev/<name>` 一行没动，并发任务/用户零干扰）。在项目目录里：

```bash
RQ=...; COORD="$(~/.claude/skills/multi-session-dev/scripts/cc-fleet-coord "$RQ" --no-mkdir)"
BASE="$(cat "$COORD/base.ref")"            # 发起任务时记下的当前开发分支，如 dev/langyi
git switch "$BASE"; git pull --ff-only     # 回到共享分支并先同步远端
git merge --no-ff "fleet/$RQ"              # 把整 RQ 验收过的成果合进来（与他人改动冲突就解决，一次性）
# 改动相关回归（按项目规范，可派 verify-final session 或亲跑门禁脚本）
git push origin "$BASE"                     # 共享分支这一次才推远端
# 收尾清理（合回+校验一致后）：
git branch -D "fleet/$RQ"                                                    # 删本地集成分支
git push origin --delete "fleet/$RQ" 2>/dev/null || true                     # 若曾推过集成分支
git for-each-ref --format='%(refname:short)' "refs/remotes/origin/fleet/$RQ/*" \
  | sed 's#^origin/##' | xargs -r -I{} git push origin --delete {} 2>/dev/null || true  # 清 cc-fleet-land --push-backup 的远端备份
```
- worker 的隔离 worktree 由它们自己 `ExitWorktree` 清掉了；这里只收集成分支与远端备份。
- 合回出冲突 = 共享分支在 RQ 期间被推进过（用户/别的已合 RQ）→ 正常解决冲突补提交，不丢码、不跳校验；冲突很重需懂业务才能解
  时，可派一个 fix/integrate session 处理。
- **本步是主 session 的 git 编排动作**（合并/推送/清分支），不是写业务代码——与「主 session 不碰代码」不冲突。

## 脚本速查

脚本固定装在 `~/.claude/skills/multi-session-dev/scripts/`（从任意 cwd 都用绝对路径调）。codex/App 可见模式把
`cc-dispatch`/`cc-fleet-status`/`cc-fleet-watch`/`cc-fleet-reply` 换成对应 `-codex-app` 变体（见「codex 模式总纲」）。

| 命令 | 作用 |
|---|---|
| `eval "$(cc-fleet-init [opts] [stem])"` | ⭐**派发前唯一入口（日常只用这一条）**：一句 eval 做 ①GC 删 >7 天旧目录 ②持久序号池+原子锁取全新单调 RQ（永不重号）③解析 canonical `$COORD` ④建集成分支 `fleet/<RQ>`。stdout 只吐 `RQ=/COORD=/INT=` 三行。选项 `--base`（detached 必给）/`--no-init-base`/`--no-gc`/`--gc-days N` |
| `cc-fleet-coord <RQ>` | **解析** canonical 绝对协调目录 `<git-common-dir>/fleet/<RQ>`（worktree 无关，作 `{{COORD_DIR}}`）。`--no-mkdir` 只读解析 |
| `cc-fleet-coord <RQ> --fresh` | **防撞**解析：该 RQ 已被往轮占用（有 `.sid`/`.summary.md`/`contracts`）则 `exit 4`。用户给显式 RQ 时兜底 |
| `cc-fleet-coord <RQ> --put <relpath> [src]` | **把文件落进协调目录**（绕开后台 job 的 Write/Edit 隔离闸）。配 `Write` 到 `$CLAUDE_JOB_DIR/tmp/` 再 `--put` 用 |
| `cc-fleet-coord --gc [days]` / `--alloc [stem]` / `--init-base <RQ> [base]` / `--check-join …` | `cc-fleet-init` 拆开的底层子命令，供高级编排。`--alloc` **只取 stdout 别 `2>&1`** |
| `cc-dispatch … --sid-file "$COORD/<m>.sid"` | 派发一个后台 session 并记 sid（**必带 --sid-file**）。疑似复用别任务 RQ → `exit 6`（新任务用 `cc-fleet-init`，同任务后续批次加 `--join`）。`--help` 看全部选项 |
| `cc-dispatch-batch <RQ>` | 结构化布局批派整个 RQ（自动记 sid + 带 ↳名/FLEET_*/哨兵；**任务卡需自包含**，不自动拼 preamble） |
| `cc-fleet-status <RQ>` / `--all` / `--json` | **按 SID 名册**关联的状态表（exit 0=无在跑无异常 / 1=进行中 / 2=daemon 不可达 / 3=异常；`gone`=已结束）。**带 `result:` 的 canonical 回执 = `receipt=1` / 🧾 = 已完成（抗 respawn），即便 daemon 仍报 running** |
| `cc-fleet-watch <RQ>`（交给 **Monitor** 跑，`persistent:true`） | ⭐**阻塞监视→推送**：每模块结束/异常/blocked/💤静默 推一行 + ≤4min 心跳 + 全部结束退出（exit 0/3）。判「还在跑」看 `tempo` 不看 `state`；`receipt=1`→立即 `✅ 已完成 — 回执在案`、单调闩锁抗 respawn。`--wait`（交给 Bash `run_in_background`）作独立兜底完成信号。`--help` 看 `--stall-idle`/`--heartbeat`/`--fail-checks`/`--grace` 等 |
| `cc-fleet-summary <RQ｜coord-dir>` | **多通道**（canonical+主树+所有 worktree）汇总各 session 回执 |
| `cc-fleet-land <RQ>`（**worker 收尾跑**，不是主 session） | worker 自测绿后把改动**安全合入集成分支 `fleet/<RQ>`**：CAS + 自动 merge 重试，多 worker 并发落地零丢更新；**绝不碰共享分支**。冲突→exit 7（解决后重跑）/ 脏树→exit 3 / 缺集成分支→exit 2。`--push-backup <module>` 额外推远端备份 |
| `cc-fleet-reply <RQ> <module> "…"` | **给在跑 worker 发消息**（等价 FleetView 回它话）：worker `tempo=blocked` 等输入时回复/纠偏。`--short`/`--text-file`/stdin/`--dry-run` |
| `cc-fleet-kill <RQ> <module>` / `<RQ> --all` | **取消/终止 worker**（`--signal SIGKILL` 强杀，`--all` 杀整个 RQ）。只杀进程不删回执 |
| `cc-fleet-respawn <RQ> <module> --prompt-file <卡>` | ⭐**换新 session 重跑同一任务卡（灰度坏模型自救，见铁律 4）**：kill 旧 + 归档旧回执 + 用同卡另起全新 worker（自动 `--join`）。watch 自动跟到新 worker，不必重挂。`--dispatch cc-dispatch-codex-app` 切 codex 模式 |
| `cc-fleet-fix-display <RQ>` / `--all` | 修已完成 worker 在 FleetView 名字退化成 `bg`、时长退化成 `0s`（watch/summary 已自动调用；主会话 SessionStart 自动 `--all` 兜底）。根因见 `reference/fleet-display.md` |

## 命名与身份约定（与取名 hook 联动）

主/子 session 靠三重信号 + 取名 hook 一眼可分：

| 信号 | 主 session | 子 session（worker） |
|---|---|---|
| 会话名 (`--name`) | 普通中文标题，无前缀 | `↳<module>@<RQ>`（`↳` 前缀） |
| 环境变量 `FLEET_ROLE` | 无 | `worker` |
| 首条消息哨兵 | 无 | `⟦FLEET-WORKER⟧ rq=… module=…` |

- 取名 hook（`~/.claude/hooks/auto-cn-title.sh`）检测到任一信号即判定 worker，把标题设成 `↳…` 并跳过 DeepSeek；主 session
  走正常中文标题。三重信号是冗余设计：`--name`/`--env` 由 `cc-dispatch`/`cc-dispatch-batch` 自动带，哨兵由
  `dispatch-preamble.md` 首行带，任一在身份就成立。
- **worker 显示名/时长会自愈**（daemon respawn/完成时会把名字退化成 `bg`、时长退化成 `0s`）：取名 hook 在 SessionStart
  多源恢复 + 直改 `state.json.name`，`cc-fleet-fix-display --all` 做完成态全局兜底，无需人工。完整根因与三层修复、回归用例
  见 **`reference/fleet-display.md`**。

## 失效降级（cc-dispatch 用的是非公开协议）

Claude Code 升级可能让 daemon 协议变动。信号 = `cc-dispatch` 退出码 `2`（daemon 不可达）或 `3`（schema/proto 不兼容）：
- 退出 2：先跑一次 `claude agents --json` 拉起 daemon 再重试。
- 退出 3：协议变了。`cc-dispatch-batch` 会自动打印**可手动派发的清单**（MODULE/CWD/NAME/PROMPT FILE）——新开 terminal 跑
  `claude agents`，照清单在 FleetView 手动「New agent」派发，**方法论流程不变**。要修脚本照 `reference/PROTOCOL.md`
  §9「协议升级应对剧本」更新 `cc-dispatch` 的字段构造（通常改 3-5 行）。
- codex 模式的问题优先看 `cc-dispatch-codex-app` / `cc-fleet-status-codex-app` / `cc-fleet-watch-codex-app` /
  `cc-fleet-reply-codex-app` 的报错与 `--help`；底层兼容策略只在脚本内维护，Claude 模式不受 Codex 脚本变动影响。

## 参考文件（reference/，按需展开）

| 文件 | 内容 |
|---|---|
| `dispatch-preamble.md` | ⭐派发 prompt 必带前缀（锁范围 + 自测 + L2 承上启下文档 + 回执契约）。codex 模式对应 `codex-app-dispatch-preamble.md` |
| `task-card-template.md` | 模块任务卡模板 |
| `contract-first.md` | ⭐跨模块协同两模式（契约先行/提供方先行）+ 判据 + 契约文件模板 + 与三层测试关系 |
| `doc-traceability.md` | ⭐文档三层模型 + L2 模块需求文档模板 + 业界依据（RTM/ISO 29148/ASPICE 等） |
| `pitfalls.md` | ⭐死等四根因复盘 + RQ 编号串台事故 + 灰度坏模型识别细节 + CLAUDE.md 自动加载历史 |
| `fleet-display.md` | FleetView `bg`/`0s` 显示自愈的根因与三层修复、回归用例 |
| `PROTOCOL.md` | daemon 协议参考（cc-dispatch 失效时照它修） |

## 注意事项

- 主 session 一旦发现自己在读/改模块源码，就是越界——退回去，写成任务卡派给模块 session。
- 派发 prompt **永远**带前缀（默认 `dispatch-preamble.md`；codex 模式由 `cc-dispatch-codex-app` 自动处理）。回执是主 session
  唯一可靠的「改动雷达」。
- **一个子 session 只承担一块代码上独立的内容——默认一个模块，可按需更细，任何情况下不许把多个模块合给一个 session**（粒度
  铁律）。接口两端本就该是两个 session；会碰同一文件的（登记散点等）由主 session 排定合回顺序串行消化。
- 模块 session 报「需裁决/要扩大范围」时由主 session 裁定，别让它自行蔓延改动面。整体效果不达标只许**派新 session 修**，主
  session 不下场改代码。
