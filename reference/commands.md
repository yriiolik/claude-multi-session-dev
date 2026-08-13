# fleet 命令手册（按需加载）

SKILL.md 只列「哪些场景有命令可用」；参数、退出码、坑在这里。脚本固定装在
`~/.claude/skills/multi-session-dev/scripts/`，**从任意 cwd 都用绝对路径调**。

## 选哪一套：Claude 后端 vs Codex 后端

**同一套场景、同一套流程、同一套 RQ/协调目录/回执/集成分支**，只是 worker 跑在哪。
默认 Claude；用户明确说 codex / codex-app / App 可见时换 Codex。

| 场景 | Claude 后端 | Codex 后端 |
|---|---|---|
| 开工取号 | `cc-fleet-init` | 同左（共用） |
| 解析协调目录 | `cc-fleet-coord` | 同左（共用） |
| 派发 worker | `cc-dispatch` | `cc-dispatch-codex-app` |
| 看状态 | `cc-fleet-status` | `cc-fleet-status-codex-app` |
| 阻塞监视→推送 | `cc-fleet-watch` | `cc-fleet-watch-codex-app` |
| 读最新快照 | （读最后一条消息） | `cc-fleet-read-codex-app` |
| 回话/纠偏 | `cc-fleet-reply` | `cc-fleet-reply-codex-app` |
| 终止 | `cc-fleet-kill` | `cc-fleet-kill-codex-app` |
| 换新 session 重跑 | `cc-fleet-respawn` | `cc-fleet-respawn --dispatch cc-dispatch-codex-app` |
| 收回执 | `cc-fleet-summary` | 同左（共用） |
| worker 落地 | `cc-fleet-land` | 同左（共用） |
| 终端可视面板 | `claude agents` | `cc-fleet-panel-codex-app`（派发时自动分屏拉起） |

`-codex` 是 `-codex-app` 的短别名，完全等价。Codex 后端的模型路由与后端就绪细节见
`codex-mode.md`——**日常派发不需要读它，脚本会自己处理**。

---

## 开工：取 RQ + 协调目录 + 集成分支

```bash
eval "$(~/.claude/skills/multi-session-dev/scripts/cc-fleet-init)"
# → $RQ / $COORD / $INT 就绪
```
一句 eval 做四件事：GC 删 >7 天旧协调目录、从持久序号池+原子锁取**全新单调 RQ**（永不重号）、
解析 canonical `$COORD`、建集成分支 `fleet/<RQ>` 并落 `base.ref`。stdout 只吐三行可 eval 的赋值，
诊断走 stderr。

选项：`--base <branch>`（detached HEAD 必给）/ `--no-init-base`（只要 RQ+COORD）/ `--no-gc` / `--gc-days N`。

> 🚫 **RQ 只能由脚本现场分配，绝不凭「今天日期+NNN」在脑内重构**（真实串台事故见 `pitfalls.md`）。
> 同一 RQ 的后续批次（契约先行第二批、修复批）**复用本轮 `$RQ`，别重跑 init**——init 会另发新号。

## 协调目录

```bash
cc-fleet-coord <RQ>                       # 解析 canonical 目录 <git-common-dir>/fleet/<RQ>
cc-fleet-coord <RQ> --no-mkdir            # 只读解析
cc-fleet-coord <RQ> --fresh               # 防撞：已被往轮占用则 exit 4（用户给显式 RQ 时用）
cc-fleet-coord <RQ> --put <rel> [src]     # 把文件落进协调目录（绕开后台 job 的 Write 隔离闸）
```

⚠ **主 session 作为后台 job 时，`Write`/`Edit` 对一切仓库内路径都会被隔离闸拦**（canonical 协调目录
在 `.git/` 里，同样算仓库内）。固定套路：`Write` 到仓库外的 `$CLAUDE_JOB_DIR/tmp/<file>`，再
`cc-fleet-coord <RQ> --put <rel> "$CLAUDE_JOB_DIR/tmp/<file>"`。`--prompt-file` 可直接吃 tmp 里的文件。

## 派发 worker

```bash
cc-dispatch \
  --cwd "$(pwd)" \                    # 默认＝主 session 自己的 cwd，勿写死项目名
  --name "↳<module>@$RQ" \
  --env FLEET_ROLE=worker --env FLEET_RQ="$RQ" --env FLEET_MODULE=<module> \
  --env FLEET_BASE_BRANCH="$INT" \
  --sid-file "$COORD/<module>.sid" \
  --prompt-file /abs/<完整prompt>.md
```

