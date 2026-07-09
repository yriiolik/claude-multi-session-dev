#!/usr/bin/env bash
# cc-fleet-watch 自带单元测试（确定性，无需 daemon）。
# 用 --mock-json 喂入一串状态快照，断言 watch 的逐模块事件 / 心跳 / 最终总结 / 退出码。
# 测试铁律：断言只增强不削弱；失败一律是脚本 bug，改脚本不改断言。
set -u

WATCH="$(cd "$(dirname "$0")/.." && pwd)/scripts/cc-fleet-watch"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
n=0

# run_case <名称> <mock内容> <期望退出码> <额外 watch 参数...> —— 输出写 $OUT，供后续断言
run_case() {
  local name="$1" mock="$2" want_rc="$3"; shift 3
  n=$((n+1))
  local mf="$TMP/mock.$n.json"
  printf '%s' "$mock" > "$mf"
  OUT="$("$WATCH" RQ-TEST --mock-json "$mf" --interval 0 "$@" 2>&1)"
  RC=$?
  CASE="$name"
  if [ "$RC" -ne "$want_rc" ]; then
    echo "✗ [$name] 退出码 期望=$want_rc 实际=$RC"; echo "--- 输出 ---"; echo "$OUT"; echo "------------"
    FAIL=$((FAIL+1)); return 1
  fi
  return 0
}

# assert_has <子串>  /  assert_no <子串>  /  assert_count <子串> <n>
assert_has() { if printf '%s' "$OUT" | grep -qF -- "$1"; then PASS=$((PASS+1)); else echo "✗ [$CASE] 缺少: $1"; echo "$OUT"; FAIL=$((FAIL+1)); fi; }
assert_no()  { if printf '%s' "$OUT" | grep -qF -- "$1"; then echo "✗ [$CASE] 不该出现: $1"; echo "$OUT"; FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi; }
assert_count() { local c; c=$(printf '%s\n' "$OUT" | grep -cF -- "$1"); if [ "$c" -eq "$2" ]; then PASS=$((PASS+1)); else echo "✗ [$CASE] '$1' 期望 $2 次 实际 $c"; echo "$OUT"; FAIL=$((FAIL+1)); fi; }

# ① 全部完成（happy path）：m1 先 done，再 m1+m2 都 done → exit 0
run_case "全部完成" '{"jobs":[{"_module":"m1","state":"running"},{"_module":"m2","state":"running"}]}
@@@
{"jobs":[{"_module":"m1","state":"done"},{"_module":"m2","state":"working"}]}
@@@
{"jobs":[{"_module":"m1","state":"done"},{"_module":"m2","state":"done"}]}' 0
assert_has "✅ m1 done"
assert_has "✅ m2 done"
assert_has "🎉 RQ-TEST 全部结束：2/2（异常 0）"
assert_count "✅ m1 done — 已结束" 1   # 同一模块结束只报一次，不重复刷

# ② 瞬时失败自愈：m1 failed 一轮（未达 fail-checks=2）后 done → 不该有 ❌
run_case "瞬时失败自愈" '{"jobs":[{"_module":"m1","state":"failed"}]}
@@@
{"jobs":[{"_module":"m1","state":"done"}]}' 0 --fail-checks 2
assert_no "❌"
assert_has "✅ m1 done"
assert_has "🎉 RQ-TEST 全部结束：1/1（异常 0）"

# ③ 持续失败：m1 连续 2 轮 failed（达阈值）→ ❌ + exit 3；m2 始终 done
run_case "持续失败" '{"jobs":[{"_module":"m1","state":"failed"},{"_module":"m2","state":"done"}]}
@@@
{"jobs":[{"_module":"m1","state":"failed","detail":"boom 持续报错"},{"_module":"m2","state":"done"}]}' 3 --fail-checks 2
assert_has "❌ m1 failed"
assert_has "boom 持续报错"
assert_has "⚠ RQ-TEST 全部结束：2/2（异常 1）"

