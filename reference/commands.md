# 命令、证据与兼容

`FLEET=<技能绝对路径>/scripts/cc-fleet`，`COORD` 取 init 输出。所有命令只操作本地资产，不调用原生工具。

```bash
"$FLEET" init --cwd <仓库或子目录> --owner-id <真实主端ID>
# 无 Git 的研究/数据工作区
"$FLEET" init --workspace --cwd <工作区>
"$FLEET" prepare --coord "$COORD" --module api --task <完整卡路径> --role developer
"$FLEET" prepare --coord "$COORD" --module verify --task <验收卡> --role verify --phase author
# 同专业独立结果分别 prepare，新 module/agent，不向旧任务塞目标
"$FLEET" prepare --coord "$COORD" --module runtime-search --task <完整搜索成果卡>
"$FLEET" dispatch --coord "$COORD" --module api
# 主端按当次 schema 默认显式 spawn(fork_context=false)，记录返回 ID 与真实证据，再登记
"$FLEET" register --coord "$COORD" --module api --attempt <attempt> --agent-id <实际agent_id> --evidence-file <spawn事件.json>
# 只有主历史短且聚焦、任务高度相关、转述遗漏风险/整理成本明显更高时，PM 自主 spawn(fork_context=true)，不询问用户
"$FLEET" register --coord "$COORD" --module api --attempt <attempt> --agent-id <实际agent_id> --evidence-file <true的spawn事件.json> \
  --context-reason '主端仅有本卡相关约束，直接继承可避免转述遗漏并省去明显整理成本'
"$FLEET" bind --coord "$COORD" --module api --attempt <attempt> --worktree <独立工作树或产物目录>
"$FLEET" observe --coord "$COORD" --module api --attempt <attempt> --agent-id <ID> --tool wait_agent --evidence-file <wait事件.json>
"$FLEET" status --coord "$COORD"
"$FLEET" validate-receipt --coord "$COORD" --module api --receipt-file <实际文件>
"$FLEET" collect --coord "$COORD" --module api
"$FLEET" snapshot --coord "$COORD" --file <完整当前快照>
"$FLEET" reply --coord "$COORD" --module api --text-file <执行交接> --session reuse \
  --reuse-reason '同一缺陷复验，保留已验证复现现场更快' --observed-agent-id <ID> --observed-state completed
# 真实 send_input 后 register 相同 agent_id、新 attempt 和接受事件
# 同结果需要换人：不能仅因阶段或固定轮数换新
"$FLEET" reply --coord "$COORD" --module api --task <完整当前卡> --text-file <执行交接> --session fresh \
  --fresh-reason '旧假设反复污染定位，已交接反例与失败尝试' --observed-agent-id <旧ID> --observed-state completed
# closed/shutdown 的 reuse 先由主端 resume 并 observe；有已核实旧轮endProof且无新提交的恢复初始化可接续，之后才 reply reuse
"$FLEET" observe --coord "$COORD" --module api --attempt <attempt> --agent-id <ID> --tool resume_agent --evidence-file <resume事件.json>
# 主端 close 后记录请求，已确认旧轮结束且 close 调用成功可记 closed/released；后续 not_found 保留该证明
"$FLEET" observe --coord "$COORD" --module api --attempt <attempt> --agent-id <ID> --tool close_agent --evidence-file <close事件.json>
"$FLEET" defer --coord "$COORD" --module <未派发任务> --attempt <attempt> --reason capacity --evidence-file <实际错误文件>
```

## 证据与状态

