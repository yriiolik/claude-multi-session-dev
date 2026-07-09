# Claude Code daemon control socket 协议参考

> 反向工程自 claude code `2.1.150` (Mach-O SEA bundle)。
> **非官方文档**——协议随版本可能变更，本文件用于 `cc-dispatch` 失效时的应急修复。

## 1. 通信入口

```
Socket: /tmp/cc-daemon-<UID>/<8-hex-instance-id>/control.sock
编码:   newline-delimited JSON
模式:   request/response，单条 JSON 一行，daemon 回单条 JSON 一行
连接:   每次请求建一个新 unix socket 连接，发完接完即关闭
```

`<UID>` 是当前用户的 numeric uid（macOS 一般 `501`）。`<8-hex-instance-id>` 是 daemon 实例 ID，每次 daemon 启动可能变；遍历 `/tmp/cc-daemon-<UID>/*/control.sock` 取存在的那个即可。

Daemon 进程命令：`claude daemon run --origin transient --spawned-by ...`。FleetView (`claude agents`) 第一次启动时会孵化 daemon。

## 2. 请求信封

```js
y.discriminatedUnion("op", [
  y.object({proto: _, op: y.literal("ping")}),
  y.object({proto: _, op: y.literal("list")}),
  y.object({proto: _, op: y.literal("has"), short: H}),
  y.object({proto: _, op: y.literal("dispatch"), d: l06(), timeoutMs: y.number()}),
  y.object({proto: _, op: y.literal("attach"), short: H, cols, rows, attachId?, caps?, holdingFrame?}),
  y.object({proto: _, op: y.literal("resize"), short: H, cols, rows, attachId?}),
  y.object({proto: _, op: y.literal("kill"), short: H, signal?: "SIGTERM"|"SIGKILL"}),
  y.object({proto: _, op: y.literal("reply"), short: H, text: y.string()}),
  y.object({proto: _, op: y.literal("subscribe"), short: H, tail?: number}),
  y.object({proto: _, op: y.literal("await-ack"), short: H, nonce?: H, timeoutMs: number}),
  y.object({proto: _, op: y.literal("ensure-spare"), cwd: y.string()}),
  y.object({proto: _, op: y.literal("permission-response"), short: H, requestId, allow}),
  y.object({proto: _, op: y.literal("respawn-stale"), short: H}),
  y.object({proto: _, op: y.literal("shutdown")}),
  y.object({proto: _, op: y.literal("lease"), client?: {label, cwd, pid}}),
  y.object({proto: _, op: y.literal("leases")}),
  y.object({proto: _, op: y.literal("nudge")}),
  y.object({proto: _, op: y.literal("yield")}),
]);
```

字段约定：
- `proto`: 当前 `1`（schema 里是 `y.number().int().min(qL_).max(f5)`，f5 是当前版本号常量）
- `H` = `y.string().regex(/^[a-f0-9]{8}$/)`，即 short ID 是 8 位小写十六进制
- `_` = proto schema 引用

## 3. 标准响应

成功：
```json
{"ok": true, "op": "<同请求>", ...op-specific-fields}
```

失败：
```json
{"ok": false, "error": "<人类可读>", "code": "<错误码>", ...extra}
```

已知错误码：

| code | 含义 | 调用方应对 |
|---|---|---|
| `EUNKNOWN` | schema 校验失败（最常见） | 字段不对，检查 schema |
| `EPROTO` | proto 版本不匹配（带 `serverProto`, `serverVersion`） | 升级 claude code 或更新本协议文档 |
| `ENOJOB` | short 不存在 | 任务已结束或从未存在 |
| `EALIVE` | short 重复（已活着） | 重新生成 short 重试 |
| `ETIMEOUT` | daemon 没在 timeout 内 ack | 重试或排查 daemon 健康 |

## 4. `dispatch` —— 派发新 background session

**这是 FleetView "new agent" 按钮等价的协议入口。** 完整 schema (`l06`)：

