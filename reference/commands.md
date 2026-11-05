# 命令与回执

`FLEET=<本技能绝对路径>/scripts/cc-fleet`，`COORD` 取 init 输出；所有命令都不操作原生线程生命周期。

```bash
"$FLEET" init --cwd <仓库或子目录> --host codex-app --owner-id <真实主会话ID>
"$FLEET" prepare --coord "$COORD" --module api --task <绝对任务卡路径> --role developer
"$FLEET" prepare --coord "$COORD" --module verify --task <验收卡路径> --role verify --phase author
# solo 也生成卡；主端用 App 原生隔离工作树后 bind，不由 CLI 创建工作树
"$FLEET" prepare --coord "$COORD" --module main --task <任务卡路径> --self
"$FLEET" bind --coord "$COORD" --module api --attempt <本轮attempt> --worktree <真实目录>
"$FLEET" register --coord "$COORD" --module api --session-id <真实ID> --host-id <host> --sidebar-section-id <已核验分区>
# setup 未完成时，register 改用 --client-thread-id，仅记 pending
"$FLEET" status --coord "$COORD"
"$FLEET" validate-receipt --coord "$COORD" --module api --receipt-file <实际回执文件>
"$FLEET" collect --coord "$COORD" --module api
"$FLEET" snapshot --coord "$COORD" --file <准备好的唯一当前快照>
"$FLEET" reply --coord "$COORD" --module api --text-file <本轮纠偏内容> --session reuse
"$FLEET" reply --coord "$COORD" --module verify --text-file <执行说明> --phase execute --session fresh \
  --observed-session-id <刚核实的旧真实ID> --observed-state completed
```

reply 的 reuse/auto 返回 promptFile，由主端按当前模型/深度用原生消息投递；接受后 register 同一身份。
fresh 需主端实际核实旧本轮结束、当前 handoff 存在，随后原生创建并带新 --attempt 登记。
`--observed-state` 允许 completed/failed/interrupted/stopped；未知、运行中、输入/审批等待不能换新，--force 不能绕过。
CLI 只检身份与显式终态断言，无法代替宿主读取。fresh 保留模块/worktree/成果与 previousSessions，不停止、归档旧线程。
auto 为旧原生任务兼容默认复用；主端按阶段决定是否明确 fresh，不按 token 阈值自动选择。

status/collect 默认输出模块、attempt、身份、结论、SHA、测试计数、风险/输入和证据位置；`--details` 才附全量回执/名册。
`read` 读取本地当前完整回执，没有回执只返回原生定位提示；不从任何旧后端取日志。
validate-receipt 成功退出0，检测到问题退出1并列全部 errors；参数/环境错误退出2。格式修正不要求重跑有效测试。
collect 保持 failed/blocked 原结果，保存回执与可找到的 handoff 到 `history/<module>/<attempt>/`。
新 handoff 路径含 attempt；兼容旧 `<module>.handoff.md` 时须更新时间不早于本轮开始，再记录来源与哈希。
无 handoff 的旧回执仍可收存并警告，fresh 前必须补齐；不能只留临时 inbox 路径。
snapshot 归档旧 CURRENT 后原子替换；相同快照幂等。主端另有可写状态目录时沿用同样单快照/历史分离原则。

回执 v2 保持 `version,rq,module,attempt,worktree,result,summary,commit,tests,risks,needsInput`。
done 核验工作树仓库/基线、干净状态及测试；developer 至少一个 passed，回执提交和工作树 HEAD 均须已合入；author 要有提交和脚本证据，
可以 not-run；最终 verify/integ/regression 所有项 passed，实际 SHA 同时等于工作树与当前集成 HEAD。
当前 failed/blocked 留 tests；resolved_failures 保存已解决历史失败。机械校验不证明业务覆盖或测试真实性。

原生 prepare 只支持 codex/native/inherit，可指定 --subdir。依赖由主端按 CURRENT 推进，不使用 --after/queue-reply。
stop-guard/rescue-owners 仅为已有全局 hook 保留静默空入口；其余旧后端、面板、daemon 命令已移除。
本地合入仍用 cc-fleet-land 的 Git CAS；E2E 统一计划在含当前集成版本的工作树执行：
`cc-fleet-e2e-scope plan "$COORD" --project-dir <项目工作目录>`。计划固定比较 fleet.json 的 baseCommit 与 integrationBranch，
不以调用目录的 HEAD 代替集成版本；执行测试仍用实际集成版本工作树。范围推导/登记与共享锁保留。

bind 若只因协调目录无写权限，会先核验实际仓库、隔离工作树和 attempt，再把 pending binding 写入临时 inbox，
允许在已核验工作树继续；回执必须填该真实路径，主端 collect 后持久绑定。身份/仓库/基线校验错误不能绕过。
E2E 锁超过 stale 只报告待核实，不按时间自动删除独占锁或共享登记。主端先原生核实持有者不再操作共享资源，
再按原 owner 执行 release；不能因等待久就抢锁。
