# 原生子智能体操作

工具名和字段以主端当次定义为准。以下是 2026-11-06 主端实际 schema 的窄映射，不是私有 SDK 或永久恢复承诺。
本地脚本只收存 `{module,attempt,tool,args,result}` 证据封装；前两个是本地绑定字段，不能当 native 参数发送。
首次派发前读实际 schema，后续宿主不兼容时报告并调整映射，不能猜参数。

## 创建、隔离与身份

- `spawn_agent({message:<完整prompt>, fork_context:false})` 为默认，message/items 二选一；有连接器提及时按 schema 使用结构化 items。
  默认不传 model/reasoning_effort，继承父模型/深度；明确用户覆盖才按当次字段传。返回 agent_id/nickname，只有 agent_id 用于身份。
  true forks current thread history；false 或省略只给 initial prompt。本技能要求证据中显式布尔值，默认 false。
  仅当主端历史短而聚焦、任务高度相关，且转述遗漏风险/整理成本明显更高时，PM 自主 true，以 register --context-reason 记录一句理由，不问用户。
  历史噪声多、为清除旧假设重新诊断、独立验收执行均 false；继承不替代完整任务卡/完成条件/写入范围/交接。
  独立执行复用现有判定：verify/integ/regression 且 phase != author；author 资产准备可选 true，进入 execute 时已有主历史则 fresh false。
  true 复制主端当前历史，不复制旧 worker 历史；reuse 不 spawn，保留该 agent 自身历史。身份选择与继承选择分开。
- prepare→主端 spawn→register --agent-id --attempt --evidence-file。worker 在写回执前读已登记 agentId；登记尚未到达不猜 ID。
  spawn 未知是否成功时先记录 defer uncertain，核实原结果，不重复创建。没有公开查询接口时保留缺口，不调用 App 线程工具兜底。
- 聊天不提供文件/权限隔离。代码在同仓库、含集成基线的独立 Git worktree 写入，正确子目录 bind；主 checkout 与用户改动受保护。
  Git worktree 可由授权 worker 使用 Git 或已确认的宿主能力创建；不编造 spawn 的 cwd/worktree/sandbox 参数。
  非代码写独立产物目录；只读卡可以共享读取来源，写交付物仍绑定独立目录。共享文件/端口/数据库/生成物有唯一 owner/锁。

## 有界等待与真实状态

当前 `wait_agent({targets:[agent_id,...],timeout_ms:30000})` 等任一结束；timeout_ms 当前最小10000、最大3600000。
主端通常 30000–60000ms 有界续等，按真实容量公平推进，不沿用 App 的 cursor/每批8条/0ms 规则。
返回 status 按 ID 映射，可能为 pending_init/running/interrupted/shutdown/not_found，或 `{completed:string|null}` / `{errored:string}`。
检查所有状态与 timed_out；空 status 加超时只记本次等待超时，不能把全体改成 running/failed/done。
send_input 接受后的首次或多次 wait 可能仍返回上一轮 completed 全文。register 保存本轮 submission_id、派发证据和旧 completion 关联；本地 module/attempt 封装及时间戳不能证明返回属于新轮。
completed 正文必须是 worker 最终完整 v2 JSON，rq/module/attempt/agent_id 与本轮登记一致，且与当前有效回执完全一致；observe 才记录经核实的 endProof。旧重复、错身份、null、摘要或缺回执只存原始事件，不授予结束/接管/交付资格。有回执或 handoff 本身也不证明停止。

| 真实状态/事件 | 本地解释及行动 |
|---|---|
| pending_init/running | 仍可能执行；不建新 attempt，不把独立工作排给它 |
| completed | raw 状态，仍需上述当前轮 JSON/回执核验；通过才确认本轮结束，业务验收另判 |
| errored/interrupted/shutdown | 无当前轮关联证明只存原始状态并保留缺口，不凭封装授予接管/释放；可核当前失败 JSON或已有同轮 endProof 才确认结束，不补造业务完成 |
| 孤立 not_found/未知/工具错误 | 可见性缺口；不认定停止/释放，不向同资产派新写者；有界核实后报告具体阻塞 |
| close_agent 成功返回 | previous_status 只是旧快照；已有同轮真实结束证据再成功 close，才派生 closed/released；缺结束证明则 closing/releasing，继续核实 |
| 已确认关闭后 wait not_found | 保留关闭证明与释放结论，nativeState=not_found；不是孤立 not_found，不伪造 shutdown |

