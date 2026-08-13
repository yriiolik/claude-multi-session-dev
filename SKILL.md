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
**不碰代码**，只做：拆解 → 派发 → 监控 → 收回执 → 整体验收 → 定位回修。

## ⛔ 先自检：你是主 session 还是被派发的 worker？

**如果你是被派发的子 session（worker），立刻停用本技能。** 满足任一即为 worker：
- 会话名以 `↳` 开头；
- 环境变量 `FLEET_ROLE=worker`（Codex 后端没有这个变量，见下）；
- 首条消息以 `⟦FLEET-WORKER⟧` 哨兵行开头、或写着「你是一个模块 session」。

worker 该做的：**按任务卡在自己范围内写代码 + 自测 + 回填回执**（见首条消息里的回执契约），**不要**再往下
派发、**不要**拒绝写代码、**不要**把活又拆给别人。下面所有「编排」动作只属于主 session。

## ⛔ 两条硬边界（动手前先记牢）

### 边界 A：派发开发 worker = 跑 `cc-dispatch`，永远不是 `Agent`/Task 工具 ⭐

**这是本技能最高频、最致命的错误。** 你被要求「用多 session 完成任务」后，会本能地伸手调内置 `Agent`（Task）
工具并行——因为它是你平时做并行工作的默认工具。**在本技能里这个本能是错的**：`Agent` 起的是挂在你名下、
FleetView（`claude agents`）里根本看不见的 subagent，不是独立 session，无法独立合回、收不到回执、watcher 监控
不到——整套 fleet 编排全部失效。「用多 session」从字面就要求真正的独立 session。

**唯一判据 = worker 要不要改代码：**

| 通道 | 用途 | 机制与可见性 |
|------|------|------|
| **内置 `Agent`**（`Explore`/`general-purpose`） | **只读探查**：拆解前摸字段/接口/数据流现状，拿结论回来。**绝不让它写/改/提交代码** | 主 session 名下的 subagent，**无 `↳` 名**、**不在 `claude agents` 列表**、无独立 worktree/合回/回执/监控 |
| **`cc-dispatch`** 系列 | **开发交付**：某模块内真写代码 + 自测 + 合回 | 独立顶层 background session，带 `↳<模块>@<RQ>` 名、可见、走完整 sid 名册/watcher/回执 |

> ⚠ harness 那句「launch multiple agents in one message for parallel work」**不适用于派发开发 worker**：
> 「并行开多个 worker」= 在一条消息里连发多条 `cc-dispatch`，**不是**连发多个 `Agent` 调用。

**派发后立刻机械验证**：确认每个模块都能看到 `↳<module>@<RQ>` 条目。看不到（或只有一个无名 `source=spare` 的
running 条目）→ **你刚才误用了 `Agent`**，立刻改用 `cc-dispatch` 重派。

### 边界 B：主 session 绝不写/调/测/读业务代码 ⭐

你是**编排者**，脑力全花在「业务需求 → 模块需求」的拆解、契约编排、验收场景设计与裁定上。

- 影响面、数据流、模块边界**靠业务知识 + L1 业务需求文档 + 项目模块地图**判断，**不靠读源码**。
- 确需探查代码现状才能拆准 → **用 subagent（`Agent` 工具、`Explore` 类型）只读探查**拿结论。
  **是 subagent 在读、主 session 拿结论，主 session 仍不亲自 grep/Read。**
- **开子 session 的唯一门槛 = 要在某领域模块内部真正开发/改代码**。凡**只读**的活（确认/了解某功能、摸字段·
  接口·数据流现状）一律走 subagent，**别为此开子 session**。
- 仅当探查量**极大** / 需独立完整上下文 / 要跑长命令链时，才退回派只读 scout 子 session
  （`--name "↳scout@<RQ>"`，preamble 写明「只读不改、只回报结论」）——这是例外，不是默认。
- 一旦发现自己在读/改模块源码，就是越界——退回去，交给 subagent 探查或写成任务卡派出去。

## 何时激活本技能

- **自动判断**：当前是主 session，且用户表达「把需求拆成模块、派发多个 session 并行开发、我只统筹验收不亲自
  写代码」这类**编排意图**时自动加载。
