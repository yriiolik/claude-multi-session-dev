#!/usr/bin/env bash
# cc-fleet-kill 单测（确定性，无需 daemon）。
# 用 --mock-status 喂 cc-fleet-status --json 快照 + --dry-run 断言：
#   module→live short 解析、--signal、--all（跳过 gone）、gone/不存在/参数错误退出码、--short 直给。
# 测试铁律：断言只增强不削弱；失败一律是脚本 bug，改脚本不改断言。
set -u

BIN="$(cd "$(dirname "$0")/.." && pwd)/scripts/cc-fleet-kill"
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

ALLGONE="$TMP/allgone.json"
cat > "$ALLGONE" <<'JSON'
{"ok":1,"rq":"RQ-T","rosterUsed":1,"jobs":[
 {"_module":"m1","short":"11111111","state":"gone","tempo":"-","receipt":1},
 {"_module":"m2","short":"22222222","state":"done","tempo":"idle","receipt":1}
]}
JSON

# ① live 模块 → kill op JSON（默认 SIGTERM）
CASE="live模块解析+SIGTERM"
OUT="$("$BIN" RQ-T stepA --mock-status "$MF" --dry-run 2>&1)"; RC=$?
{ [[ $RC -eq 0 ]] && grep -q '"op":"kill"' <<<"$OUT" && grep -q '"short":"aaaa1111"' <<<"$OUT" && grep -q '"signal":"SIGTERM"' <<<"$OUT"; } \
  && ok || fail "rc=$RC out=$OUT"

# ② --signal SIGKILL
CASE="signal SIGKILL"
OUT2="$("$BIN" RQ-T stepA --signal SIGKILL --mock-status "$MF" --dry-run 2>&1)"
grep -q '"signal":"SIGKILL"' <<<"$OUT2" && ok || fail "out=$OUT2"

# ③ --all → 解析所有 live（stepA+stepB），跳过 gone（step0）→ 恰好 2 条 kill
CASE="all跳过gone只杀2个live"
OUT3="$("$BIN" RQ-T --all --mock-status "$MF" --dry-run 2>&1)"; RC=$?
N="$(grep -c '"op":"kill"' <<<"$OUT3")"
{ [[ $RC -eq 0 ]] && [[ "$N" -eq 2 ]] \
  && grep -q '"short":"aaaa1111"' <<<"$OUT3" && grep -q '"short":"bbbb2222"' <<<"$OUT3" \
  && ! grep -q '"short":"49ed8265"' <<<"$OUT3"; } \
  && ok || fail "rc=$RC n=$N out=$OUT3"

# ④ --all 但全部 gone/done → 无 live 目标 → exit 2
CASE="all无live目标exit2"
"$BIN" RQ-T --all --mock-status "$ALLGONE" --dry-run >/dev/null 2>&1
[[ $? -eq 2 ]] && ok || fail "期望 exit 2"

# ⑤ gone 模块 → exit 3（已结束，无需 kill）
CASE="gone模块exit3"
"$BIN" RQ-T step0 --mock-status "$MF" --dry-run >/dev/null 2>&1
[[ $? -eq 3 ]] && ok || fail "期望 exit 3"

# ⑥ 不在名册的模块 → exit 2
CASE="不存在模块exit2"
"$BIN" RQ-T nope --mock-status "$MF" --dry-run >/dev/null 2>&1
[[ $? -eq 2 ]] && ok || fail "期望 exit 2"

# ⑦ --short 直给：跳过解析
CASE="short直给跳过解析"
OUT7="$("$BIN" --short deadbe01 --dry-run 2>&1)"; RC=$?
{ [[ $RC -eq 0 ]] && grep -q '"short":"deadbe01"' <<<"$OUT7"; } && ok || fail "rc=$RC out=$OUT7"

# ⑧ 非法 --signal → exit 5
CASE="非法signal exit5"
"$BIN" RQ-T stepA --signal BOGUS --mock-status "$MF" --dry-run >/dev/null 2>&1
[[ $? -eq 5 ]] && ok || fail "期望 exit 5"

# ⑨ 缺 RQ 且无 --short → exit 5
CASE="缺RQ且无short exit5"
"$BIN" --dry-run >/dev/null 2>&1
[[ $? -eq 5 ]] && ok || fail "期望 exit 5"

# ⑩ 有 RQ 无 module 又没 --all → exit 5
CASE="有RQ无module无all exit5"
"$BIN" RQ-T --mock-status "$MF" --dry-run >/dev/null 2>&1
[[ $? -eq 5 ]] && ok || fail "期望 exit 5"

echo
echo "==== cc-fleet-kill 测试：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] && echo "✅ 全绿" || { echo "❌ 有失败"; exit 1; }
