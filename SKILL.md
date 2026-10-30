---
name: multi-session-dev
description: >-
  在 Codex 或 Claude Code 主 session 中，按可并行的业务结果编排独立 Codex / Claude Code 子 session（不能真并行时走
  solo + 独立验收），依赖图自动接续，支持混合后端、契约先行、worktree 隔离、需求追溯、用例先行和页面验收。
  触发：用户消息任意位置出现「多 session / 多session / 多会话 / 多 session 模式」「子 session / 子会话」
  「让子 session 去…」「开几个 session」「并行 session」「独立 session」「fleet」「multi-session」时必须使用本技能，
  哪怕只是长需求末尾的一句「多 session 模式完成」、任务本身不是写代码（调研、数据分析、方案验证也算）。
  默认使用 Codex App 原生独立任务，明确选择 Claude 时使用 cc-fleet；「子 session」不是 Agent/Task subagent。
  不用于未提多 session 的普通单任务，不在 FLEET-WORKER 子 session 内再次编排。
---

# 跨客户端多 session 编排 · v2.3

本技能共享一套流程，通过主端能力和 worker 后端选择执行方式。不要把 Claude 工具名、模型名或目录
替换成 Codex 字样来移植技能。`multi-thread-dev` 是旧入口，统一使用这里的流程。

## 身份与职责

首条任务带 `⟦FLEET-WORKER⟧` / `⟦CODEX-THREAD-WORKER⟧` 或 `FLEET_ROLE=worker` 时，你是 worker：
按任务卡开发、自测、回执，不加载编排流程或再开 worker。标题 `↳` 只是展示，寻址用真实 ID。

主 session 对需求完整性和最终业务闭环负责，承担拆解、定契约、派发、监控和裁定。fanout 模式下业务代码交给独立 session，
solo 模式（见「执行模式」）由主 session 自己在 `--self` worktree 开发、验收仍交独立 verify session；主端可以维护技能、
协调文档、检查 Git 状态、审阅必要的 diff 和运行验收。纯探查优先使用可用的只读 subagent；
没有相应工具时自行只读检查，不臆造 `Agent`、`ListAgents`、`Monitor` 或 `SendMessage`。
开发 worker 是独立 session，不用内部 subagent 替代。

## 触发：口语说法一律算

用户说「多 session（模式）完成」「让子 session 去做 X」「开 N 个 session」「派个子会话」等，都等于要求本技能，
不论出现在消息开头还是长需求末尾、任务是开发还是调研/数据分析/方案验证。**子 session = 独立 Codex App 任务或
Claude 后台会话**，与 Agent/Task 工具的 subagent（子 agent）不是一回事：用户说「子 session」时不得改用 subagent，
用户只说 subagent / 子 agent 时也不进入本技能。`scripts/cc-fleet-trigger-hook` 作为两端 UserPromptSubmit hook
命中这些说法会注入提醒，看到提醒即按本技能执行（讨论或维护本技能本身除外）。

**触发后的硬约束**（2026-10-26 复盘 market-research-agents 会话：主端先自写调度器核心才加载技能，研究阶段改用自写的
`mrs` 以 `claude -p`/`codex exec` 派 session 并自设并发 3，用户纠正后才切回 cc-fleet）：

- **先加载再动手**：第一步加载本技能并 `cc-fleet init`，加载前不写业务代码、不起 session。
- **Codex 默认走 App 原生任务**：Codex App 主端未指定后端时使用 Codex；`cc-fleet prepare --transport native`
  只生成任务卡和协调元数据，session 生命周期必须使用宿主的 `create_thread` / `wait_threads` / `read_thread` /
  `send_message_to_thread`。新 RQ 不得用 `codex app-server`、`codex-server`、`codex exec` 或自写脚本代替原生任务工具。
- **Claude 才由 `cc-fleet dispatch` 派发**：用户明确指定 Claude 时，使用 `cc-fleet prepare/dispatch --backend claude`。
  宿主没有原生 Codex 工具时说明能力缺口，请用户切到 Codex App 或明确选择 Claude，不能静默切换。不得借用其它派发器（`claude -p`、裸
  `claude --bg`、项目自带/本次新写的调度器）起 session。
  被交付物本身是调度器/派发器时，它的真实运行是**被测对象**：放进 worker 或 verify 卡里当 e2e 跑，
  不拿来替代 cc-fleet 编排本任务。项目文档与用户「多 session」要求冲突时以用户为准，并在汇报里写明。
