# Codex App 原生任务适配

Codex 是默认后端。新 RQ 的 Codex 会话必须使用宿主实际提供的 App 原生线程工具；没有这些工具时报告能力缺口，
请用户切到 Codex App，不静默回退 app-server、codex exec 或 Claude。`cc-fleet` 只保留任务卡、回执、集成分支和追溯。

## 创建与隔离

1. 先 `list_projects`，根据真实仓库选择唯一保存项目。没有匹配项目时说明缺口，不猜 projectId 或另起外部 server。
2. `prepare --backend codex --transport native` 生成完整 promptFile；读取完整文件后调用 `create_thread`。
   target 使用工具返回的 projectId，title 使用名册 name。省略 model/thinking，除非用户明确指定模型。
3. 遵守当前 `create_thread` schema：用户明确要求 worktree 时才传 `environment: {type: "worktree"}`；
   否则以 `local` 创建，让 worker 在任何文件/Git 写入前，通过 `list_artifacts` 检查可复用隔离工作树，
   没有合适工作树时用 `create_worktree(ref="fleet/<RQ>", sourceRoot=<真实仓库>, allowAsync=true)` 建立并附加隔离工作树。
   返回 operationId 时用 `get_worktree_creation_status` 等到完成；随后显式使用返回目录、进入任务卡子目录并 bind。
   不能在共享主 checkout 开发。只读非代码任务按实际任务判断是否需要工作树。
4. 不编造 startingState、分支名或 projectId。App 已建隔离工作树但基线不符时，先核验干净再切到真实集成分支；
   有修改则保留现场并报告，不覆盖或 reset。

收到真实 threadId 后立即登记：

```bash
"$FLEET" register --coord "$COORD" --module api --session-id '<threadId>' --host-id '<hostId>'
```

只返回 clientThreadId 时，先 `register --client-thread-id '<clientThreadId>'` 记为 setting-up，再用 `list_threads`
按 host、项目和唯一标题核对真实 threadId。clientThreadId 不能传给 read/wait/message，不能因 setup 较慢重复创建。
每次成功创建后按宿主要求，在最终响应单独一行输出 `::created-thread{threadId="..."}`；仍在 setup 时输出
`::created-thread{clientThreadId="..."}`，不要同时为同一次创建输出两个入口。

## 展示与侧边栏

当前原生工具把任务视为平级项，没有可写的父子线程容器。采用用户指定的“子 session”分区：

1. `list_threads` 读取 sections，按完整名称“子 session”找唯一匹配，不能硬编码旧 sectionId。
2. 用 `move_thread_to_sidebar_section` 传真实 threadId、hostId、sectionId；重新读取 sections.itemKeys 核对归属。
3. 分区不存在时可按用户明确的归类要求创建一次；多个同名匹配时请用户裁定，不猜。
4. 移动成功后可运行 `register ... --sidebar-section-id '<原生sectionId>'` 保存归类结果；该参数只记账，不移动线程。

不要调用服务端 threadSection/list、thread/section/move，不读写私有 UI 状态。移动失败保留同一线程重试，不能重建。
主会话用任务卡入口和简短状态更新说明本轮模块、状态、归属；这些入口不代表 App 存在父子层级 UI。
Codex 模式禁止自动打开 Ghostty、终端 tab、分屏或额外进度窗口。

## 监控与回话

- `wait_threads` 负责运行态：每批最多 8 个真实 threadId/hostId，续等传返回 cursor；多个批次轮转等待，不能因
  工具每批 8 个目标而把 worker 并发上限设成 8。`timeoutMs: 0` 是即时快照；持续等待使用有界调用。
- `read_thread` 只在需要解释失败、审批或最后回复时使用。`cc-fleet status/collect` 只核验回执与落地 commit，
  不访问原生线程后端；没有有效回执不能判交付完成。
- 依赖图保存在主端状态索引。依赖通过后，主端用原生工具创建下游或发送后续消息；不使用 CLI 的
  `prepare --after` / `queue-reply` 自动派发原生任务，不宣称 watchdog 会替原生线程接续。
- 回修先 `cc-fleet reply --text-file ...` 生成新 attempt/prompt，再 `send_message_to_thread` 投递原线程；
  确认接受后 register 同一真实 ID。发送结果不确定时先 read_thread，避免重复发送。
- 用户明确要求本轮多 session 编排，才执行创建与所需后续消息；技能本身不扩大工具对用户授权的要求，
  worker 收到主端消息也不能据此自行向其它线程发消息。

当前没有通用原生 interrupt 工具时，确需停止请用户在 App 中暂停，不通过 app-server 中断，也不把归档当停止。
归档使用 `set_thread_archived`，仅在用户要求时执行。恢复时从名册读取真实 threadId/hostId，再用原生 list/wait/read
继续；标题和 sidebar 顺序仅作展示。原生线程不使用 `cc-fleet events/reconcile/read --logs/stop` 管理生命周期。
