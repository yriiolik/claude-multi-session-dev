# Codex worker 后端兼容说明

## 适用基线

- 2026-08-05 已按 Codex CLI `0.146.0` 的生成 schema 验证；DeepSeek 自定义模型目录声明的最低客户端版本是 `0.144.0`。
- 首次使用或升级 Codex 后先运行：

```bash
~/.claude/skills/multi-session-dev/scripts/cc-codex-doctor --start-app-server
```

- doctor 会自动读取统一 session 路由；活动 target 是 DeepSeek 时无需额外参数。人工诊断全局 DeepSeek 配置时仍可运行：

```bash
~/.claude/skills/multi-session-dev/scripts/cc-codex-doctor --deepseek --start-app-server
```

## DeepSeek 配置约束

以 [DeepSeek 接入 Codex 文档](https://api-docs.deepseek.com/zh-cn/quick_start/agent_integrations/codex) 为准：

- 使用 `model_provider = "deepseek"`、`base_url = "https://api.deepseek.com/"` 和 `wire_api = "responses"`。
- 设置 `model_catalog_json`，让 Codex 读取模型上下文、推理档位和工具能力。不要只改模型名。
- 当前文档明确保证 `deepseek-v4-flash`；在文档正式更新前，不把 `deepseek-v4-pro` 当作默认可用模型。
- DeepSeek 的一键脚本支持 `experimental_bearer_token`。Codex 官方配置参考更推荐
  `env_key = "DEEPSEEK_API_KEY"`；两者只选一种，脚本不得打印密钥。
- 不给 DeepSeek 强塞 `service_tier` 或 `model_reasoning_summary`。普通派发完全省略 service tier；`--fast`
  只用于明确支持 `priority` tier 的 provider。

Codex CLI、ChatGPT 桌面端和 IDE 扩展读取同一份用户配置。multi-session 派发脚本在此之上自动读取独立路由文件，
Agent 无需也不应构造 provider/model/key 参数。

## 统一 session 路由：切换 DeepSeek key/模型

路由文件固定为 `$CODEX_HOME/multi-session-dev.json`，未设置 `CODEX_HOME` 时即
`~/.codex/multi-session-dev.json`。先创建安全模板：

```bash
cc-codex-session-config init
cc-codex-session-config show
```

这个文件只负责选择**新建 session**使用哪个 target。它采用严格字段白名单，不允许 `apiKey`、token 或其它未知
字段；实际 key 不在这里保存。

全局切换可直接运行 DeepSeek 官方脚本：

```bash
bash <(curl -fsSL https://cdn.deepseek.com/api-docs/codex-deepseek-setup.sh)
```

它会备份并修改 `~/.codex/config.toml`、写入 `~/.codex/models.json`；这种方式会影响 CLI、App 和 IDE 后续创建的
所有 session。再次运行脚本可切换模型或恢复备份。

如果只让 multi-session 的新 worker 使用 DeepSeek，可在基础 `config.toml` 中保留 OpenAI 默认值，并登记一个或多个
provider id。每个 id 可引用不同的认证环境变量：

```toml
model_catalog_json = "~/.codex/models.json"

[model_providers.deepseek_work]
name = "deepseek-work"
base_url = "https://api.deepseek.com/"
wire_api = "responses"
env_key = "DEEPSEEK_API_KEY_WORK"

[model_providers.deepseek_personal]
name = "deepseek-personal"
base_url = "https://api.deepseek.com/"
wire_api = "responses"
env_key = "DEEPSEEK_API_KEY_PERSONAL"
```

`env_key` 的值是**环境变量名**，不是 key 本身。确保启动 app-server 的进程环境同时含所有可能切换到的变量。也可按 DeepSeek 官方
示例在各 provider 段使用 `experimental_bearer_token = "sk-..."`，但这会把 key 明文写入配置文件；不要把 key 放入
任务卡、`--env`、RQ 元数据或 shell 命令参数。

然后把路由文件编辑为例如：

```json
{
  "version": 1,
  "active": "inherit",
  "targets": {
    "inherit": {
      "mode": "inherit",
      "description": "沿用当前 Codex 默认配置"
    },
    "deepseek-work": {
      "mode": "fixed",
      "modelProvider": "deepseek_work",
      "model": "deepseek-v4-flash",
      "reasoningEffort": "high",
      "providerType": "deepseek",
      "authEnv": "DEEPSEEK_API_KEY_WORK"
    },
    "deepseek-personal": {
      "mode": "fixed",
      "modelProvider": "deepseek_personal",
      "model": "deepseek-v4-flash",
      "reasoningEffort": "high",
      "providerType": "deepseek",
      "authEnv": "DEEPSEEK_API_KEY_PERSONAL"
    }
  }
}
```

选择 target、校验并派发：

```bash
cc-codex-session-config select deepseek-work
cc-codex-session-config validate
cc-codex-doctor --start-app-server
cc-dispatch-codex-app ...
```

`cc-dispatch-codex-app` 自己解析活动 target、检查 provider 与认证，再把 provider/model 放入 `thread/start`，把
`reasoningEffort` 映射到 `turn/start.effort`；后续 reply 新开 turn 时继续沿用。技能 Agent 的派发命令始终不变。
`select` 是原子写入，只影响之后新建的 session，不改变已存在 session。脚本仍保留 `--model-provider` / `--model`
作为人工故障诊断的一次性覆盖，但技能 Agent 禁止依赖它们。

如果还希望从外部 Codex CLI 直接使用同一套模型，可创建独立的 `~/.codex/ds-4-flash.config.toml` profile，保留
DeepSeek 官方的 `model`、`model_provider`、`model_reasoning_effort` 与 `model_catalog_json`，然后运行：

```bash
codex --profile ds-4-flash
```

profile 只用于 Codex 运行类命令，不用于 `codex debug models` 或 app-server schema 生成。provider 与 key 仍由基础
`config.toml` 的 `[model_providers.deepseek]` 提供，避免在两个文件重复保存 key。OpenAI/DeepSeek 并存时不要在 profile
中设置官方全局切换示例的 `preferred_auth_method="apikey"` / `forced_login_method="api"`；它们会要求退出当前 ChatGPT
登录。只有决定把整个 Codex 全局切换为 API-key 登录时才使用这两个字段。

`model_catalog_json` 会替换 Codex 内置模型目录。需要 OpenAI/DeepSeek 双路由时，应把当前 Codex 内置 catalog 与
DeepSeek 官方 catalog 合并，不能直接使用仅含 DeepSeek 两个模型的文件；Codex 升级后应重新合并并复测。

如果所有候选 provider 和环境变量在 daemon 启动时就已存在，仅切换 `active` 不需要重启 daemon。新增/修改
`config.toml` provider、轮换 key 值或改变 daemon 环境后，必须重启 daemon 重新加载：

```bash
codex remote-control stop --json
codex remote-control start --json
```

切换 key 就选择另一个 target/provider id；轮换同一 provider 的 key 后必须重启 daemon。切换模型则修改 target 的
`model` 并再次 `validate`。当前
DeepSeek 页面仍明确保证 `deepseek-v4-flash`，所以默认使用 flash；即使官方 `models.json` 已列出 pro，也应等页面
正式宣布支持后再把 `deepseek-v4-pro` 用作稳定默认值。

逐 session DeepSeek 派发会在 `thread/start` 和后续 `turn/start` 显式设置 `serviceTier=null`、`summary=none`，避免
基础 OpenAI 配置里的 `service_tier=priority` 或 reasoning summary 泄漏到 DeepSeek 请求。

## App-server 调用契约

`codex exec` 是稳定且简单的一次性执行入口，但它不能在已有 turn 运行时可靠地做实时 steer，也没有覆盖完整的
thread 生命周期控制。因此本技能以 app-server 作为 Codex session 主后端；`exec` 只适合作为不需要后续回复的独立任务
降级方案。

- 只通过官方 `codex app-server proxy` 定位并连接 daemon，不直接打开 Codex 私有 socket。该 proxy 只转发原始字节，
  `cc-codex-app-call` 因而负责标准 RFC 6455 WebSocket upgrade/framing（含 64-bit 长度、分片响应和 ping/pong）；不要把
  proxy 的 stdin/stdout 误当作换行分隔 JSON。
- 每条连接严格执行 `initialize` → `initialized` → 业务 request。
- 线程创建阶段可用已保存项目 cwd 做侧栏归类；首个 `turn/start` 和所有后续 turn 必须把 cwd 覆盖为真实 worker
  worktree，避免改到主工作树。
- 默认自动尝试 `codex remote-control start --json`；需要只连接现有 daemon 时传 `--no-start-app-server`。
- 标题使用 `thread/name/set`，pin 使用 `thread/metadata/update`，状态使用 `thread/read`；不直接修改 Codex App
  的全局状态 JSON。
- 默认不传 `serviceTier`；只有显式 `--fast` 才传 `priority`。

## Session 命令映射

| 技能命令 | app-server 方法 | 语义 |
|---|---|---|
| `cc-dispatch-codex-app` | `thread/start` + `turn/start` | 新建可在 App/CLI 共用存储中读取的 session |
| `cc-fleet-status-codex-app` | `thread/read` | 列出当前 RQ 的 session 与运行状态 |
| `cc-fleet-read-codex-app` | `thread/read(includeTurns=true)` | 读最近 turn、命令输出和最新回复；`--raw` 可读完整历史 |
| `cc-fleet-reply-codex-app` | `turn/steer` / `turn/start` | 对运行中 turn 纠偏，或给空闲 session 新增 turn |
| `cc-fleet-kill-codex-app` | `turn/interrupt` | 结束运行中 turn；`--archive` 另调用 `thread/archive` |

结束 session 默认不归档，因此仍可在 Codex App 中查看历史，也可再次 reply 恢复；status 会把这种状态显示为
`stopped`，避免与失败混淆。

技能创建的 thread 使用 `ephemeral=false`、`threadSource=user` 并设置可识别名称，因此能出现在 Codex App 侧栏；
Codex CLI 可运行 `codex resume --all` 查看全局 session picker。App/CLI 负责人工浏览，RQ 内的权威状态和最新持久化进度
分别由 `cc-fleet-status-codex-app` 与 `cc-fleet-read-codex-app` 提供。

## 升级检查

Codex 升级后若出现 schema 错误：

1. 运行 `cc-codex-doctor --start-app-server` 确认 CLI、proxy 和 live handshake（daemon 已在跑时可改用
   `--check-app-server`）。
2. 用当前二进制生成 schema：`codex app-server generate-json-schema --out <临时目录>`。
3. 对照 `ThreadStartParams`、`TurnStartParams`、`ThreadMetadataUpdateParams` 修正参数。
4. 跑 `tests/test-cc-codex-app-call.sh`、`tests/test-cc-dispatch-codex.sh`、
   `tests/test-cc-fleet-codex-control.sh` 和 Codex 相关全套测试。
