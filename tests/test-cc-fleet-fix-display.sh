#!/usr/bin/env bash
# test-cc-fleet-fix-display.sh — cc-fleet-fix-display 显示修复脚本的端到端测试
#
# 回归「已完成 worker 在 FleetView 名字退化成 bg、时长退化成 0s」的修复：daemon 完成时把 state.json
# 重写成丢 name + 三时间戳塌缩的极简记录，本脚本据 cc-fleet-status 的名册 + transcript 把它修回。
#
# 隔离：临时 jobs-root（伪造 job 目录 + 伪造 transcript）+ --mock-status 注入状态 JSON，绕过 daemon。
# 纯本地、可重复、零网络。断言修复后 state.json 的 name / createdAt / firstTerminalAt / updatedAt。

set -u
SCRIPT="$(cd "$(dirname "$0")/../scripts" && pwd)/cc-fleet-fix-display"
[ -x "$SCRIPT" ] || { echo "❌ 找不到可执行脚本: $SCRIPT"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "❌ 需要 jq"; exit 1; }

PASS=0; FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
JOBS="$TMP/jobs"; mkdir -p "$JOBS"

RQ="RQ-2026-0622-099"
T_START="2026-06-22T14:00:00.000Z"
T_END="2026-06-22T15:00:00.000Z"
T_COLLAPSE="2026-06-22T15:00:00.123Z"   # 塌缩点（created==firstTerminal==updated）

check() {  # $1=用例名 $2=期望 $3=实际
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n    期望=[%s] 实际=[%s]\n' "$1" "$2" "$3"; fi
}
field() { jq -r "$2 // \"∅\"" "$JOBS/$1/state.json" 2>/dev/null; }

# 伪造 transcript：多行 JSON 对象，含首/末两个不同时间戳
mk_tx() {  # $1=路径 $2=首ts $3=末ts
  {
    printf '%s\n' '{"type":"summary","summary":"no timestamp here"}'
    printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"start"}}\n' "$2"
    printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":"mid"}}\n' "2026-06-22T14:30:00.000Z"
    printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":"end"}}\n' "$3"
  } > "$1"
}

mk_job() {  # $1=short $2=state.json 内容
  mkdir -p "$JOBS/$1"; printf '%s' "$2" > "$JOBS/$1/state.json"
}

# ---- A: 坏掉的 worker（无 name + 时间戳塌缩）→ 应被完整修复 ----
mk_tx "$TMP/tx-A.jsonl" "$T_START" "$T_END"
mk_job aaa11111 "$(jq -nc --arg tx "$TMP/tx-A.jsonl" --arg t "$T_COLLAPSE" \
  '{state:"done",template:"bg",tempo:"idle",detail:"A 完成",intent:"",sessionId:"sid-A",
    linkScanPath:$tx,createdAt:$t,updatedAt:$t,firstTerminalAt:$t}')"

# ---- B: 已正常的 worker（name 在 + 时间戳正常）→ 应原样不动（幂等）----
mk_job bbb22222 "$(jq -nc --arg s "$T_START" --arg e "$T_END" \
  '{state:"done",template:"bg",name:"↳moduleB@RQ-2026-0622-099",nameSource:"user",
    sessionId:"sid-B",createdAt:$s,updatedAt:$e,firstTerminalAt:$e}')"

# ---- D: 运行中的 worker（塌缩+无name）→ 绝不能碰（on-disk state=running）----
mk_job ddd44444 "$(jq -nc --arg t "$T_COLLAPSE" \
  '{state:"running",template:"bg",tempo:"active",sessionId:"sid-D",
    createdAt:$t,updatedAt:$t,firstTerminalAt:$t}')"

# ---- E: gone（status 里 short 为空，须靠 sessionId 全扫定位）→ 应被修复 ----
mk_tx "$TMP/tx-E.jsonl" "$T_START" "$T_END"
mk_job zzz99999 "$(jq -nc --arg tx "$TMP/tx-E.jsonl" --arg t "$T_COLLAPSE" \
  '{state:"done",template:"bg",sessionId:"sid-E",linkScanPath:$tx,
    createdAt:$t,updatedAt:$t,firstTerminalAt:$t}')"

# ---- F: 仅 name 缺失、时间戳本来正常 → 只补 name，不动时间戳 ----
mk_job fff66666 "$(jq -nc --arg s "$T_START" --arg e "$T_END" \
  '{state:"done",template:"bg",sessionId:"sid-F",createdAt:$s,updatedAt:$e,firstTerminalAt:$e}')"

