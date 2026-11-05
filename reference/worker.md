# 独立 worker 协议

只执行本卡授权范围，不再派子 session。开工及压缩恢复读：本卡→相关原始需求/追加要求→用例→契约→最新交接/Git 状态。
遵守实际工作树与子目录适用的 AGENTS.md 及其引用规则，不把聊天摘要当唯一需求。

## 执行与验证

- developer：隔离 worktree 开发，相关定向自测，提交后在该 worktree 执行本技能 `scripts/cc-fleet-land <RQ>`，只合入本地集成分支。
- verify/integ author：按原始需求、用例和契约独立编写验收脚本/夹具/清单，提交但暂不 land；不等待开发，tests 可 not-run，
  evidence 指向脚本与用例映射。收到 execute 后保留脚本、合并最新集成基线，需交付的脚本提交并 land，再测试最终集成 SHA。
- verify/integ execute：不改业务代码或放宽断言；真实页面先连续跑主流程，再逐项验证适用分支/异常、幂等与事务。
  API/单测/mock 自家业务接口不能替代页面；确无页面入口记录理由及实际入口。逐例保存操作、结果、截图/trace、SHA 和环境。
- regression：在集成基线上按给定去重范围统一执行，不自行扩到全量。与 verify 合并承担时分阶段记录。
- scout/研究：提交可复现结论、来源和反例；精确 ID/路径先核身份和原字段。核真实 schema/语义；缺源前检查已配置的相关库/镜像。
  自测包含会改变结论的去重、单位/分母、时期或范围不可比、缺证等反例。研究样本仅是本次输入，不能硬编码生产白名单/答案。

开发自测默认仅本卡相关最小集合，E2E ≤6 spec 且 ≤15 分钟；超预算列待回归，不偷偷跑全量。
任务卡没给范围时用 `cc-fleet-e2e-scope suggest --base fleet/<RQ>` 推导裁剪；跑后 record 实际范围。
E2E 前后通过 `cc-fleet-e2e-lock acquire/release <COORD> <module>` 协调共享资源；regression 默认 exclusive。
锁等待使用短有界 --wait；stale 只提醒核实，不证明持有者死亡，不自动抢锁；纯远端等待仅在确认不再写共享资源后释放自己的锁，需要共享操作再获取，禁止强解他人锁。

本卡负责的异步业务尚在运行时持续有界等待，accepted/首轮返回不等于最终结果。只有实际失败或真实外部阻断才交 failed/blocked。
真实小样本须贯通到最终产物和业务判断，结构绿/零外研不能冒充成功；最终仍完成全部指定范围。
不 reset --hard、不推远端、不擅自合共享分支、删除或清理 worktree。

## 输入与回执

业务澄清交主端汇总，不自行调用 request_user_input / request_user_input_async / AskUserQuestion 弹卡，也不跨线程求答。
已有授权能决定就继续；确缺必需输入先做独立工作，再 result=blocked，needsInput 给问题、选项/推荐、影响和已查来源。
强制审批仍走宿主真实通道，调用前 commentary 说明动作、原因、操作入口；不能代批、改权限或用普通消息冒充批准。
异步提问返回不表示已有答案；旧问题解决后记录已解除及当前真实阻塞，避免重复提问。

每轮先写任务前缀指定的 attempt 专属 handoff（建议 ≤80 行）：
原始需求/用例/契约版本、已实现/未实现项、worktree/提交/合入 SHA、环境与必要命令、验证证据、当前失败/未决问题、下一步。
保留对独立验收有用的事实与证据链接，不复制聊天、完整日志或已作废猜测。
随后将完整 v2 JSON 原子写到指定 receipt；协调目录不可写时使用前缀指定的临时 inbox 与同 attempt handoff。
最后执行前缀中的 validate-receipt，检查通过再输出同一 JSON。检查只核协议与 Git 证据，业务真实性仍由独立验收判断。

当前版本失败如实写 tests.result=failed 且 result=failed/blocked，不藏进 risks、改 not-run 或删断言。
已解决的历史失败放顶层 resolved_failures，保留原 command/result/evidence、修复 SHA 与当前复验引用；当前 tests 仅列当前检查。
必需入口、算法、判断或校验仍待实现即未完成；按预期实现并验证的 unknown/gap 是业务结果，不能冒充业务成功。
开发 done 表示本卡实现及定向测试已交付，不等待下游 verify 形成环；契约替身自测不等于真实联调完成。
只修正回执字段且代码/配置/测试基线未变时，引用仍有效证据，不重新跑整套测试；证据失效则按范围复测。
