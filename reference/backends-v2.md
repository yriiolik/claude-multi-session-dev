# 跨客户端执行适配

## Claude 后台 session（两个主端都能调用）

`cc-fleet prepare --backend claude` 从集成分支创建独立 worktree，再由 `dispatch` 在该目录调用
`claude --bg --name ... <完整prompt>`。已有 linked worktree 不再自动创建第二层 worktree。
默认附加 `--dangerously-skip-permissions`，显式 `--permissions inherit` 时省略。
派发后用 `claude agents --json --all` 按唯一任务名称和准确 cwd 解析后台 short ID、真实 sessionId。
名称仅用于启动结果关联，后续管理使用 ID；stdout 文案/语言变化不影响关联。

状态、读取、停止使用公开 CLI。启动成功但列表尚未反映结果时显示 launch-uncertain，保留现场，稍后 reconcile。
`--bg` 输出不明确不意味着创建失败；禁止自动重派。模型/effort 使用 Claude 自己的配置，不继承 Codex 名称。

**运行中回话的有限兼容层**：当前检查到的公开 CLI 没有独立 live send/steer 命令，因此 v2 继续调用
原有 `cc-fleet-reply --short` 的私有 reply 协议。其余生命周期已不再直接访问 daemon 状态文件。
reply 协议失败明确报错，用户可 `claude attach <shortId>` 手工接续；不能伪报送达、自动重启或重复创建。
升级后若公开 CLI 提供同等能力再替换该接口。`claude --resume ... --bg` 可能建立副本，因此不把它当无条件原位回话。

## Codex app-server（两个主端/CLI 都能调用）

v2 预建 worktree，从该真实目录 thread/start，再 turn/start。不使用“先挂主目录、后覆盖 cwd”的侧栏技巧，
不临时 pin，不强行注入用户级 CLAUDE.md。独立 session 为非 ephemeral、有清晰名称。
派发脚本通过服务端分区 API 自动归入“子 session”；任务是否成功以 API 和回执为准。

派发成功后自动把协调目录登记进面板注册表，并在当前 Ghostty 窗口右侧分屏拉起只读面板
`cc-fleet-panel-codex-app`（Codex worker 进不了 `claude agents`，这块分屏是用户看子 session 的地方）。
面板读 `v2/<module>.json` 名册与 `<module>.receipt.json` 回执，幂等复用已开的分屏；Ghostty 没开/未授权/非 macOS
只提示不报错，绝不因面板让派发失败。`CC_FLEET_PANEL=0` 全局关掉。native 路径（Codex App 主端）不开面板。

传输复用 `cc-codex-app-call`，它通过官方 `codex app-server proxy` 使用 WebSocket handshake。
权限默认开放：Codex 的 thread/start、thread/resume 使用 `approvalPolicy=never` 和 `sandbox=danger-full-access`，turn/start 使用 `approvalPolicy=never` 和 `sandboxPolicy={"type":"dangerFullAccess"}`。`--permissions inherit` 不传权限覆盖。Claude Code 主端的新 Codex worker 使用用户指定的 `gpt-6-astra` / `low` / `openai`；
其他主端沿用原有 session route 的 model/modelProvider/effort。不会把 GPT-6 发到 DeepSeek provider。
模型不可用时报告实际错误，不静默更换模型；本偏好不修改全局配置或已有 session 的 routing。
DeepSeek 特例继续省去 priority 和 reasoning summary。threadId 在 turn/start 前落盘，避免后续 RPC 失败丢身份。

`events` 用持续连接接收 thread/status/changed、turn/completed；不会替 worker 回答审批请求。
连接超时/丢失后 status 补读 thread/read，回执负责持久交付状态。`read` 默认 API 消息视图，必要的历史
rollout 诊断可使用保留的旧辅助脚本；不把某个历史版本的返回条数当作永久 API 限制。

## 主端通知适配

- Codex App → Codex：宿主 wait_threads/cursor。
- Claude 主端有 Monitor：可以执行有界 wait/events，接收 stdout 变化后重新挂下一次；工具不存在则降级。
- Codex → Claude、CLI 主端：cc-fleet wait 有界等待；监控生命周期由主端维持。
- 已结束主端响应后的自动唤醒没有跨客户端通用保证。不得只起一个后台进程便宣称“会主动通知”。

## 验证基线与限制

2026-09-10 本机 Codex CLI 0.146.1、Claude Code 2.1.267。升级后用当前 CLI help 和
`codex app-server generate-json-schema` 检查方法/字段；仅在线文档有、实际 schema 尚无的字段不要直接发送。
公开文档：[Codex app-server](https://learn.chatgpt.com/docs/app-server)、
[Claude agent view](https://code.claude.com/docs/en/agent-view)。

验证分三层：离线四路适配契约测试、真实 CLI/API 连通性、真实模型 smoke。只完成前两层时不能声称
已经完成四种主 session 的真实模型端到端验证。原生 App 工具必须在实际宿主中验证，外部脚本只能测试登记契约。
