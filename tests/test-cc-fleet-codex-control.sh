#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
READ="$ROOT/scripts/cc-fleet-read-codex-app"
KILL="$ROOT/scripts/cc-fleet-kill-codex-app"
REPLY="$ROOT/scripts/cc-fleet-reply-codex-app"
STATUS="$ROOT/scripts/cc-fleet-status-codex-app"
WATCH="$ROOT/scripts/cc-fleet-watch-codex-app"

PASS=0; FAIL=0
DIRS=()
trap 'for d in "${DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done' EXIT
ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ [$CASE] $1"; FAIL=$((FAIL+1)); }
assert_has(){ if printf '%s' "$OUT" | grep -qF -- "$1"; then ok; else fail "缺少: $1"; echo "$OUT"; fi; }

T="$(mktemp -d)"; DIRS+=("$T")
COORD="$T/fleet/RQ-test"; mkdir -p "$COORD"
cat > "$COORD/mod.codex-app.env" <<EOF
id=thread-test
thread_id=thread-test
rq=RQ-test
module=mod
mode=codex-app
summary_file=$COORD/mod.summary.md
terminated=0
deepseek_session=1
service_tier=inherit
reasoning_effort=high
EOF

FAKE="$T/fake-app-call.js"
LOG="$T/calls.jsonl"
cat > "$FAKE" <<'NODE'
#!/usr/bin/env node
const fs = require("fs");
const args = process.argv.slice(2);
let method = "", paramsPath = "";
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--codex-bin") { i++; continue; }
  if (args[i] === "--start-app-server") continue;
  if (!method) method = args[i]; else if (!paramsPath) paramsPath = args[i];
}
const params = paramsPath ? JSON.parse(fs.readFileSync(paramsPath, "utf8")) : {};
fs.appendFileSync(process.env.FAKE_LOG, `${JSON.stringify({method, params})}\n`);
if (method === "thread/read") {
  // idle=被打断后空闲；done=turn 正常跑完后空闲（worker 可能在等追加指令）；其余=在跑
  const state = process.env.FAKE_STATE || "";
  const status = (state === "idle" || state === "done") ? "idle" : "active";
  const turnStatus = state === "idle" ? "interrupted" : state === "done" ? "completed" : "inProgress";
  console.log(JSON.stringify({thread:{id:"thread-test",status:{type:status,activeFlags:[]},turns:[
    {id:"turn-old",status:"completed",items:[{id:"msg-old",type:"agentMessage",text:"旧结果"}]},
    {id:"turn-live",status:turnStatus,items:[
      {id:"cmd-1",type:"commandExecution",command:"npm test",status:"completed",exitCode:0,aggregatedOutput:"tests ok"},
      {id:"msg-new",type:"agentMessage",text:"最新进度：测试已经通过"}
    ]}
  ]}}));
} else if (method === "turn/start" || method === "turn/steer") {
  console.log(JSON.stringify({turn:{id:"turn-next"}}));
} else console.log("{}");
NODE
chmod +x "$FAKE"

CASE="read_human_latest"
OUT="$(CODEX_APP_CALL_BIN="$FAKE" FAKE_LOG="$LOG" "$READ" RQ-test mod --coord "$COORD" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok || fail "read 应退出 0，实得 $RC"
assert_has "[completed] npm test"
assert_has "tests ok"
assert_has "最新进度：测试已经通过"

CASE="read_json_normalized"
OUT="$(CODEX_APP_CALL_BIN="$FAKE" FAKE_LOG="$LOG" "$ROOT/scripts/cc-fleet-read-codex" RQ-test mod --coord "$COORD" --json 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok || fail "read alias 应退出 0，实得 $RC"
node -e 'const x=JSON.parse(process.argv[1]); if(x.latestTurn.status!=="inProgress"||x.latestAgentMessage.text!=="最新进度：测试已经通过")process.exit(1)' "$OUT"
[ "$?" -eq 0 ] && ok || fail "read JSON 内容不对: $OUT"

CASE="kill_interrupt_and_mark"
: > "$LOG"
OUT="$(CODEX_APP_CALL_BIN="$FAKE" FAKE_LOG="$LOG" "$ROOT/scripts/cc-fleet-kill-codex" RQ-test mod --coord "$COORD" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok || fail "kill 应退出 0，实得 $RC"
assert_has "已结束 mod"
grep -q '^terminated=1$' "$COORD/mod.codex-app.env" && ok || fail "未记录 terminated=1"
METHODS="$(node - "$LOG" <<'NODE'
const fs=require("fs"); const rows=fs.readFileSync(process.argv[2],"utf8").trim().split(/\n/).map(JSON.parse); process.stdout.write(rows.map(x=>x.method).join(" "));
NODE
)"
[ "$METHODS" = "thread/read turn/interrupt" ] && ok || fail "kill 调用顺序不对: $METHODS"

CASE="status_and_watch_report_stopped"
OUT="$(CODEX_APP_CALL_BIN="$FAKE" FAKE_LOG="$LOG" FAKE_STATE=idle "$STATUS" RQ-test --coord "$COORD" 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && ok || fail "stopped status 应退出 3，实得 $RC"
assert_has "stopped"
OUT="$(CODEX_APP_CALL_BIN="$FAKE" FAKE_LOG="$LOG" FAKE_STATE=idle "$WATCH" RQ-test --coord "$COORD" --once 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && ok || fail "stopped watch 应退出 3，实得 $RC"
assert_has "由主控停止"

