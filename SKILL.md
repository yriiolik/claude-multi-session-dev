---
name: multi-session-dev
description: >-
  按可独立验收的结果编排原生子智能体，主端承担 PM，支持工作树隔离、契约协作、关联回修与独立验收。
  用户要求多 session、多会话、子 session、子会话、独立或并行 session、fleet、multi-session，或明确要求子智能体/多智能体委派时使用，开发、调研和数据均适用。
  兼容旧调用词，执行统一使用 native subagents。普通单任务、顺带提及、讨论和维护本技能不自动编排；维护时用户直接要求委派则遵从。worker 不递归编排。
---

# 原生子智能体协作

`multi-session-dev` 保留名称和任务/回执资产；旧 session 用语在本技能中路由到原生 subagents。
`scripts/cc-fleet`（下称 `$FLEET`，按技能绝对路径调用）只管理本地任务资产、证据与名册，不调用 native tools、不运行后台调度器。
首条任务以 `⟦FLEET-WORKER⟧` / `⟦CODEX-THREAD-WORKER⟧` 开头，或 `FLEET_ROLE=worker`：只读本卡及 [worker 协议](reference/worker.md)，不加载主端编排。

## 主端与开局

- 主端保持清洁 PM：目标、拆分、派发、裁定、资源/依赖推进、必要的精简状态/证据核对和用户沟通。
  实际调查、事实整理、实现、环境修复、集成、打包、回归、真实验收均委派；单结果也交一个 worker。
  不为写卡先重做整项调查，也不强制常驻“管理/资料 worker”。事实整理确实需要执行时，按需指定唯一负责人。
  只有用户明确要求主端亲自执行时才用 self。维护本技能本身不强制业务编排，用户直接要求委派时照做。
- 先读项目指导与原始需求，按 [交付保障](reference/delivery-quality.md) 保存原文/附件版本、用例、证据和当前快照。
  代码用 `$FLEET init --cwd <实际目录>`，基线只含已提交内容；不提交、覆盖或丢弃用户改动。
  非 Git 研究/数据用 `init --workspace --cwd <资产工作区>`，产物仍须独立目录和来源追溯。
- 多结果按 [拆分与契约](reference/contract-first.md) 拆成可独立验收的成果；同专业/岗位可有多个 module。
  分清开发、局部真实融合、最终验收前置，冻结必要契约后并行，不把最终消费依赖误当开工门槛。
  共享文件、事实文档和接线点有唯一写者，长异步/高不确定路径先真实小样本贯通再扩量，不阻塞无关工作。
- 每轮完成条件由实现者提出、独立验收者按原始要求审定，再放行受影响结果；不等全项目设计或全部脚本完成。
  验收 author 可并行准备脚本，author done 仅表示验收资产就绪，execute 才验证实际集成结果。

## 精准派发与上下文

按 [任务卡](reference/task-card-template.md) 给每个结果一份完整当前卡，用 prepare 保存版本/哈希。卡片必须交代：
整体目标、本卡作用、当前全部要求、成功/失败条件、授权与唯一写入范围、真实资产入口。

针对反复熟悉和重复调查，共享一份最小背景：稳定目标、版本化事实/契约/决策、失败尝试、证据及未知项。
沿用项目现有文件；每卡只引用相关版本/片段，并给精准入口、相关文件、阅读顺序及目的，避免全仓摸底。
事实负责人更新共享版本并通知受影响卡；主端只核决策所需摘要。卡片完整不等于复制所有共享资料：日志、大数据、
历史和废弃方案保留索引按需读取；CURRENT 整体替换，旧版归档，不能累叠“以下覆盖以上”。

新建默认显式 `fork_context=false`，以效果和速度为先。主会话短而聚焦、任务高度相关，且转述的遗漏风险或整理成本明显更高时，
PM 可自主选择 `true`，用 register `--context-reason` 记录一句理由，不询问用户。历史噪声多、独立验收执行，
或为了摆脱旧假设重新诊断时用 false。true 只复制主端当前聊天历史，不复制旧 worker 历史；false 或宿主省略时仅给初始 prompt，
本技能仍要求显式布尔值。继承不能替代完整任务卡、完成条件、写入范围和交接。验收 author 准备资产可按上述收益判断，
独立执行按现有模型 `verify/integ/regression 且 phase != author` 判定；继承过主历史的 author 进入 execute 须 fresh false。

## 原生生命周期

首次派发先读 [native 操作](reference/native-codex.md)，命令按需查 [命令与兼容](reference/commands.md)。

1. 发现主端当次实际 `spawn_agent/send_input/wait_agent/close_agent/resume_agent` 定义；缺能力就记录具体缺口。
   worker 没有嵌套工具不等于主端缺能力。禁止改用 App 独立会话、侧栏或 CLI 后台后端。
