#!/usr/bin/env bash
# 面板数据层兼容 v2 名册（scripts/cc-fleet）：`<coord>/v2/<module>.json` 翻译成面板 job、JSON 回执算「回执在案」、
# 没拿到真实会话 ID 的记录不上面板、Claude 后端按 `claude agents --json --all` 判状态（一轮只调一次 CLI）、
# listJobs 本身不混入 v2（status 脚本会回写 env 元数据）。
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
{"version":2,"module":"ui","backend":"claude","transport":"claude-bg","state":"running","name":"↳ui@RQ-v2-test","createdAt":1700000100,
 "startedAt":1700000100,"shortId":"c0ffee01","sessionId":"sid-ui","worktree":"/wt/ui","cwd":"/wt/ui/factory","branch":"fleet-worker/RQ-v2-test/ui",
 "claudeProfile":{"model":"claude-opus-5","effort":"high"}}
J
# 启动结果未对上 shortId（launch-uncertain）的 Claude 记录不是 worker
cat > "$COORD/v2/ui2.json" <<'J'
{"version":2,"module":"ui2","backend":"claude","transport":"claude-bg","state":"launch-uncertain","shortId":null,"sessionId":null}
J
# 名册有、`claude agents` 里已经没有的会话
cat > "$COORD/v2/zz.json" <<'J'
{"version":2,"module":"zz","backend":"claude","transport":"claude-bg","state":"running","shortId":"gone0000","sessionId":"sid-gone"}
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

# 假 claude：agents 列表里 ui 在等审批；每次调用记一行，用来断言「一轮只调一次」
CLAUDE_LOG="$TMP/claude.log"; : > "$CLAUDE_LOG"
FAKE_CLAUDE="$TMP/claude"
cat > "$FAKE_CLAUDE" <<SH3
#!/bin/sh
echo "\$*" >> "$CLAUDE_LOG"
[ "\$1" = logs ] && { echo "fake-logs \$2"; exit 0; }
echo '[{"id":"c0ffee01","sessionId":"sid-ui","state":"blocked","waitingFor":"权限审批"},{"id":"other","state":"working"}]'
SH3
chmod +x "$FAKE_CLAUDE"
BAD_CLAUDE="$TMP/claude-bad"
printf '#!/bin/sh\necho x >> "%s"\necho boom >&2\nexit 1\n' "$TMP/bad.log" > "$BAD_CLAUDE"; chmod +x "$BAD_CLAUDE"

OUT="$(cd "$ROOT" && node -e '
const lib = require("./scripts/lib/codex-app-jobs.js");
const coord = process.argv[1];
const v2 = lib.listV2Jobs(coord);
const legacy = lib.listJobs(coord);
const snap = lib.readOnlySnapshot(coord, { callBin: process.argv[2], claudeBin: process.argv[4] });
const j = v2.find((x) => x.module === "api");
const u = v2.find((x) => x.module === "ui");
const cls = (state, extra = {}) => lib.classifyFromClaudeAgent({ ...extra }, state === null ? null : { state }).state;
const lazy = lib.lazyClaudeAgents({ bin: process.argv[4] });
const lazyN = [lazy(), lazy(), lazy()].map((x) => x.length).join(",");
const bad = lib.lazyClaudeAgents({ bin: process.argv[5] });
let badThrows = 0;
for (let i = 0; i < 3; i++) { try { bad(); } catch { badThrows += 1; } }
const out = {
  v2Modules: v2.map((x) => x.module).join(","),
  legacyModules: legacy.map((x) => x.module).join(","),
  api: [j.backend, j.thread_id, j.turn_id, j.rq, j.name, j.started_at, j.model_provider, j.model, j.reasoning_effort, j.worktree_cwd, j.branch, j.terminated, j.mode, j.summary_file.endsWith("/api.receipt.json")].join("|"),
  ui: [u.backend, u.id, u.thread_id, u.short_id, u.session_id, u.model_provider, u.model, u.reasoning_effort, u.worktree_cwd, u.start_cwd, u.mode, u.summary_file.endsWith("/ui.receipt.json")].join("|"),
  oldTerminated: v2.find((x) => x.module === "old").terminated,
  snap: snap.jobs.map((x) => `${x.module}:${x.state}:${x.receipt}`).join(","),
  uiDetail: snap.jobs.find((x) => x.module === "ui").detail,
  claudeUnavailable: snap.claudeUnavailable,
  classify: [cls("working"), cls("blocked"), cls("done"), cls("failed"), cls("stopped"), cls("weird"), cls(null), cls("done", { terminated: "1" })].join(","),
  lazyN,
  badThrows,
  logs: lib.readClaudeLogs("c0ffee01", { bin: process.argv[4] }).text.trim(),
  oldLine: lib.receiptLine(coord + "/old.receipt.json"),
  apiDone: lib.receiptDone(coord + "/api.receipt.json"),
  mdLine: lib.receiptLine(process.argv[3]),
};
for (const [k, v] of Object.entries(out)) console.log(`${k}=${v}`);
' "$COORD" "$FAKE" "$TMP/legacy.summary.md" "$FAKE_CLAUDE" "$BAD_CLAUDE" 2>&1)"
# 快照（1 次）+ lazy 三连调（1 次）+ logs（1 次）；bad 三连调只 spawn 1 次
CLAUDE_CALLS="$(grep -c '^agents --json --all$' "$CLAUDE_LOG")"
BAD_CALLS="$(wc -l < "$TMP/bad.log" | tr -d ' ')"
# 读不到 claude agents：该后端 worker 判 unknown 并置 claudeUnavailable，Codex worker 不受影响
BAD_SNAP="$(cd "$ROOT" && node -e '
const lib = require("./scripts/lib/codex-app-jobs.js");
const s = lib.readOnlySnapshot(process.argv[1], { callBin: process.argv[2], claudeBin: process.argv[3] });
console.log(`${s.claudeUnavailable}|${s.jobs.map((x) => `${x.module}:${x.state}`).join(",")}`);
' "$COORD" "$FAKE" "$BAD_CLAUDE")"
printf 'result: done 全部通过\n细节...\n' > "$TMP/legacy.summary.md"
MD_LINE="$(cd "$ROOT" && node -e 'console.log(require("./scripts/lib/codex-app-jobs.js").receiptLine(process.argv[1]))' "$TMP/legacy.summary.md")"

