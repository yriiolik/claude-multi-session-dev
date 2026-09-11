---
name: multi-session-dev
description: >-
  在 Codex 或 Claude Code 主 session 中，按既有模块编排独立 Codex / Claude Code 子 session，
  支持混合后端、契约先行、worktree 隔离、回执和集成验收。用于用户要求多 session、独立任务并行开发、
  fleet 编排或跨客户端调度；不用于普通单任务开发，不在 FLEET-WORKER 子 session 内再次编排。
---

# 跨客户端多 session 编排 · v2

本技能共享一套流程，通过主端能力和 worker 后端选择执行方式。不要把 Claude 工具名、模型名或目录
替换成 Codex 字样来移植技能。`multi-thread-dev` 是旧入口，统一使用这里的流程。

## 身份与职责

首条任务带 `⟦FLEET-WORKER⟧` / `⟦CODEX-THREAD-WORKER⟧` 或 `FLEET_ROLE=worker` 时，你是 worker：
按任务卡开发、自测、回执，不加载编排流程或再开 worker。标题 `↳` 只是展示，寻址用真实 ID。

主 session 拆解、定契约、派发、监控和裁定。模块业务代码交给独立 session；主端可以维护技能、
协调文档、检查 Git 状态、审阅必要的 diff 和运行验收。纯探查优先使用可用的只读 subagent；
没有相应工具时自行只读检查，不臆造 `Agent`、`ListAgents`、`Monitor` 或 `SendMessage`。
开发 worker 是独立 session，不用内部 subagent 替代。

## 路由：主端和执行后端分别选择

| 主端 host | worker backend | 路径 |
|---|---|---|
| codex-app | codex | 默认 app-server（开放权限）；显式继承权限时可用原生任务工具 |
| codex-app / codex-cli | claude | `cc-fleet` → Claude 公开后台 CLI |
| claude-code | codex | `cc-fleet` → Codex app-server |
| claude-code | claude | `cc-fleet` → Claude 公开后台 CLI |

用户明确指定 worker 后端时服从；未指定时默认使用 Codex worker。同一 RQ 可以混用两个 backend。
**用户偏好（2026-09-11）：Claude Code 主端调用本技能时，默认派 Codex 子 session，模型 `gpt-6-astra`、
思考档 `low`、provider `openai`。** 由脚本在新派发时执行，后续 reply 沿用登记的 routing；不要改 Claude
主 session 自己的模型，也不要将 GPT-6 名称传给 Claude 后端。用户明确指定 Claude worker 时仍可使用 Claude 后端。
Codex CLI 没有 App 原生任务工具时自动走 app-server；不要把工具名称当作所有客户端都提供的能力。
使用前读取 [v2-commands.md](reference/v2-commands.md)。Codex App 原生路径另读
[native-codex.md](reference/native-codex.md)，跨客户端路径读 [backends-v2.md](reference/backends-v2.md)。
技能脚本相对于本 SKILL.md 的 `scripts/` 定位，不能假设已加入 PATH。

## 一轮开发

1. 读项目指导和模块地图，将需求归属到既有模块，默认一模块一卡一独立 session；耦合紧的同模块内容
   不必硬拆。列出数据生产方、消费方和验收场景。
2. 跨模块接口未稳定时，按 [contract-first.md](reference/contract-first.md) 先定契约，再并行实现，
   最后独立联调/验收。该文档里的旧派发命令以 v2 路由替代，业务分层原则继续保留。
3. `cc-fleet init` 创建唯一 RQ、协调目录、`fleet/<RQ>` 集成分支，并记录主端及可用的真实会话 ID；不可取得时使用明确标识的 controller ID，不能冒充真实会话 ID。
   只包含 base 的已提交内容；若用户要求包含未提交改动，先做受控快照，不擅自丢弃或提交用户改动。
4. 任务卡写清范围、依赖契约、自测、L1/L2 追溯（项目需要时）、验收口径。`prepare` 生成统一
   worker prompt 和身份，CLI 路径还会预建独立 worktree；原生路径让 App 创建 worktree。