- **没有并发上限**：依赖已满足、写入范围不冲突的卡一次全部派出。不从项目文档、经验值或成本顾虑引入上限；
  只有用户明确指定才限流。

## 非代码任务：调研 / 数据分析 / 方案验证

同样走 cc-fleet，不因"产物不是代码"另起派发通道。卡片约定：产物（报告、CSV、可复现脚本、result/handoff）写在
worker 自己 worktree 的约定目录并提交，照常 `cc-fleet-land`；大数据留在仓库外，按路径 + SHA 引用，不入 Git。
回执的检查项写「产物完整性自检」（脚本可复跑、覆盖/行数核对），commit SHA 即产物版本。verify 卡做独立复算/抽样核对和结论审查，
没有页面入口时按「纯接口/CLI」记录实际验证方式。研究结论不需要单测，但数据口径、事实/推导/假设要分清。

## 路由：主端和执行后端分别选择

| 主端 host | worker backend | 新 RQ 路径 |
|---|---|---|
| codex-app | codex | **默认**：Codex App 原生 `create_thread`，原生工具管理完整生命周期 |
| codex-app | claude | 用户明确选择时：`cc-fleet` → Claude 公开后台 CLI |
| claude-code / codex-cli | claude | 用户明确选择的兼容模式 |
| codex-cli / claude-code | codex | 不支持新 RQ；切到 Codex App，不能静默回退 app-server |

用户明确指定 worker 后端时服从。**所有主端的默认后端都是 Codex**；宿主没有原生任务工具时明确报告能力缺口，
不能自动改派 Claude 或 app-server。已有 app-server RQ 只允许继续收尾，
不作为新任务或新模块的路由。同一 RQ 需要混用 Claude 时显式写 `--backend claude`。
使用前读取 [v2-commands.md](reference/v2-commands.md)。Codex App 原生路径另读
[native-codex.md](reference/native-codex.md)，跨客户端路径读 [backends-v2.md](reference/backends-v2.md)。
技能脚本相对于本 SKILL.md 的 `scripts/` 定位，不能假设已加入 PATH。

## 默认交付门槛（用户无需重复提醒）

理解需求并确定方案后，**先生成用户验收用例，再派实现卡**。覆盖核心完整主流程、
本次每项改动及相关业务分支/异常；涉及写入和异步交互时，覆盖幂等、事务失败与恢复。
**最终通过真实页面操作逐条执行这些用例**，主流程必须从业务入口连续跑到最终结果。
单测、API 测试、mock 页面或 worker 的 done 不能替代页面业务验收。
没有页面入口的纯接口/CLI 需求，明确记录不适用原因和实际入口验证方式；有页面但环境/账号/工具
不可用属于 blocked，不能降级成 API 通过。失败、阻塞、未执行均不算通过，不为通过而删用例。

首次规划必读 [delivery-quality.md](reference/delivery-quality.md)，它规定需求追溯、粒度、
上下文恢复和页面验收证据。派发使用 [task-card-template.md](reference/task-card-template.md)。
主端保留简短的持久化状态索引；压缩后、追加需求后和最终验收前重新核对原始需求与用例清单。

## 执行模式：先判断能不能真并行（目的是质量不降、时间和 token 都省）

2026-10 复盘 18 个 RQ：并行加速只有 1.17×（≥2 个 worker 同时在跑的时间多数 <25%），26% 墙钟花在主端交接；
每张卡第一次改代码前就花掉自身 23.5% 的 token（冷启动），75/137 张卡是回修/回归/验收的后续卡。
真正的质量收益来自**独立验收**（10/18 个 RQ 由它查出缺陷），而不是开发拆得多。所以先选模式：

- **solo（默认）**：本轮能**同时**开工、写入范围不重叠的开发卡 < 2 张时。主 session 自己在
  `prepare --module main --self` 建的 worktree 里开发、自测、`cc-fleet-land`；独立 `verify` 卡照派（与开发并行写验收脚本，
  见下），回修由主 session 直接改。省掉主端编排和每张卡的冷启动，质量门槛不变。
