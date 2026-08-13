# Codex 后端模式（用户明确要求时加载）

触发：用户说「codex / codex-app / App 可见 / 子 session 要在 Codex App 里看到」。

## 唯一要记住的一句话

**把 fleet 命令换成 `-codex-app` 后缀，其余一切不变**——RQ、协调目录、任务卡、preamble、sid 名册、
回执契约、集成分支、验收流程全部共用。命令对照表在 `commands.md`。

## 后端就绪：不用你操心

`cc-dispatch-codex-app` 在创建 worktree/thread 之前会自动跑 `cc-codex-ensure`，它负责：

- app-server 没启动 → 拉起来；
- pid 文件指向已死进程 / 残留辅助进程 / 陈旧 socket → 先收干净再拉起
  （不收的话 `daemon start` 会以为"已经在跑"，空等 socket 直到超时，还会把**前几天的**旧日志当报错贴出来）；
- 活动路由目标不可用（provider 没在 `config.toml` 定义、认证缺失、模型不在目录里）→ 一句话报错，
  **不会**留下半个 worktree；
- `config.toml` / 模型目录改过但 server 还是旧配置 → 自动重启使其生效；**若此刻有 worker 正在跑，
  则不重启**，只提示"等它们结束后再派发会自动生效"，绝不为了配置新鲜打断在跑的 turn。

正常情况它**零输出**；只有真做了动作才打一行 `🔧 codex: …`。所以：

> **派发前不需要先跑 `cc-codex-doctor`，也不需要判断 server 起没起。** 直接派发即可。
> 只有派发报「Codex 后端未就绪」时，才跑 `cc-codex-doctor` 看逐项明细。

## 模型 / provider 路由

由 `$CODEX_HOME/multi-session-dev.json`（默认 `~/.codex/multi-session-dev.json`）的 active target 决定，
脚本自动应用其 provider / model / `reasoningEffort`。

- **Agent 不得拼接 provider / model / key 参数**；切换由操作者跑 `cc-codex-session-config select <target>`。
- `active=inherit` 或配置不存在 → 沿用当前 Codex 设置。
- provider 定义必须预先写进 Codex `config.toml`；真实 key 只放认证环境或 Codex 认证配置，
  **不得**进路由文件、任务卡、`--env` 或命令行。
- 默认**不传 service tier**（兼容 DeepSeek Responses API）。只有用户明确要快速模式、且当前 provider
  支持 `priority` 时才加 `--fast`；DeepSeek 不加。
- 想确认 worker 实际用的是什么模型：看 `<COORD>/<module>.codex-app.env` 的 `model=` / `model_provider=`，
  或 `cc-fleet-read-codex-app` 输出的头两行。多 key、切换与 daemon 重启规则见 `codex-integration.md`。

## 与 Claude 后端的行为差异（这几条会真的影响编排）

1. **没有 `FLEET_*` 环境变量。** app-server 协议不提供注入 shell 环境的通道，worker 里
   `env | grep FLEET_` 必然为空。身份靠 prompt 里的 preamble + `<COORD>/<module>.codex-app.env` 落盘副本。
   所以三重身份信号在 Codex 模式只剩两重（`↳` 名 + `⟦FLEET-WORKER⟧` 哨兵）。写任务卡别让 worker 读环境变量。
2. **thread 空闲 ≠ 任务完成。** Codex 的 turn 跑完就进 idle，可能只是在等你追加指令。
   `cc-fleet-watch-codex-app` 因此按回执分级：有 `result:` 回执才判 `✅ 已完成 — 回执在案`；
   空闲无回执先推 `⏳ 本轮 turn 结束但未落回执`，持续超过 `--stall-idle`（默认 240s）才判
   `💤 需核验`，并在总结里标 🟡。**看到 🟡 就去 `cc-fleet-summary` / `cc-fleet-read-codex-app` 核验，别当完成。**
3. **worker 自述模型永远是「Codex，基于 GPT-5」**——那是 Codex 内置 base_instructions 写死的一句话，
   与实际后端无关。判模型只看上面说的元数据来源。
4. **worktree 由派发脚本预建**，worker 不再自己 `EnterWorktree`（preamble 已说明等价处理）。
   thread 创建失败时脚本会自动回滚 worktree 与分支；要留现场加 `--keep-on-failure`。
5. **派发是串行的**（脚本内部 mkdir 原子锁）。并发建 thread 实测会撞 `thread not found`，
   所以即使你在一条消息里连发多条 `cc-dispatch-codex-app`，它们也会排队执行——这是正确行为，不是卡住。

## 外部查看

Codex App 侧栏直接显示这些非 ephemeral、已命名 thread；CLI 用 `codex resume --all` 看全局列表。
编排视角的最新状态仍以 `cc-fleet-status-codex-app` / `cc-fleet-read-codex-app` 为准。

## 终端面板（`cc-fleet-panel-codex-app`）

**为什么必须单独做一个**：`claude agents` 的 FleetView 只列 `~/.claude/sessions/<pid>.json`（活着的
claude 进程自注册）+ `~/.claude/daemon/roster.json`（daemon 托管的 PTY worker）里的条目。Codex worker
既没有独立进程也没有 PTY，伪造 `jobs/<short>/state.json` 或 `sessions/<pid>.json` 实测都不会被列出
（有进程/密钥校验）。所以 codex 侧的可视化只能自己出一个等价面板。

`cc-dispatch-codex-app` 派发成功后**自动**：登记 `$COORD` 进全局注册表 → 在当前 Ghostty 窗口右侧
分屏拉起面板。用法与按键见 `commands.md`。设计上的几条硬约束：

1. **只读**。面板每几秒刷一次，绝不 `thread/resume` / `thread/unarchive` / 取消 pin / 写回 `.codex-app.env`
   ——否则会和编排者的 status 调用互相打架，还会把副作用放大成刷屏级写入。状态判定与 status 脚本
   共用 `scripts/lib/codex-app-jobs.js` 的纯函数，两边对同一 worker 的答案必然一致。
2. **全局**。worker 是跨 session、跨仓库派发的，面板读全局注册表
   （`~/.claude/fleet/codex-coords.json`）而不是某个 cwd 的 `.git/fleet`。
3. **「空闲 ≠ 完成」照旧**。thread idle 但没落 `result:` 回执的，单独归入**需核验**组，不混进
   Completed，**也不触发自动关闭**——那正是最需要你看一眼的状态。
4. **自动关闭**只在「见过活跃 worker → 现在全部收工」时触发，跨 session 的新派发会重置计时。
   全绿收工才关；有需核验/异常就一直留着（要强制关加 `--close-on-attention`）。

分屏走 Ghostty 1.3+ 的 AppleScript 字典（`split ... with configuration`），不是模拟 ⌘D：模拟按键要
辅助功能权限、会被前台应用抢走、也拿不到新 surface 的句柄用于幂等与关闭。首次会弹一次"允许控制
Ghostty"授权框。Ghostty 没开 / 没授权 / 非 macOS —— 一律只提示不报错，**绝不让已派发成功的 thread
因为面板没开出来而被判失败**。

## 排障

先看对应 `-codex-app` 命令的报错与 `--help`，再依次：

```bash
cc-codex-ensure --verbose        # 后端就绪 + 路由目标是否可用
cc-codex-session-config validate # 路由文件本身是否合法
cc-codex-doctor                  # 逐项体检明细
```

底层版本基线、DeepSeek Responses API 配置约束、app-server 调用契约见 `codex-integration.md`。
Claude 模式不受 Codex 脚本变动影响。