- **显式调用**：用户输入 `/multi-session-dev`。
- **不激活**：普通单 session 开发、被派发的 worker（见上自检）、纯运维/查询、需求小到一个 session 能利落做完时。
- **只读理解类不开子 session**：用户只让你「根据代码确认 / 了解某功能 / 摸现状」这种纯只读请求 → 用 subagent
  拿结论即可（见边界 B）。

## 选后端：Claude（默认）还是 Codex

**两套后端的场景、流程、RQ、协调目录、任务卡、回执、集成分支完全相同**，只是 worker 跑在哪、命令换个后缀。

- 默认 **Claude 后端**。
- 用户明确说「codex / codex-app / App 可见」→ **Codex 后端**：所有 fleet 命令换成 `-codex-app` 后缀，
  **动手前加载 `reference/codex-mode.md`**（那里有它与 Claude 后端的几条真实行为差异）。
- 后端就绪（server 起没起、模型路由对不对、配置改了要不要重启）**全部由脚本内部自愈**——
  派发前不需要额外体检、不需要确认、不需要手动拉服务。
- Codex worker 进不了 `claude agents`（它是 app-server 里的 thread，不是进程）。派发脚本会自动在
  Ghostty 分屏拉起只读面板 `cc-fleet-panel-codex-app` 给用户看，**你不需要为此做任何事**，
  编排判断照旧只看 `cc-fleet-status-codex-app` 与回执。

## 主 session 的六步职责

1. **拆解（归属，非发明）**：把业务需求**归属到项目既有模块**——识别受影响模块、数据流/数据来源、实现策略
   （见「业务需求拆解」）。模块划分是项目自带的，只映射、禁止自创；默认**一模块=一卡=一 session**。
2. **派发**：给每个模块派一个独立后台 session，让 worker 在自己范围内开发 + **自测**。
3. **监控**：派完**立刻 arm watcher**（交给 Monitor 跑）让完成/异常**推送**给你——零轮询、不傻等。
4. **收回执**：收齐每个 session 的会话回执。
5. **验收**：从验收口径**设计 e2e 场景**（测哪些由你定），但执行**派给独立 session**（联调/验收 session）；
   你只读它的报告 + 各模块回执来**裁定**。
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
  worker 隔离后**第一件事 `git reset --hard "$FLEET_BASE_BRANCH"`** 强制锚定（防 bg 隔离从 origin/main 生的 worktree
  没有项目代码），自测绿后跑 **`cc-fleet-land <RQ>`** 把改动安全合入 `fleet/<RQ>`（内部 CAS 重试、多 worker 并发落地
  零丢更新），**绝不 merge/push 共享分支**。
- **共享分支只在主 session 整体验收通过后动一次**：把 `fleet/<RQ>` 合回 `$FLEET_BASE`（读 `base.ref`）+ push + 删
  集成分支（Step 6）。**验收完成前 `dev/<name>` 一行不动** → 其它并发任务、用户本人完全不受干扰。

> 为什么 worker 能「自己合进一条没被 checkout 的分支」且抗并发：`fleet/<RQ>` 只是 `.git` 里一条共享 ref，没在任何
> worktree 被 checkout。`cc-fleet-land` 用 compare-and-swap——先把 `fleet/<RQ>` 现 tip 合进 worker 自己分支、再
> 原子推进 ref，被抢先就重读重试。零丢更新；冲突（RQ 内按模块粒度本就罕见）留给 worker 解决后重跑。

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

**铁律 0 ｜ 不轮询，arm 一个 watcher 让 harness【推】给你。** ⭐ 派发完**立刻**把 watch 命令交给 Claude Code 原生
**Monitor 工具**（`persistent:true`）跑。它阻塞监视该 RQ，**每个模块一结束就往 stdout 写一行 → harness 变成推回
主 session 的通知**；全部结束写一条总结并退出（退出码=完成信号）。于是「子 session 结束」被转成「主 session 原生
推送」，全程零轮询、零 sleep——派完就去跟用户聊别的，done 事件自动找上门。内置 ≤4 分钟心跳，漏掉的完成事件被下条
心跳补上，保证至少每 <5min 被唤醒一次。
- **`blocked`（等授权/输入）不算结束**：先按铁律 4 判「真需要输入」还是「模型降级空转」，再走三条路之一：
  **回复它**（`cc-fleet-reply`，确属该由人拍板才用）／**换新 session 重派**（`cc-fleet-respawn`，疑似灰度坏模型时）
  ／**取消它**（`cc-fleet-kill`，只终止进程、不删已落盘回执）。

