# v2 统一命令

将 `FLEET` 设置为本技能 `scripts/cc-fleet` 的绝对路径。以下是参数示例，RQ、coord 和真实 ID 必须使用
工具返回值；不要重新猜测。主 session ID 可取得时传 --owner-id；否则读取适用环境变量，仍不可得时生成独立 controller ID，并标明不是会话 ID。命令输出为 JSON（read 日志与 events 除外）。Python 3 + Node.js + Git 为依赖。

```bash
"$FLEET" init --cwd /absolute/repo --host codex-app --owner-id '<真实主任务ID>'
# host: codex-app / codex-cli / claude-code；可传 --base 已有分支、--rq 指定唯一任务号
"$FLEET" prepare --coord "$COORD" --module api --backend codex --task /absolute/api.md
"$FLEET" prepare --coord "$COORD" --module ui --backend claude --task /absolute/ui.md
"$FLEET" dispatch --coord "$COORD" --module api
"$FLEET" dispatch --coord "$COORD" --module ui
"$FLEET" status --coord "$COORD"
"$FLEET" wait --coord "$COORD" --timeout 50
"$FLEET" await --coord "$COORD" --label '等 m3 回修、m7 完成'   # 长驻唤醒，配 run_in_background
"$FLEET" read --coord "$COORD" --module api
"$FLEET" collect --coord "$COORD" --module api
"$FLEET" reply --coord "$COORD" --module api --text-file /absolute/correction.md
"$FLEET" stop --coord "$COORD" --module api
# 依赖图（开局一次排好，之后编排器自动接续）
"$FLEET" prepare --coord "$COORD" --module main --self                      # solo：主 session 自己开发的 worktree
"$FLEET" prepare --coord "$COORD" --module verify --role verify --phase author --task /absolute/verify.md
"$FLEET" prepare --coord "$COORD" --module regression --role regression --after api,ui --task /absolute/reg.md
"$FLEET" queue-reply --coord "$COORD" --module verify --after regression --phase execute --text-file /absolute/exec.md
"$FLEET" advance --coord "$COORD"     # 手动推进一次；平时由 await / rescue-owners 自动调用
```

## 依赖图与自动推进

- `prepare --after a,b`：卡进入 `queued`，不需要手动 dispatch；a、b 的回执都核验为 done 后自动派发。
  派发时 worker 还没动过的 worktree 快进到集成分支最新提交（含依赖改动），`baselineCommit` 随之更新。
- `queue-reply --after a,b [--phase execute]`：给已派发的模块排一条消息；依赖全部 done 且本模块这一轮已结束
  （done/failed/blocked/needs-review）时自动发出，只发一次（`firedReply` 留痕）。典型用法：验收编写→执行；回修后自动复测。
- 推进由 `advance` 完成：`await` 每轮调用，watchdog 每分钟的 `rescue-owners` 在主端没挂 await 时也调用——主 session
  被回收时流水线照样往前走。协调目录级 flock 单例；自动派发不改写 `owner.meta`、不拉分屏。
- 唤醒规则：依赖模块 done（下游已被接续）、自己还排着消息的模块 done、被下游验收合入推动基线后旧回执变成
  `acceptance baseline changed` 都算例行，不唤醒；失败/阻塞/待核实、推进出错、无下游的完成、流水线全部收尾才唤醒。
  依赖失败导致排队卡无法推进时，唤醒输出带 `queueBlocked`；`advanced` 列出本次 await 期间自动做过的动作。
- `--phase author`（仅 verify/integ）：编写阶段回执 tests 可 `not-run`、不校验验收基线；执行阶段恢复严格验收。
- `prepare --self`：solo 模式下主 session 自己开发用的 worktree（state=`self`），不派发、不算 pending；
  主 session 提交后在该 worktree 里运行 `cc-fleet-land <RQ>`。

