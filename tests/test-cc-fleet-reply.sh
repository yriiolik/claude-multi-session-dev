#!/usr/bin/env bash
# cc-fleet-reply 单测（确定性，无需 daemon）。
# 用 --mock-status 喂一份 cc-fleet-status --json 快照 + --dry-run 断言：
#   module→live short 解析、UTF-8 文本编码、gone/不存在/参数错误的退出码、--short 直给、stdin/文件文本源。
# 测试铁律：断言只增强不削弱；失败一律是脚本 bug，改脚本不改断言。
set -u

BIN="$(cd "$(dirname "$0")/.." && pwd)/scripts/cc-fleet-reply"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; CASE=""
ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ [$CASE] $1"; FAIL=$((FAIL+1)); }

MF="$TMP/status.json"
cat > "$MF" <<'JSON'
{"ok":1,"rq":"RQ-T","rosterUsed":1,"jobs":[
 {"_module":"stepA","short":"aaaa1111","state":"running","tempo":"active","sessionId":"aaaa1111-1111-4111-8111-111111111111","receipt":0},
 {"_module":"stepB","short":"bbbb2222","state":"working","tempo":"idle","sessionId":"bbbb2222-2222-4222-8222-222222222222","receipt":0},
 {"_module":"step0","short":"49ed8265","state":"gone","tempo":"-","sessionId":"49ed8265-e877-40f0-9879-0f9ccd7cfd20","receipt":1}
]}
JSON

# ① live 模块 → 解析出真 short + reply op JSON
CASE="live模块解析short"
OUT="$("$BIN" RQ-T stepA "继续按方案A改并自测" --mock-status "$MF" --dry-run 2>&1)"; RC=$?
{ [[ $RC -eq 0 ]] && grep -q '"short":"aaaa1111"' <<<"$OUT" && grep -q '"op":"reply"' <<<"$OUT"; } \
  && ok || fail "rc=$RC out=$OUT"

# ② UTF-8 中文文本原样进 JSON（不乱码、不转义成 \uXXXX）
CASE="中文文本UTF-8原样"
grep -qF '"text":"继续按方案A改并自测"' <<<"$OUT" && ok || fail "中文未原样: $OUT"

# ③ gone 模块 → 没有在跑会话可回复 → exit 2
CASE="gone模块exit2"
"$BIN" RQ-T step0 "x" --mock-status "$MF" --dry-run >/dev/null 2>&1
[[ $? -eq 2 ]] && ok || fail "期望 exit 2"

# ④ 不在名册的模块 → exit 2
CASE="不存在模块exit2"
"$BIN" RQ-T nope "x" --mock-status "$MF" --dry-run >/dev/null 2>&1
[[ $? -eq 2 ]] && ok || fail "期望 exit 2"

# ⑤ --short 直给：跳过解析，op JSON 用该 short
CASE="short直给跳过解析"
OUT5="$("$BIN" --short c0ffee99 "hi" --dry-run 2>&1)"; RC=$?
{ [[ $RC -eq 0 ]] && grep -q '"short":"c0ffee99"' <<<"$OUT5" && grep -q '"text":"hi"' <<<"$OUT5"; } \
  && ok || fail "rc=$RC out=$OUT5"

# ⑥ --short 格式非法（非 8hex）→ exit 5
CASE="short非法格式exit5"
"$BIN" --short XYZ "hi" --dry-run >/dev/null 2>&1
[[ $? -eq 5 ]] && ok || fail "期望 exit 5"

# ⑦ 缺 RQ/module 且无 --short → exit 5
CASE="缺RQ与module且无short exit5"
"$BIN" --dry-run >/dev/null 2>&1 </dev/null
[[ $? -eq 5 ]] && ok || fail "期望 exit 5"

# ⑧ 缺文本（有 RQ/module 但无 text/stdin）→ exit 5
CASE="缺文本exit5"
"$BIN" RQ-T stepA --mock-status "$MF" --dry-run >/dev/null 2>&1 </dev/null
[[ $? -eq 5 ]] && ok || fail "期望 exit 5"

# ⑨ 文本从 stdin 读
CASE="文本从stdin"
OUT9="$(printf '从标准输入来的话' | "$BIN" RQ-T stepA --mock-status "$MF" --dry-run 2>&1)"; RC=$?
{ [[ $RC -eq 0 ]] && grep -qF '"text":"从标准输入来的话"' <<<"$OUT9"; } && ok || fail "rc=$RC out=$OUT9"

# ⑩ 文本从 --text-file 读
CASE="文本从text-file"
printf '文件里的话' > "$TMP/msg.txt"
OUT10="$("$BIN" RQ-T stepB --text-file "$TMP/msg.txt" --mock-status "$MF" --dry-run 2>&1)"; RC=$?
{ [[ $RC -eq 0 ]] && grep -q '"short":"bbbb2222"' <<<"$OUT10" && grep -qF '"text":"文件里的话"' <<<"$OUT10"; } \
  && ok || fail "rc=$RC out=$OUT10"

echo
echo "==== cc-fleet-reply 测试：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] && echo "✅ 全绿" || { echo "❌ 有失败"; exit 1; }