**铁律 1 ｜ 完成 = daemon `done`/`gone`（按 SID 名册关联）** 或 **canonical 回执带 `result:`——二者任一即完成。**
- 权威完成信号 = status 命令。它读协调目录 `*.sid` 名册，用 **sessionId** 关联 daemon 状态。**别靠 session 名关联**
  ——完成后 daemon 里 name 会变空，靠 name 过滤会漏掉已完成的 session 而死等。SID 是稳定键。
- ⭐ 它**同时**把 canonical 目录里带 `result:` 的回执作为第二条权威完成信号（`receipt=1` / 🧾）：只要
  `<COORD>/<module>.summary.md` 首个非空行是 `result:`，该模块即判**已完成**，**不管此刻报什么 state**——这是抗
  respawn 的关键（铁律 1.6）。看到 🧾 = 已完成，**别再当进度参考继续等**。
- `gone`（名册有、daemon 列表无）= 已结束去收回执，不是「还在跑」。

**铁律 1.5 ｜「还在跑」看 `tempo`，不看 `state`。** ⭐ daemon 报两个维度：`state`（分类器读最后一条消息文本推出，
打了 `result:` 才翻 `done`）和 `tempo`（agent 循环此刻是否在产出）。**判「要不要继续等」看 `tempo`**：`active` 才是
真在跑；`working`/`running` 但 `tempo=idle` = 循环已停（多半做完没打 `result:`，也可能卡住）→ 去收回执 / 读最后一条
消息核验，别死等。watch 已自动兜底：持续 idle 够久判【静默已结束】（推 `💤 …需核验`），一旦又活跃自动撤销。
（**Codex 后端**：thread 空闲同理不等于完成，判据同样是回执——见 `reference/codex-mode.md`。）

**铁律 1.6 ｜ 持久回执闩锁：daemon 会 respawn 已完成的后台 session，唯有持久回执抹不掉。** ⭐ spare 池会把一个早已
done 的 session respawn（`state` 翻回 `running`、`tempo` 回 `active`、`name` 变空），把易失的 `done` 完全擦掉，连铁律
1.5 的静默兜底都失效。**根治 = 用持久信号做单调闩锁**：worker 完成时把回执写进 canonical
`<COORD>/<module>.summary.md` 且**首行 `result:`**。status 标 `receipt=1`、完成判定以回执为准；watch 见 `receipt=1`
立即推 `✅ 已完成 — 回执在案` 并【单调】结案，respawn 之后翻回 running 也**不反悔**。文件持久，respawn 抹不掉。
所以这条**强依赖 canonical 协调目录**——worker 必须把回执写到那里（preamble 已要求）。

**铁律 2 ｜ 回执三通道兜底，任一拿到即可（永不把「文件出现」当门禁）。**
① **canonical 绝对协调目录**（`cc-fleet-coord <RQ>` 给路径，主仓库和所有 worktree 解析成同一处、在 `.git/` 里不进
版本库）——派发时作 `{{COORD_DIR}}`；② **`cc-fleet-summary` 自动遍历所有 git worktree** 收回执——worker 在自己
worktree 里写的回执，主 session 照样读得到，兜底主力；③ **worker 的最后一条消息**：preamble 要求 worker 把回执作为
最后一条消息发出，FleetView/通知里永远看得到，不依赖任何文件路径。前两条都没拿到时读这条。

**铁律 3 ｜ 瞬时 failed 会自愈，绝不无限等。** `failed`/error 可能是瞬时 API 抖动（如
`UNKNOWN_CERTIFICATE_VERIFICATION`），隔一会儿再查常自愈成 `done`。确认是**持续**异常再进 Step 5。任一 session 超
合理时长仍无 `done`/`gone` → 读最后一条消息 / daemon `detail` 排查，**绝不无限 sleep 等一个可能永远不出现在你所盯
路径的文件**。

