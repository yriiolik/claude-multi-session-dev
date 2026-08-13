# FleetView 显示名/时长自愈（bg / 0s / 被抢名 的根因与修复）

> **主 session 运行时不需要读本文**——显示名与时长由取名 hook + `cc-fleet-name-guard` +
> `cc-fleet-watch`/`cc-fleet-summary` 自动修复，无需人工。本文是这套自愈机制的根因考古与回归依据，
> 供维护脚本时参考。

FleetView 列表显示名读的**始终**是 `~/.claude/jobs/<short>/state.json` 的 `.name`（缺失时回退显示
`.template`，daemon spare 池的模板名就是字面量 `bg`）。围绕这个字段目前有两条独立的故障线：

| | 故障线 A/B：`bg` / `0s` | 故障线 C：名字被抢 |
|---|---|---|
| 现象 | 已完成 worker 名字变 `bg`、时长变 `0s` | **运行中**就丢 `↳`，名字变英文小写短语 |
| 首次实测 | 2026-06-22 / cli 2.1.185 | 2026-08-13 / cli 2.1.231 |
| 肇事者 | daemon 完成态落盘把记录写成极简形态 | CC 内建 LLM 自动取名器（`agent_namer`） |
| 正解 | 事后用权威数据修回（`cc-fleet-fix-display`） | 事前抢占（`cc-fleet-name-guard`） |

下面先讲 C（新），再讲 A/B（旧）。

---

## 故障线 C：名字被内建自动取名器抢走（2.1.231+）

**现象.** 主 session 一眼分不出哪些是子 session：FleetView 里运行中的 worker 叫
`fleet warehouse config` / `voms foundation context setup` 这类英文小写短语，`↳<module>@<RQ>` 没了。
前台普通会话同理——取名 hook 出的中文名被 `deploy to cce test` 这类英文短语顶掉。

**根因（2.1.231 二进制逆向 + 实测）.**
- 2.1.231 起 CC 内建了一个 LLM 取名器：side-query `querySource:"agent_namer"`，提示词是
  *"2-4 word lowercase label for this job"*，命中后写 `state.json` 的 `.name` + `.nameSource="auto"`，
  并同步成会话的 ai-title / agent-name。
- 它唯一的让位条件：**写回前重读 `state.json`，若 `.name` 已非空就永久放弃**（`if(a.name) return`，
  实测一旦被占后续再不重取）。所以这不是"持续覆盖"，而是**一次性抢跑**——谁先写进去谁赢。
- 我们输在起跑线：`cc-dispatch` 走 daemon `source:"fleet"` 派发，而 daemon 对 fleet/spare 派发
  **不在派发时落 state.json 种子**（`spawnBgSession` 跳过 seed 写盘），state.json 是 worker 自己起来后才建的。
  取名 hook 在 UserPromptSubmit 时刻去写 `.name`，此时文件往往**还不存在** → 静默 no-op → 几秒后被占。
  worktree 隔离的 worker 建树更慢，几乎必输。
- 注意 transcript 里的 `custom-title` **一直是对的**（实测某 worker 有 24 条 `↳…` 的 custom-title），
  所以"看标题以为没事、看列表却是英文名"——排查时别被标题误导，**认 `state.json.name`**。

**修复分层.**
1. **事前抢占（主）**：`cc-fleet-name-guard` —— 脱离父进程的后台守护，在时间窗内反复确保
   `.name == 期望名`；state.json 还没出生就等它出生。`cc-dispatch` 派发成功后自动 `--detach` 拉起
   （`CC_FLEET_NAME_GUARD=0` 可关），取名 hook 在 state.json 缺失时也会拉起它。
   ⚠ 它的单例锁**不能**放在 job 目录里——那时目录还不存在，锁建不出来就会在最该干活时罢工（踩过）。
2. **事后兜底**：`cc-fleet-fix-display` 新增 C 类判据（现名非 `↳` 形且 `nameSource != user`），
   **允许修运行中的 job**（只改 `.name`，绝不动运行中 job 的时间戳，落盘前再比一次 mtime）。
   身份来源新增最强的一条：`state.json.intent` 首行的 `⟦FLEET-WORKER⟧` 哨兵——不 fork git、不读别的文件、
   跨 worktree/跨仓库路径都成立。
3. **取名 hook**：不再只写 worker 的名字——**普通会话的 `.name` 也要写**（否则中文名同样被英文短语顶掉）。
   唯一不碰的是用户 Ctrl+R 手改名（`nameSource=user` 且非 `↳` 形）。DeepSeek 2s 没赶上转后台的那条路径，
   拿到结果后也立刻落盘 + 起守护，不再干等下一条 prompt（很多会话根本没有下一条）。

**为什么"写运行中会话的 state.json"是安全的**：daemon 每次落盘前都会重读磁盘上的 state.json 再合并
（`name: k?.name`），我们写进去的名字会被它原样带走。实测给两个运行中的 worker 写回 `↳` 名后 30s 稳定不变。

**回归用例**：`tests/test-cc-fleet-name-guard.sh`（25 项）、`tests/test-name-guard-e2e.sh`
（端到端：假 daemon socket → cc-dispatch → 守护 vs 自动取名器抢跑；含**关掉守护必须复现故障**的反证）。

---

## 故障线 A/B：bg / 0s

## 现象

被 `cc-dispatch` 派发的 worker **完成后**，`claude agents` FleetView「Completed」区里名字列退化成字面量
**`bg`**、时间列退化成 **`0s`**（只影响刚完成的；运行中的、更早完成的都正常）。

## 根因（daemon 完成态落盘行为，PROTOCOL.md §8/§11 记录，历史随版本变动）