- `--sid-file`：**必带**。没有 SID 名册，status 只能靠会变空的 session 名关联 → 已完成却被漏判 → 死等。
- `--env FLEET_BASE_BRANCH="$INT"`：开发型 worker **必带**（联调/验收/scout 等只读角色可省）。
- `--cwd`：多项目容器仓库务必指向**项目子目录**而非仓库根，否则 worker 读不到子目录 `CLAUDE.md`。
- prompt 第一行必须是 `⟦FLEET-WORKER⟧ rq=<RQ> module=<module>`（preamble 模板已含）。
- **默认不加 `--isolation worktree`**：preamble 已要求 worker 自开隔离 worktree，加了会叠两层。
- `--join`：同一任务的后续批次；撞到 `exit 6`（复用别任务 RQ 的兜底闸）时才用。
- `--dry-run` 只打印将发的 JSON。
- 退出码：`2`=daemon 不可达（先 `claude agents --json` 拉起）/ `3`=协议不兼容（见 `PROTOCOL.md`）/ `6`=疑似复用别任务 RQ。

Codex 后端把命令换成 `cc-dispatch-codex-app`，**参数完全一致**；它额外自己处理 worktree 预建、
三层 CLAUDE.md 注入、App 侧栏可见性、后端就绪自愈。Codex 专有选项：
`--keep-on-failure`（thread 建失败时保留 worktree 现场，默认自动回滚）、`--raw-prompt`、`--pin-policy`。

结构化布局可批派：`cc-dispatch-batch <RQ>`（自动扫 `tasks/<RQ>/modules/*.md`）——但它**不自动拼
preamble**，每张卡需自包含。

### 派发后立刻机械验证（漏做＝没派）
跑 `claude agents`（Codex 用 `cc-fleet-status-codex-app "$RQ"`），逐个模块确认看到 `↳<module>@<RQ>`。
看不到（或只有一个无名 `source=spare` 的 running 条目）→ **你误用了 `Agent` 工具**，立刻改用 `cc-dispatch` 重派。

### Codex 终端面板（自动分屏，无需你操心）

Codex worker 是 app-server 里的 thread，**永远不会出现在 `claude agents` 里**。所以
`cc-dispatch-codex-app` 派发成功后会自动做两件事：把本次 `$COORD` 登记进全局注册表、在当前
Ghostty 窗口右侧分屏拉起 `cc-fleet-panel-codex-app`。面板是**全局**的——跨 session、跨仓库派发的
worker 都汇总在同一块屏上；全部收工后面板自行退出、分屏随之关闭。

```bash
cc-fleet-panel-codex-app                 # 手动开（全局）
cc-fleet-panel-codex-app --rq "$RQ"      # 只看一个 RQ
cc-fleet-panel-open                      # 手动分屏拉起（幂等，已开则复用）
cc-fleet-panel-open --close              # 手动关掉面板与分屏
cc-fleet-panel-register --list           # 看注册表里有哪些协调目录
```

面板交互：`↑↓` 选择 · `→` 进详情（实时看 reasoning / 执行的命令 / 文件改动 / 回执）· `←` 返回 · `r` 刷新 · `q` 退出。
面板**只读**，不会替你 resume / unarchive / 改元数据；编排决策仍以 `cc-fleet-status-codex-app` 与
`cc-fleet-summary` 为准。不想要它：派发加 `--no-panel`，或全局 `export CC_FLEET_PANEL=0`。

## 监控（零轮询，让 harness 推给你）

派完**立刻**把 watch 交给 Claude Code 原生 **Monitor 工具**（`persistent: true`）：

```
command     = ~/.claude/skills/multi-session-dev/scripts/cc-fleet-watch <RQ>
description = fleet <RQ> 各模块完成/异常推送
persistent  = true
```

watch 阻塞监视，每模块一结束推一行，全部结束推总结并退出（exit 0=无异常 / 3=有持续异常）。
推送种类：`✅ done` / `✅ 已完成 — 回执在案` / `💤 静默已结束需核验` / `❌ 持续异常` / `⏸ blocked` / ≤4min 心跳。

