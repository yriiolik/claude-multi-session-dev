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
