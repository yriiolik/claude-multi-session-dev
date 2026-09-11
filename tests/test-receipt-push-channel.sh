#!/usr/bin/env bash
# 回执通道 ⓪（worker 主动 SendMessage 推给主 session）的**文档契约测试**。
#
# 为什么要有这个测试：通道 ⓪ 全部由 prompt 文本承载（preamble 教 worker 怎么推、SKILL.md 教主 session
# 怎么填名字/怎么处置），没有可执行代码可测。而其中几条是**安全护栏**，被后续编辑顺手删掉不会有任何
# 报错，却会造成真实伤害：
#   · 删掉「禁止猜名字」→ worker 发不到主 session 时会去 ListAgents 找个名字相近的发过去，
#     把回执灌进用户另一个毫不相干的工作 session；
#   · 删掉「禁止发给其它 worker」→ worker 之间私下串联，绕过主 session 的模块边界编排；
#   · 删掉「推送失败就降级」→ 新通道从"加速器"退化成新的单点故障，worker 卡在重试上；
#   · 删掉「watch 照挂不误」→ 主 session 误以为有推送就不用 watch，worker 一崩溃就永远等不到。
# 所以这里逐条钉死。旧协议断言只覆盖保留的 v1 prompt；v2 使用独立行为测试。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRE="$ROOT/reference/dispatch-preamble.md"
CODEX_PRE="$ROOT/reference/codex-app-dispatch-preamble.md"
CODEX_MODE="$ROOT/reference/codex-mode.md"
PROTO="$ROOT/reference/PROTOCOL.md"

PASS=0; FAIL=0; CASE=""
ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ [$CASE] $1"; FAIL=$((FAIL+1)); }
# has <file> <描述> <正则...>  —— 全部正则都命中才算过
has(){ local f="$1" d="$2"; shift 2; local p
  for p in "$@"; do grep -qE -- "$p" "$f" || { fail "${d}：缺 /$p/ @ $(basename "$f")"; return; }; done; ok; }
hasnt(){ local f="$1" d="$2" p="$3"
  grep -qE -- "$p" "$f" && fail "${d}：不该出现 /$p/ @ $(basename "$f")" || ok; }

for f in "$PRE" "$CODEX_PRE" "$CODEX_MODE" "$PROTO"; do
  [[ -r "$f" ]] || { echo "✗ 读不到 $f"; exit 2; }
done

# ── A. Claude 后端 preamble：worker 侧的推送契约 ──────────────────────────────
CASE="preamble/三通道成立"
has "$PRE" "回执声明为三通道" '三通道'

CASE="preamble/占位符"
has "$PRE" "有 MAIN_SESSION 占位符" '\{\{MAIN_SESSION\}\}'

CASE="preamble/推送指令"
has "$PRE" "教 worker 用 SendMessage 推给主 session" \
  'SendMessage' 'to *= *"\{\{MAIN_SESSION\}\}"'

CASE="preamble/第一行自解释"
has "$PRE" "要求第一行带 [FLEET] 前缀且自解释" '\[FLEET\]' '第一行必须自解释'

CASE="preamble/卡住也要推"
has "$PRE" "需要裁决/失败同样要推" '需要裁决' '失败'

# ↓↓↓ 安全护栏三条：删掉不会报错，但会造成真实伤害 ↓↓↓
CASE="preamble/护栏-推送失败降级"
has "$PRE" "推送失败必须放弃并继续走第 3 步" \
  'No agent named' '不要重试' '直接做第 3 步|放弃'

CASE="preamble/护栏-禁止猜名字"
has "$PRE" "禁止用 ListAgents 猜相近名字发过去" '不要用 ListAgents 去猜|不要.*猜'

CASE="preamble/护栏-禁止联络其它 worker"
has "$PRE" "禁止 SendMessage 给其它模块 session" '绝不 SendMessage 给其它模块|不是让你去联络别的 worker'

# 新通道绝不能把两条老通道挤掉
CASE="preamble/老通道-落盘仍在"
has "$PRE" "落盘回执仍是必做项" '\{\{COORD_DIR\}\}/\{\{MODULE\}\}\.summary\.md'

CASE="preamble/老通道-最后一条消息仍在"
has "$PRE" "最后一条消息仍必须以 result: 开头" '最后一条消息' 'result:' 'needs input:' 'failed:'

# ── B. Codex 后端：通道 ⓪ 不适用，且不能教 codex worker 去用 SendMessage ────────
CASE="codex/标注通道⓪不适用"
has "$CODEX_PRE" "codex preamble 明确说通道 ⓪ 不适用" '不适用' '两条通道|只有两条通道'

CASE="codex/不误教 SendMessage"
hasnt "$CODEX_PRE" "codex worker 不该被要求调 SendMessage" 'to *= *"\{\{MAIN_SESSION\}\}"'

CASE="codex/两条老通道仍在"
has "$CODEX_PRE" "落盘 + 最后一条消息仍在" 'summary\.md' 'result:'

CASE="codex/差异清单登记"
has "$CODEX_MODE" "行为差异里登记了没有通道 ⓪" '通道 ⓪' 'SendMessage'

# v2 不使用按显示名寻址/原生 Monitor 假设；主端契约改由 test_fleet_v2.py 的真实 ID、
# pending 登记、新 attempt 和持久回执行为测试覆盖。旧 worker/preamble 协议继续回归。

# ── D. PROTOCOL.md §12：实测依据必须留档 ─────────────────────────────────────
CASE="proto/§12 存在"
has "$PROTO" "有跨 session 消息通道章节" '^## 12\.'

CASE="proto/寻址结论"
has "$PROTO" "记录了名字即地址、裸 ref 不可用" '名字即地址|名字必须精确匹配' '裸 ref'

CASE="proto/唤醒前提"
has "$PROTO" "记录了消息会唤醒空闲主 session 这一前提" '唤醒'

CASE="proto/实测版本留档"
has "$PROTO" "记录了实测版本号" '2\.1\.252'

CASE="proto/notify_when_idle 取舍留档"
has "$PROTO" "记录了为何不采纳 notify_when_idle" 'notify_when_idle' 'one-shot|瞬时'

# 「送达可能严重滞后」是四条理由里最致命的一条，且是事后才撞出来的实测——
# 它正是「watch 的延迟有确定上界」这个取舍依据的反面，删掉就没人知道当初为什么不用它了。
CASE="proto/notify_when_idle 滞后实证"
has "$PROTO" "记录了送达严重滞后这条最致命的理由" '滞后' '18:11' '上界'

echo "==== 回执通道 ⓪ 文档契约：PASS=$PASS FAIL=$FAIL ===="
[[ $FAIL -eq 0 ]] || exit 1
