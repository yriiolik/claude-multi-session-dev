---
name: multi-session-dev
description: >-
  在 Codex 或 Claude Code 主 session 中，按可并行的业务结果编排独立 Codex / Claude Code 子 session（不能真并行时走
  solo + 独立验收），依赖图自动接续，支持混合后端、契约先行、worktree 隔离、需求追溯、用例先行和页面验收。用于用户要求多 session、独立任务并行开发、
  fleet 编排或跨客户端调度；不用于普通单任务开发，不在 FLEET-WORKER 子 session 内再次编排。
---

# 跨客户端多 session 编排 · v2.2

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

## 路由：主端和执行后端分别选择

| 主端 host | worker backend | 路径 |
|---|---|---|
| codex-app | codex | 默认 app-server（开放权限）；显式继承权限时可用原生任务工具 |
| codex-app / codex-cli | claude | `cc-fleet` → Claude 公开后台 CLI |
| claude-code | codex | `cc-fleet` → Codex app-server |
| claude-code | claude | `cc-fleet` → Claude 公开后台 CLI |

用户明确指定 worker 后端时服从；**未指定时跟随主端**：Claude Code 主端默认派 Claude worker（`claude --bg`，
模型按 `~/.claude/multi-session-dev.json`），Codex 主端默认派 Codex worker。同一 RQ 可以混用两个 backend。
（2026-09-11 用户纠正：v2 曾把 Claude 主端未指定时默认成 Codex，属误改，不要恢复。）
Claude Code 主端**明确要求** Codex worker 时，脚本固定使用 `gpt-6-astra` / `low` / provider `openai`，
后续 reply 沿用登记的 routing；不要改 Claude 主 session 自己的模型，也不要将 GPT-6 名称传给 Claude 后端。
Codex CLI 没有 App 原生任务工具时自动走 app-server；不要把工具名称当作所有客户端都提供的能力。
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
- 两种模式都在开局一次排好**依赖图**（`prepare --after`、`queue-reply`），之后由编排器自动接续，主端只在失败、
  需要裁定或整条流水线收尾时被唤醒。用户明确指定拆法/worker 数时服从。

## 一轮开发

1. 读项目指导、原始需求及本次参考资料（如有），将每项行为映射到需求锚点、用例和负责人；按上一节选模式、定卡。
   指定贯穿核心主流程的负责人和独立验收者；具体规则见 delivery-quality.md。
2. 跨模块接口未稳定时，按 [contract-first.md](reference/contract-first.md) 先定契约，再并行实现，
   最后独立联调/验收。该文档里的旧派发命令以 v2 路由替代，业务分层原则继续保留。
3. `cc-fleet init` 创建唯一 RQ、协调目录、`fleet/<RQ>` 集成分支，并记录主端及可用的真实会话 ID；不可取得时使用明确标识的 controller ID，不能冒充真实会话 ID。
   只包含 base 的已提交内容；若用户要求包含未提交改动，先做受控快照，不擅自丢弃或提交用户改动。
4. 派实现卡前将用户用例和方案落盘；任务卡写清范围、原始来源、用例锚点、依赖契约、自测、L1/L2 追溯（项目需要时）、验收口径。`prepare` 生成统一
   worker prompt 和身份，CLI 路径还会预建独立 worktree（`<repo>/.claude/worktrees/fleet-<RQ>-<module>`）；原生路径让 App 创建 worktree。
   worker 在 worktree 内与主 session 相同的子目录启动（取 `init --cwd` 相对仓库根的路径，跨子项目的卡用
   `prepare --subdir` 覆盖），客户端才会自动加载该子项目的 CLAUDE.md / AGENTS.md；从根目录启动会漏掉子项目规则。
5. **一次排好依赖图再派发**：开发卡（或 solo 的 `--self`）立即开工；`verify` 卡用 `prepare --role verify --phase author`
   与开发**同时**派出，先按用例与契约写验收脚本/造数/检查清单；`regression` 卡 `prepare --after <全部开发卡>` 排队；
   验收的执行阶段用 `queue-reply --module verify --after regression --phase execute --text-file <执行说明>` 排队。
   依赖全部 done 后，`await`（以及 watchdog 每分钟的 `rescue-owners`）自动派发排队卡、自动发出排队消息，
   排队卡的 worktree 派发时快进到含依赖的最新集成基线。依赖失败时 await 唤醒主端并列出 `queueBlocked`。
   按路由派发。即时记录真实 thread/session ID；原生创建返回 `clientThreadId` 时仅记为 setup pending，
   等到真实 `threadId` 后再监控。不能把 client ID 当真实 ID，也不能因等待久而重复创建。
   Claude Code / Codex CLI 主端跑在 Ghostty 里时，CLI 路径（Codex app-server 与 Claude `--bg`）派发成功即自动在右侧分屏
   拉起只读面板 `cc-fleet-panel-codex-app`，两种后端的子 session 按任务组同屏展示；面板是全机一块，多个编排主 session 并行时所有任务组都在里面（`init` 即登记，
   `CC_FLEET_PANEL=0` 只是本 session 不开分屏，登记照做）；
   编排判断仍只看 `status` 与回执。
