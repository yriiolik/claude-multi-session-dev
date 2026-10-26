# 脚本侧栏归类实现

归类由 `cc-fleet` 自动执行，不需要主端或 worker 提示词调用 UI 工具。
`dispatch` 成功、`register` 获得真实 ID、`reconcile` 恢复名册时，调用
`threadSection/list` 按完整名称“子 session”查找唯一服务端分区，再调用 `thread/section/move`。
服务端分区 ID 与 App UI 分区 ID 不同，不混用或硬编码。

名册 `sidebar.state=placed` 表示接口成功；`pending` 带具体原因。
归类失败不改变开发运行状态、不重复创建 session；`reconcile` 会重试。
已归类的登记不重复移动，避免改变顺序。clientThreadId 和 Claude worker 不执行归类。
远程 host 不误用本地服务端；记录 pending，由对应主机提供连接后再处理。
不读写 Codex 私有 UI 状态，不创建同名分区。

**桌面端显示滞后不是归类失败**（2026-10-26 核对 ChatGPT 桌面端代码）：App 的「子 session」分区按自己缓存的
`app-server-custom-section-threads` 渲染，全局关闭了窗口聚焦刷新；只在 App 启动、与 app-server 重连、
或在 App 内拖动/置顶（主进程广播 `pinned-threads-updated`）时重拉。服务端没有分区变更通知，外部客户端调
`thread/section/move` 后 App 不会立即看到，新 worker 会先出现在「最近」。核实以 `thread/read` 的 `section.name`
或 `state_5.sqlite` 的 `threads.thread_section_id` 为准；想立刻看到就重启 App，或在 App 里往该分区拖一条线程。