5. 按路由派发。即时记录真实 thread/session ID；原生创建返回 `clientThreadId` 时仅记为 setup pending，
   等到真实 `threadId` 后再监控。不能把 client ID 当真实 ID，也不能因等待久而重复创建。
   Claude Code / Codex CLI 主端跑在 Ghostty 里时，app-server 路径派发成功即自动在右侧分屏拉起只读面板
   `cc-fleet-panel-codex-app` 展示子 session（`CC_FLEET_PANEL=0` 关闭）；编排判断仍只看 `status` 与回执。
6. Codex App 原生 worker 用 `wait_threads` + cursor 等待；跨客户端可订阅 Codex events，或使用
   有界 `cc-fleet wait`。Claude 主端存在 Monitor 才用它挂有界等待；没有推醒机制时继续主端工具等待，
   不结束响应后声称后台会自动通知。用户明确要求稍后跟进时才按宿主能力设置自动跟进。
7. `status` 从协调目录或本轮临时 inbox 读取回执，`collect` 核验后收存到持久协调目录。`status` 验证回执身份和开发 commit 是否在集成分支；空闲/turn 完成只是运行状态，**不等于任务交付**。
   无回执、未知状态、审批等待均返回需关注，不能死等或擅自判 done。`read` 查看最后回复/日志后纠偏。
8. 用 `reply` 生成新 attempt，避免上一轮 done 回执冒充新一轮完成；原生路径按输出调用宿主消息工具。
   接口超时显示 launch-uncertain 时先 `reconcile`，不直接再派。换后端/重新实现用新 fix 模块卡。
9. 模块完成后独立安排 integ/verify worker；验收必须在含全部已合入改动的集成基线上。
   主端核对场景、回执、测试证据、必要的 diff，未达标定位回修。
10. 验收通过后，按用户授权处理集成分支合回。不要从“多 session”推导出自动 push、发布、删除 worktree
    或删除分支的授权。默认保留本地成果和会话历史，明确报告未完成事项。

## 不变条件

- `cc-fleet` v2 名册包含 host/owner、backend/transport、真实 ID、worktree、attempt，不能混用旧 `.sid` 名册。
- 每个开发 worker 使用独立 worktree；从集成基线开始，提交后用现有 `cc-fleet-land` 的 CAS 合回机制。
  不在已有目录执行 `reset --hard`，不让 worker 清理自己的 worktree；完成前先保证 commit 可追溯。
- 模型/provider 除上述 Claude 主端 GPT-6 low 偏好外沿用各后端配置。其他主端的 Codex app-server 复用现有 session 路由；原生 App 沿用保存项目默认，
  若用户要求独立 provider 路由则选择 app-server。不把后端 A 的模型名/effort 强塞给后端 B。
- 用户偏好（2026-09-11）：worker 默认开放权限。Codex app-server 在启动、恢复及新 turn 显式设置完整访问和无需审批；Claude 新 worker 使用 `--dangerously-skip-permissions`。`prepare --permissions inherit` 可改为继承后端配置。开放权限不扩大任务授权，不代表允许推送、发布或删除成果；宿主若仍拒绝执行，应报告 blocked。
- 不把整份用户级 CLAUDE.md 强行提升为 Codex developer instructions。两端读取各自适用的项目规则，
  需要共享的业务规则由任务卡/契约显式引用。
- CLI watch 超时是“本次等待结束”，不是 worker 失败。工具不可用则明确降级和限制。

## 维护与旧入口

两端安装使用同一份技能源，避免正文复制漂移。旧 `cc-dispatch*`、面板和测试保留用于历史 RQ，
新 RQ 默认只走 `cc-fleet`。旧参考文件中的 Monitor、强制模型、权限、清理和自动 push 约定不适用于 v2。
新命令与行为以三个 v2 reference 为准。协议基线按实际 CLI help/schema 探测，不按模型自述或历史版本号判断。