register/observe 使用本地封装（仅示意格式，不能把示例当真实证据）：
```json
{"module":"api","attempt":"本轮身份","tool":"wait_agent","args":{"targets":["实际ID"],"timeout_ms":30000},"result":{"status":{"实际ID":"pending_init"},"timed_out":true}}
```
封装的 module/attempt 是本地字段；args/result 复制实际工具输入输出，不加 role/purpose 等 schema 外参数。
原始事件按内容哈希收存 `history/<module>/<attempt>/native-events/`；脚本校验结构/身份，不能认证证据来源，主端对真实性负责。
register 核 spawn 的显式布尔 fork_context 和实际返回 ID；false 保持旧行为，true 必须带单行非空 --context-reason。
该理由只存本地 spawnContext，不是宿主工具参数；false/reuse 传该参数、reuse 证据中带 fork_context、非布尔/缺省值均拒绝，验证失败不修改任务资产。
true 只继承主端当前历史，不继承旧 worker 历史；噪声多、清除旧假设的重新诊断用 false，不能用继承省略完整卡/完成条件/写入范围/交接。
独立执行按现有 role in verify/integ/regression 且 phase != author 判定并拒绝 true；author 准备资产允许按收益选择。
reuse 核 send_input.target/submission_id 并保留原 agent 自身历史；重复登记须相同事件与理由才幂等，不能借重放改理由。
prepare/dispatch/reply fresh 输出 spawnPolicy（defaultForkContext=false、allowForkContext）供主端决定，不调用宿主；register 按实际证据校验并保存 spawnContext（forkContext、reason），reuse 保留，fresh 将旧值归档后按新 spawn 记录。
allowForkContext 仅表示角色/阶段未硬性禁止 true；上下文收益、噪声及清除旧假设的判断仍由 PM 负责，不是自动放行。
observe 接受当前契约的 wait/close/resume 状态；不支持的形状拒绝，保留原文件并核当次 schema，不能猜状态。
send 后 wait 可能反复返回旧 completed。完成正文须为含本轮 rq/module/attempt/agent_id 的完整 v2 JSON，与有效当前回执一致才取得 endProof；封装不洗身份。null/摘要/旧结果只留证；不能用回执或时间戳替代结束证明。不能关联本轮的其它 raw 终态同样不放行。

status/collect 默认精简输出：state 是本地流程/业务回执，runtime 是最近真实宿主证据，capacity 是该证据能支持的占用判断；
全局容量上限仍由宿主判定。deliveryReady 要有效 done 回执且与当前已核实 completion 一致；reply/close 也核同一本轮 endProof，独立业务验收仍另判。
close 的 previous_status 不补造完成；同轮真实结束证据加成功 close 可派生 closed/released。shutdown 不补造 completed；孤立 not_found/未知不标释放。已关闭后 not_found 保留关闭证明，超时无目标状态不改变原运行态。
`--details` 才展开本地名册/回执；read 只读本地回执，缺回执给定位提示，不读 App 线程。

fresh 后旧者仍在 previousSessions/retiredAgents 显示真实容量；可用旧 agent-id/attempt observe close/wait 更新它（先前终态+成功close可确认释放，不强制shutdown），不允许 resume 已退役执行者。

defer capacity/tools 保留未派发任务和真实错误，dispatch 只给主端下一步，不自动排队重试。
defer uncertain 阻断再次 dispatch；若之后找回实际 spawn 结果，可原身份 register，不重复创建。
脚本不承诺处理主端崩溃后原生身份恢复；不确定调用必须先核真实结果，不能靠本地 prepared 推断从未发出。

## 回执与接续

v2 保留 `version,rq,module,attempt,worktree,result,summary,commit,tests,risks,needsInput`；新 native 回执加 `agent_id`，必须与名册匹配。
任务卡由 prepare 保存 `<module>.task.md`、taskRevision/taskSha256；reply --task 全量替换，旧任务/身份/prompt 按 attempt 归档。
text-file 仅交执行步骤，不增改要求。reuse 同 ID 新 attempt、保留智能体历史；fresh 同 module 新 ID/attempt，保留原资产和 previousSessions。
两者须先 observe 并核得旧轮 endProof；已核实 completed 后关闭/恢复为 pending_init 且无新 submission 时，可带该状态 reuse（不适用于新任务初始化），reply 的 observed 参数只核同一证据，不接受口头终态代替；auto 不隐式选择。
reuse 需具体 reuse-reason；fresh 需 fresh-reason、当前 handoff 和经核验的现有资产。所有参数验证先于卡片/回执变更。
执行者身份与继承选择分开：fresh 不按阶段名称机械禁 true，符合新建策略可用；为清除旧假设而 fresh 时用 false。
fresh true 不能恢复旧 worker 的现场，仍需完整交接；关联回修需要该现场时优先 reuse。
原有三轮回修复核护栏保留：重审需求/契约/环境和失败尝试后可 --force 继续；它不绕过身份/终态/交接校验，也不强制 fresh。

