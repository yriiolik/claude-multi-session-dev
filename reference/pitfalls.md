# 踩过的坑与事故复盘（完成判定 / RQ 编号 / 灰度坏模型）

> SKILL.md 正文的「完成判定与回执」「RQ 编号」「灰度坏模型」几条铁律，结论与操作已在正文。
> 本文保存它们背后的**根因分析与真实事故复盘**——理解「为什么这么定」时看，日常编排不必读。

## 一、主 session 死等一个早已完成的 worker —— 四个根因

主 session 无限等一个子 session，而它其实早已完成。四个根因：

**① 把「回执文件出现了没」当成「完成了没」。** worker 常跑在隔离 worktree+sandbox，回执写进**它自己
worktree** 的相对 `.fleet/<RQ>/`，主 session 盯主仓库路径 → 那文件**永远不出现** → 死等。

**② 主 session 拿不到任何完成推送。** `cc-dispatch` 派的是独立 daemon session，**不被主 session 的 harness
跟踪**，子 session 结束时主 session 收不到通知，只能自己轮询 → 模型要么 sleep 死等、要么呆等用户，子 session
早 done 了也察觉不到（10~20min 盲等）。→ 对策：铁律 0 用 watcher 把「完成」转成原生推送。

**③ 把 `state=working` 当「还在跑」。** daemon 的 `state` 是【分类器读最后一条消息】推出的，worker 活干完却
没打 `result:` 就会停在 `working`，而它的 `tempo` 早已 `idle`（循环已停）。盯 `state` 就会对一个**实质已结束**
的 session 无限等。→ 对策：铁律 1.5 看 `tempo` 不看 `state`。

**④ daemon 把已完成的后台 session respawn 回 `running+active`，把 `done` 擦掉。** spare 池保活/resume 会让一个
早已 done 的 worker `state` 翻回 `running`、`tempo` 回 `active`、`startedAt` 重置、`name` 变空。只看易失的
`state` 就把它当「还在跑」无限等，连静默兜底（根因③）都因为 `tempo=active` 失效。**这个最隐蔽**：worker 真的
100% 做完了（回执落盘、合回、清了 worktree），daemon 却又报它在跑。→ 对策：铁律 1.6 用带 `result:` 的持久
回执做【单调闩锁】，respawn 抹不掉文件 → 抹不掉完成。

### 踩过的两个坑（实录）

> 🚫 **坑①（worktree 相对路径）**：worker 在隔离 worktree + sandbox 下把回执写进**自己 worktree** 的相对
> `.fleet/`，主路径那个文件永不出现，主 session 死等，而 worker 早已 `done`（还把回执 commit 进 git 才让主
> session 事后看到）。**完成看 `cc-fleet-status`（SID 关联）+ canonical 回执，回执走多通道。**
>
> 🚫 **坑②（respawn 擦掉 done）**：worker `ic-viewer` 09:48 已彻底完成（回执落 canonical、result: 写着「已合回
> main 并 push、worktree 已清理」），11:27 被 daemon respawn 回 `running+active`、name 变空。主 session 当时的
> 原话是「**完成判定看 daemon 状态不看文件**，它多半在做合回/清理收尾，回执仅作进度参考」——于是死等一个早已
> done 的 worker，完成通知永不到。**根治**：`cc-fleet-status`/`cc-fleet-watch` 已把 canonical 里带 `result:` 的
> 回执作为**抗 respawn 的单调完成闩锁**（`receipt=1` / 🧾 / `✅ 已完成 — 回执在案`），respawn 翻不动它。看到 🧾
> 就是已完成，**别再当进度参考继续等**。

### tempo/state 判定要点补充

- `blocked`（等授权/输入）**不算结束**：worker 等输入时 daemon 报 `tempo=blocked`（`state` 仍 `working`，
  2.1.167 实证——别只看 `state` 把它当 active 在跑而死等；watch/status 已把 `tempo=blocked` 归入 blocked 路径）。
- `idle` 可能是瞬时（worker 等自己起的后台 E2E 时会短暂 idle 再被唤醒），所以静默判定要连续够久（`--stall-idle`
  默认 240s，带 2 轮去抖），且**一旦被判静默的模块又 `active` 会自动撤销静默**继续等。若 watch 因某模块静默而
  退出、你去核验时发现它又活跃——**重挂一次 `cc-fleet-watch` 即可**（成本极低）。
- 有回执→硬完成（抗 respawn）；无回执→看 tempo 静默兜底。两条互补。

## 二、RQ 编号手拼串台（2026-06-09 真实事故）