**铁律 4 ｜ worker 质量降级（灰度坏模型）→ 别硬纠偏，kill 掉换【新 session】重派。** ⭐ 当前大模型灰度分流，偶尔某
worker 被分到质量很差的模型实例，硬纠偏（reply）往往无效——换个新 session 通常就分到好模型、自愈。识别信号、与
「真 blocked」的区分、别滥用的边界见 **`reference/pitfalls.md`**；对策一条命令 `cc-fleet-respawn`（用同一张任务卡
另起全新 worker，旧 worker 半成品从未落地、集成分支始终干净；**无需重挂 watch**）。

## 标准流程

### 协调目录约定

每个需求建一个协调目录存任务卡、sid、回执。**优先用 worktree 无关的 canonical 绝对路径**
`<git-common-dir>/fleet/<RQ>`（`cc-fleet-coord <RQ>` 解析）：主仓库与所有 worktree 解析一致、在 `.git/` 内不进版本库，
从根上消除「worker 写自己 worktree、主 session 读不到」和「回执误入版本库」两个坑。派发时作 `{{COORD_DIR}}`。

兼容布局：仓库根 `.fleet/<RQ>/`（用它**务必把 `.fleet/` 加进 `.gitignore`**）；结构化 `tasks/<RQ>/{modules,sessions}/`
（配合 `cc-dispatch-batch` 批派）。三种布局 summary/status 都会扫，派发侧统一用 canonical 最省心。

⚠ **主 session 作为后台 job 时，`Write`/`Edit` 对一切仓库内路径都会被隔离闸拦**（canonical 协调目录在 `.git/` 里，
同样算仓库内），而主 session 是编排者、故意不开 worktree。固定套路：用 **`Write` 工具**写到仓库外的
`$CLAUDE_JOB_DIR/tmp/<file>`，再 `cc-fleet-coord <RQ> --put <rel> "$CLAUDE_JOB_DIR/tmp/<file>"` 拷进协调目录；
`--prompt-file` 可直接吃 tmp 里的文件。这只约束主 session；worker 在自己 worktree 里正常用 `Write`/`Edit`。

### Step 1 — 拆解（主 session，只写 L1 业务需求文档 + L1.5 任务卡）

1. 用业务语言理清整体效果（验收口径），跑「业务需求拆解」四问（要查现状用 subagent 探查，别自己读源码）。
2. **维护 L1 业务需求文档（先于派发，独立 commit）**：缺失/过时先补齐到与需求一致——它是子模块向上比对的锚。
   适配项目既有约定（如 `docs/requirements/<NN>/README.md` + `procurement-flow/`）。
3. 按**项目既有模块边界**归属出 N 个子任务（模块划分用项目自带的，不自创；找不到时按项目规则判断是否新建、告知
   用户）。**一模块一卡一 session，有依赖/接口交互也不合并**：互不冲突并行派；纯先后依赖排派发顺序；命中接口交互
   按「协同两模式」。
4. 每个模块写一张任务卡（`reference/task-card-template.md`），**必填**：整体业务目标（看到全局不跑偏）、业务需求锚点
   （针对哪些 L1 条目/anchor + 变化）、验收清单（R 条目，建议 EARS 句式 `WHEN…THE SYSTEM SHALL…`，可直接转测试）。
   任务卡是**业务面委托**，不写模块内部设计（那是 L2）。
5. **设计验收场景（你的活，Step 4 交独立 session 执行）**：从「如何验证需求做完」反推一份**业务级 e2e 场景清单**
   （跨模块端到端口径），写进 L1 文档/留作验收 session 输入。

**派发前一律先跑 `cc-fleet-init`** 拿到 `$RQ` / `$COORD` / `$INT`。

