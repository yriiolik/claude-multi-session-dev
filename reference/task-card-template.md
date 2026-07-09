# 模块任务卡模板

> 主 session 拆需求时，每个模块写一张任务卡。
> ⚠ **粒度铁律：一张卡只锚定一个既有模块**（项目模块地图 / `docs/requirements/<NN>/` 的一个编号）。
> 「业务需求锚点」里出现第二个模块的文档编号 = 拆错了，回去拆成多张卡各派一个 session；
> 跨模块联系写进「上下游协作」段（协同模式 + 依赖锚点），不是把别的模块塞进本卡。
> 结构化布局放 `tasks/<RQ>/modules/<module>.md`（供 `cc-dispatch-batch` 批量派发）；
> 轻量布局放 `.fleet/<RQ>/<module>.task.md` 亦可。
> 派发时由主 session 在卡正文前拼上 `dispatch-preamble.md`。

```markdown
# 任务: [一句话业务目标]

> RQ: {{RQ-id}}
> Module: {{module}}
> Scope: {{要改动的包/目录/能力边界}}

## 整体业务目标（主 session 必填，给子模块看全局，防跑偏）

[这次需求最终要达到的业务效果——不只本模块，是整体。让子模块知道自己这块服务于什么。]

## 业务需求锚点（主 session 必填，承上）

- 针对的 L1 业务需求文档/章节: <docs/requirements/<NN>/README.md#<anchor>，可多条，
  **但必须同属本卡这一个模块**——出现第二个模块编号即违反粒度铁律，拆卡>
- 业务级变化如何: <相对原状态，业务上发生了什么变化>
- 本模块承接其中: <本模块负责支撑上面哪几条业务需求>

## 上下游协作（有跨模块联系时主 session 必填；本卡范围仍只限本模块）

- 协同模式: <模式 A 契约先行（并行，按契约 mock 对端）/ 模式 B 提供方先行（串行，按真实接口接入）/
  仅先后依赖（无新接口）/ 无>
- 上游依赖: <依赖哪个模块的什么——契约文件 `<COORD>/contracts/<name>.contract.md`、或上游模块回执里
  的真实接口形态（模式 B）；无则写"无">
- 下游消费方: <本模块产出将被哪些模块消费（提供方卡必填，让它知道契约/接口服务于谁）>
- 登记散点授权: <本卡允许顺带改的范围外注册点，如 menu-config.ts 加一条菜单 / 路由注册 / rbac 门禁，
  逐条列出；**未列出的范围外文件一律不许碰**。无则写"无">

## 业务背景

[用业务语言写：为什么要做、影响哪些单据/流程。不要写"改 X 表的 Y 字段"这类实现细节。]

## 验收清单（主 session 拆需求时必填，每条对应一个可验证行为；建议 EARS 句式）

- [ ] R1: WHEN 库存不足 THE SYSTEM SHALL 下单返回 409 + INSUFFICIENT_STOCK
- [ ] R2: ...
- [ ] R3: ...

## 接口/契约约束（如涉及跨模块——协同两模式，见 reference/contract-first.md）

按本卡在所选协同模式里的角色填其一（无跨模块接口交互则整段删除）：

**模式 A · 契约先行：**
- **契约设计卡（派给 API 提供方，段①）**：本轮**只产出契约、不实现业务逻辑**；契约文件落
  `<COORD>/contracts/<name>.contract.md`，需覆盖接口签名 / 请求·响应 schema / 字段口径单位 /
  错误码 / 示例（供消费方写 mock）。主 session 评审定稿后才进段②。
- **提供方实现卡（段②）**：按已定稿契约 `<COORD>/contracts/<name>.contract.md` 实现真逻辑。
- **消费方接入卡（段②）**：依赖契约 `<COORD>/contracts/<name>.contract.md`（作锚点）；**对端按
  契约 mock 自测，不等提供方做完**。发现契约需改 → 写「需主 session 裁决」，不要单边改契约。

**模式 B · 提供方先行：**
- **提供方完整开发卡（第一批）**：一张卡完成本模块设计 + 实现 + 自测；对外接口形态在回执里写清，
  契约文件仍建议落 `<COORD>/contracts/`（供消费方与验收引用）。
- **消费方接入卡（第二批，提供方 done 后才派）**：依赖锚点 = 提供方回执/契约里的**真实接口形态**；
  自测直接打真接口、无需 mock。发现接口不够用 → 写「需主 session 裁决」，由主 session 派提供方补改。

## 实现回执（模块 session 完成时回填，对应每条 R）

- [ ] R1 ← <测试文件:行号>
- [ ] R2 ← ...
- L2 模块需求文档: <路径>（↑挂 L1 业务需求条目、↓到本模块设计与测试）
- 自测结果: <单测/e2e pass 条数>
- worktree 隔离: <开了哪个 / 已 reset --hard 对齐 fleet/<RQ> / 已 cc-fleet-land 落地 / 已清理；纯只读未开>
- 集成分支落地: <已 cc-fleet-land 到 fleet/<RQ>，落地 sha；未碰任何共享分支(dev/<name>/main)>
- 关键 commit: <你模块改动的 commit sha>
```

**承重墙**：主 session 不填「整体业务目标/业务需求锚点/验收清单」不派发；模块 session 不建 L2 模块
需求文档（承上启下双向 trace）、不回填「实现回执」+ 回执（`<module>.summary.md` 到主 session 给的
绝对 `{{COORD_DIR}}`，写不进就退回自己 cwd 的 `./.fleet/<RQ>/`，**并永远把回执作为最后一条消息发出**）
不算完成。主 session 凭回执 + 双向 trace 链 + 验收 session 报告判断整体业务效果。**主 session 不代写 L2 文档。**

> 派发侧：主 session 先用 `RQ="$(cc-fleet-coord --alloc)"` 自动取一个全新空号 RQ（**只收 stdout、别加 `2>&1`**；
> **绝不许凭"今天日期+NNN"手拼编号**——丢了 `$RQ` 就回读它/协调目录，别另敲一个，否则同日多 run 会撞已用目录串台），
> 再用 `cc-fleet-coord "$RQ"` 取 `{{COORD_DIR}}`（worktree 无关绝对路径），
> 用 `INT="$(cc-fleet-coord --init-base "$RQ")"` 在**发起任务时的当前分支**上建本 RQ 的集成分支 `fleet/<RQ>`，
> 派发时加 `--env FLEET_BASE_BRANCH="$INT"`（worker 据此 reset --hard 锚定 base + `cc-fleet-land` 落地，**不碰共享分支**），
> 用 `cc-dispatch --sid-file "$COORD/<module>.sid"` 记 SID 名册（带 --sid-file 会过复用兜底闸，疑似复用别任务 RQ 即 `exit 6`）；完成判定只认 `cc-fleet-status`
> （按 SID 关联 daemon 状态，不靠会变空的 session 名、不靠 summary 文件是否出现），防主 session 死等。
> **验收通过后**主 session 把 `fleet/<RQ>` 合回 base（读 `<COORD>/base.ref`）+ push + 删集成分支，共享分支才动这一次。