6. **⛔ 不许空手结束响应**：只要还有已派发未终态的 worker，结束本轮响应前必须挂上能把你唤醒的等待。
   没有任何东西会替你兜底——worker 的主动推送只是快报，会因主端改名/已退出而静默失败，Codex worker
   根本没有这条通道；写一句「等 m3 和 m7 完成后再派」就交回控制权，等于停在那里直到用户开口。
   Claude Code 主端：`Bash(run_in_background)` 跑 `cc-fleet await`，进程退出即把通知投递回主 session；
   Codex App 原生 worker 用 `wait_threads` + cursor；跨客户端可订阅 Codex events 或重复有界 `cc-fleet wait`。
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
7. `status` 从协调目录或本轮临时 inbox 读取回执，`collect` 核验后收存到持久协调目录。`status` 验证回执身份和开发 commit 是否在集成分支；空闲/turn 完成只是运行状态，**不等于任务交付**。
   无回执、未知状态、审批等待均返回需关注，不能死等或擅自判 done。`read` 查看最后回复/日志后纠偏。
   `running` 只是后端自述，会话已退出后它还会那么说（worker 末条消息没打 `result:` 时尤其如此）。
   Claude worker 的 status 已改以 job 的 `state.json` 与进程存活为准：进程没了（`process-exited`）或这一轮已停且
   无后台任务超过 60 秒（`turn-ended-without-result`）直接报 `needs-review`，await 约 1–2 分钟内唤醒你，先 `read` 核实。
   `attention=stalled`（久无可观测活动）多半就是这种僵尸 running：**reply 会被静默吞掉**。先 `read` /
   核对 worktree HEAD 证实再 `--force`。已结束/被回收的 Claude 会话则可直接 `reply`（按下条原则复用或换新会话）。
8. **回修交回原模块，会话「热且小」才复用**：验收/回归失败时，把失败用例和证据 `reply` 给负责该结果的模块。
   不分会话类型，`reply` / `queue-reply` 投递前自动判定：距上一轮结束 <1 小时（提示缓存还在）、上下文 <150k、没压缩过，
   三条都满足才复用原会话（已被回收的原地复活，`revived=true`）；任一不满足就**换新会话**（输出 `rotated`）——停旧会话，
   同一 worktree、同一任务卡起新会话，靠交接文件 `<COORD>/<module>.handoff.md`（worker 每轮回执前覆写）与 worktree 现状续上。
   理由：每轮都重读整段上下文，成本≈上下文×轮数，缓存凉了首轮还要整段重写；旧过程超过一定体量后锚定与稀释盖过它的价值，
   压缩过的已是有损摘要。正在跑的会话不打断；`--session reuse|fresh` 可强制。⛔ 不因"会话没了"新开 fix 卡。
   同时 `queue-reply --module verify --after <回修模块> --text-file <复测说明>`，回修合入后验收自动复测失败项与主流程。
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
   回归卡只跑测试读结果，派发时默认用 `multi-session-dev.json` 的 `runner` 配置（较便宜的模型），没有该配置则用 `worker`。
10. 独立 integ/verify 由第 5 步的编写阶段提前开工，执行阶段在依赖合入后自动开始；验收必须在含全部已合入改动的集成基线上。
   先跑通完整主流程，再按用例逐项执行分支/异常。主端核对原始需求覆盖、逐例页面证据、
   回执和必要的 diff，未达标定位回修。修复后复测失败项、受影响分支及完整主流程；记录最终验收 SHA，
   后续合入改动时评估证据失效范围，不能沿用旧基线的“全部通过”。
10. 验收通过后，按用户授权处理集成分支合回。不要从“多 session”推导出自动 push、发布、删除 worktree
    或删除分支的授权。默认保留本地成果和会话历史，明确报告未完成事项。

## 不变条件

- `cc-fleet` v2 名册包含 host/owner、backend/transport、真实 ID、worktree、attempt，不能混用旧 `.sid` 名册。
- 每个开发 worker 使用独立 worktree；从集成基线开始，提交后用现有 `cc-fleet-land` 的 CAS 合回机制。
  不在已有目录执行 `reset --hard`，不让 worker 清理自己的 worktree；完成前先保证 commit 可追溯。
- 模型/provider 除上述 Claude 主端显式派 Codex 的 GPT-6 low 路由外沿用各后端配置。其他主端的 Codex app-server 复用现有 session 路由；原生 App 沿用保存项目默认，
  若用户要求独立 provider 路由则选择 app-server。不把后端 A 的模型名/effort 强塞给后端 B。
- 用户偏好（2026-09-11）：worker 默认开放权限。Codex app-server 在启动、恢复及新 turn 显式设置完整访问和无需审批；Claude 新 worker 使用 `--dangerously-skip-permissions`。`prepare --permissions inherit` 可改为继承后端配置。开放权限不扩大任务授权，不代表允许推送、发布或删除成果；宿主若仍拒绝执行，应报告 blocked。
- 不把整份用户级 CLAUDE.md 强行提升为 Codex developer instructions。两端读取各自适用的项目规则，
  需要共享的业务规则由任务卡/契约显式引用。
- CLI watch 超时是“本次等待结束”，不是 worker 失败。工具不可用则明确降级和限制。

## 维护与旧入口

两端安装使用同一份技能源，避免正文复制漂移。旧 `cc-dispatch*`、面板和测试保留用于历史 RQ，
新 RQ 默认只走 `cc-fleet`。旧参考文件中的 Monitor、强制模型、权限、清理和自动 push 约定不适用于 v2。
新命令与行为以三个 v2 reference 为准。协议基线按实际 CLI help/schema 探测，不按模型自述或历史版本号判断。
