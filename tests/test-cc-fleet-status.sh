#!/usr/bin/env bash
# cc-fleet-status 持久回执闩锁单测（确定性，无需 daemon）。
# 用 --mock-list 喂入 daemon list、--coord 指定临时协调目录（放 .sid 名册 + .summary.md 回执），
# 断言 receipt 检测 / 退出码中和（respawn-after-done → done）/ json receipt 字段 / result: 首行判定。
# 测试铁律：断言只增强不削弱；失败一律是脚本 bug，改脚本不改断言。
set -u

STATUS="$(cd "$(dirname "$0")/.." && pwd)/scripts/cc-fleet-status"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0

# new_coord —— 建一个干净【唯一】的临时协调目录，回显路径
# 注意：本函数在 $(...) 子 shell 里被调用，父 shell 的变量自增不回传，故必须用 mktemp 保证唯一，
#       不能用自增计数器（否则多次调用会落到同一目录、.sid 互相串台）。
new_coord() { mktemp -d "$TMP/coord.XXXXXX"; }
# put_sid <coorddir> <module> <token>
put_sid() { printf '%s\n' "$3" > "$1/$2.sid"; }
# put_receipt <coorddir> <module> <首行内容...>  —— 写一份回执文件，首行即给定内容
put_receipt() { local d="$1" m="$2"; shift 2; printf '%s\n# 会话回执: %s\n- 范围: x\n' "$*" "$m" > "$d/$m.summary.md"; }
# put_receipt_raw <coorddir> <module> <完整内容(可含前导空行)>
put_receipt_raw() { printf '%b' "$3" > "$1/$2.summary.md"; }

# run_status <coorddir> <mockjobs-json> <期望退出码> <额外参数...> —— 表格模式，输出写 $OUT
run_status() {
  local coord="$1" mock="$2" want_rc="$3"; shift 3
  local mf; mf="$(mktemp "$TMP/mock.XXXXXX")"
  printf '%s' "$mock" > "$mf"
  OUT="$("$STATUS" RQ-TEST-STATUS --coord "$coord" --mock-list "$mf" "$@" 2>&1)"
  RC=$?
  if [ "$RC" -ne "$want_rc" ]; then
    echo "✗ [$CASE] 退出码 期望=$want_rc 实际=$RC"; echo "--- 输出 ---"; echo "$OUT"; echo "------------"
    FAIL=$((FAIL+1)); return 1
  fi
  return 0
}

assert_has() { if printf '%s' "$OUT" | grep -qF -- "$1"; then PASS=$((PASS+1)); else echo "✗ [$CASE] 缺少: $1"; echo "$OUT"; FAIL=$((FAIL+1)); fi; }
assert_no()  { if printf '%s' "$OUT" | grep -qF -- "$1"; then echo "✗ [$CASE] 不该出现: $1"; echo "$OUT"; FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi; }

# ① 事故重演：ic-viewer 做完被 respawn → daemon 报 running+active，但协调目录有 result: 回执
#    → receipt=1、退出码中和为 0（可进收回执），表格标 🧾已完成
CASE="respawn做完_回执判完成"
C="$(new_coord)"; put_sid "$C" ic-viewer aaaa1111; put_receipt "$C" ic-viewer "result: ic-viewer 完成 — 已合回 main 并 push、worktree 已清理"
run_status "$C" '{"jobs":[{"short":"aaaa1111","sessionId":"aaaa1111-0000-0000-0000-000000000000","state":"running","tempo":"active"}]}' 0
assert_has "🧾已完成"
assert_has "可进入收回执"
assert_has "做完后被 respawn"

# ② 同上 --json：receipt=1
CASE="respawn做完_json带receipt"
run_status "$C" '{"jobs":[{"short":"aaaa1111","sessionId":"aaaa1111-0000-0000-0000-000000000000","state":"running","tempo":"active"}]}' 0 --json
assert_has '"receipt":1'
assert_has '"_module":"ic-viewer"'