- **fanout**：≥2 张开发卡可以同时开工（契约已稳定、文件归属不重叠）时才扇出。拆卡依据是**可并行、可独立验收的业务结果**，
  不按模块编号、前后端或文件数拆：同一业务结果跨前后端/多模块时放在一张卡里；"后端做完前端才能开始"的串行拆法
  只增加冷启动和交接，⛔ 不要这样拆（契约能先定时用 contract-first 让两边同时开工）。
- 两种模式都在开局排好依赖图。Codex 原生任务由主端用 `wait_threads` 持续监督、按依赖调用原生工具接续；
  Claude 兼容模式可用 `prepare --after` / `queue-reply` 自动推进。用户明确指定拆法/worker 数时服从。

## 一轮开发

1. 读项目指导、原始需求及本次参考资料（如有），将每项行为映射到需求锚点、用例和负责人；按上一节选模式、定卡。
   指定贯穿核心主流程的负责人和独立验收者；具体规则见 delivery-quality.md。
2. 跨模块接口未稳定时，按 [contract-first.md](reference/contract-first.md) 先定契约，再并行实现，
   最后独立联调/验收。该文档里的旧派发命令以 v2 路由替代，业务分层原则继续保留。
3. `cc-fleet init` 创建唯一 RQ、协调目录、`fleet/<RQ>` 集成分支，并记录主端及可用的真实会话 ID；不可取得时使用明确标识的 controller ID，不能冒充真实会话 ID。
   只包含 base 的已提交内容；若用户要求包含未提交改动，先做受控快照，不擅自丢弃或提交用户改动。
4. 派实现卡前将用户用例和方案落盘；任务卡写清范围、原始来源、用例锚点、依赖契约、自测、L1/L2 追溯（项目需要时）、验收口径。`prepare` 生成统一
   worker prompt 和身份；Codex 原生路径使用 App 管理的工作树：用户明确要求 worktree 时由 `create_thread` 创建，
   否则 worker 在写入前用原生 `create_worktree` 建立隔离（详见 native-codex.md）。Claude 路径才由 CLI 预建
   `<repo>/.claude/worktrees/fleet-<RQ>-<module>`。
   worker 在 worktree 内与主 session 相同的子目录启动（取 `init --cwd` 相对仓库根的路径，跨子项目的卡用
   `prepare --subdir` 覆盖），客户端才会自动加载该子项目的 CLAUDE.md / AGENTS.md；从根目录启动会漏掉子项目规则。
5. **一次排好依赖图再派发**：开发卡（或 solo 的 `--self`）立即开工；`verify` 卡用 `prepare --role verify --phase author`
   与开发**同时**派出，先按用例与契约写验收脚本/造数/检查清单；将 regression 依赖全部开发卡、verify 执行阶段
   依赖 regression 的关系保存到状态索引。Claude 路径可用 `prepare --after` 和 `queue-reply` 表达这些关系。
   Codex 原生路径不使用 CLI 自动依赖派发：主 session 根据同一依赖图，在依赖回执通过后调用 `create_thread` 或
   `send_message_to_thread`；Claude 路径仍可用 `prepare --after` / `queue-reply` 自动接续。
   原生创建返回 `clientThreadId` 时仅记为 setup pending，等到真实 `threadId` 后再监控；不能把 client ID 当真实 ID，
   也不能因等待久而重复创建。取得真实 ID 后立即：登记名册、用 `move_thread_to_sidebar_section` 移入唯一的
   “子 session”分区，并在最终响应输出 `::created-thread` 指令。当前工具没有可写的父子层级容器；主会话用任务入口和
   简短状态更新展示本轮子任务，侧边栏分区用于持续查看。
   **Codex 模式禁止自动打开 Ghostty/终端 tab 或分屏进度面板**；历史 Codex 面板脚本仅供旧 RQ 手动诊断。