参数：`--stall-idle`（判静默的空闲秒数，默认 240）/ `--heartbeat` / `--fail-checks`（默认 2 轮才判异常，吸收 API 抖动）/ `--grace` / `--wait`（静默模式，配 Bash `run_in_background` 作独立兜底）。

⚠ `<RQ>` 必须是**本轮的 `$RQ`**，别在 Monitor 的 command 里手敲日期编号（2026-06-09 盯错 RQ 事故）。

点查用 `cc-fleet-status <RQ>`：exit `0`=无在跑无异常 / `1`=进行中 / `2`=daemon 不可达 / `3`=异常终止态。
`gone`（名册有、daemon 列表无）= 已结束，去收回执，不是「还在跑」。

## 读 worker 最新状态（Codex 专有）

```bash
cc-fleet-read-codex-app <RQ> <module>          # thread/turn 状态 + 最近命令输出 + 最新回复
cc-fleet-read-codex-app <RQ> <module> --json   # 稳定摘要
cc-fleet-read-codex-app <RQ> <module> --raw    # 完整 thread/read 响应
```
Claude 后端没有对应命令——直接读它在 FleetView/通知里的最后一条消息。

## 回话 / 纠偏

```bash
cc-fleet-reply <RQ> <module> "继续，按 X 改"
```
等价于在 FleetView 里回它话。worker `tempo=blocked` 等输入、或你要纠偏时用。
`--short` / `--text-file` / stdin / `--dry-run`。Codex 后端用 `cc-fleet-reply-codex-app`：
运行中走 `turn/steer`，空闲/已停止走 `turn/start` 新增 turn。

## 终止 / 换新 session 重跑

```bash
cc-fleet-kill <RQ> <module>            # 只杀进程，不删已落盘回执
cc-fleet-kill <RQ> --all               # 整个 RQ
cc-fleet-kill <RQ> <module> --signal SIGKILL
cc-fleet-kill-codex-app <RQ> --all --archive   # Codex：--archive 才从 App 侧栏隐藏
```

```bash
cc-fleet-respawn <RQ> <module> --prompt-file <当初那张任务卡.md>
```
⭐ 灰度坏模型自救（见 `pitfalls.md`）：kill 旧 worker + 归档旧回执（防坏 worker 落了 `result:` 被回执
闩锁误判完成）+ 用同卡另起全新 worker（自动 `--join`），一条原子操作。旧 worker 半成品从未
`cc-fleet-land`、不进集成分支。**无需重挂 watch**（复用同一 `.sid`）。Codex 加 `--dispatch cc-dispatch-codex-app`。

## 收回执

```bash
cc-fleet-summary <RQ>
```
**多通道兜底**：canonical 协调目录 + 主树 + 所有 git worktree 一起扫，worker 在自己 worktree 里写的
回执也收得到。某模块 done/gone 但收不到回执 → 直接读它最后一条消息，**别回头死等文件**。

## worker 落地（worker 自己跑，不是主 session）

```bash
cc-fleet-land <RQ>
```
自测绿后把改动安全合入集成分支 `fleet/<RQ>`：CAS + 自动 merge 重试，多 worker 并发落地零丢更新，
**绝不碰共享分支**。退出码：`7`=冲突（解决后重跑）/ `3`=脏树 / `2`=缺集成分支。
`--push-backup <module>` 额外推远端备份。

## 显示自愈

`cc-fleet-fix-display <RQ>` / `--all` — 修已完成 worker 在 FleetView 里名字退化成 `bg`、时长退化成 `0s`。
watch/summary 已自动调用，主会话 SessionStart 也会 `--all` 兜底，通常无需手动。根因见 `fleet-display.md`。

## Codex 后端维护（一般不用手动跑）

```bash
cc-codex-ensure                 # 后端就绪自愈：拉起 server / 收陈旧 pid / 配置变更后重启。正常时零输出
cc-codex-ensure --verbose --json
cc-codex-doctor                 # 逐项体检报告（人看的）
cc-codex-session-config show|validate|select <target>   # 切换模型路由（由操作者执行，Agent 只读）
```
`cc-dispatch-codex-app` 已在内部自动调用 `cc-codex-ensure`，所以**派发前不需要先跑 doctor**。
只有在派发报「Codex 后端未就绪」时，才用 `cc-codex-doctor` 看逐项明细。
