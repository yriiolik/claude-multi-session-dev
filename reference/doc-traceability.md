# 文档分层与承上启下（需求可追溯性，防子模块跑偏）

> 目的：让每个子模块**知道整体业务需求**、**知道这次改动针对哪些业务需求文档及其变化**，
> 并在模块内形成**承上启下**的需求文档——向上比对到业务需求文档，向下关联到自身模块设计。
> 设计依据业界成熟实践（见文末「业界依据」）。

## 三层文档 + 严格 ownership

| 层 | 内容 | **Owner（谁写）** | 追溯方向 |
|---|---|---|---|
| **L1 业务需求文档** | 整体业务目标、跨模块场景、业务级验收口径（纯业务语言，单一事实源） | **主 session** | 顶层（被 L2 向上挂） |
| **L1.5 模块委托（任务卡）** | ①整体业务上下文 ②本次针对哪些业务需求文档/章节 + 业务级变化 ③本模块验收清单(R 条目，建议 EARS) | **主 session** | 承上（指向 L1） |
| **L2 模块需求 + 设计文档** | 本模块要满足的需求（向上挂 L1）+ 功能/技术设计（向下到代码/测试） | **子 session（主 session 绝不代写）** | **承上启下** |

L1.5 任务卡是「context map 的一格」——它是**业务面的委托书**，不是模块内部设计，
所以主 session 写它不算下钻模块。L2 才是模块内部文档，必须由最接近实现的子 session 写。

> **跨模块接口交互**还有一层**共享契约**（介于 L1.5 与各模块 L2 之间）：由 API 提供方 session 写、
> 主 session 评审定稿、多模块共同向下引用。详见 `reference/contract-first.md`（含契约文件模板与
> 协同两模式编排：模式 A 契约先行 / 模式 B 提供方先行）；契约同样遵循「主 session 评审不代写」。

## 承上启下 = 双向追溯链（不是口头交代）

```
L1 业务需求文档  ──(parent 锚点)──▶  L1.5 任务卡  ──(委托)──▶  L2 模块需求
        ▲                                                         │
        └──────────────── 向上 trace ────────────────────────────┘
                                          L2 模块需求 ──(设计/任务/测试)──▶ code
```

- **向上（承上）**：L2 里每条模块需求都挂一个 parent——指向 L1 业务需求文档的**具体条目/章节锚点**
  （如 `docs/requirements/<NN>/README.md#<anchor>` 的 `R<NN>.x`），并用业务语言复述"本模块为支撑
  业务需求 X 需要做什么"。子模块据此随时和整体业务对齐，不跑偏。
- **向下（启下）**：L2 里每条模块需求向下挂到本模块的**功能/技术设计**（接口、数据模型、状态机、
  字段）与**任务、测试用例**。
- **验收即查链**（ASPICE 4.0：光有链接不够，要评审两端是否真对得上）：主 session 验收时核对
  ——每条业务需求是否都有模块需求承接（向下覆盖无遗漏）、每个模块改动是否都能回溯到业务需求
  （向上有据无越权）。回执必须带 trace。

## 为什么"主 session 代写子模块需求文档"是反模式（已被排除的错误路线）

1. **结构上做不到向下链**：L2 必须关联模块内部设计，而主 session 按铁律从不读/碰模块源码与设计，
   它写的向下链必然失真、立刻 stale。
2. **ownership 缺失 + 中央瓶颈**：人人拥有=无人拥有；中央代写扼杀并行、文档与代码脱钩即腐化
   （docs-as-code 共识）。
3. **违反 bounded context 自治 / Conway**：模型与语言天然属于 owner（子 session）；中央强控是反模式
   （Fowler）。
- **正解**：主 session **定标准 + 画桥（委托书/锚点）**，**离实现最近的子 session 写 L2 内容**，
  文档与代码**同仓同 PR** 演化（docs-as-code）。

## L2 模块需求 + 设计文档模板（子 session 填，主 session 只评审一致性）

> 路径建议：结构化布局 `modules/<module>/docs/requirements.md`；已有仓库适配其既有约定
> （如本项目 `docs/requirements/<NN>/` 为 L1、模块 `docs/design/<NN>/` 放 L2 设计）。
> 与代码同仓、同一原子 commit/PR 更新。

```markdown
# 模块需求与设计: <module>   (RQ: <RQ>)

> Owner: 本模块 session（子 session 自维护，主 session 不代写）
> 上游业务需求(L1): docs/requirements/<NN>/README.md#<anchor>

## 一、承上：本模块承接的业务需求
| 业务需求条目(parent) | 业务期望（业务语言） | 本模块职责 |
|---|---|---|
| R<NN>.3 ← docs/requirements/<NN>/README.md#<anchor> | 库存不足时下单被拦 | 提供扣减校验接口 |

## 二、本模块需求（建议 EARS 句式：WHEN <条件> THE SYSTEM SHALL <行为>，可直接转测试）
- MR1: WHEN 收到扣减请求且可用量 < 需求量 THE SYSTEM SHALL 返回 409 + INSUFFICIENT_STOCK
  - ↑上溯: R<NN>.3   ↓下联: 设计§接口.扣减 / 测试 order.stock.spec.ts
- MR2: ...

## 三、启下：模块设计（怎么实现）
- 接口/契约: <指向 contracts/ 或现有接口定义>
- 数据模型 / 状态机 / 字段: ...
- 关键取舍（可选 ADR 风格"为什么这么定"）: ...

## 四、双向追溯表（验收据此查链）
| 模块需求 MR | ←上溯 业务需求 | →下联 设计 | →下联 测试 |
|---|---|---|---|
| MR1 | R<NN>.3 | §接口.扣减 | order.stock.spec.ts:42 |
```

## 业界依据（来源）

- **双向需求追溯 / RTM**：每条需求向上追到来源、向下追到设计/代码/测试——ISO/IEC/IEEE 29148、
  Automotive SPICE（L2 起强制双向追溯，4.0 强调"评审追溯链的一致性"）、DO-178C。
  [Perforce RTM](https://www.perforce.com/resources/alm/requirements-traceability-matrix) ·
  [ASPICE 4.0](https://a-spice.de/wp-content/uploads/2024/05/ASPICE_31_vs_40_part_SWE_1-6.pdf)
- **Spec-Driven Development（AI agent 防漂移）**：requirements→design→tasks 三件套互链、规格即事实源、
  EARS 可测试句式——Amazon Kiro、GitHub Spec Kit。
  [Kiro Specs](https://kiro.dev/docs/specs/feature-specs/) ·
  [GitHub Spec-Driven Development](https://github.blog/ai-and-ml/generative-ai/spec-driven-development-with-ai-get-started-with-a-new-open-source-toolkit/)
- **DDD Bounded Context / Conway / Team Topologies**：模型与文档归 owner 团队，中央只画 context map，
  反对中央强控统一模型。 [Fowler: Bounded Context](https://www.martinfowler.com/bliki/BoundedContext.html)
- **分层文档 + docs-as-code**：C4（Context→Container→Component→Code 逐层放大）、ADR（决策留痕、与代码
  同仓同 PR）。 [c4model.com](https://c4model.com/) ·
  [Fowler: ADR](https://martinfowler.com/bliki/ArchitectureDecisionRecord.html)
- **中央代写下层文档=反模式**：导致 stale / bottleneck / ownership 缺失；正解是离实现最近的人写 + docs-as-code。
  [centralize documentation?](https://www.jenbergren.com/blog/centralize-documentation)
