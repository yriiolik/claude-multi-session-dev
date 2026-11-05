# 原生会话操作

仅用宿主实际提供的原生线程/工作树工具；先发现工具并读 schema，不编造参数、projectId、startingState 或分支。

## 当前配置、创建与工作树

每次 create_thread/send_message_to_thread 前读取当前主 session 的可信运行元数据；必要时只读最新 turn 的配置。
模型自述、全局 config 默认或上一批 worker 值不能替代当前会话。完整 model ID 保留 provider/自定义来源，
思考深度用宿主支持的 thinking 值；会话中明确覆盖按字段与作用范围执行，未覆盖字段仍继承。
把两个值显式作为工具参数传入；`nativeSettings={}` 只是无固定覆盖，不是已解析配置。
缺字段时报告实际缺失并确认该字段，不猜值、不省略或借旧后端查询。不按角色自动降档，不改变窗口或压缩设置。
父会话配置变化后下次创建/续聊用最新值，不中断运行中 turn。原生接口拒绝组合时报告真实错误。

1. 用 list_projects 定位真实仓库对应的唯一项目；无匹配则说明缺口，不猜 ID。
2. 创建首个线程前用 list_threads 查唯一“子 session”分区并缓存 sectionId。没有分区时按明确归类要求创建一次，
   重名则先解决歧义。读取 prepare 生成的完整 promptFile，title 用名册 name。
3. 遵守当前 create_thread schema 的工作树约束：用户明确要求 worktree 才传 worktree 环境；否则 local 创建，
   让 worker 在任何写入前用 list_artifacts 检查隔离工作树，需要时 create_worktree(ref="fleet/<RQ>", sourceRoot=<repo>, allowAsync=true)。
   有 operationId 用 get_worktree_creation_status 等完成，显式使用返回目录并进入正确子目录 bind。
4. App 已创建的隔离工作树基线不符时，先确认干净再 switch --detach 到集成分支，读取实际目录项目规则；
   有改动就保留现场，不 reset 或覆盖。solo 由主端用同样原生隔离能力建树再 bind --self 模块。
   fresh 复用任务卡已绑定的工作树，不让新线程自动新建一套替代资产；新线程先核实旧线程确实不再执行。

## 侧栏与身份

create_thread 返回真实 threadId/hostId 后，**下一步立即 move_thread_to_sidebar_section** 到已解析的分区；
每条并行创建链各自立即移动，不能等整批完成。不在创建和移动之间登记、重新查分区或汇报。
移动后可合并 list_threads 核验 section 的 itemKeys，再 register --session-id --host-id --sidebar-section-id。
移动失败仍登记真实身份但不传分区参数，保留 pending，有界重试同一线程，不重建。
只返回 clientThreadId 时登记 setting-up，按 host/项目/唯一标题解析真实 ID 后先移动再登记；不阻塞其它线程。
client ID 不能用于 read/wait/message/move，不因 setup 慢重复创建。

当前侧栏是平级项，分区不代表有父子容器；创建与移动非原子，不能保证零闪现。禁止私有 UI 状态、额外终端面板。
成功创建后按宿主要求在最终响应单独输出 created-thread 指令，真实 threadId 或仍 pending 的 clientThreadId 二选一。

## 监督、接续与异常

- wait_threads 每批最多8个真实 hostId/threadId，cursor 增量读取；批次大小不限制开发并发。
  每轮全部未完成批次先 timeoutMs:0 即时扫描，独立批次可并行；处理事件后对仍可执行线程做一次≤30秒等待，
  多批轮换，随后重新扫描全部。不能只长等一个批次而漏其它输入。
- 检查 wake、全部 polls、errors；超时也可带事件。先保存问题与动作，再推进 cursor；cursor 不代表问题已解决。
- 回执先 status/collect；done 必须同时核实宿主本轮已结束，避免回执写完但仍在改成果。
  read_thread 只查异常/输入/无回执结束，先 turnLimit:1、includeOutputs:false，再按需要扩大，已解释且无变化不重复读。
- 无活动约60秒且无法解释时读一次确认是否漏输入；真实长计算有证据则继续有界等待，不按时间自动判失败。
  未知/离线/读取错误有界重试并记录，不伪装 running，也不靠文件 mtime 推断原生执行状态。
- 依赖通过后主端原生创建/消息接续。新交付轮次先 reply 生成 attempt；原生消息被接受后 register 同一身份。
  活跃 turn 内补答案不新建 attempt；发送不确定先核实，沿用已有 next-prompt，不重复 reply 或盲目再发。
- fresh 先取得旧目标线程 ended 状态，再 reply --session fresh 并原生创建；绑定新身份必须带 --attempt。
  旧名册、回执、handoff 按 attempt 保留；不自动归档/暂停旧线程。没有原生 interrupt 时请用户在 App 暂停，归档不等于停止。

## 输入与审批

业务问题 worker 在本轮 blocked 回执的 needsInput 汇总，主端先查原始要求、已答问题和授权，能裁定就继续，
缺用户决定才合并提问。实际审批仍走宿主真实通道，普通线程消息不能答另一个尚未完成的审批工具。

快照的 activeFlags、输入/审批工具标记、明确求助或 blocked 回执出现时核实正文；异步输入工具 completed 不代表用户已答。
缺正文就记 unknown 可见性缺口，不猜要批准什么。问题按 request/turn ID 或原文指纹去重，保存 CURRENT 未解决问题及证据。
已答业务问题可消息通知 worker 记录继续，但不能声称关闭旧弹卡；无公开答卡接口时明确指出线程和 App 操作入口。

确定等待输入/审批的线程移出长等集合，仍纳入每轮即时扫描；其它卡继续。全部剩余都等用户时明确交接后结束，
不空转，不宣称后台自动唤醒。收到答案后先即时快照核实真实恢复，再放回运行集合。