`prepare` 省略 --backend 时跟随主端：`claude-code` → claude，`codex-app` / `codex-cli` → codex。
Claude Code 主端显式 `--backend codex` 时固定使用 `gpt-6-astra` / `low` / `openai`；后续 reply 保持已保存 routing。

worktree 建在 `<repo>/.claude/worktrees/fleet-<RQ>-<module>`（该路径未被忽略时自动写入 `.git/info/exclude`），
不放 `.git/` 内：Vite 等开发服务器默认拒绝服务 `**/.git/**`。worker 启动目录（名册 `cwd`）取 `init --cwd`
相对仓库根的子目录；`prepare --subdir <相对路径>` 按卡覆盖，`--subdir ''` 为仓库根。Claude 与 Codex 都只加载
git 根到启动目录路径上的 CLAUDE.md / AGENTS.md（2026-09-11 实测；不会越过 worktree 根读到主 checkout），
所以子项目卡必须从子项目目录启动。`bind` 与回执里的子目录路径统一规整为 worktree 根。

`prepare --transport auto` 根据明确 host/backend 选择路径，不靠环境变量猜宿主。可强制
`--transport app-server` / `claude-bg` / `native`（原生仅 Codex App + Codex）。`--role` 为
`developer`（默认）、`scout`、`integ`、`verify`、`regression`。非开发角色不合回业务代码。
`regression` 是全 RQ 唯一跑成批 e2e 的角色（开发卡各自只跑改动相关的最小集合），范围用
`cc-fleet-e2e-scope plan` 合成后写进任务卡；规则见 delivery-quality.md §6。

`prepare` 只创建任务元数据/prompt/worktree，不调用模型；`dispatch` 才启动 worker，接受 prepared 与 queued（后者可提前手动派）。
未知启动结果保留 worktree，禁止自动重试创建。回修与追加指令一律 `reply` 原模块，投递前按「热且小才复用」判定（不分角色）：

- 复用：距上一轮结束 < `CC_FLEET_FRESH_IDLE`（默认 3600 秒，缓存还在）、上下文 < `CC_FLEET_FRESH_CTX`（默认 150000）、没压缩过。
  Claude worker 已被回收（daemon ENOJOB）时自动用其 job `state.json` 经 daemon `launch.mode=resume` 原地复活再投递（`revived=true`）。
- 换新会话：任一不满足 → `claude stop` 旧会话（Codex 旧 thread 留着不动），同一 worktree / 分支 / 任务卡起新会话，
  消息里带【接续】说明（交接文件、上一轮回执、旧 transcript 路径只许 grep），输出 `rotated`，名册 `previousSessions` 留痕。
  worker 每轮回执前覆写交接文件 `<COORD>/<module>.handoff.md`（不可写时放临时回执同目录）。
- 测不到（找不到 transcript/rollout）按复用；正在跑（running 且非 stalled）的会话不打断；`reply/queue-reply --session reuse|fresh` 强制。
- `status` 每行带 `context`（tokens / idleFor / compactions / reuse / why），面板详情页显示「下次回复复用/换新会话」；
  `advance` 的动作带 `rotated` 原因，await 唤醒摘要的 `advanced` 里可见。
同一模块人工 reply 满 `CC_FLEET_MAX_REPLIES`（默认 3）轮后再 reply 须 `--force`（熔断，先核对需求/契约/环境）。
reply 后 `CC_FLEET_REPLY_GRACE`（默认 180 秒）内，若 job `state.json` 尚未刷新，仍按 running 计，reply 后立即挂 await 不会秒退。
只有换后端/重新实现才用新模块名（如 `api-fix1`）。

## 回执与状态

