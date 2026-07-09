#!/usr/bin/env bash
# cc-dispatch-codex 兼容层测试：codex 模式现在转发到 codex-app 模式。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISPATCH="$ROOT/scripts/cc-dispatch-codex"
STATUS="$ROOT/scripts/cc-fleet-status-codex"
WATCH="$ROOT/scripts/cc-fleet-watch-codex"
COORD="$ROOT/scripts/cc-fleet-coord"

PASS=0
FAIL=0
DIRS=()
trap 'for d in "${DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done' EXIT

ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ [$CASE] $1"; FAIL=$((FAIL+1)); }
assert_has(){ if printf '%s' "$OUT" | grep -qF -- "$1"; then ok; else fail "缺少: $1"; echo "$OUT"; fi; }
assert_no(){ if printf '%s' "$OUT" | grep -qF -- "$1"; then fail "不应出现: $1"; echo "$OUT"; else ok; fi; }

R="$(mktemp -d)"; DIRS+=("$R")
git -C "$R" init -q -b main
git -C "$R" config user.email t@t
git -C "$R" config user.name t
printf 'root\n' > "$R/README.md"
git -C "$R" add -A
git -C "$R" commit -qm "init"
git -C "$R" checkout -q -b dev/test
mkdir -p "$R/pkg"
printf 'project rules\n' > "$R/CLAUDE.md"
printf 'dir rules\n' > "$R/pkg/CLAUDE.md"
printf '# card\n\nDo the module task.\n' > "$R/card.md"
git -C "$R" add -A
git -C "$R" commit -qm "add project claude rules"

RQ="$(cd "$R" && "$COORD" --alloc 2>/dev/null)"
INT="$(cd "$R" && "$COORD" --init-base "$RQ" 2>/dev/null)"
CDIR="$(cd "$R" && "$COORD" "$RQ" 2>/dev/null)"

CASE="dispatch_shim_dry_run默认走codex_app"
OUT="$("$DISPATCH" --cwd "$R/pkg" --name "↳mod@$RQ" \
  --env FLEET_ROLE=worker --env FLEET_RQ="$RQ" --env FLEET_MODULE=mod --env FLEET_BASE_BRANCH="$INT" \
  --sid-file "$CDIR/mod.sid" --prompt-file "$R/card.md" --codex-bin /usr/bin/true --pin-policy never --dry-run 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok || fail "dry-run 退出码应为 0，实得 $RC"
assert_has "app visible cwd:"
assert_has "serviceTier: default"
assert_has "visibility pin policy: never"
assert_no "codex exec"
assert_no "service_tier=\"default\""

CASE="dispatch_shim_fast走priority"
OUT="$("$DISPATCH" --cwd "$R/pkg" --name "↳mod@$RQ" \
  --env FLEET_ROLE=worker --env FLEET_RQ="$RQ" --env FLEET_MODULE=mod --env FLEET_BASE_BRANCH="$INT" \
  --sid-file "$CDIR/mod.sid" --prompt-file "$R/card.md" --codex-bin /usr/bin/true --pin-policy never --fast --dry-run 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok || fail "fast dry-run 退出码应为 0，实得 $RC"
assert_has "serviceTier: priority"

CASE="status_watch_shim读codex_app元数据"
cat > "$CDIR/mod.codex-app.env" <<EOF
id=thread-shim-test
thread_id=thread-shim-test
rq=$RQ
module=mod
summary_file=$CDIR/mod.summary.md
mode=codex-app
visibility_pinned=0
visibility_unpinned=0
EOF
printf 'result: mod 完成\n' > "$CDIR/mod.summary.md"

OUT="$("$STATUS" "$RQ" --coord "$CDIR" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok || { fail "status 应为 0，实得 $RC"; echo "$OUT"; }
assert_has "Codex App worker 无在跑"

OUT="$("$WATCH" "$RQ" --coord "$CDIR" --once 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok || { fail "watch 应为 0，实得 $RC"; echo "$OUT"; }
assert_has "Codex App fleet $RQ 全部完成"

CASE="codex_app派发隐藏长规则只显示短任务卡"
RQ2="$(cd "$R" && "$COORD" --alloc 2>/dev/null)"
INT2="$(cd "$R" && "$COORD" --init-base "$RQ2" 2>/dev/null)"
CDIR2="$(cd "$R" && "$COORD" "$RQ2" 2>/dev/null)"
FAKE_APP="$R/fake-app-call.js"
FAKE_LOG="$R/fake-app-calls.jsonl"
cat > "$FAKE_APP" <<'NODE'
#!/usr/bin/env node
const fs = require("fs");