CASE="archive_is_not_undone_by_status"
: > "$LOG"
OUT="$(CODEX_APP_CALL_BIN="$FAKE" FAKE_LOG="$LOG" "$KILL" RQ-test mod --coord "$COORD" --archive 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok || fail "kill --archive 应退出 0，实得 $RC"
grep -q '^terminated_archived=1$' "$COORD/mod.codex-app.env" && ok || fail "未记录主动归档"
: > "$LOG"
CODEX_APP_CALL_BIN="$FAKE" FAKE_LOG="$LOG" FAKE_STATE=idle "$STATUS" RQ-test --coord "$COORD" >/dev/null 2>&1
METHODS="$(node - "$LOG" <<'NODE'
const fs=require("fs"); const rows=fs.readFileSync(process.argv[2],"utf8").trim().split(/\n/).filter(Boolean).map(JSON.parse); process.stdout.write(rows.map(x=>x.method).join(" "));
NODE
)"
[ "$METHODS" = "thread/read" ] && ok || fail "status 不应取消主动归档: $METHODS"

CASE="reply_resumes_stopped_session"
OUT="$(CODEX_APP_CALL_BIN="$FAKE" FAKE_LOG="$LOG" FAKE_STATE=idle "$ROOT/scripts/cc-fleet-reply-codex" RQ-test mod "继续执行" --coord "$COORD" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok || fail "reply 应退出 0，实得 $RC"
assert_has "追加新 turn"
grep -q '^terminated=0$' "$COORD/mod.codex-app.env" && ok || fail "reply 后未清除 stopped 标记"
LAST_TURN_PARAMS="$(node - "$LOG" <<'NODE'
const fs=require("fs"); const rows=fs.readFileSync(process.argv[2],"utf8").trim().split(/\n/).filter(Boolean).map(JSON.parse); const row=rows.slice().reverse().find(x=>x.method==="turn/start"); process.stdout.write(JSON.stringify(row?.params||{}));
NODE
)"
node -e 'const x=JSON.parse(process.argv[1]); if(x.serviceTier!==null||x.summary!=="none"||x.effort!=="high")process.exit(1)' "$LAST_TURN_PARAMS"
[ "$?" -eq 0 ] && ok || fail "DeepSeek follow-up 未清除 tier/summary: $LAST_TURN_PARAMS"

CASE="respawn_uses_codex_interrupt"
OUT="$("$ROOT/scripts/cc-fleet-respawn" RQ-test mod --coord "$COORD" --dispatch cc-dispatch-codex-app --dry-run 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok || fail "respawn dry-run 应退出 0，实得 $RC"
assert_has "cc-fleet-kill-codex-app"
if printf '%s' "$OUT" | grep -q -- '--signal'; then fail "Codex respawn 不应传 POSIX signal"; else ok; fi

# thread 空闲 ≠ 干完了：它可能只是在等主 session 追加指令。没有 result: 回执就不许结案，
# 否则 watch 会在 worker 等回话时宣告"全部完成"（2026-08-06 实测踩到）。
CASE="watch_idle_without_receipt_is_not_completed"
COORD2="$T/fleet/RQ-watch"; mkdir -p "$COORD2"
cat > "$COORD2/w.codex-app.env" <<EOF
id=thread-test
thread_id=thread-test
rq=RQ-watch
module=w
mode=codex-app
summary_file=$COORD2/w.summary.md
terminated=0
EOF
OUT="$(CODEX_APP_CALL_BIN="$FAKE" FAKE_LOG="$LOG" FAKE_STATE=done "$WATCH" RQ-watch --coord "$COORD2" --once 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ok || fail "空闲但无回执不该结案，应 rc=1，实得 $RC"
if printf '%s' "$OUT" | grep -q "已完成"; then fail "不该宣告已完成: $OUT"; else ok; fi
assert_has "未落回执"

CASE="watch_receipt_closes_the_case"
printf 'result: w 完成\n\n细节\n' > "$COORD2/w.summary.md"
OUT="$(CODEX_APP_CALL_BIN="$FAKE" FAKE_LOG="$LOG" FAKE_STATE=done "$WATCH" RQ-watch --coord "$COORD2" --once 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok || fail "有回执应结案 rc=0，实得 $RC"
assert_has "回执在案"

CASE="watch_stall_idle_settles_as_unverified"
rm -f "$COORD2/w.summary.md"
# --stall-idle 0：空闲立刻判"静默结束"，但要标成需核验而不是完成
OUT="$(CODEX_APP_CALL_BIN="$FAKE" FAKE_LOG="$LOG" FAKE_STATE=done "$WATCH" RQ-watch --coord "$COORD2" --once --stall-idle 0 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok || fail "静默判定应结束 rc=0，实得 $RC"
assert_has "需核验"

# status 对"从未归档过的 thread"不该把 unarchive 的良性报错塞进 DETAIL
CASE="status_hides_benign_unarchive_error"
FAKE_UNARCH="$T/fake-unarchive.js"
sed 's#} else console.log("{}");#} else if (method === "thread/unarchive") { console.error("no archived rollout found"); process.exit(1); } else console.log("{}");#' "$FAKE" > "$FAKE_UNARCH"
chmod +x "$FAKE_UNARCH"
OUT="$(CODEX_APP_CALL_BIN="$FAKE_UNARCH" FAKE_LOG="$LOG" FAKE_STATE=done "$STATUS" RQ-watch --coord "$COORD2" 2>&1)"
if printf '%s' "$OUT" | grep -q "unarchive 兜底失败"; then fail "良性 unarchive 报错不该进 DETAIL: $OUT"; else ok; fi

echo
echo "==== Codex session control 测试：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] && echo "✅ 全绿" || { echo "❌ 有失败"; exit 1; }