# ④ 心跳兜底：两轮都 running，heartbeat=0（每轮无事件即心跳）→ 至少 1 条 ⏳；未完成 exit 1
run_case "心跳兜底" '{"jobs":[{"_module":"m1","state":"running"},{"_module":"m2","state":"running"}]}
@@@
{"jobs":[{"_module":"m1","state":"running"},{"_module":"m2","state":"running"}]}' 1 --heartbeat 0 --max-loops 2
assert_has "⏳ RQ-TEST 进度 0/2"
assert_has "监视结束（未全部完成）"

# ⑤ blocked 主动提醒 + 恢复：m1 blocked → running → 报 ⏸ 再报 ▶；未完成 exit 1
run_case "blocked提醒与恢复" '{"jobs":[{"_module":"m1","state":"blocked","detail":"等权限"}]}
@@@
{"jobs":[{"_module":"m1","state":"running"}]}' 1 --max-loops 2
assert_has "⏸ m1 blocked"
assert_has "等权限"
assert_has "▶ m1 已恢复运行"

# ⑥ gone 视作已结束：m1 gone → ✅ + exit 0
run_case "gone视作完成" '{"jobs":[{"_module":"m1","state":"gone"}]}' 0
assert_has "✅ m1 gone — 已结束"
assert_has "🎉 RQ-TEST 全部结束：1/1"

# ⑦ wait 模式静默：仅末尾一行总结，无逐模块 ✅；exit 0
run_case "wait模式静默" '{"jobs":[{"_module":"m1","state":"running"}]}
@@@
{"jobs":[{"_module":"m1","state":"done"}]}' 0 --wait
assert_no "✅ m1"
assert_has "🎉 RQ-TEST 全部结束：1/1"
assert_count "全部结束" 1

# ⑧ 空名册不秒退：jobs=[] → 不报"全部结束"，报"尚未发现"，未完成 exit 1
run_case "空名册不秒退" '{"jobs":[]}
@@@
{"jobs":[]}' 1 --heartbeat 0 --max-loops 2
assert_no "全部结束"
assert_has "尚未发现 RQ-TEST 的 session"

# ── tempo 静默判定（本次根治"做完却留在 working、主 session 死等"的核心）──
# 关键模型：state=working 但 tempo=idle = agent 循环已停（做完没打 result:，或卡住）。--stall-idle 0
# 让"连续 2 轮 idle 即判静默"，便于确定性测试去抖（单次 idle 不判、需 ≥2 连续轮）。

# ⑨ 单次 idle 不秒判静默：一轮 working+idle（idle_polls=1<2）→ 不该有 💤，未完成 exit 1
run_case "单次idle不判静默" '{"jobs":[{"_module":"m1","state":"working","tempo":"idle"}]}' 1 --stall-idle 0 --once
assert_no "💤"
assert_has "监视结束（未全部完成）"

# ⑩ 持续 idle → 静默已结束：连续 2 轮 working+idle → 💤 + 🟡 总结(含核验提示) + exit 0
run_case "持续idle判静默" '{"jobs":[{"_module":"m1","state":"working","tempo":"idle"}]}
@@@
{"jobs":[{"_module":"m1","state":"working","tempo":"idle"}]}' 0 --stall-idle 0
assert_has "💤 m1 working+idle"
assert_has "🟡 RQ-TEST 全部结束：1/1（异常 0，含静默未打result 1 个需核验）"

# ⑪ idle 瞬时→恢复 active 不判静默：working+idle 后变 active（去抖未达即被重置）→ 无 💤、无复活、未完成 exit 1
run_case "idle瞬时恢复不判静默" '{"jobs":[{"_module":"m1","state":"working","tempo":"idle"}]}
@@@
{"jobs":[{"_module":"m1","state":"working","tempo":"active"}]}' 1 --stall-idle 0 --max-loops 2
assert_no "💤"
assert_no "▶ m1 又活跃了"
assert_has "监视结束（未全部完成）"