正常只消费结果摘要和回执；异常/缺回执/证据矛盾才委派相应负责人定向查证，不能主端全量读日志重做调查。
保存 CURRENT 的当前 agent/attempt、native 状态证据、业务结果、容量、问题与下一步；状态变化才更新用户，不逐条转述过程。
业务问题先用原文/已答事项裁定，确需用户再合并问；实际工具审批走宿主，send_input 不代批。

## 关联接续、关闭与恢复

- 活跃执行只补本任务必要澄清或安全停点。`send_input({target:agent_id,message:...})` 返回 submission_id 只证明接受/入队，
  不证明执行结束；默认 interrupt=false/省略会排队。不要把独立新轮排在仍执行任务后。
  必须立即停点时按实际支持 `interrupt:true`，中断后仍等待终态并核资产，不把“已请求”当“已停止”。
- 关联 reuse：先 observe 并取得经核实的本轮 endProof；reply --session reuse --reuse-reason 生成当前完整卡和运行说明；
  向相同 agent send_input，register 同 ID 和实际接受证据。它保留自身上下文，模型参数不在 send_input schema 中。
- fresh：先确认旧轮停止、持久交接与真实工作树/产物目录，记录具体 fresh-reason；同 module reply fresh 新 attempt。
  旧执行者不再写后才让新 agent 接管原资产。spawn 按上述新建策略，默认 false，满足条件可 true；不按阶段名称机械禁 true，清除旧假设时须 false。
  新旧身份与提交/脏资产均保留，true 不能取代旧 worker 交接。
  可先关闭旧者再换新释放容量，或旧轮终态后先完成交接再换；关闭旧者的观察属于旧 attempt，不冒充新 agent 状态。
- 结果与 handoff 收存后及时 `close_agent({target:agent_id})`；返回 previous_status 是关闭请求前状态，已有同轮结束证据且 close 实际成功即可确认关闭并释放；宿主实测卸载后 wait 返回 not_found，不能强制等不存在的 shutdown。
  未知执行态下只收到 close 响应仍先保存关闭请求与缺口，不用 previous_status 冒充先前执行完成。已完成且仍开放者也占容量；不要囤积无当前用途的 agent。
  reply、deliveryReady 与 close 使用同一当前轮证明；旧 completed 缓存后再 close 仍是未核实的 closing，不会转成 closed/released。
- 已关闭但需要 reuse：`resume_agent({id:agent_id})`，核实际返回状态与同 ID；若旧轮已真实结束、close 已确认，且之后只有恢复，没有新提交，resume 的 pending_init 表示恢复初始化；可向同 ID 排入本任务接续，保留旧终态及恢复证据。
  若无上述证明，pending_init/running 仍需等到可安全接续，不能据此排新轮。
  shutdown/not_found 未证明恢复时不称成功；保留已确认旧者关闭的证据，可在有交接时 fresh。孤立 not_found 无关闭证明仍阻断接管。恢复后实际终态可重新裁定续做；
  不能靠磁盘名册恢复真实 agent，不保证跨客户端重启恢复。失败时可在确认原执行者停止后按 fresh 接管资产，并记录原因。

## 容量与工具缺口

按宿主真实容量并行；无业务固定并发上限不等于无限创建。容量拒绝用 defer capacity 保存实际错误，先收存和关闭已完成者，
确认释放后再派；占用都为必要执行时有界等待。缺 native 工具用 defer tools，不能后台 CLI/外部调度器或 App 独立线程替换。
resume 受容量限制也同样处理。全部剩余都需用户输入时交接，不宣称主端结束后仍会自动被唤醒。