> 🚫 **RQ 编号只能由脚本现场分配，绝不凭「今天日期 + NNN」在脑内重构**（真实串台事故见 `reference/pitfalls.md`）。
> 引用 RQ 的所有场合（派发 / arm Monitor / 回执路径 / 二次派发 / 跨 turn）一律从本轮 `$RQ` 变量或协调目录回读；
> 同一 RQ 的后续批次**别重跑 init**（它会另发新号）。用法与各道防串台闸见 `reference/commands.md`。

### Step 2 — 派发（每个 prompt 必带回执契约）

**每个派发 prompt = `reference/dispatch-preamble.md` 前缀（替换占位符）+ 该模块任务卡正文。** 前缀锁死「简体中文 +
写代码前先开 worktree 隔离（禁止改主工作树）+ 只在范围内改 + 自测自负责 + 先建/更新 L2 模块需求文档（承上启下）再写
代码 + 完成回填 `<COORD_DIR>/<module>.summary.md`（首行 `result:`）并把简短回执作为最后一条消息」。**不带前缀就派发
= 拿不到回执 = 主 session 失明，禁止。**（Codex 后端由 `cc-dispatch-codex-app` 自动拼对应 preamble。）

派发编排：
- 互不冲突的模块**一次性全部派发**即并行；有依赖的等前序回执 done 再派后续。
- **命中跨模块协同的分两批派**（详见 `reference/contract-first.md`）：模式 A 先单独派提供方做契约设计（`--name
  "↳<provider>-contract@$RQ"`，任务卡注明「本轮只产出 `<COORD>/contracts/` 契约、不实现业务逻辑」），主 session 评审
  定稿后**再并行派**提供方实现 + 各消费方接入（消费方任务卡把契约作依赖锚点、注明「对端按契约 mock 自测」）；模式 B
  先派提供方完整开发，done 后把真实接口形态写进消费方任务卡再派。⚠ 第二批打到**同一个 `$RQ`/COORD**——复用本轮
  `$RQ` 变量，超新鲜窗口就加 `--join` 放行。

**派发命令的完整参数、必带项与退出码见 `reference/commands.md`**（`--sid-file` 与 `--env FLEET_BASE_BRANCH` 是两个
最容易漏、漏了就出事的必带项）。

### Step 3 — 监控（arm watcher 拿推送，零轮询；见铁律 0/1）

派发完**立刻**用 **Monitor 工具**（`persistent:true`）跑对应后端的 watch 命令。⚠ 其中 `<RQ>` 必须是**本轮派发用的
同一个 `$RQ`**，别在 Monitor 的 command/description 里凭日期手敲（2026-06-09 事故就是盯错 RQ）。

推送种类：`✅ done`／`✅ 已完成 — 回执在案`（抗 respawn，铁律 1.6）／`💤 静默已结束需核验`（铁律 1.5，别当 done
盲信，要去收回执核验）／`❌ 持续异常`（已连续复查过，可直接进 Step 5）／`⏸ blocked`／≤4min 心跳。
参数与 daemon 不可达时的处置见 `reference/commands.md`。

### Step 4 — 收回执 + 整体验证

1. status 报 0 后用 `cc-fleet-summary` 收回执（多通道兜底）。逐模块读「真实改动 / 预期变化 / 影响面 / 已知缺陷 /
   自测结果 / L2 文档与双向 trace / 需裁决」。有「需主 session 裁决」的先处理（裁定范围/口径，必要时改任务卡再补派）。
   - 某模块 done/gone 但收不到回执 → 该 session 没把回执落盘，**直接读它最后一条消息**（铁律 2③）。**绝不因此判它
     「没完成」而回头死等文件**——完成与否已由 Step 3 定论。
   - **查追溯链一致性**：每条 L1 业务需求是否都有模块 L2 承接（向下覆盖无遗漏）、各模块 L2 是否都能回溯到 L1 条目
     （向上有据无越权）。链断/越权即回 Step 5。