const args = process.argv.slice(2);
let method = "";
let paramsPath = "";
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === "--codex-bin") { i++; continue; }
  if (a === "--start-app-server") continue;
  if (!method) method = a;
  else if (!paramsPath) paramsPath = a;
}
const params = paramsPath ? JSON.parse(fs.readFileSync(paramsPath, "utf8")) : {};
fs.appendFileSync(process.env.FAKE_APP_LOG, `${JSON.stringify({ method, params })}\n`);
if (method === "thread/start") console.log(JSON.stringify({ thread: { id: "thread-visible-test" } }));
else if (method === "turn/start") console.log(JSON.stringify({ turn: { id: "turn-visible-test" } }));
else console.log("{}");
NODE
chmod +x "$FAKE_APP"

OUT="$(CODEX_APP_CALL_BIN="$FAKE_APP" FAKE_APP_LOG="$FAKE_LOG" "$DISPATCH" --cwd "$R/pkg" --name "↳vis@$RQ2" \
  --env FLEET_ROLE=worker --env FLEET_RQ="$RQ2" --env FLEET_MODULE=vis --env FLEET_BASE_BRANCH="$INT2" \
  --sid-file "$CDIR2/vis.sid" --prompt-file "$R/card.md" --codex-bin /usr/bin/true --pin-policy never --json 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok || { fail "codex-app 派发应为 0，实得 $RC"; echo "$OUT"; }
assert_has '"threadId":"thread-visible-test"'

METHODS="$(node - "$FAKE_LOG" <<'NODE'
const fs = require("fs");
const rows = fs.readFileSync(process.argv[2], "utf8").trim().split(/\n/).map(JSON.parse);
process.stdout.write(rows.map((r) => r.method).join(" "));
NODE
)"
if [[ "$METHODS" == "thread/start thread/name/set thread/unarchive turn/start thread/unarchive thread/resume" ]]; then ok; else fail "调用顺序不对: $METHODS"; fi

CONTEXT="$CDIR2/prompts/vis.codex-app.context.md"
VISIBLE="$CDIR2/prompts/vis.codex-app.visible.md"
FULL="$CDIR2/prompts/vis.codex-app.prompt.md"
[ -s "$CONTEXT" ] && ok || fail "context prompt 应存在"
[ -s "$VISIBLE" ] && ok || fail "visible prompt 应存在"
[ -s "$FULL" ] && ok || fail "full audit prompt 应存在"
grep -qF "project rules" "$CONTEXT" && ok || fail "context 缺项目 CLAUDE.md"
grep -qF "dir rules" "$CONTEXT" && ok || fail "context 缺目录 CLAUDE.md"
grep -qF "project rules" "$FULL" && ok || fail "full prompt 缺完整规则"
if grep -qF "project rules" "$VISIBLE"; then fail "visible prompt 不应包含完整项目规则"; else ok; fi
grep -qF "Do the module task." "$VISIBLE" && ok || fail "visible prompt 缺任务卡"

node - "$FAKE_LOG" <<'NODE'
const fs = require("fs");
const rows = fs.readFileSync(process.argv[2], "utf8").trim().split(/\n/).map(JSON.parse);
const start = rows.find((r) => r.method === "thread/start");
const turn = rows.find((r) => r.method === "turn/start");
const resume = rows.find((r) => r.method === "thread/resume");
if (!start || !String(start.params.developerInstructions || "").includes("project rules")) process.exit(11);
if (!String(start.params.developerInstructions || "").includes("dir rules")) process.exit(12);
if (start.params.threadSource !== "user") process.exit(15);
if (String(turn.params.input?.[0]?.text || "").includes("project rules")) process.exit(13);
if (!resume || resume.params.threadId !== "thread-visible-test") process.exit(14);
NODE
RC=$?
[ "$RC" -eq 0 ] && ok || fail "thread-start/turn/resume 参数不符合预期，node rc=$RC"

echo
echo "==== cc-dispatch-codex shim 测试：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] && echo "✅ 全绿" || { echo "❌ 有失败"; exit 1; }
