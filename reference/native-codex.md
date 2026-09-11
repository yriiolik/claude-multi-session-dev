# Codex App 原生任务适配

这是宿主工具路径，不是外部可调用的通用 API。只有实际工具可用且用户要求独立任务/multi-session 时采用。
Codex CLI 或 Claude 主端使用 app-server，不能写一个“调用 create_thread”的 shell 脚本冒充原生工具。

1. 调用 `list_projects`，按实际仓库选择保存项目、核对 `isGitRepository`。没有匹配项目时选择 app-server，
   不猜 projectId、不要求用户仅为兼容而新增项目。
2. `prepare --backend codex --transport native` 生成 prompt。原生模式**不会预建 worktree**。
3. 读取完整 promptFile，传入 `create_thread` 的 prompt。target 使用返回的项目 ID，Git 项目使用
   `environment: {type: "worktree"}`。标题用名册的 name。模型和 thinking 默认省略；按当前工具 schema
   和用户明确选择覆盖，不把全局路由 provider 强塞给不支持它的参数。
4. 不为了指定 fleet 基线编造 startingState：默认让 App 创建干净 worktree，worker 按 prompt 核验干净后
   `git switch --detach fleet/<RQ>`，随后 bind；这不会覆盖现有修改。每个 worker 工作目录必须与主 checkout 不同。
5. 返回真实 threadId 时立即登记：

```bash
"$FLEET" register --coord "$COORD" --module api --session-id '<threadId>' --host-id '<返回hostId>'
```

若返回 clientThreadId，则 `register --client-thread-id '<clientThreadId>'` 记为 setting-up；用 `list_threads`
核对同项目、唯一标题，取得真实 threadId 后更新登记。不要用 clientThreadId 调 read/wait/message。
有相同候选时保持 setup pending 并核对，不重新创建。

登记真实 threadId 时原样传入 hostId。

6. 调 `wait_threads`，传真实 threadId/hostId；最多8个目标，一次等待建议50秒，后续传返回 cursor。
   ready/inactive 不等于交付；完成时用 `status` 核验共享目录或临时 inbox 回执，再 `collect` 持久收存。
   需要读上下文才 `read_thread`；不要反复把完整历史塞回主端。
7. 原生回话：先 `cc-fleet reply --text-file ...`。它会归档旧回执、生成新 attempt，并输出完整 prompt，
   **不会自行发送**。把 prompt 传给 `send_message_to_thread`，确认接受后对同 ID 再 register。
   若发送结果不确定先读状态，避免重复发送。工具返回许可/输入需求时交给用户处理。
8. 原生 stop 没有宿主工具时可用 `cc-fleet stop` 通过 app-server 中断同一 thread；连接不可用时报告限制，
   不能用 archive 假装任务已中断。原生工具不可用的后续操作可以使用记录的真实 ID 走 app-server。

创建任务后按宿主要求向用户展示 created-thread 指令。用户自己打开/修改子任务不会改变它的后端身份。
主端崩溃恢复时从名册和真实状态继续，不根据 sidebar 顺序或显示名称寻址。