2. **整体业务效果验证（测试三层：你设计场景，独立 session 执行，你不亲自跑测试）**：
   - **自测**（已在各模块内完成）：每个 worker 跑自己改动相关的单测/模块 e2e，对端按契约 mock。
   - **联调**（走过契约先行才需要）：派一个联调 session（`↳integ@<RQ>`）把相关模块真实拼起来（去 mock、真接口）跑通。
   - **验收**：派一个验收 session（`↳verify@<RQ>`），拿你在 Step 1 设计的**验收场景清单**做端到端验证——测哪些场景是
     你定的，验收 session 只执行并逐条回报过/不过、不过时现象指向哪个模块。
   联调/验收 session 都是被派发的子 session（带 `↳` + preamble），范围=只读各模块 + 跑 e2e/集成，**不改业务代码**，
   回执写 `<COORD_DIR>/<verify|integ>.summary.md`，并同样注入 `--env FLEET_BASE_BRANCH="$INT"`。
   > ⚠ 验收/联调必须在**集成分支 `fleet/<RQ>`** 上测——主检出停在共享分支、没有各 worker 落地的改动。preamble 已要求
   > 它们隔离后 `reset --hard "$FLEET_BASE_BRANCH"` 对齐后**只读**跑测，不落地、不碰分支。
3. 你读联调 + 验收 + 各模块回执，**对照 Step 1 的整体效果口径与验收场景清单裁定**是否达成业务需求。

### Step 5 — 定位回修循环

任一验收项不过：
1. 从验收回执的「现象指向」+ 各模块「影响面/缺陷」定位**问题模块**。
2. 写一张聚焦修复的任务卡（含复现/期望），带 preamble，派发**新 session**（`--name "↳<module>-fix@$RQ"`，同样注入
   `FLEET_BASE_BRANCH="$INT"`）。fix session 同样 base 锚定 `fleet/<RQ>`（已含本 RQ 各模块的落地）、改完
   `cc-fleet-land` 回 `fleet/<RQ>`。
3. 回 Step 3 监控 → Step 4 重新验收。直到整体效果达标，进 Step 6。**主 session 不下场改代码。**

### Step 6 — 验收通过后：合集成分支回共享分支 + 收尾（共享分支唯一一次合入）⭐

**只有整体验收通过后**，主 session 才把本 RQ 集成分支合回共享开发分支——这是整条流程里**共享分支唯一一次被改动**
（之前全程 `dev/<name>` 一行没动，并发任务/用户零干扰）。顺序：读 `<COORD>/base.ref` 拿回 base 分支 → 切回去
`git pull --ff-only` → `git merge --no-ff "fleet/$RQ"` → 跑改动相关回归 → `git push` → 清理本地/远端集成分支与
`--push-backup` 留下的远端备份。**完整命令序列见 `reference/commands.md`。**

- worker 的隔离 worktree 由它们自己清掉了；这里只收集成分支与远端备份。
- 合回出冲突 = 共享分支在 RQ 期间被推进过（用户/别的已合 RQ）→ 正常解决冲突补提交，不丢码、不跳校验；冲突很重需懂
  业务才能解时，可派一个 fix/integrate session 处理。
- **本步是主 session 的 git 编排动作**（合并/推送/清分支），不是写业务代码——与「主 session 不碰代码」不冲突。

## 子 session 场景命令速查

**这里只列「有哪些场景可用」；参数、退出码、坑一律去 `reference/commands.md` 按需加载。**
Codex 后端把命令换成 `-codex-app` 后缀（见 `reference/codex-mode.md`），场景与流程完全相同。

| 场景 | 命令 |
|---|---|
| 开工：取 RQ + 协调目录 + 集成分支 | `cc-fleet-init` |
| 解析协调目录 / 往里落文件 | `cc-fleet-coord` |
| 派发一个 worker | `cc-dispatch` |
| 批派整个 RQ（结构化布局） | `cc-dispatch-batch` |
| 阻塞监视 → 推送（交给 Monitor 跑） | `cc-fleet-watch` |
| 点查状态 | `cc-fleet-status` |
| 读 worker 最新快照 | `cc-fleet-read-codex-app`（Codex 专有） |
| 给在跑的 worker 回话 / 纠偏 | `cc-fleet-reply` |
| 终止 worker | `cc-fleet-kill` |
| 换新 session 重跑同一张卡（灰度坏模型自救） | `cc-fleet-respawn` |
| 收齐各模块回执 | `cc-fleet-summary` |
| **worker 自己**把改动落进集成分支 | `cc-fleet-land` |
| 修 FleetView 显示退化（`bg` / `0s`） | `cc-fleet-fix-display` |
| Codex 后端体检 / 切模型路由 | `cc-codex-doctor` / `cc-codex-session-config` |