`<coord>/fleet.json` 保存 RQ 和主端，`v2/<module>.json` 保存 worker。
`<module>.prompt.md` 是模型输入，`<module>.receipt.json` 是交付依据（统一 prompt 内有 schema）。
Codex 沙箱可能不允许写共享 `.git/fleet`。统一 prompt 提供当前系统临时目录下的
`fleet-v2-inbox/<RQ>/<module>-<attempt>.receipt.json` 作为备用，worker 自动使用可写路径。
status/read 同时读取这两个位置，主端必须在收工前 `collect` 将核验后的临时回执收存；不能把临时目录当永久存储。
已绑定的同一 worktree 再次 bind 不写锁；原生 worker 无法 bind 时在回执 worktree 字段报告路径，由主端 collect
核对仓库身份、独立工作树和派发基线后绑定。业务开发若 Git 元数据写权限不足，仍走正常审批流程。
回执必须匹配 rq/module/attempt。开发 done 必须有至少一个通过的检查及证据、完整 commit SHA，
该 commit 必须是集成分支祖先；检查失败、证据缺失、未合回均变成 needs-review。

- `running`：还在执行；`blocked`：输入/审批等阻塞；`needs-review`：空闲无回执或回执未通过核验。
- `unknown`：查询失败/后端缺记录；不要判失败后立即重复创建。
- `launch-uncertain`：启动/回话可能已送达；先用公开列表和名册查证，再 reconcile。
- `prepared` / `setting-up`：尚未派发/原生 worktree 仍在创建。`queued`：等依赖，编排器自动派发（计入 pending）。`self`：主 session 自己的 worktree。
- `done`：回执经过机械核验；仍需主端业务验收。verify/integ 存在 not-run 时不能 done（真正不适用项在报告说明理由，不伪装为已通过检查）。

新派发前默认先生成用户用例并引用原始需求及本次参考资料（如有）；统一 worker prompt 和 reply 都提醒该流程。
verify/integ 的 commit 必须是实际验收 SHA，且与工作树 HEAD 和当前集成分支一致；基线变化返回 needs-review，
主端评估变化并在当前基线复验、更新证据与回执。机器核验不证明用例完整或页面确已操作，主端仍按 delivery-quality.md 逐例审核证据。
失败如实保留 tests.result=failed，整体 result=failed 或 blocked；不能为让 done 通过校验隐藏失败。

```bash
"$FLEET" reconcile --coord "$COORD" --module ui
# Claude 按唯一名称+实际工作目录从公开 JSON 列表恢复 shortId/sessionId。
"$FLEET" reconcile --coord "$COORD" --module api --session-id '<已核对的真实threadId>'
# Codex 验证 thread/read 的工作目录；未知 turn/start 结果先 read，再决定 reply。
"$FLEET" events --coord "$COORD" --module api --timeout 50
# 仅 Codex：活动控制器订阅 thread/resume，JSONL 输出状态变化/turn完成，最长55秒。
```

events 的 turn-completed 只触发收回执，不直接判业务完成。连接断开用 status 补查；订阅会加载 thread，
只读 UI 面板禁止使用 events。wait 是每5秒补查的有界降级路径（≤55 秒），不会替主端建立持久唤醒。
主端需要持续监督时重复有界等待并回应用户，不做高频 read_thread 轮询。

## await：主 session 的持久唤醒（SKILL.md §6 硬纪律）

`wait` 撑不过一轮响应，而 worker 的主动推送只是快报（主端改名/已退出即静默失败，Codex worker 没有这条
通道）。**Claude Code 主端结束响应前，只要还有未终态 worker，就用 `Bash(run_in_background)` 挂一个**：

```bash
"$FLEET" await --coord "$COORD" --modules m3,m7 --label '等 m3 回修、m7 完成' --timeout 1800
```

进程退出时宿主把通知投递回主 session，无需轮询，也不依赖 worker 是否记得推送。语义：

- 进入时拍一次基线，盯已派发且未终态的模块（`prepared` 不算；`--modules` 可限定子集）。不带 `--modules` 时，
  挂着期间**新派发的模块自动纳入**（纳入本身不算变化）。基线里没有活着的模块时立即返回 `nothing-to-await`。