get(){ printf '%s\n' "$OUT" | awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}'; }
assert_eq "$(get v2Modules)" "api,old,ui,zz" "v2 收有真实会话 ID 的 Codex 与 Claude 记录（不含未派发 svc、未对上 shortId 的 ui2）"
assert_eq "$(get legacyModules)" "legacy" "listJobs 不混入 v2 记录"
assert_eq "$(get api)" "codex|thread-api|turn-1|RQ-v2-test|↳api@RQ-v2-test|1700000010|openai|gpt-6-astra|low|/wt/api|fleet-worker/RQ-v2-test/api|0|v2-app-server|true" "v2 Codex 记录字段翻译"
assert_eq "$(get ui)" "claude|c0ffee01||c0ffee01|sid-ui|anthropic|claude-opus-5|high|/wt/ui|/wt/ui/factory|v2-claude-bg|true" "v2 Claude 记录字段翻译（短 id 寻址、sessionId 找 transcript、启动子目录）"
assert_eq "$(get oldTerminated)" "1" "stopped → terminated=1"
assert_eq "$(get snap)" "legacy:running:0,api:running:0,old:done:1,ui:blocked:0,zz:unknown:0" "只读快照合并旧 env 与 v2；JSON 回执直接定案；Claude 按 agents 列表判状态，列表里没有的判 unknown"
assert_eq "$(get uiDetail)" "Claude worker 等待：权限审批" "blocked 带 waitingFor"
assert_eq "$(get claudeUnavailable)" "false" "claude agents 可读"
assert_eq "$(get classify)" "running,blocked,done,failed,stopped,unknown,unknown,stopped" "claude agents 状态映射（done 只是空闲，交给回执定案；被主控 stop 的记 stopped）"
assert_eq "$(get lazyN)" "2,2,2" "lazy 读取返回同一份列表"
assert_eq "$CLAUDE_CALLS" "2" "一次快照 + 一个 lazy 实例各只调一次 claude agents"
assert_eq "$(get badThrows)" "3" "读取失败每次都如实抛错"
assert_eq "$BAD_CALLS" "1" "读取失败也只 spawn 一次，不逐个 worker 重试"
assert_eq "$(get logs)" "fake-logs c0ffee01" "降级视图读 claude logs"
assert_eq "$BAD_SNAP" "true|legacy:running,api:running,old:done,ui:unknown,zz:unknown" "claude agents 不可读：Claude worker 判 unknown，Codex 不受影响"
assert_eq "$(get oldLine)" "failed: 第一行摘要" "JSON 回执首行 = result: summary 首行"
assert_eq "$(get apiDone)" "false" "没有回执文件 → 未回执"
assert_eq "$MD_LINE" "done 全部通过" "md 回执首行去掉 result: 前缀"

echo "panel-v2-jobs: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
