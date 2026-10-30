#!/usr/bin/env bash
# test-cc-fleet-trigger-hook.sh — 「多 session / 子 session」口语触发 hook 的回归测试
#
# 覆盖 2026-10-26 用户反馈的漏触发：长需求末尾「多 session 模式完成」、「让子 session 去 xxx」，
# 以及 worker 会话、显式 /multi-session-dev、无关消息、坏 JSON 不得注入。

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/scripts/cc-fleet-trigger-hook"
[ -x "$BIN" ] || { echo "❌ 找不到可执行 $BIN"; exit 1; }

PASS=0; FAIL=0
check() {  # $1=用例 $2=期望 $3=实际
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n    期望=[%s] 实际=[%s]\n' "$1" "$2" "$3"; fi
}

hinted() {  # $1=prompt → yes/no
  local out
  out="$(jq -n --arg p "$1" '{hook_event_name:"UserPromptSubmit",session_id:"t",prompt:$p}' | "$BIN")"
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("multi-session-dev")' >/dev/null 2>&1
  then echo yes; else echo no; fi
}

check '长需求末尾「多 session 模式完成」' yes "$(hinted '这个项目里实现一下方案，目标是选出 10 个品类，并且是公司供应链有能力去做的。  多 session 模式完成。')"
check '「让子 session 去 xxx」' yes "$(hinted '让子 session 去把导出接口改了')"
check '「子会话」' yes "$(hinted '派个子会话处理一下')"
check '「多session」无空格' yes "$(hinted '用多session做')"
check '「开 3 个 session」' yes "$(hinted '开 3 个 session 并行搞')"
check '「开两个会话」' yes "$(hinted '开两个会话分别做前后端')"
check '「并行 session」' yes "$(hinted '用并行 session 跑')"
check '英文 multi-session' yes "$(hinted 'do it in multi-session mode')"
check 'fleet 编排' yes "$(hinted '走 fleet 编排')"
check '无关消息不注入' no "$(hinted '修一下导出按钮的样式')"
check '仅提 subagent 不注入' no "$(hinted '用 subagent 查一下代码')"
check 'worker 首条任务卡不注入' no "$(hinted '⟦FLEET-WORKER⟧ 按任务卡开发，多 session 协作')"
check '显式 /multi-session-dev 不重复注入' no "$(hinted '/multi-session-dev 多 session 做这个')"

out="$(jq -n '{prompt:"多 session 做"}' | FLEET_ROLE=worker "$BIN")"
check 'FLEET_ROLE=worker 不注入' '' "$out"
out="$(printf 'not json' | "$BIN")"; rc=$?
check '坏 JSON 静默退出 0' '0|' "$rc|$out"

hint="$(jq -n '{prompt:"让子 session 去做"}' | "$BIN" | jq -r '.hookSpecificOutput.additionalContext')"
case "$hint" in *subagent*) r=yes;; *) r=no;; esac
check '提示里明确子 session ≠ subagent' yes "$r"
for kw in 'claude -p' 'codex exec' '调度器' '不设并发上限' '调研'; do
  case "$hint" in *"$kw"*) r=yes;; *) r=no;; esac
  check "提示包含「${kw}」约束" yes "$r"
done

# 文档契约：2026-10-26 market-research 复盘的四条约束必须留在 SKILL.md
SKILL="$ROOT/SKILL.md"
for kw in '先加载再动手' 'Codex 默认走 App 原生任务' '没有并发上限' '被测对象' '## 非代码任务'; do
  if command grep -qF -- "$kw" "$SKILL"; then r=yes; else r=no; fi
  check "SKILL.md 含「${kw}」" yes "$r"
done

ev="$(jq -n '{prompt:"多 session"}' | "$BIN" | jq -r '.hookSpecificOutput.hookEventName')"
check 'hookEventName=UserPromptSubmit' UserPromptSubmit "$ev"

echo
[ "$FAIL" -eq 0 ] && { echo "trigger-hook: $PASS 通过"; exit 0; }
echo "trigger-hook: $FAIL 失败 / $((PASS+FAIL))"; exit 1
