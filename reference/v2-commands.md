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
```

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

`prepare` 只创建任务元数据/prompt/worktree，不调用模型；`dispatch` 才启动 worker，且只接受 prepared。
未知启动结果保留 worktree，禁止自动重试创建。修复可用新模块名 `api-fix1`；同模块追加指令用 reply。

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
- `prepared` / `setting-up`：尚未派发/原生 worktree 仍在创建。
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

`reply` 对 stalled 模块**直接拒绝**并提示核实，确认会话还活着才用 `--force`；会话确已结束就开 fix 卡接手
（新模块名如 `m1-fix1`），⛔ 不要对死会话反复 reply。`reconcile` 同理只认后端真实状态：找到 job 记录只能
证明 worker 存在，`done` 的会话按 `needs-review` 报，不再硬写 running。

`stop` 中断 worker，保留会话和 worktree；不会删除分支或成果。没有运行 turn 的 Codex 任务只登记 stopped。

## 兼容配置

- `CODEX_CLI_PATH`：Codex 二进制绝对路径；app-server 使用已有官方 proxy 传输辅助脚本。
- `CODEX_MULTI_SESSION_CONFIG` / `CODEX_HOME`：沿用 Codex 原有路由机制。
- `CLAUDE_CLI_PATH`：Claude 二进制；`CLAUDE_FLEET_CONFIG`：默认 `~/.claude/multi-session-dev.json`，
  派发使用其中 `worker.model/effort`；可 `dispatch --profile spike`。没有配置则不传模型/effort。
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