```js
l06 = () => y.object({
  proto:        y.number().int(),                                  // 必填: 1
  short:        y.string().regex(/^[a-f0-9]{8}$/),                 // 必填: 自己生成
  nonce:        y.string().regex(/^[a-f0-9]{8}$/).optional(),
  sessionId:    y.string(),                                        // 必填: 自己生成 UUIDv4
  createdAt:    y.number(),                                        // 必填: Date.now() (ms)
  source:       y.enum(["shell","slash","fleet","spare","respawn"]),// 必填: 推荐 "fleet"
  cwd:          y.string(),                                        // 必填: 绝对路径
  launch:       y.discriminatedUnion("mode", [
    y.object({mode: y.literal("prompt"), args: y.array(y.string())}),
    y.object({mode: y.literal("resume"), sessionId: y.string(), fork: y.boolean(), flagArgs: y.array(y.string())}),
    y.object({mode: y.literal("exec"),   cmd: y.string(),       args: y.array(y.string())}),
  ]),                                                              // 必填
  env:          y.record(y.string(), y.string()).default({}),
  reattachEnv:  y.record(y.string(), y.string()).optional(),
  worktree:     y.object({path: y.string(), ownershipToken: y.string()}).optional(),
  isolation:    y.enum(["none","worktree"]).default("none"),
  respawnFlags: y.array(y.string()).default([]),
  attachStallRespawns: y.number().int().optional(),
  agent:        y.string().optional(),                             // 默认 "claude"
  routine:      y.string().optional(),                             // /loop, /schedule 等 routine 名
  seed:         y.object({intent: y.string(), name: y.string().optional()}).optional(),
                                                                   // ⭐ FleetView 显示用：intent=prompt，name=显示名
  cols:         y.number().int().positive().optional(),
  rows:         y.number().int().positive().optional(),
});
```

请求：
```json
{
  "proto": 1,
  "op": "dispatch",
  "d": {
    "proto": 1,
    "short": "a1b2c3d4",
    "sessionId": "12345678-1234-4abc-89ab-123456789abc",
    "createdAt": 1779600000000,
    "source": "fleet",
    "cwd": "/path/to/module",
    "launch": {"mode": "prompt", "args": ["首条 prompt 内容"]},
    "seed":   {"intent": "首条 prompt 内容", "name": "FleetView 显示名"},
    "agent":  "claude",
    "isolation": "none",
    "respawnFlags": []
  },
  "timeoutMs": 10000
}
```

成功响应：
```json
{"ok":true, "op":"dispatch", "short":"a1b2c3d4", "pid":71884, "messagingSock":"", "via":"spare"}
```

**launch.mode 三选一**：

| mode | 用途 | 字段 |
|---|---|---|
| `prompt` | 新启动 claude 并把 args 作为 argv 传入（首条 user message） | `args: string[]` |
| `resume` | 重连已有 session（可选 fork 出新 sessionId） | `sessionId, fork, flagArgs` |
| `exec` | 自定义命令（不限定 claude） | `cmd, args` |

99% 场景用 `prompt`，相当于 `claude "prompt 内容"`。

## 5. 其他 op 速查

### `list` —— 列出所有活跃 session
```json
请求: {"proto":1, "op":"list"}
响应: {"ok":true, "op":"list", "jobs":[{short, sessionId, pid, attempt, startedAt, cwd, state, tempo, detail, intent, name, agent, source, ...}]}
```

`state` 值: `running` / `done` / `working` / ...（由分类器读 worker 最后一条消息推出，易失、会被 respawn 擦掉）
`tempo` 值: `active`（循环在产出）/ `idle`（回到等输入态）/ **`blocked`（在等用户输入/授权——2.1.167 实证：
            worker 等回复时 `state` 仍 `working`、靠 `tempo=blocked` 表达；要用 `reply` 回它或 `kill` 取消）**
`source` 值: 同 dispatch 的 source

> ⚠ 官方 CLI `claude agents --json` 与本 socket `list` **不同形态**：CLI 返回**顶层数组** + 每项
> `{name,status,kind,sessionId,pid,cwd,startedAt}`（`status`=idle/active，**无** `state`/`tempo` 富字段）。
> 本技能脚本一律走 socket `list`（仍是 `{ok,jobs[{state,tempo,...}]}`），不解析 CLI 输出，故 CLI 形态变化不影响。

### `has` —— 检查 short 是否活着
```json
请求: {"proto":1, "op":"has", "short":"a1b2c3d4"}
响应: {"ok":true, "op":"has", "alive":true, "present":true}
```

### `subscribe` —— 订阅 session 流（持续返回多条消息）
```json
请求: {"proto":1, "op":"subscribe", "short":"a1b2c3d4", "tail":100}
响应: 第一条 {"type":"snapshot", "record":{...}, "streamTail":[...]}
       后续持续推送 stream 事件直到连接关闭
```

### `kill` —— 终止 session
```json
请求: {"proto":1, "op":"kill", "short":"a1b2c3d4", "signal":"SIGTERM"}
响应: {"ok":true, "op":"kill"}      或     {"ok":false, "code":"ENOJOB"}
```