- 退出条件：被盯模块状态变化（`state-changed`，带 from/to、回执 summary 与 attention）、**新出现**的 stalled
  （`stalled`；挂上时已 stalled 的只等它状态变化，不会让 await 秒退空转）、或超时（`timeout`，退出码 0）。
  输出首字段 `wake` 是一行摘要，`stillPending` 告诉你还剩谁在跑；不带整份 jobs，⛔ 不要接 `| tail`。
- `--timeout` 60..86400（默认 7200）、`--interval` 5..300（默认 20）。
- 单例：运行中写 `<coord>/await.json` 心跳（pid、主 session、watching、beatAt），退出时删除。同一主 session
  已有全量 await 在跑时，再挂返回 `already-awaiting`（新模块由在跑的那个接管），所以派发/醒来后无脑重挂即可。
- 醒来后先 `status` 再决策，别拿 await 的快照当交付依据。

## stop-guard：漏挂 await 的强制兜底（Claude Code Stop hook）

`~/.claude/settings.json` 的 `hooks.Stop` 配 `python3 <skill>/scripts/cc-fleet stop-guard`。每次主 session 要结束
响应时：按 hook 的 `session_id` 找本 session 作为主端的协调目录（面板注册表 ∪ cwd 仓库 `.git/fleet`，身份认
`fleet.json` 的 owner.id 或 `owner.meta` 的 owner_session_id），有未终态 worker 且没有活着的 `await.json` 心跳
→ 返回 `decision=block`，reason 里给出要用 `run_in_background` 跑的 await 命令。自写轮询不算数。
`stop_hook_active` 为真（已提醒过一次）、worker session（`FLEET_ROLE=worker`）、非主端 session 一律放行；
守卫自身任何异常都放行，不会卡住 session。非编排 session 耗时约 60ms。

## rescue-owners：主 session 被回收/重启后的兜底唤醒（watchdog 周期调用）

await 是主 session 的子进程：主 session 被 watchdog 回收、daemon 重启或 OOM，await 跟着没了，之后 worker 交回执
不会有任何东西通知主端（2026-10-08 现场：主端 20:08 被回收，core 20:43 完成，次日 09:07 才被人叫醒）。

```bash
"$FLEET" rescue-owners                 # 扫描面板注册表里 3 天内动过的协调目录
"$FLEET" rescue-owners --coord "$COORD" --dry-run   # 只报告将唤醒谁，不复活、不注入、不推进基线
```

- 每个协调目录维护 `<coord>/owner-wake.json` 基线（各模块上次见到的状态）。首次见到只记基线；有活着的
  `await.json` 心跳时只推进基线、交给 await。
- 触发条件全满足才动手：有模块**新进入终态** ∧ 没有活着的 await ∧ 主端 transcript 最后一条事件**早于**该模块完成时刻
  （回执 mtime，缺省取 worker job 的 `updatedAt`；主端事后还活动过 = 已经看到了，不打扰）∧ 主端是 claude-code。
- 主端还在 daemon 列表里：`tempo=active` 时推迟到下一轮，空闲则直接 `reply`。已被回收：经 daemon `dispatch`
  （`launch.mode=resume`，同一 short + sessionId + respawnFlags + 显示名）原地复活，就绪后再 `reply`。
  ⛔ 不用公开 CLI 的 `claude --bg --resume`：它会 fork 出新 sessionId（实测 26db1f26→71417ba6），
  `fleet.json`/`owner.meta` 里的主端身份就对不上了，Stop 守卫和 await 都会失效。
- 同一协调目录两次唤醒至少间隔 `CC_FLEET_RESCUE_COOLDOWN`（默认 300 秒）；注入失败不推进基线，下轮重试。
  全局 flock 单例（`$CC_FLEET_HOME/rescue-owners.lock`），单个目录出错不影响其余。
- 测试用：`CC_FLEET_DAEMON_SOCK` 指定 control socket，`CLAUDE_DAEMON_CONTROL_KEY` 指定 key。
- 真实 daemon e2e（不在 run-all 里，会起一个 haiku 后台会话）：`python3 tests/e2e-live-rescue-owners.py`。

