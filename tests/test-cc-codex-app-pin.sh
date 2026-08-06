#!/usr/bin/env bash
# Pinning must use app-server thread metadata instead of editing global state files.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$ROOT/scripts/cc-codex-app-pin"
PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ [$CASE] $1"; FAIL=$((FAIL+1)); }

FAKE="$TMP/fake-call"
LOG="$TMP/calls.jsonl"
cat > "$FAKE" <<'NODE'
#!/usr/bin/env node
const fs = require("fs");
const args = process.argv.slice(2);
let method = "";
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--codex-bin") { i++; continue; }
  if (args[i] === "--start-app-server") continue;
  if (!method) method = args[i];
}
const params = JSON.parse(fs.readFileSync(0, "utf8"));
fs.appendFileSync(process.env.FAKE_LOG, `${JSON.stringify({method,params})}\n`);
if (method === "thread/metadata/update" && process.env.FAIL_FIRST_MARKER && !fs.existsSync(process.env.FAIL_FIRST_MARKER)) {
  fs.writeFileSync(process.env.FAIL_FIRST_MARKER, "failed once\n");
  console.error('{"code":-32600,"message":"gitInfo must include at least one field"}');
  process.exit(1);
}
if (method === "thread/read") console.log('{"thread":{"isPinned":true}}');
else console.log('{"thread":{"id":"thr-1"}}');
NODE
chmod +x "$FAKE"

CASE="pin_and_unpin_use_metadata_api"
OUT="$(CODEX_APP_CALL_BIN="$FAKE" FAKE_LOG="$LOG" "$PIN" pin thr-1 2>&1)"
[ "$?" -eq 0 ] && [ "$OUT" = "pinned" ] && ok || fail "$OUT"
OUT="$(CODEX_APP_CALL_BIN="$FAKE" FAKE_LOG="$LOG" "$PIN" unpin thr-1 2>&1)"
[ "$?" -eq 0 ] && [ "$OUT" = "unpinned" ] && ok || fail "$OUT"
OUT="$(CODEX_APP_CALL_BIN="$FAKE" FAKE_LOG="$LOG" "$PIN" is-pinned thr-1 2>&1)"
[ "$?" -eq 0 ] && [ "$OUT" = "1" ] && ok || fail "$OUT"

node - "$LOG" <<'NODE'
const fs = require("fs");
const rows = fs.readFileSync(process.argv[2], "utf8").trim().split(/\n/).map(JSON.parse);
if (rows.length !== 3) process.exit(10);
if (rows[0].method !== "thread/metadata/update" || rows[0].params.isPinned !== true) process.exit(11);
if (rows[1].method !== "thread/metadata/update" || rows[1].params.isPinned !== false) process.exit(12);
if (rows[2].method !== "thread/read" || rows[2].params.includeTurns !== false) process.exit(13);
NODE
[ "$?" -eq 0 ] && ok || fail "app-server 调用参数不正确"

CASE="pin_retries_new_thread_metadata_race"
: > "$LOG"
RETRY_MARKER="$TMP/retry-marker"
OUT="$(CODEX_APP_CALL_BIN="$FAKE" FAKE_LOG="$LOG" FAIL_FIRST_MARKER="$RETRY_MARKER" "$PIN" pin thr-new 2>&1)"
[ "$?" -eq 0 ] && [ "$OUT" = "pinned" ] && ok || fail "$OUT"
[ "$(wc -l < "$LOG" | tr -d ' ')" = "2" ] && ok || fail "应在瞬时 metadata race 后重试一次"

echo
echo "==== cc-codex-app-pin 测试：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] && echo "✅ 全绿" || { echo "❌ 有失败"; exit 1; }