# ③ 混合：ic-viewer 有回执(done)、verify 无回执仍 running → 整体仍 exit 1（verify 在跑），各自 receipt 对
CASE="混合_有回执done与无回执running"
C2="$(new_coord)"; put_sid "$C2" ic-viewer aaaa1111; put_receipt "$C2" ic-viewer "result: ic-viewer 完成"
put_sid "$C2" verify bbbb2222   # verify 无 .summary.md
run_status "$C2" '{"jobs":[{"short":"aaaa1111","state":"running","tempo":"active"},{"short":"bbbb2222","state":"running","tempo":"active"}]}' 1
assert_has "进行中"
run_status "$C2" '{"jobs":[{"short":"aaaa1111","state":"running","tempo":"active"},{"short":"bbbb2222","state":"running","tempo":"active"}]}' 1 --json
assert_has '"_module":"ic-viewer"'

# ④ failed: 首行不算完成回执：协调目录文件首行是 failed: → receipt=0，daemon running → 仍 exit 1
CASE="failed首行不算完成"
C3="$(new_coord)"; put_sid "$C3" m1 cccc3333; put_receipt "$C3" m1 "failed: m1 结构性失败，无法完成"
run_status "$C3" '{"jobs":[{"short":"cccc3333","state":"running","tempo":"active"}]}' 1 --json
assert_has '"receipt":0'
assert_no '"receipt":1'

# ⑤ needs input: 首行不算完成（blocked 半截回执）→ receipt=0
CASE="needsinput首行不算完成"
C4="$(new_coord)"; put_sid "$C4" m1 dddd4444; put_receipt "$C4" m1 "needs input: 等 DBA 签字"
run_status "$C4" '{"jobs":[{"short":"dddd4444","state":"running","tempo":"active"}]}' 1 --json
assert_has '"receipt":0'

# ⑥ 前导空行 + result: 仍判完成（容忍空行/BOM）
CASE="前导空行后result仍判完成"
C5="$(new_coord)"; put_sid "$C5" m1 eeee5555; put_receipt_raw "$C5" m1 "\n\n   result: m1 完成\n# 会话回执\n"
run_status "$C5" '{"jobs":[{"short":"eeee5555","state":"running","tempo":"active"}]}' 0 --json
assert_has '"receipt":1'

# ⑦ gone + 回执：daemon 列表已无该 session（roster 判 gone），仍有回执 → done，exit 0
CASE="gone带回执仍done"
C6="$(new_coord)"; put_sid "$C6" m1 ffff6666; put_receipt "$C6" m1 "result: m1 完成"
run_status "$C6" '{"jobs":[]}' 0
assert_has "可进入收回执"

# ⑧ 无回执、daemon done：照常 done（不依赖回执）→ exit 0，receipt=0
CASE="无回执daemon_done照常完成"
C7="$(new_coord)"; put_sid "$C7" m1 a211aaaa
run_status "$C7" '{"jobs":[{"short":"a211aaaa","state":"done","tempo":"idle"}]}' 0 --json
assert_has '"receipt":0'

# ⑨ tempo=blocked(state仍working)=等输入：exit 1（进行中非异常），提示去 cc-fleet-reply/kill，行标 ⏸
CASE="tempo=blocked等输入提示reply"
C8="$(new_coord)"; put_sid "$C8" m1 b1ddddaa
run_status "$C8" '{"jobs":[{"short":"b1ddddaa","state":"working","tempo":"blocked"}]}' 1
assert_has "等输入"
assert_has "cc-fleet-reply RQ-TEST-STATUS"
assert_has "⏸等输入"

# ⑩ state=blocked 字面态：归"进行中"非异常 → exit 1（守住 summary_exit 不把 blocked 误判成 exit 3）
CASE="state=blocked归进行中非异常"
C9="$(new_coord)"; put_sid "$C9" m1 b2ddddbb
run_status "$C9" '{"jobs":[{"short":"b2ddddbb","state":"blocked","tempo":"-"}]}' 1
assert_has "等输入"

echo
echo "==== cc-fleet-status 测试：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] && echo "✅ 全绿" || { echo "❌ 有失败"; exit 1; }