- FleetView 显示读磁盘 `~/.claude/jobs/<short>/state.json`。
- 新版（CC 2.1.16x+）任务列表显示名只读 `state.json.name`，缺失时回退显示 `.template`——spare 池后台模板名
  就是字面量 **`bg`**。
- daemon 在 worker **完成时**把这份记录重写成极简形态：丢掉 `.name`（→ 回退 `bg`）、把
  `createdAt`/`firstTerminalAt`/`updatedAt` **塌缩成同一瞬间**（→ 时长 = 终点 − 起点 = 0 → `0s`）。
- 取名 hook（`auto-cn-title.sh`）只在 SessionStart/UserPromptSubmit 补 `.name`，完成后这两个事件都不再触发，
  所以补不回来。daemon 是闭源二进制改不了，但这份完成态记录**写完即稳定**——完成后用权威数据修回去即稳稳生效。

## 三层修复（自愈、无需人盯）

**① 运行/respawn 时：hook 直改 `state.json.name`。** hook 输出的 `sessionTitle` 只写进 transcript 的
`custom-title`/`agent-name`（只影响 `/resume` 列表与会话标签），**不进 `state.json.name`**——所以 spare 池
respawn 完成后的 worker 列表仍退化成 `bg`。修复：取名 hook 在 SessionStart 恢复出 `↳` 名后、以及 worker 首条
UPS 命中后，**直接原子改写 `$CLAUDE_JOB_DIR/state.json` 的 `.name`（并置 `.nameSource=user`）**。名字多源恢复
优先级：① transcript 的 `⟦FLEET-WORKER⟧ rq=… module=…` 哨兵（最稳，跨 respawn 永在）→ ② `FLEET_*` env / `↳`
job 名 → ③ `<sid>.title` 缓存 → ④ transcript 既有 `custom-title`/`agent-name`。
安全约束：只处理 worker（标题带 `↳`），**绝不碰普通/主 session 命名**（其 name 由 CC 原生维护、不退化，避免覆盖
用户 Ctrl+R 手改名）；幂等；原子写；仅在 `state.json` 可解析时动手，异常静默 no-op。

**② per-RQ 精修** `cc-fleet-fix-display <RQ>`：用名册名（`↳<module>@<RQ>`）+ 该 session transcript 首/末时间戳，
把磁盘 `state.json` 的 `name`/`createdAt`/`firstTerminalAt`/`updatedAt` 修回（幂等、原子、只动**已完成**的 worker，
绝不碰运行中/普通会话）。`cc-fleet-watch`（每有模块结算 + 退出前）和 `cc-fleet-summary`（收回执时）已**自动
best-effort 调用**它。

**③ 全局兜底** `cc-fleet-fix-display --all`（2026-06-24 / cli 2.1.187 复发后加固）——per-RQ 有两个结构盲区：
- **触发盲区**：per-RQ 只在 watch/summary 监视【该 RQ】时触发；跟进 worker（在 watch 退出后才完成 / 被 respawn）
  没人再修 → 永远卡 `bg`/`0s`。
- **名册-cwd 盲区**：per-RQ 靠 `cc-fleet-status` 从【编排者当前 cwd】解析名册；worker 跑在别的仓库路径时解析不到。

`--all` 绕开两者：扫所有 job，按**每个 job 自己的 cwd** 回溯它自己的 `git-common-dir/fleet/*/*.sid`
（sid 内容 == sessionId → 模块名 + RQ）还原 `↳<module>@<RQ>`，再兜底 transcript 的 `⟦FLEET-WORKER⟧` 哨兵；
**不要 RQ、不依赖编排者 cwd、不连 daemon**，只动【能确认是 fleet worker 且确实 `bg`/`0s` 退化】的 job
（普通会话 / 仅缺 ↳ 前缀的健康 job 一律不碰）。取名 hook 在**非 worker 会话每次 SessionStart** 节流（≥120s）
后台调一次 `--all --max-age-hours 48`——主/编排会话一启动就自动把漏网的全补上。仅想立刻全量修时手动跑
`cc-fleet-fix-display --all`。

> ⚠ 若某次升级后**运行中**或**更早完成**的 worker 也开始 `bg`/`0s`，说明退化形态变了，照
> `cc-fleet-fix-display` 头注释更新判定/恢复来源即可。

## 回归用例（两条故障线合计）

- `tests/test-auto-cn-title.sh`（多源恢复 / `state.json.name` 持久化 / **普通会话空名与被抢名都要写、
  用户手改名不覆盖** / **缺 state.json 时调起守护** / 幂等 / SessionStart sweep 门控·节流·调起，35 项）
- `tests/test-cc-fleet-name-guard.sh`（守护本体：等 state.json 出生·夺回 auto 名·幂等·尊重手改名·
  `--force`·`--detach`·**锁不落在 job 目录**·job 目录整个不存在也能干活，25 项）
- `tests/test-name-guard-e2e.sh`（端到端：假 daemon socket → `cc-dispatch` → 守护 vs 自动取名器抢跑；
  含**关掉守护必须复现故障**的反证 + `--all` 事后夺回，11 项）
- `tests/test-cc-fleet-fix-display.sh`（per-RQ；含"运行中只补名字、时间戳不碰"，21 项）
- `tests/test-cc-fleet-fix-display-all.sh`（`--all` 全局兜底：intent 哨兵还原·sid 还原·transcript 哨兵还原·
  非 fleet 不碰·纯外观不 churn·**被抢名夺回**·用户手改名不覆盖·正文引用哨兵不误判·max-age·幂等，31 项）

> ⚠ 已知与本机制无关的既有失败：`test-cc-fleet-panel-*` / `test-codex-rollout` / `test-panel-codex-e2e`
> 共 5 个文件在 main 上就红（断言值里混进了 ANSI 颜色码），与显示名自愈无关。
