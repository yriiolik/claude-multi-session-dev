# 新建 Codex worker 的侧栏分区

用户偏好（2026-09-11 确认）：本技能自动创建的 Codex 独立子 session，归入现有“子 session”分区。
这是技能派发后的 UI 操作，不是 Codex 全局设置，不影响手动创建的普通任务或其他技能的任务。

当前已核验的分区：
- 名称：`子 session`
- sectionId：`1c803426-f4fa-493e-8681-bc7bc23e2430`

## 主端操作

适用于主端实际可调用 `list_threads` 和 `move_thread_to_sidebar_section` 的环境。
Codex worker 无论通过原生 create_thread 还是 app-server 创建，都执行此步骤。

1. 每轮派发前或第一次归类时用 `list_threads` 核验 sections。优先匹配以上 sectionId；
   若该 ID 不存在，按完全相同的名称查找唯一分区。不要猜 ID、自动新建同名分区或用序号寻址。
2. 新 worker 获得**真实 threadId** 后调用：

```json
{
  "threadId": "本次创建返回的真实 threadId",
  "hostId": "本次创建返回或核验的 hostId",
  "sectionId": "核验后的 sectionId"
}
```

上面的参数传给 `move_thread_to_sidebar_section`，不是 app-server JSON-RPC 方法。
3. 只有 clientThreadId 时先保持 setup pending；获取真实 ID 后再移动。不要为了归类重复创建 worker。
4. 移动成功后正常监控；新创建的 fix/scout/integ/verify Codex worker 也归入该分区。
   只移动本轮新建且身份已登记的任务，不批量移动历史任务、主任务或项目。
5. 分区不存在/名称有歧义/移动失败时，保留已创建的 worker 并继续执行，向用户报告未归类。
   不因 UI 归类失败重新派发、终止任务或修改其他分区。

Claude Code 主端、Codex CLI 主端若没有这些 App 工具，不能假装已移动，也不能直接编辑 Codex 私有 UI 状态文件。
这种情况下自动分区尚不可用，回报真实 threadId 供用户在 App 中归类；不要承诺主端响应结束后还会自动归类。
Claude worker 不属于 Codex 任务，不能移动到 Codex 分区。
