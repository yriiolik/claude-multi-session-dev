# claude-multi-session-dev

Claude Code 的 **multi-session-dev** 技能：主 session 把一个开发需求按模块拆开、派发给多个独立后台 session 并行开发，最后由主 session 做整体业务效果验收的编排框架（Claude Code / Codex App 两种 worker 后端）。

> 完整规范见 [`SKILL.md`](./SKILL.md)。本 README 只讲**这个仓库是什么、装在哪、怎么同步改进**。

## 安装位置（重要）

本仓库的脚本与文档**硬编码**了技能的规范安装路径：

```
~/.claude/skills/multi-session-dev/
```

即：这个 git 仓库的工作树**就是** `~/.claude/skills/multi-session-dev` 本身。Claude Code 从该固定路径加载技能，脚本之间也以此绝对路径互相调用（`~/.claude/skills/multi-session-dev/scripts/...`）。因此本仓库不是"随便 clone 到哪都能跑"的可移植包，而是**该安装点的版本控制副本**。

在一台新机器上落地：

```bash
git clone git@github.com:yriiolik/claude-multi-session-dev.git ~/.claude/skills/multi-session-dev
```

## 外部耦合（不在本仓库内）

取名 hook `~/.claude/hooks/auto-cn-title.sh` 与本技能**双向耦合**：
- 本仓库 `tests/test-auto-cn-title.sh` 端到端测试该 hook；
- 该 hook 依据 `⟦FLEET-WORKER⟧` 哨兵 / `FLEET_ROLE` 环境变量给 worker session 命名，并回调本仓库的 `scripts/cc-fleet-fix-display`。

但 `auto-cn-title.sh` 是一个**通用取名 hook**（fleet 识别只是其中一部分），且位于技能目录之外，故**未纳入本仓库**。改动该 hook 时需自行同步，本仓库的 fleet 逻辑变更若牵动 worker 命名契约，务必一并核对该 hook。

## 目录结构

- `SKILL.md` — 技能主文档：**只讲编排方法论 + 有哪些场景命令可用**；命令参数与后端细节按需从 `reference/` 加载。
- `scripts/` — fleet 编排命令（`cc-dispatch*` 派发、`cc-fleet-*` 初始化/监控/读取/回执/收尾/复活/回复/终止；`*-codex` / `*-codex-app` 为 Codex app-server 后端变体）。
- `scripts/lib/` — 脚本共享库：`codex-config.js`（Codex CLI 发现 / config.toml 解析 / 路由目标校验）、`codex-daemon.js`（app-server 活性探测、陈旧 pid 自愈、配置漂移判定）。
- `scripts/cc-codex-ensure` — **Codex 后端一站式就绪自愈**，由 `cc-dispatch-codex-app` 内部自动调用：拉起 app-server、收陈旧 pid、config.toml 变更后按需重启（有 worker 在跑则不打断）。正常情况零输出，所以派发前**不需要**先跑 doctor。
- `scripts/cc-codex-session-config` — 统一管理 Codex worker 路由；默认读取 `~/.codex/multi-session-dev.json`，只保存 provider/model 与认证环境变量名，不保存 key。
- `scripts/cc-codex-doctor` — Codex/DeepSeek worker 后端逐项体检报告（人看的）；派发报「后端未就绪」时再跑。
- `reference/` — 命令手册与模板：`commands.md`（每个场景的完整参数/退出码）、`codex-mode.md`（Codex 后端差异）、`PROTOCOL.md`、`dispatch-preamble.md`、`task-card-template.md`、`contract-first.md`、`doc-traceability.md`、`pitfalls.md` 等。
- `tests/` — 各命令的 shell 端到端测试（hermetic：假 codex CLI / 假 app-call，不触碰真实 Codex 后端）。

## 同步改进（工作流）

对技能的任何改进都在本仓库内提交并推送，保持 GitHub 与本地安装点一致：

```bash
cd ~/.claude/skills/multi-session-dev
# 改脚本 / 文档 / 测试 …
bash tests/run-all.sh          # 跑全部测试（或 bash tests/run-all.sh codex 只跑 codex 相关）
git add -A && git commit -m "描述本次改进"
git push
```