# ⑫ 静默后又活跃 → 撤销静默(resurrect)：m1 idle,idle(判静默💤),active(撤销▶)；m2 始终 running 不让
#    watch 因"全部结束"提前退出 → 撤销后整体仍未结束，exit 1。
#    （注：若 m1 是唯一模块，它一旦静默就凑齐"全部结束"而退出，watch 无从对唯一模块复活——
#     那是预期：主 session 去核验时若发现它又活跃，重挂 watch 即可，编排层自愈。）
run_case "静默后复活撤销" '{"jobs":[{"_module":"m1","state":"working","tempo":"idle"},{"_module":"m2","state":"running","tempo":"active"}]}
@@@
{"jobs":[{"_module":"m1","state":"working","tempo":"idle"},{"_module":"m2","state":"running","tempo":"active"}]}
@@@
{"jobs":[{"_module":"m1","state":"working","tempo":"active"},{"_module":"m2","state":"running","tempo":"active"}]}' 1 --stall-idle 0 --max-loops 3
assert_has "💤 m1 working+idle"
assert_has "▶ m1 又活跃了"
assert_has "监视结束（未全部完成）"

# ⑬ done + 静默 混合总结：m1 硬 done、m2 持续 idle 静默 → ✅+💤，🟡 总结 2/2 含核验，exit 0
run_case "done与静默混合" '{"jobs":[{"_module":"m1","state":"done"},{"_module":"m2","state":"working","tempo":"idle"}]}
@@@
{"jobs":[{"_module":"m1","state":"done"},{"_module":"m2","state":"working","tempo":"idle"}]}' 0 --stall-idle 0
assert_has "✅ m1 done"
assert_has "💤 m2 working+idle"
assert_has "🟡 RQ-TEST 全部结束：2/2（异常 0，含静默未打result 1 个需核验）"

# ⑭ tempo=active 的 working 绝不误判静默：连续 active → 无 💤，仍在跑，exit 1（守住"不误杀真在跑"）
#    --heartbeat 0 让每轮打进度行，验证 active 被归到"运行"而非"空闲待判"。
run_case "active不误判静默" '{"jobs":[{"_module":"m1","state":"working","tempo":"active"}]}
@@@
{"jobs":[{"_module":"m1","state":"working","tempo":"active"}]}' 1 --stall-idle 0 --heartbeat 0 --max-loops 2
assert_no "💤"
assert_has "运行 1 / 空闲待判 0"
assert_has "监视结束（未全部完成）"

# ⑮ 心跳进度按 tempo 区分"运行/空闲待判"：m1 active、m2 idle（未达静默阈值）→ 运行1/空闲待判1
run_case "心跳区分运行与空闲待判" '{"jobs":[{"_module":"m1","state":"working","tempo":"active"},{"_module":"m2","state":"working","tempo":"idle"}]}
@@@
{"jobs":[{"_module":"m1","state":"working","tempo":"active"},{"_module":"m2","state":"working","tempo":"idle"}]}' 1 --stall-idle 999 --heartbeat 0 --max-loops 2
assert_has "运行 1 / 空闲待判 1"
assert_no "💤"

# ── tempo=blocked 等输入（2.1.167：等回复/授权时 state 仍 working，靠 tempo=blocked 表达）──
# 必须归入 blocked 路径主动提醒去 cc-fleet-reply/kill，绝不当 active 在跑而死等，也绝不判静默。

# ⑮.1 tempo=blocked(state=working) → ⏸ 提醒带 cc-fleet-reply；变 active 后 ▶ 恢复；未完成 exit 1
run_case "tempo=blocked等输入提醒并恢复" '{"jobs":[{"_module":"m1","state":"working","tempo":"blocked","detail":"awaiting instruction"}]}
@@@
{"jobs":[{"_module":"m1","state":"working","tempo":"active"}]}' 1 --stall-idle 0 --max-loops 2
assert_has "⏸ m1 blocked"
assert_has "cc-fleet-reply RQ-TEST m1"
assert_has "▶ m1 已恢复运行"
assert_no "💤"