6. **⛔ 不许空手结束响应**：只要还有已派发未终态的 worker，结束本轮响应前必须挂上能把你唤醒的等待。
   没有任何东西会替你兜底——worker 的主动推送只是快报，会因主端改名/已退出而静默失败，Codex worker
   根本没有这条通道；写一句「等 m3 和 m7 完成后再派」就交回控制权，等于停在那里直到用户开口。
   Claude Code 主端：`Bash(run_in_background)` 跑 `cc-fleet await`，进程退出即把通知投递回主 session；
   Codex App 原生 worker 用 `wait_threads` + cursor；Claude 兼容模式使用 `cc-fleet await`。
   `await` 在被盯模块状态变化、或 running 却长时间无可观测活动（stalled）时退出；被依赖图自动接续的完成
   （依赖 done → 下游已派发/已发消息）**不唤醒**，失败/阻塞/待核实、无下游的完成、流水线全部收尾才唤醒；醒来先 `status` 再决定。
   挂着期间新派发的模块自动纳入监视；同一主 session 重复挂会返回 `already-awaiting`，所以**每次派发/醒来后照挂不误**。
   ⛔ 不要自写 `sleep`/`while true` 轮询代替 await，⛔ 不要把输出接 `| tail`（输出已精简成一行 `wake` 摘要）；
   `timeout` 只是本次等待到点（退出码 0），用同一命令重挂。worker 还在跑时尽量别用 AskUserQuestion 阻塞自己。
   Claude Code 装了 `cc-fleet stop-guard` Stop hook 时，漏挂会被拦下并给出要跑的命令——照做即可。
   await 跑在主 session 自己的进程树里，主 session 被回收/重启时 await 一起消失。本机常驻 watchdog 不回收还有后台任务
   （inFlight>0）的会话，并每分钟跑 `cc-fleet rescue-owners`：worker 进入终态而主端没人在等时，复活主 session
   （同一 sessionId）并注入「⟦fleet 自动唤醒⟧」。收到它就照提示先 `status`、再继续编排、仍有 worker 在跑就重挂 await。
   用户要求稍后跟进时才另设自动跟进。
7. Codex 原生任务的运行态只用 `wait_threads` / `read_thread`；`cc-fleet status` 只负责读取、核验协调目录或临时
   inbox 回执，不得通过 app-server 补查原生线程。`collect` 核验后收存到持久协调目录。空闲/turn 完成只是运行状态，**不等于任务交付**。
   无回执、未知状态、审批等待均需核对，不能死等或擅自判 done。原生用 `read_thread`，Claude 用 `cc-fleet read` 查看后纠偏。
   `running` 只是后端自述，会话已退出后它还会那么说（worker 末条消息没打 `result:` 时尤其如此）。
   Claude worker 的 status 已改以 job 的 `state.json` 与进程存活为准：进程没了（`process-exited`）或这一轮已停且
   无后台任务超过 60 秒（`turn-ended-without-result`）直接报 `needs-review`，await 约 1–2 分钟内唤醒你，先 `read` 核实。
   Codex 原生线程没有 CLI goal 兜底；任务卡必须明确“写回执才完成”，主 session 以 `wait_threads` 终态和回执双重核对。
   `attention=stalled`（久无可观测活动）多半就是这种僵尸 running：**reply 会被静默吞掉**。先 `read` /
   核对 worktree HEAD 证实再 `--force`。已结束/被回收的 Claude 会话则可直接 `reply`（按下条原则复用或换新会话）。
8. **回修交回原模块**：验收/回归失败时，把失败用例和证据交回负责该结果的模块。Codex 原生路径先用
   `cc-fleet reply` 生成新 attempt/prompt，再用 `send_message_to_thread` 投递同一 thread；Claude 兼容路径继续按
   “热且小”策略自动决定复用或换会话。
   以下自动轮换规则只适用于 Claude 和历史 app-server RQ：`reply` / `queue-reply` 投递前判定距上一轮结束 <1 小时、上下文 <150k、没压缩过，
   三条都满足才复用原会话（已被回收的原地复活，`revived=true`）；任一不满足就**换新会话**（输出 `rotated`）——停旧会话，
   同一 worktree、同一任务卡起新会话，靠交接文件 `<COORD>/<module>.handoff.md`（worker 每轮回执前覆写）与 worktree 现状续上。
   理由：每轮都重读整段上下文，成本≈上下文×轮数，缓存凉了首轮还要整段重写；旧过程超过一定体量后锚定与稀释盖过它的价值，
   压缩过的已是有损摘要。正在跑的会话不打断；`--session reuse|fresh` 可强制。⛔ 不因"会话没了"新开 fix 卡。
   Claude 路径可用 `queue-reply --module verify --after <回修模块> --text-file <复测说明>` 接续复测；原生路径把依赖记入
   状态索引，回修合入后由主端调用 `send_message_to_thread` 复测失败项与主流程。
   `reply` 生成新 attempt，避免上一轮 done 回执冒充新一轮完成；原生路径按输出调用宿主消息工具。
   **熔断**：同一模块人工 reply 满 3 轮（`CC_FLEET_MAX_REPLIES`）后再 reply 会被拒——反复返工说明需求/契约/环境有问题，
   先回到原始需求与用例核对（业务语义问题找用户），确认后 `--force` 或开带完整资产引用的新卡。
   接口超时显示 launch-uncertain 时先 `reconcile`，不直接再派。换后端/重新实现用新 fix 模块卡。