### `reply` —— 给运行中 session 发一条 user message
```json
请求: {"proto":1, "op":"reply", "short":"a1b2c3d4", "text":"继续干下一步"}
响应: {"ok":true, "op":"reply"}
```

### `attach` / `resize` —— 把当前终端 attach 上去（FleetView UI 用的）
```json
请求: {"proto":1, "op":"attach", "short":"a1b2c3d4", "cols":80, "rows":24}
响应: {"ok":true, "op":"attach", "decModes":[...], "via":"spare", "tempo":"active", "state":"running"}
```

注意 attach 后服务端会通过 ptySock 接管 IO，这条 op 只是协商；真正的终端字节流走 `/tmp/cc-daemon-<uid>/<inst>/spare/<x>.pty.sock`。

### `ping` —— 心跳
```json
请求: {"proto":1, "op":"ping"}
响应: {"ok":true, "op":"ping", "version":"2.1.150", "proto":1}
```

测试 daemon 是否可达 + 拿当前 proto 版本号最便捷的方式。

### `ensure-spare` —— 给指定 cwd 预热 spare 进程
```json
请求: {"proto":1, "op":"ensure-spare", "cwd":"/path"}
响应: {"ok":true, "op":"ensure-spare", ...}
```

为后续在该 cwd 派发预先准备好 spare worker，能让首次 dispatch 更快。

### `shutdown` —— 关停 daemon
```json
请求: {"proto":1, "op":"shutdown"}
```

⚠️ 会杀掉所有 background session。

## 6. 派发流程详解

```
client          control.sock           daemon                  spare pool
  │                  │                    │                        │
  ├─ dispatch(d) ───>│                    │                        │
  │                  ├─ validate(zod)──>  │                        │
  │                  │                    ├─ pick free spare ────> │
  │                  │                    │                        ├─ adopt (cwd/env/args)
  │                  │                    │                        ├─ run as new session
  │                  │                    │ <── messagingSock ─────┤
  │ <── {ok, pid, ──┤                    │                        │
  │     short, via}  │                    │                        │
```

派发后，session 出现在 `list` 输出里、可被 `subscribe`/`attach`/`kill`/`reply`，跟 FleetView UI 派发的完全等价（包括计费、scheduling、SendUserMessage 通知）。

`source` 字段记录的是 "派发动作的来源"：
- `fleet` = FleetView UI（推荐用这个，跟 UI 行为一致）
- `spare` = 预热产生
- `shell` = `claude` CLI 启动
- `slash` = /agent 之类 slash command 派发
- `respawn` = 父 session 因 stall 自动 respawn

## 7. spare 池机制

Daemon 启动后会预热若干 spare 进程（参数 `--bg-spare <claim.sock>`）。dispatch 时 daemon 把任务"喂"给某个 spare（通过它的 `claim.sock`），spare 进程接收后变身成正式 session：

```
父进程: /Users/lik/.local/share/claude/versions/2.1.150 --bg-pty-host <ptysock> <cols> <rows> -- ... --bg-spare <claimsock>
子进程: /Users/lik/.local/share/claude/versions/2.1.150 --bg-spare <claimsock>
```

派发成功响应里 `pid` 是父进程（`--bg-pty-host`）的 PID，子进程是实际的 claude session。

`via` 字段：
- `"spare"` = 命中了预热 spare（快）
- `"fresh"` = 临时孵化（慢）

## 8. 持久化文件

```
~/.claude/jobs/<short>/           每个 background session 一个目录（CLAUDE_JOB_DIR）
  ├── intent                       初始 prompt
  ├── name                         显示名
  ├── (流水 JSONL ...)             消息历史等
  ├── pins.json                    全局 pin 列表

/tmp/cc-daemon-<uid>/<inst>/
  ├── control.sock                 daemon 主控
  ├── rv/<short>.sock              每个 session 的 rendezvous socket
  └── spare/<id>.{claim,pty}.sock  spare 池 IO
```

清理：`~/.claude/jobs/settled/*.json` 是已结束 session 的尾迹，daemon 周期清理。

`state.json` 关键字段：`name`（FleetView 显示名，缺失则回退显示 `template`）、`template`（spare 池后台模板 = 字面量
`bg`）、`createdAt`/`firstTerminalAt`/`updatedAt`（FleetView 时长 ≈ `firstTerminalAt − createdAt`）、`sessionId`、
`linkScanPath`（该 session transcript jsonl 路径）、`detail`/`output`/`tokens`（session 进程写的进度/产物）。