## stalled：识破「僵尸 running」

**Claude worker 先看 job 事实**（`$CLAUDE_JOBS_DIR`，缺省 `~/.claude/jobs/<shortId>/state.json`）：`claude agents --json`
在进程被回收后可能一直报 working（现场 d35a0e47：state.json 早已 done）。state.json 为终态 → 以它为准；列表项没有
`pid`/`status` → 进程已退出（`attention=process-exited`）；`tempo≠active`、`inFlight.tasks=0` 且 `updatedAt` 超过
`CC_FLEET_IDLE_GRACE`（默认 60 秒）→ 这一轮已结束且没有后台任务会再唤醒它（`attention=turn-ended-without-result`）。
后两种报 `needs-review`，await 因此在 worker 停下后约 60–80 秒内唤醒主端。在等自己后台任务的 worker（tasks>0）不受影响。

其余情况下，后端状态字会在会话结束后继续说 running（worker 末条消息没打 `result:` 时 daemon 就把它钉在 `working`），
此时 `reply` 发出去无人接收、`status` 永远 running，主端死等。`status` / `await` 因此不只看状态字，还查
**文件系统层面的活动证据**：worktree 的 git 活动与 HEAD 提交时间、`<coord>/<module>.alive` 心跳、回执/
临时回执、Claude 后端的 job `state.json` 与 transcript mtime，以及最近一次 dispatch/reply 时刻（`activeSince`）。

`running` 且这些证据全都超过 `--stale-after`（默认 600 秒，`CC_FLEET_STALE_AFTER` 可改，0 关闭）没动过
→ 标 `attention=stalled`，`status` 顶层给 `stalled` 列表，`await` 据此唤醒主端。**state 本身不改**，
stalled 只是「该去看一眼」。核实手段：`read` 看最后回复/日志、比对 worktree HEAD 有没有动。

`reply` 对 stalled 模块**直接拒绝**并提示核实（后端仍报 running、消息可能被吞），确认会话状态后再 `--force`。
已正常结束/被回收的 Claude 会话不属于此列：`reply` 按「热且小」原地复活再投递或换新会话。`reconcile` 同理只认后端真实状态：找到 job 记录只能
证明 worker 存在，`done` 的会话按 `needs-review` 报，不再硬写 running。

`stop` 中断 worker，保留会话和 worktree；不会删除分支或成果。没有运行 turn 的 Codex 任务只登记 stopped。
Codex worker 挂着目标时 `stop` 同时把目标置为 paused（active 目标会在 resume/daemon 重启后自己续跑）。

## Codex goal：提前停下自动续跑（app-server worker 默认开启）

Codex 0.164 起线程可挂持久目标（`thread/goal/*`，stable 特性 `goals`）：目标 active 时这一轮停下会自动开下一轮，
直到模型用 `update_goal` 标 complete/blocked、预算耗尽或被暂停。`dispatch` / 换新会话在 **turn/start 下发完整任务卡之后**
挂目标（先挂会让空闲线程按短目标自己开跑一轮、与任务卡抢跑），目标 = 本轮 attempt 的交付标准（合入 + 写好回执），
`reply` 在 steer/turn/start 后以新 attempt 重新激活。名册 `goal.state=attached|unavailable`，挂不上不影响派发。

`status` 对挂了目标的 Codex worker 附 `goal{status,tokensUsed,tokenBudget,timeUsedSeconds}`，并只在线程已空闲时细化状态：
上一轮完成不到 `CC_FLEET_GOAL_GRACE`（默认 90 秒）且目标 active → running（续跑间隙，不误唤醒）；blocked/usageLimited → blocked；
budgetLimited/paused/complete → needs-review，附 `goalHint`。paused 多半是用户在 Codex App 里接手了这个会话。
**回执仍是唯一交付凭据**：目标 complete 而没有本轮回执只到 needs-review。反过来，`status` 收到本轮有效回执时主动关目标
（done→complete，其余→paused，每个 attempt 一次）：实测 worker 写完回执常不标完成，放着会再续跑一轮、整段上下文重读一遍。