# ---- mock 状态 JSON（模拟 cc-fleet-status <RQ> --json 的 jobs[]）----
MOCK="$TMP/status.json"
cat > "$MOCK" <<JSON
{"ok":1,"rq":"$RQ","rosterUsed":1,"jobs":[
  {"_module":"moduleA","name":"↳moduleA@$RQ","sessionId":"sid-A","short":"aaa11111","state":"done"},
  {"_module":"moduleB","name":"↳moduleB@$RQ","sessionId":"sid-B","short":"bbb22222","state":"done"},
  {"_module":"moduleD","name":"↳moduleD@$RQ","sessionId":"sid-D","short":"ddd44444","state":"running"},
  {"_module":"moduleE","name":"↳moduleE@$RQ","sessionId":"sid-E","short":"","state":"gone"},
  {"_module":"moduleF","name":"↳moduleF@$RQ","sessionId":"sid-F","short":"fff66666","state":"done"}
]}
JSON

echo "================= dry-run 不落盘 ================="
B_DRY="$(field bbb22222 .name)"; A_BEFORE="$(field aaa11111 .name)"
out="$("$SCRIPT" "$RQ" --jobs-root "$JOBS" --mock-status "$MOCK" --dry-run 2>&1)"
check "dry-run 报告含 moduleA" "yes" "$(echo "$out" | grep -q 'moduleA' && echo yes || echo no)"
check "dry-run 不改 A 的 name（仍 ∅）" "∅" "$(field aaa11111 .name)"
check "dry-run 不改 A 的 createdAt（仍塌缩）" "$T_COLLAPSE" "$(field aaa11111 .createdAt)"

echo "================= 实跑修复 ================="
out="$("$SCRIPT" "$RQ" --jobs-root "$JOBS" --mock-status "$MOCK" 2>&1)"

# A：name + 时间戳都修
check "A name → ↳moduleA@$RQ"          "↳moduleA@$RQ" "$(field aaa11111 .name)"
check "A nameSource → user"            "user"         "$(field aaa11111 .nameSource)"
check "A createdAt → transcript首ts"   "$T_START"     "$(field aaa11111 .createdAt)"
check "A firstTerminalAt → transcript末ts" "$T_END"   "$(field aaa11111 .firstTerminalAt)"
check "A updatedAt → transcript末ts"   "$T_END"       "$(field aaa11111 .updatedAt)"
check "A 其它字段保留（detail 不丢）"   "A 完成"        "$(field aaa11111 .detail)"

# B：原样不动
check "B name 不变"                    "↳moduleB@RQ-2026-0622-099" "$(field bbb22222 .name)"
check "B createdAt 不变"               "$T_START"     "$(field bbb22222 .createdAt)"

# D：运行中绝不碰
check "D（running）name 仍 ∅（未被碰）" "∅"            "$(field ddd44444 .name)"
check "D（running）createdAt 仍塌缩"    "$T_COLLAPSE"  "$(field ddd44444 .createdAt)"

# E：靠 sessionId 定位也能修
check "E（sid定位）name → ↳moduleE@$RQ" "↳moduleE@$RQ" "$(field zzz99999 .name)"
check "E createdAt → transcript首ts"    "$T_START"     "$(field zzz99999 .createdAt)"

# F：只补 name，不动本来正常的时间戳
check "F name → ↳moduleF@$RQ"          "↳moduleF@$RQ" "$(field fff66666 .name)"
check "F createdAt 不被改（仍 T_START）" "$T_START"    "$(field fff66666 .createdAt)"
check "F firstTerminalAt 不被改（仍 T_END）" "$T_END"  "$(field fff66666 .firstTerminalAt)"

echo "================= 幂等：再跑一次不应有任何改动 ================="
before="$(cat "$JOBS/aaa11111/state.json")"
sleep 1
mt_before="$(stat -f %m "$JOBS/aaa11111/state.json" 2>/dev/null || stat -c %Y "$JOBS/aaa11111/state.json" 2>/dev/null)"
out2="$("$SCRIPT" "$RQ" --jobs-root "$JOBS" --mock-status "$MOCK" 2>&1)"
mt_after="$(stat -f %m "$JOBS/aaa11111/state.json" 2>/dev/null || stat -c %Y "$JOBS/aaa11111/state.json" 2>/dev/null)"
check "幂等：A 内容不变" "$before" "$(cat "$JOBS/aaa11111/state.json")"
check "幂等：A 文件未被重写（mtime 不变）" "$mt_before" "$mt_after"
check "幂等：第二次报告无需修复" "yes" "$(echo "$out2" | grep -q '无需修复' && echo yes || echo no)"

echo
echo "==== cc-fleet-fix-display 测试：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] && { echo "✅ 全绿"; exit 0; } || { echo "❌ 有失败"; exit 1; }