> ⚠ **完成态退化（2.1.185 实测）**：daemon 在 worker **完成时**会把 `state.json` 重写成极简形态——**丢掉 `.name`**
> （→ FleetView 显示退回 `bg`）、把 `.createdAt`/`.firstTerminalAt`/`.updatedAt` **塌缩成同一瞬间**（→ 时长显示 `0s`）、
> 清空 `.intent`。只影响**刚完成**的 worker（运行中、更早完成的不受影响）。这份完成态记录**写完即稳定**，故
> `cc-fleet-fix-display` 在完成后用名册名 + transcript 首/末时间戳把它修回（详见 SKILL.md「FleetView 显示修复」）。

## 9. 协议升级应对剧本

当 `cc-dispatch` 失败（exit code 3，schema rejected）：

1. **先 ping 确认 daemon 跑着**：
   ```bash
   echo '{"proto":1,"op":"ping"}' | nc -U /tmp/cc-daemon-<UID>/<INST>/control.sock
   ```
   如果返回 `EPROTO` + `serverProto: 2`，那就是协议版本升级了。

2. **拉新 binary 提取 schema**：
   ```bash
   strings -a /Users/lik/.local/share/claude/versions/<NEW>/ | \
     grep -E 'y.discriminatedUnion\("op"|y.object\(\{mode:y.literal'
   ```
   定位 `l06`（或同名工厂）的新定义，对照本文件 §4 更新字段。

3. **改 `cc-dispatch` 里的 `$opt_proto` 默认值** 和必填字段构造。

4. **如果完全跑不通**：临时降级到 FleetView 手动派发，`cc-dispatch-batch` 已经会打印可粘贴的清单。

## 10. 安全边界

- Unix socket 权限：`srwxr-xr-x lik wheel`，**只有同用户可连**（macOS 默认）。
- 没有认证：daemon 假设凡能连 socket 的就是合法 client（跟 docker / systemd 同模型）。
- 不建议把 socket 透过网络转发（SSH tunnel 也别），因为这相当于给远端无条件 RCE。

## 11. 兼容性历史

| claude code | proto | 备注 |
|---|---|---|
| `2.1.150` (2026-05-23) | 1 | 本文档基准 |
| `2.1.167` (2026-06-06) | 1 | 实测 `ping/list/dispatch/reply/kill/has` 全部兼容（`dispatch` 真派发 + `reply`/`kill` 真投递/终止均验证）。socket `list` 仍返回 `{ok,jobs[{state,tempo,...}]}`；等输入态用 **`tempo=blocked`**（非 `state=blocked`）。官方 CLI `claude agents --json` 改为顶层数组 + `status`（本技能不解析它，无影响）。 |
| `2.1.185` (2026-06-22) | 1 | 协议全兼容。**新发现完成态显示退化**：worker 完成时 daemon 把 `~/.claude/jobs/<short>/state.json` 重写成丢 `.name`（FleetView 名字→`bg`）+ 三时间戳塌缩（时长→`0s`）的极简记录（见 §8）。取名 hook 在完成后无事件可补 → 由 `cc-fleet-fix-display` 在完成后修回磁盘记录（`cc-fleet-watch`/`cc-fleet-summary` 自动调用）。 |
| `2.1.181` (2026-06-18) | 1 | 协议全兼容（`ping` 免 auth；`list`/`kill` 等 op 须带**顶层 `auth`=`~/.claude/daemon/control.key`** 控制密钥，2.1.169+ 起）。**CLAUDE.md 自动加载 bug 已修**：实测派发 14 个**关注入**（`--no-inject-claude-md`）探针 worker（factory/ 8 个 + followup/ 6 个，**全 `via=spare`**），**14/14** 均自动加载三层 `CLAUDE.md`（用户/项目/目录级），且目录级**精确跟随派发 cwd**（factory 批载 factory、followup 批载 followup，无错位）、**0 miss**——旧版"约 3/4 miss / spare 沿用预热 cwd"不复现。故 `cc-dispatch` 注入**默认翻为关**，`--inject-claude-md` 留作版本回归时的兜底逃生口。复测办法：派一批 `--no-inject-claude-md` worker 让其自检上下文有无 `# claudeMd` 块（见 `tests/test-cc-dispatch-inject.sh` 头注释）。 |

发现新版本破坏兼容时，更新此表 + §4 schema + `cc-dispatch` 默认值。