2. prepare 后，主端读取完整 prompt，用 `spawn_agent` 默认显式 `fork_context=false`，符合上述条件才选 true 并登记理由；默认省略 model/reasoning_effort 以继承。
   不猜父配置、不按岗位降档；只有用户明确覆盖时使用当次 schema 允许的参数。send_input 没有模型/深度参数。
   登记实际返回 agent_id，绑定独立 Git worktree 或产物目录。false 不复制父聊天；两种选择均继承宿主的系统/工具/权限，不承诺沙箱独立。
3. 按依赖、唯一写者和宿主实际容量并行，无人为固定模块/岗位上限，也不保证无限容量。
   容量不足先收存已完成成果、关闭可释放的 agent，再派就绪任务；不盲目重复 spawn，不建后台队列。
4. `wait_agent` 有界等待，正常只消费终态/精简结果；按当前 schema 选超时，当前契约最短 10000ms，可用 30000–60000ms。
   超时不推断失败/完成，不因沉默或普通进度反复读日志/催问。检查全部返回状态与错误，先处理需输入、审批及失败；
   有可推进 worker 就继续等待和推进，所有剩余都确实等用户时给明确交接。
5. 收取回执与当前 attempt handoff，核对真实 native 终态。业务 result、执行 runtime、容量 capacity 分开：
   send 后 wait 可能返回旧 completed；正文须含本轮 rq/module/attempt/agent_id 并与有效回执一致才确认结束，不能靠本地封装洗身份。reply、交付与关闭均使用该 endProof，细节见 native-codex。
   completed 不是业务验收通过；closed/shutdown 不是 completed；孤立 not_found 是可见性缺口，不能证明停止或容量释放。
   `$FLEET observe` 只记录主端真实工具证据，不能代调工具或证明证据来自宿主。
6. 收存证据/交接后及时 `close_agent` 释放已完成容量；它返回 previous_status，不能单从旧状态推断停止。
   已确认旧执行轮结束且对同 ID 的实际 close 调用成功，可按工具关闭/释放契约记 closed/released；宿主之后可能返回 not_found，不强求 shutdown。后续 reuse 若已关闭，先 `resume_agent` 核同身份实际恢复与可接续状态；恢复失败保留资产并报告，
   不保证跨重启恢复或主会话结束后自动唤醒。普通消息不代审批。

## reuse、fresh 与接续

先判任务关系，再选执行者，以效果和速度为先：

| 关系 | 动作 |
|---|---|
| 可独立验收的新成果 | 新 module、新 agent；无关旧任务无需先结束 |
| 同一成果的关联缺陷/紧密接续，现场有价值 | 优先 reuse，同 agent 的 send_input，保留它自己的历史 |
| 同一成果但旧假设污染、能力/上下文障碍使换人更有效 | fresh，具体说明收益，交接后同 module、新 attempt/agent，沿用原资产 |
| 活跃执行只缺澄清/解除阻塞 | 同 attempt 补本任务信息；不排新成果或新交付轮 |

reuse/fresh 均先确认目标旧执行轮已停止；回执文件不能代替宿主观察。fresh 必须有当前 handoff、已验证资产与实际理由，
不能按时间、固定轮数、岗位或阶段名称机械换新。关联缺陷保留失败尝试，避免冷启动重复排查。
要求变化先通知安全停点、保存现场，停止后用 reply --task 完整替换卡；text-file 只作运行交接，不另藏要求。
reply 只生成提示；reuse 由主端 send_input 并登记接受证据，fresh 由主端 spawn 并登记新身份。
选择执行者身份与是否继承主历史分开：reuse 保留原 agent 自身历史；fresh 按新建策略选择 false/true，不因阶段名称机械禁 true，
但为了清除旧假设而 fresh 时用 false。需要旧 worker 现场优先 reuse；fresh true 仍须完整资产交接。
投递不确定先核实既有调用，不能盲目重发。详细步骤见 [接续](reference/delivery-quality.md#执行者接续)。

## 验收与交付

保留模块定向验证→相关真实融合→完整集成的分层保障，跨卡回归去重，由独立 worker 在明确集成 SHA 执行。
实现者负责授权内定位、修复、自测与相关回修；独立验收者不改业务代码或放宽断言。主端只裁定与必要证据核对。
有页面必须实际操作页面；API/mock/编译/worker done 不能代替。纯 CLI/研究验证实际入口并说明页面不适用。
失败、blocked、未执行不能冒充完成；最终追溯原始要求→用例→证据→集成/验收版本，代码变化按影响复测，纯协议修正不重跑有效测试。
研究/数据验收还要核来源、口径、反例和专业判断，结构/计数通过不代表结论成立。

聊天隔离不等于文件隔离：独立工作树/产物目录、唯一文件写者、端口/数据库/生成产物和 E2E 锁仍要协调。
fresh 保留原树、未提交资产与历史身份；不 reset --hard、不自动 push/发布/合共享分支/清理工作树，按用户已有授权执行。
旧 v2 App 名册只读收存、明确阻断续派；sessionId 不自动变成 agent ID。兼容详情见命令参考。
stop-guard/rescue-owners 保留静默空操作；源目录外的旧 hook/触发配置仅报告，本技能不修改外部全局配置。