> 🚫 **铁律**：RQ 编号只能由脚本现场分配，每个新任务一次；任何时候都不许凭「今天日期 + NNN」在脑内重构编号。
> 引用 RQ 的所有场合（派发 / arm Monitor / 写回执路径 / 二次派发 / 跨 turn 接着做）一律从**本轮 `$RQ` shell
> 变量**或**协调目录**回读，**绝不重新拼字面量**。日期段对人脑「太好猜」——一旦丢了 `$RQ` 就会下意识填
> `今天-001`，正好撞上早些时候那一轮还在的协调目录。

**事故经过**：上午任务用了 `RQ-2026-0609-001`；下午另一个任务丢了 `$RQ`、凭日期重构又敲了 `001`，普通解析
（`cc-fleet-coord <RQ>` 会 `mkdir -p` 静默建/复用）直接复用了上午仍在的协调目录，两个任务的 `.sid`/回执混进同一
目录、`Monitor` 也盯错了 RQ，主 session 收到串台状态。分配脚本本会给下午分到 `004`——根因就是**绕过分配、手拼
编号**。→ 对策：`cc-fleet-init` 从持久序号池 + 原子锁发号，永不重号；显式 RQ 用 `--fresh` 防撞；派发侧复用兜底闸
（`exit 6`）兜住手拼旧编号。

## 三、灰度坏模型（worker 质量降级）识别细节

> 当前大模型处于**灰度分流**：偶尔某个 worker 会被分到**质量很差的模型实例**，硬纠偏（`cc-fleet-reply`）往往
> 无效——它还在同一个坏模型上。**换一个新 session（`cc-fleet-respawn`）通常就分到好模型、问题自愈。**

**识别信号（命中即疑似降级，不是任务真有歧义）**：
- 把**瞬时工具抖动**（`cat`/`echo`/`Read` 偶发无回显、单次超时）误判成「通道彻底卡死 / 环境坏了」，**停下来
  问人而不重试**（真相多是抖动，重试即好）；
- 明明能按「自主判断」自决的口径 / 文案 / 阈值 / 实现路径，却**反复要人确认、要人手把手**；
- **空转很久没实质进展**（Brewed 20min+ 仍在原地）、或轻易放弃 / 兜圈子 / 反复重述已知事实；
- 输出明显低质：答非所问、违反已下发的范围铁律、中英混杂。
- 这些多半以 watch 推的 **`⏸ <module> blocked`（等输入）** 出现，也可能是 `running` 但最后一条消息 / 回执肉眼
  可见地烂。

**与「真 blocked」区分（关键判断）**：先问一句——**一个称职的 worker 在这里会不会自己往下走？**
- 会（此处本该自主判断，它却停下来问）→ **降级信号，走 respawn**，别浪费 reply。
- 不会（确属该由人拍板的业务口径冲突 / 需要授权 / 需要外部信息）→ 这是**合理的 blocked**，用 `cc-fleet-reply`
  回它或向用户 `AskUserQuestion`，**不要 respawn**（换模型也解决不了缺信息）。

**别滥用**：respawn 是给「模型能力降级」的，不是给「任务本身难 / 需求没写清」的——后者是主 session 把任务卡写
更清楚、或补 L1 文档的事。同一模块**连续 respawn 两三次仍降级**，多半不是模型问题（是任务卡有坑 / 环境真坏），
停下来查根因，别无限换 session。

## 四、CLAUDE.md 自动加载的历史回归（为什么 cc-dispatch 注入默认关）

后台 session 现在会自动加载三层 `CLAUDE.md`（2.1.181 实测：14/14 spare worker 均按【派发 cwd】重新解析加载
用户级 + 项目级 + 目录级）。但早期 daemon 不保证加载（spare 池沿用预热 cwd、约 3/4 miss，致 worker 英文回复 /
不自觉开 worktree / 甚至改主树；`--setting-sources` 当年已证伪是安慰剂），曾靠 cc-dispatch **默认把规范原文塞进
prompt** 兜底；现已改为**默认关**注入，不再与自动加载重复烧 token。
⚠ 这是 daemon 内部行为、历史上回归过（2.1.167 还在 miss）——若某次升级后 worker 又不守规范（英文 / 不开 worktree /
改主树），用 `cc-dispatch --inject-claude-md` 重开兜底（把三层 `CLAUDE.md` 原文塞进首行哨兵后的
`⟦INJECTED-CLAUDE-MD⟧` 块，spare 无关、稳定可靠），并重跑 `tests/test-cc-dispatch-inject.sh` + 真实探针确认。
