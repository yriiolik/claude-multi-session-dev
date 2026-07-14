# FleetView 显示名/时长自愈（bg / 0s 根因与三层修复）

> **主 session 运行时不需要读本文**——显示名与时长由取名 hook + `cc-fleet-watch`/`cc-fleet-summary`
> 自动修复，无需人工。本文是这套自愈机制的根因考古与回归依据，供维护脚本时参考。

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

## 回归用例

- `tests/test-auto-cn-title.sh`（多源恢复 / `state.json.name` 持久化 / 普通会话不被改写 / 缺 state.json 不崩 /
  幂等 / SessionStart sweep 门控·节流·调起，29 项）
- `tests/test-cc-fleet-fix-display.sh`（per-RQ，21 项）
- `tests/test-cc-fleet-fix-display-all.sh`（`--all` 全局兜底：sid 还原·哨兵还原·非 fleet 不碰·纯外观不 churn·
  running 不碰·max-age·幂等，23 项）