- 关闭：`CC_FLEET_CODEX_GOAL=0` 或 `fleet.json` 的 `"codexGoal": false`。
- 预算：`CC_FLEET_CODEX_GOAL_BUDGET` 或 `fleet.json` 的 `codexGoalBudget`（token，默认不限）。单轮基础开销约 2 万 token，
  预算按整张卡给足，耗尽后当前轮收尾即停（budgetLimited），`reply` 重新激活。
- native 路径（Codex App 主端原生任务）与 Claude worker 不挂目标。

## 兼容配置

- `CODEX_CLI_PATH`：Codex 二进制绝对路径；app-server 使用已有官方 proxy 传输辅助脚本。
- `CODEX_MULTI_SESSION_CONFIG` / `CODEX_HOME`：沿用 Codex 原有路由机制。
- `CLAUDE_CLI_PATH`：Claude 二进制；`CLAUDE_FLEET_CONFIG`：默认 `~/.claude/multi-session-dev.json`，
  派发使用其中 `worker.model/effort`；`regression` 卡缺省用 `runner`（存在时），也可 `prepare/dispatch --profile spike`。
  没有配置则不传模型/effort。
- v2 生成 UUID 后缀 RQ，协调数据在 git-common-dir，避免两端各自分配同号；历史全局序号池不受影响。
- `CC_FLEET_PANEL=0`：不在 Ghostty 分屏拉起只读面板（默认 Codex app-server 与 Claude `--bg` 派发成功即拉起，
  两种后端同屏，幂等复用）。**登记不受它影响**：`init` 与 `dispatch` 总会把协调目录登记进全局注册表，
  别的主 session 已开着的面板照样显示本任务组；面板还会自动发现已知仓库里漏登记的近期 v2 任务组
  （`--no-discover` / `CC_FLEET_PANEL_DISCOVER=0` 关）。混合后端时标题为 Fleet 并按 Claude/Codex 报数、行内标后端。
  主 session 确定已退出（fleet.json 记的 Claude 会话 UUID 已不在活会话里，或 owner.meta 的 pid 已退出）且
  没有执行中 worker 的任务组不再展示，计数行提示隐藏了几个（`--include-gone` / `CC_FLEET_PANEL_INCLUDE_GONE=1` 全显示）；
  Codex 主端与非 UUID 的 owner id 判不了，照常展示。`init` 未传 `--owner-id` 时 Claude 主端读 `CLAUDE_CODE_SESSION_ID`。
  列表每行裁到面板宽，超出屏高时标题常驻、视窗跟随光标。
  手动开/关/看状态：`scripts/cc-fleet-panel-open` / `--close` / `--status`；比例与方向见 `commands.md`。

## 权限和完成

脚本继承执行端权限配置，不替用户批准工具请求。需要用户输入时保留任务并给出具体阻塞原因。
回执只能证明技术检查通过，不能扩大合回/推送/发布授权。

## 默认权限

用户已指定 worker 默认开放权限。`prepare --permissions full`（默认）写入名册；
`prepare --permissions inherit` 保留后端配置。Codex 的 auto transport 在 full 模式走 app-server；
原生 App 接口不能指定权限，因此 `--transport native` 要搭配 `--permissions inherit`。
新 Claude worker 的 full 模式传 `--dangerously-skip-permissions`，后续 reply 沿用会话权限。
Codex 没有 permissions 字段的旧名册在下一次空闲 reply 时也使用 full；显式 inherit 的记录保持继承。
运行中的 turn/steer 不能改变权限，需等当前轮结束再 reply，脚本不会自动中断或重派。
修改脚本不会立即改变正在运行的会话。宿主强制限制仍可能拒绝执行，此时报告真实 blocked 原因。