## 命名与身份约定（与取名 hook 联动）

| 信号 | 主 session | 子 session（worker） |
|---|---|---|
| 会话名 (`--name`) | 普通中文标题，无前缀 | `↳<module>@<RQ>`（`↳` 前缀） |
| 环境变量 `FLEET_ROLE` | 无 | `worker`（**Codex 后端没有此变量**，身份靠另两个信号） |
| 首条消息哨兵 | 无 | `⟦FLEET-WORKER⟧ rq=… module=…` |

取名 hook（`~/.claude/hooks/auto-cn-title.sh`）检测到任一信号即判定 worker，把标题设成 `↳…`；主 session 走正常中文
标题。三重信号是冗余设计：`--name`/`--env` 由派发脚本自动带，哨兵由 preamble 首行带，任一在身份就成立。
worker 显示名/时长会自愈（完整根因与三层修复、回归用例见 **`reference/fleet-display.md`**），无需人工。

## 失效降级

`cc-dispatch` 用的是非公开 daemon 协议，Claude Code 升级可能让它变动。信号 = 退出码 `2`（daemon 不可达：先跑一次
`claude agents --json` 拉起再重试）或 `3`（schema/proto 不兼容）。退出 3 时 `cc-dispatch-batch` 会自动打印**可手动
派发的清单**（MODULE/CWD/NAME/PROMPT FILE）——新开 terminal 跑 `claude agents`，照清单在 FleetView 手动「New agent」
派发，**方法论流程不变**；要修脚本照 `reference/PROTOCOL.md` §9「协议升级应对剧本」更新字段构造（通常 3-5 行）。
Codex 后端的问题见 `reference/codex-mode.md` 排障段——它不影响 Claude 后端。

## 参考文件（reference/，按需展开）

| 文件 | 内容 |
|---|---|
| `commands.md` | ⭐**命令手册**：每个场景的完整参数、必带项、退出码、坑。要敲命令前加载 |
| `codex-mode.md` | ⭐**Codex 后端**：命令后缀、后端自愈、模型路由、与 Claude 后端的行为差异。用户说 codex 时加载 |
| `dispatch-preamble.md` | ⭐派发 prompt 必带前缀（锁范围 + 自测 + L2 承上启下文档 + 回执契约）。Codex 版 `codex-app-dispatch-preamble.md` |
| `task-card-template.md` | 模块任务卡模板 |
| `contract-first.md` | ⭐跨模块协同两模式（契约先行/提供方先行）+ 判据 + 契约文件模板 + 与三层测试关系 |
| `doc-traceability.md` | ⭐文档三层模型 + L2 模块需求文档模板 + 业界依据（RTM/ISO 29148/ASPICE 等） |
| `pitfalls.md` | ⭐死等四根因复盘 + RQ 编号串台事故 + 灰度坏模型识别细节 + CLAUDE.md 自动加载历史 |
| `fleet-display.md` | FleetView `bg`/`0s` 显示自愈的根因与三层修复、回归用例 |
| `PROTOCOL.md` | daemon 协议参考（cc-dispatch 失效时照它修） |
| `codex-integration.md` | Codex 版本基线、DeepSeek Responses API 配置约束、app-server 调用契约与升级检查 |

## 注意事项

- 主 session 一旦发现自己在读/改模块源码，就是越界——退回去，写成任务卡派给模块 session。
- 派发 prompt **永远**带前缀。回执是主 session 唯一可靠的「改动雷达」。
- **一个子 session 只承担一块代码上独立的内容——默认一个模块，可按需更细，任何情况下不许把多个模块合给一个
  session**（粒度铁律）。接口两端本就该是两个 session；会碰同一文件的（登记散点等）由主 session 排定合回顺序串行消化。
- 模块 session 报「需裁决/要扩大范围」时由主 session 裁定，别让它自行蔓延改动面。整体效果不达标只许**派新 session
  修**，主 session 不下场改代码。