9. **测试范围分工（默认，用户无需提醒）**：开发 worker 只跑**自己改动相关**的最小 e2e（任务卡「E2E 范围」
   或 `cc-fleet-e2e-scope suggest` 推导，≤6 spec / ≤15 分钟），⛔ 不许跑项目全量入口——全量一轮几十分钟且
   在 e2e 锁下堵住同 RQ 其它 worker。跨模块回归由主端在模块全部落地后**统一派一张回归卡跑一次**：
   范围用 `cc-fleet-e2e-scope plan <COORD>` 合成（各 worker 登记范围 ∪ 集成分支 diff 反推），
   默认只跑这个集合；仅在改了 schema/迁移、公共基座（共享 service/中间件/鉴权/seed/全局开关）、
   或本轮要合回共享分支发布时才升级为全量，且在状态索引里写明升级理由。详见 delivery-quality.md §6。
   回归卡只跑测试读结果；Claude 路径默认用 `multi-session-dev.json` 的 runner 配置，缺少时用 worker。
   Codex 原生回归卡仍沿用 App 默认模型，不能套用 Claude 配置。
10. 独立 integ/verify 由第 5 步的编写阶段提前开工，执行阶段在依赖合入后自动开始；验收必须在含全部已合入改动的集成基线上。
   先跑通完整主流程，再按用例逐项执行分支/异常。主端核对原始需求覆盖、逐例页面证据、
   回执和必要的 diff，未达标定位回修。修复后复测失败项、受影响分支及完整主流程；记录最终验收 SHA，
   后续合入改动时评估证据失效范围，不能沿用旧基线的“全部通过”。
11. 验收通过后，按用户授权处理集成分支合回。不要从“多 session”推导出自动 push、发布、删除 worktree
    或删除分支的授权。默认保留本地成果和会话历史，明确报告未完成事项。

## 不变条件

- `cc-fleet` v2 名册包含 host/owner、backend/transport、真实 ID、worktree、attempt，不能混用旧 `.sid` 名册。
- 每个开发 worker 使用独立 worktree；从集成基线开始，提交后用现有 `cc-fleet-land` 的 CAS 合回机制。
  不在已有目录执行 `reset --hard`，不让 worker 清理自己的 worktree；完成前先保证 commit 可追溯。
- Codex 原生 App 沿用保存项目默认模型；只有用户明确要求模型时才把工具 schema 支持的 model/thinking 传给
  `create_thread` / `send_message_to_thread`。原生工具不支持的 provider 参数不通过 app-server 绕行。
- Claude worker 默认开放权限；Codex 原生任务继承 App/项目权限配置。开放权限不扩大任务授权，不代表允许推送、
  发布或删除成果；宿主若仍拒绝执行，应报告 blocked。
- 不把整份用户级 CLAUDE.md 强行提升为 Codex developer instructions。两端读取各自适用的项目规则，
  需要共享的业务规则由任务卡/契约显式引用。
- CLI watch 超时是“本次等待结束”，不是 worker 失败。工具不可用则明确降级和限制。

## 维护与旧入口

两端安装使用同一份技能源，避免正文复制漂移。旧 `cc-dispatch*`、app-server、面板和相应测试保留用于历史 RQ，
但新 Codex RQ 只走 App 原生线程工具，且不自动打开终端面板。旧参考文件中的 Monitor、强制模型、权限、清理和自动 push 约定不适用于 v2。
新命令与行为以三个 v2 reference 为准。协议基线按实际 CLI help/schema 探测，不按模型自述或历史版本号判断。
