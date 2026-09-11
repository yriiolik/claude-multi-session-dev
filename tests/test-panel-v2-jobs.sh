#!/usr/bin/env bash
# 面板数据层兼容 v2 名册（scripts/cc-fleet）：`<coord>/v2/<module>.json` 翻译成面板 job、JSON 回执算「回执在案」、
# 没拿到 thread id 的记录与 Claude 后端不上面板、listJobs 本身不混入 v2（status 脚本会回写 env 元数据）。
set -u
export FORCE_COLOR=0 NO_COLOR=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ $1"; FAIL=$((FAIL+1)); }
assert_eq(){ [[ "$1" == "$2" ]] && ok || fail "$3: 期望 [$2] 实得 [$1]"; }

COORD="$TMP/repo/.git/fleet/RQ-v2-test"
mkdir -p "$COORD/v2"
printf '{"version":2,"rq":"RQ-v2-test","repo":"%s/repo"}\n' "$TMP" > "$COORD/fleet.json"
cat > "$COORD/v2/api.json" <<'J'
{"version":2,"module":"api","backend":"codex","transport":"app-server","state":"running","name":"↳api@RQ-v2-test",
 "createdAt":1700000000.4,"startedAt":1700000010.9,"sessionId":"thread-api","turnId":"turn-1","worktree":"/wt/api","branch":"fleet-worker/RQ-v2-test/api",
 "routing":{"model":"gpt-6-astra","modelProvider":"openai","reasoningEffort":"low"}}
J
cat > "$COORD/v2/ui.json" <<'J'
{"version":2,"module":"ui","backend":"claude","transport":"claude-bg","state":"running","sessionId":"sid-1"}
J
cat > "$COORD/v2/svc.json" <<'J'
{"version":2,"module":"svc","backend":"codex","transport":"app-server","state":"prepared","sessionId":null}
J
cat > "$COORD/v2/old.json" <<'J'
{"version":2,"module":"old","backend":"codex","transport":"native","state":"stopped","sessionId":"thread-old","createdAt":1700000000}
J
printf '{"version":2,"rq":"RQ-v2-test","module":"old","attempt":"x","result":"failed","summary":"第一行摘要\\n第二行"}\n' > "$COORD/old.receipt.json"
# 旧 env 名册照常并存
printf 'id=thread-legacy\nthread_id=thread-legacy\nmodule=legacy\nstarted_at=1700000000\n' > "$COORD/legacy.codex-app.env"

# 假 app-call：thread/read 一律返回 active
FAKE="$TMP/app-call"
cat > "$FAKE" <<'SH2'
#!/bin/sh
echo '{"thread":{"id":"x","status":{"type":"active"},"turns":[{"id":"t","status":"inProgress"}]}}'
SH2
chmod +x "$FAKE"

OUT="$(cd "$ROOT" && node -e '
const lib = require("./scripts/lib/codex-app-jobs.js");
const coord = process.argv[1];
const v2 = lib.listV2Jobs(coord);
const legacy = lib.listJobs(coord);
const snap = lib.readOnlySnapshot(coord, { callBin: process.argv[2] });
const j = v2.find((x) => x.module === "api");
const out = {
  v2Modules: v2.map((x) => x.module).join(","),
  legacyModules: legacy.map((x) => x.module).join(","),
  api: [j.thread_id, j.turn_id, j.rq, j.name, j.started_at, j.model_provider, j.model, j.reasoning_effort, j.worktree_cwd, j.branch, j.terminated, j.mode, j.summary_file.endsWith("/api.receipt.json")].join("|"),
  oldTerminated: v2.find((x) => x.module === "old").terminated,
  snap: snap.jobs.map((x) => `${x.module}:${x.state}:${x.receipt}`).join(","),
  oldLine: lib.receiptLine(coord + "/old.receipt.json"),
  apiDone: lib.receiptDone(coord + "/api.receipt.json"),
  mdLine: lib.receiptLine(process.argv[3]),
};
for (const [k, v] of Object.entries(out)) console.log(`${k}=${v}`);
' "$COORD" "$FAKE" "$TMP/legacy.summary.md" 2>&1)"
printf 'result: done 全部通过\n细节...\n' > "$TMP/legacy.summary.md"
MD_LINE="$(cd "$ROOT" && node -e 'console.log(require("./scripts/lib/codex-app-jobs.js").receiptLine(process.argv[1]))' "$TMP/legacy.summary.md")"

get(){ printf '%s\n' "$OUT" | awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}'; }
assert_eq "$(get v2Modules)" "api,old" "v2 只收有 thread id 的 Codex 记录（不含 claude 后端 ui、未派发 svc）"
assert_eq "$(get legacyModules)" "legacy" "listJobs 不混入 v2 记录"
assert_eq "$(get api)" "thread-api|turn-1|RQ-v2-test|↳api@RQ-v2-test|1700000010|openai|gpt-6-astra|low|/wt/api|fleet-worker/RQ-v2-test/api|0|v2-app-server|true" "v2 记录字段翻译"
assert_eq "$(get oldTerminated)" "1" "stopped → terminated=1"
assert_eq "$(get snap)" "legacy:running:0,api:running:0,old:done:1" "只读快照合并旧 env 与 v2；JSON 回执直接定案不问 app-server"
assert_eq "$(get oldLine)" "failed: 第一行摘要" "JSON 回执首行 = result: summary 首行"
assert_eq "$(get apiDone)" "false" "没有回执文件 → 未回执"
assert_eq "$MD_LINE" "done 全部通过" "md 回执首行去掉 result: 前缀"

echo "panel-v2-jobs: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