author→execute 若本卡已约定两阶段与切换条件，可仅 --phase execute；否则 --task 给完整执行卡。默认按关联收益考虑 reuse。
若 author 的 spawnContext.forkContext=true，不能 reuse 进入独立 execute（自身历史仍含主端聊天），须 fresh 后显式 false；旧名册无该字段沿用此前强制 false 的兼容行为。
validate-receipt 退出0表示协议/Git证据通过，退出1列全部检测错误，参数/环境错误退出2，不认证业务真实性。
done 的代码检查保留：同仓库/独立树/基线与干净状态；developer 至少一个 passed，回执提交和工作树 HEAD 必须已合入；
author 可 not-run 但须提交/脚本证据；最终 verify/integ/regression 全部 passed，SHA 同时等于工作树与当前集成 HEAD。
非 Git 产物不伪造 SHA；核真实产物目录、定向证据，独立验收复核来源/结论。纯只读卡可 --read-only，不据此授权写来源。

collect 保留 failed/blocked、需要输入和失败证据；失败/blocked 的工作树也验证并持久绑定，避免 fresh 丢失未提交现场。
协调目录不可写时 bind 核真实资产/attempt，输出 pending binding 到临时 inbox；collect 从有效回执持久绑定，不能绕过身份/仓库校验。
handoff 使用 attempt 专属路径；兼容旧 `<module>.handoff.md` 仅接受不早于本轮的文件并持久归档来源/hash。
无 handoff 的旧回执可收存并警告，fresh 前必须补齐。CURRENT 用 snapshot 原子替换、旧版归档，相同内容幂等。

## 旧入口处置

| 入口/字段 | 处置 |
|---|---|
| 多 session/子会话/fleet 等词、技能名、module/attempt、v2 回执 | 保留，执行转 native subagents |
| 新名册 executionKind=subagent/agentId | 唯一 native 身份；sessionId 只为同值兼容别名 |
| 旧 App 名册无 executionKind、旧 sessionId/hostId/clientThreadId/sidebar/cursor | 保留历史，不映射 agent；status/read/validate/collect 可只读/收存，register/observe/reply/dispatch/bind 拒绝旧执行路径 |
| --session-id/--observed-session-id | 仅新 subagent 名册接受 agent ID 别名；不接受 App ID 冒充 |
| register --client-thread-id/--host-id/--sidebar-section-id | 显式拒绝并提示原生 agent 证据 |
| --transport auto/native、--backend codex、--permissions inherit | 本地兼容，统一 native；不改变宿主权限 |
| prepare --self | 仅用户明确要求主端亲做时保留，不默认走此路径 |
| stop-guard/rescue-owners | 静默空操作，不启动旧后端 |
| 旧 backend/daemon/queue/panel 命令、--after | 明确拒绝，无静默回退 |

旧 App 任务接管：先由主端核原写者确实停止（本技能不替它运行旧 App 后端），保存原名册/卡片/回执/handoff/树与提交。
为新 native 任务 prepare 唯一身份，卡片链接旧 RQ/module/attempt；沿用原树与脏资产，核同仓库/基线后 bind。
如同 RQ 的旧模块已占原树，另建 RQ 记录接管关系，不改旧名册伪造 agent 历史；旧执行者停止无法确认时阻断写入接管。

本地合入仍用 cc-fleet-land Git CAS；集成 worker 按用户授权处理共享分支，默认不 push/发布/清理。
`cc-fleet-e2e-scope plan "$COORD" --project-dir <实际集成工作目录>` 固定比较 baseCommit 与 integrationBranch；回归 worker 汇总去重范围。
共享锁 stale 仅提示核实，不能按时间抢锁；主端核持有者确实停止操作后再让资源负责人按原 owner release。