# ⑮.2 持续 tempo=blocked 即便 --stall-idle 0 也绝不判静默/结束，且只提醒一次 → exit 1
run_case "tempo=blocked持续不判静默不结束" '{"jobs":[{"_module":"m1","state":"working","tempo":"blocked"}]}
@@@
{"jobs":[{"_module":"m1","state":"working","tempo":"blocked"}]}' 1 --stall-idle 0 --max-loops 2
assert_no "💤"
assert_count "⏸ m1 blocked" 1

# ── 持久回执闩锁（抗 respawn）：cc-fleet-status 标 receipt=1 = 协调目录已有 result: 回执 = 已完成 ──
# 这是本次根治"worker 做完被 daemon respawn 回 running+active、watch 只发心跳不发完成、主 session 死等"的核心。

# ⑯ 事故重演：worker 做完被 respawn → running+active 但 receipt=1 → 立即 ✅ 已完成 + 🎉，exit 0（不再死等）
run_case "回执闩锁_respawn做完判完成" '{"jobs":[{"_module":"ic-viewer","state":"running","tempo":"active","receipt":1}]}' 0
assert_has "✅ ic-viewer 已完成 — 回执在案"
assert_has "daemon 报 running 多为 respawn"
assert_has "🎉 RQ-TEST 全部结束：1/1（异常 0）"
assert_no "💤"

# ⑰ 回执优先于异常态：daemon 报 failed 但 receipt=1（respawn 时瞬时报错）→ 判完成、不报 ❌，exit 0
run_case "回执闩锁_优先于failed" '{"jobs":[{"_module":"m1","state":"failed","tempo":"-","receipt":1}]}
@@@
{"jobs":[{"_module":"m1","state":"failed","tempo":"-","receipt":1}]}' 0 --fail-checks 2
assert_has "✅ m1 已完成 — 回执在案"
assert_no "❌"
assert_has "🎉 RQ-TEST 全部结束：1/1（异常 0）"

# ⑱ 无回执的 running 不被误判完成：verify 无 receipt 始终 running → 仍在跑，未完成 exit 1
#    （守住"没回执的真在跑 session 不能因别人有回执就被判完成"）
run_case "无回执running不误判完成" '{"jobs":[{"_module":"ic-viewer","state":"running","tempo":"active","receipt":1},{"_module":"verify","state":"running","tempo":"active"}]}
@@@
{"jobs":[{"_module":"ic-viewer","state":"running","tempo":"active","receipt":1},{"_module":"verify","state":"running","tempo":"active"}]}' 1 --heartbeat 0 --max-loops 2
assert_has "✅ ic-viewer 已完成 — 回执在案"
assert_no "✅ verify"
assert_has "运行 1"          # 心跳进度里只算 verify 在跑，ic-viewer(receipt) 不计
assert_has "监视结束（未全部完成）"

# ⑲ 回执完成单调、不被后续 respawn 反悔：m1 第1轮 receipt 判完成；第2轮 daemon 又报 running+active(receipt 仍在)
#    → 不重复刷 ✅、不撤销，全程算完成；m2 始终 done → 🎉 2/2 exit 0
run_case "回执完成单调不反悔" '{"jobs":[{"_module":"m1","state":"running","tempo":"active","receipt":1},{"_module":"m2","state":"working","tempo":"active"}]}
@@@
{"jobs":[{"_module":"m1","state":"running","tempo":"active","receipt":1},{"_module":"m2","state":"done"}]}' 0
assert_count "✅ m1 已完成 — 回执在案" 1
assert_has "✅ m2 done"
assert_no "▶ m1 又活跃了"
assert_has "🎉 RQ-TEST 全部结束：2/2（异常 0）"

echo
echo "==== cc-fleet-watch 测试：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] && echo "✅ 全绿" || { echo "❌ 有失败"; exit 1; }
