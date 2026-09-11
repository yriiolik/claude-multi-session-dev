#!/usr/bin/env bash
# v2 全链路 e2e：`cc-fleet init → prepare → dispatch`（Codex app-server）派发成功即登记面板注册表 + 在 Ghostty
# 分屏拉起面板；面板 `--json` 从 v2 名册看到这个 worker；落 JSON 回执后面板判「已回执」；Claude 后端（claude --bg）
# 同样登记 + 分屏，面板按 `claude agents` 判状态、按会话 transcript 出最近动作与详情时间线。
# 全程假 app-server / 假 claude / 假 osascript，不碰真实 Ghostty、真实 ~/.claude/fleet 与真实 ~/.claude/projects。
set -u
export FORCE_COLOR=0 NO_COLOR=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLEET="$ROOT/scripts/cc-fleet"
PANEL="$ROOT/scripts/cc-fleet-panel-codex-app"
T="$(mktemp -d)"
trap 'rm -rf "$T"; rm -rf "${TMPDIR:-/tmp}/fleet-v2-inbox/RQ-panel-v2-e2e" "${TMPDIR:-/tmp}/fleet-v2-inbox/RQ-panel-v2-e2e-c"' EXIT
PASS=0; FAIL=0; CASE="init"
ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ [$CASE] $1"; FAIL=$((FAIL+1)); }
assert_eq(){ [[ "$1" == "$2" ]] && ok || fail "$3: 期望 [$2] 实得 [$1]"; }
assert_contains(){ [[ "$1" == *"$2"* ]] && ok || fail "$3: 找不到 [$2]"; }
jq_(){ node -pe 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); eval(process.argv[1])' "$1"; }

R="$T/repo"; mkdir -p "$R"
git -C "$R" init -q -b main; git -C "$R" config user.email t@t; git -C "$R" config user.name t
printf 'root\n' > "$R/README.md"; git -C "$R" add -A; git -C "$R" commit -qm init
printf '# card\n\n做 api 模块。\n' > "$T/card.md"

# 假 app-server：cc-fleet 走 stdin（参数 `-`），面板走参数文件；两种都认
FAKE_CALL="$T/fake-app-call"
cat > "$FAKE_CALL" <<'NODE'
#!/usr/bin/env node
const fs = require("fs");
const pos = process.argv.slice(2).filter((a, i, all) => !a.startsWith("--") && all[i - 1] !== "--timeout-ms" && all[i - 1] !== "--codex-bin");
const method = pos[0];
const r = { "thread/start": { thread: { id: "thread-v2-e2e" } }, "turn/start": { turn: { id: "turn-v2-e2e" } },
  "thread/read": { thread: { id: "thread-v2-e2e", status: { type: "active" }, turns: [{ id: "turn-v2-e2e", status: "inProgress" }] } } };
console.log(JSON.stringify(r[method] || {}));
NODE
chmod +x "$FAKE_CALL"

# 假 osascript：记录分屏命令，回一个假 terminal id
OSA_LOG="$T/osa.log"; : > "$OSA_LOG"
FAKE_OSA="$T/fake-osascript"
printf '#!/bin/sh\ncat >/dev/null\nprintf "%%s\\n" "$@" >> "$OSA_LOG"\necho FAKE-TERM-V2\n' > "$FAKE_OSA"
sed -i '' "s|\$OSA_LOG|$OSA_LOG|" "$FAKE_OSA"; chmod +x "$FAKE_OSA"

# 假 claude：--bg 按 --name + 当前目录登记一条 working 会话；agents --json --all 吐名册；logs 吐假输出
FAKE_CLAUDE="$T/claude"
cat > "$FAKE_CLAUDE" <<'NODE'
#!/usr/bin/env node
const fs = require("fs");
const db = process.env.FAKE_CLAUDE_DB;
const jobs = fs.existsSync(db) ? JSON.parse(fs.readFileSync(db, "utf8")) : [];
const a = process.argv.slice(2);
if (a[0] === "agents") { console.log(JSON.stringify(jobs)); process.exit(0); }
if (a[0] === "logs") { console.log(`fake logs ${a[1]}`); process.exit(0); }
if (a.includes("--bg")) {
  const id = String(jobs.length + 1).padStart(8, "c");
  jobs.push({ id, sessionId: `sid-${id}`, name: a[a.indexOf("--name") + 1], cwd: process.cwd(), kind: "background", state: "working" });
  fs.writeFileSync(db, JSON.stringify(jobs));
  console.log("launched");
  process.exit(0);
}
process.exit(3);
NODE
chmod +x "$FAKE_CLAUDE"
set_claude_state(){ node -e 'const fs=require("fs");const f=process.argv[1];const j=JSON.parse(fs.readFileSync(f,"utf8"));j.find(x=>x.id===process.argv[2]).state=process.argv[3];fs.writeFileSync(f,JSON.stringify(j))' "$T/claude-db.json" "$1" "$2"; }

export CODEX_APP_CALL_BIN="$FAKE_CALL" CC_GHOSTTY_OSASCRIPT="$FAKE_OSA" CC_FLEET_PANEL=1 \
  CC_FLEET_PANEL_REGISTRY="$T/coords.json" CC_FLEET_PANEL_STATE="$T/panel.json" CC_FLEET_PANEL_PIDFILE="$T/panel.pid" \
  CLAUDE_FLEET_CONFIG="$T/missing.json" CODEX_MULTI_SESSION_CONFIG="$T/absent.json" \
  CLAUDE_CLI_PATH="$FAKE_CLAUDE" FAKE_CLAUDE_DB="$T/claude-db.json" CLAUDE_CONFIG_DIR="$T/claude-home"

CASE="v2 派发即拉起面板"
INIT="$("$FLEET" init --cwd "$R" --host claude-code --owner-id main-e2e --rq RQ-panel-v2-e2e)"
C="$(printf '%s' "$INIT" | jq_ 'j.coord')"
"$FLEET" prepare --coord "$C" --module api --backend codex --task "$T/card.md" > /dev/null
OUT="$("$FLEET" dispatch --coord "$C" --module api)"; RC=$?
assert_eq "$RC" "0" "派发应成功（${OUT:0:200}）"
assert_eq "$(printf '%s' "$OUT" | jq_ 'j.state')" "running" "worker running"
assert_eq "$(printf '%s' "$OUT" | jq_ 'JSON.stringify(j.panel)')" '{"registered":true,"panelOpened":true}' "输出带面板结果"
assert_contains "$(cat "$T/coords.json")" "$C" "协调目录登记进面板注册表"
assert_contains "$(cat "$C/owner.meta" 2>/dev/null || echo MISSING)" "owner_pid=" "落下主 session 归属"
assert_contains "$(cat "$OSA_LOG")" "cc-fleet-panel-codex-app" "分屏里跑的是面板程序"
assert_contains "$(cat "$OSA_LOG")" "right" "默认右侧分屏"
assert_eq "$(jq_ 'j.terminalId' < "$T/panel.json")" "FAKE-TERM-V2" "记下分屏 surface id"

CASE="面板看得见 v2 worker"
P="$("$PANEL" --json)"
assert_eq "$(printf '%s' "$P" | jq_ 'j.jobs.length')" "1" "面板列出 1 个 worker"
assert_eq "$(printf '%s' "$P" | jq_ 'j.jobs[0].module')" "api" "模块名"
assert_eq "$(printf '%s' "$P" | jq_ 'j.jobs[0].label')" "执行中" "状态词执行中"
assert_eq "$(printf '%s' "$P" | jq_ 'j.jobs[0].receipt')" "0" "还没落回执"
assert_eq "$(printf '%s' "$P" | jq_ 'j.groups[0].rq')" "RQ-panel-v2-e2e" "任务组是本次 RQ"

CASE="JSON 回执 → 已回执"
ATT="$(jq_ 'j.attempt' < "$C/v2/api.json")"
printf '{"version":2,"rq":"RQ-panel-v2-e2e","module":"api","attempt":"%s","result":"done","summary":"api 完成","tests":[{"command":"t","result":"passed","evidence":"e"}],"commit":""}\n' "$ATT" > "$C/api.receipt.json"
P="$("$PANEL" --json)"
assert_eq "$(printf '%s' "$P" | jq_ 'j.jobs[0].label')" "已回执" "JSON 回执在案"
assert_eq "$(printf '%s' "$P" | jq_ 'j.jobs[0].receipt')" "1" "receipt=1"

CASE="Claude 后端同样拉起面板"
: > "$OSA_LOG"
"$FLEET" prepare --coord "$C" --module ui --backend claude --task "$T/card.md" > /dev/null
OUT="$("$FLEET" dispatch --coord "$C" --module ui)"; RC=$?
assert_eq "$RC" "0" "Claude 派发应成功（${OUT:0:200}）"
assert_eq "$(printf '%s' "$OUT" | jq_ 'j.state')" "running" "Claude worker running"
assert_eq "$(printf '%s' "$OUT" | jq_ 'JSON.stringify(j.panel)')" '{"registered":true,"panelOpened":true}' "Claude 派发输出带面板结果"
assert_contains "$(cat "$OSA_LOG")" "cc-fleet-panel-codex-app" "Claude 派发也在分屏里拉起面板"
assert_contains "$(cat "$OSA_LOG")" "CLAUDE_CLI_PATH=$FAKE_CLAUDE" "分屏环境带上 CLAUDE_CLI_PATH"
assert_contains "$(cat "$OSA_LOG")" "CLAUDE_CONFIG_DIR=$T/claude-home" "分屏环境带上 CLAUDE_CONFIG_DIR"
SHORT="$(jq_ 'j.shortId' < "$C/v2/ui.json")"; SID="$(jq_ 'j.sessionId' < "$C/v2/ui.json")"; WCWD="$(jq_ 'j.cwd' < "$C/v2/ui.json")"

CASE="面板看得见 Claude worker"
P="$("$PANEL" --json)"
assert_eq "$(printf '%s' "$P" | jq_ 'j.jobs.length')" "2" "Codex + Claude 同屏 2 个 worker"
assert_eq "$(printf '%s' "$P" | jq_ 'j.title')" "Fleet" "混合后端标题是 Fleet"
assert_eq "$(printf '%s' "$P" | jq_ 'j.jobs[0].module')" "ui" "未完成的 Claude worker 排在前面"
assert_eq "$(printf '%s' "$P" | jq_ 'j.jobs[0].backend')" "claude" "backend=claude"
assert_eq "$(printf '%s' "$P" | jq_ 'j.jobs[0].label')" "执行中" "agents working → 执行中"
assert_eq "$(printf '%s' "$P" | jq_ 'j.jobs[0].thread_id')" "$SHORT" "寻址用 claude agents 短 id"

CASE="transcript → 最近动作与详情"
TDIR="$T/claude-home/projects/$(printf '%s' "$WCWD" | sed 's/[^A-Za-z0-9]/-/g')"; mkdir -p "$TDIR"
node -e '
const [file, cwd] = process.argv.slice(1);
const L = [
  { type: "user", cwd, timestamp: "2026-09-11T08:00:00Z", message: { role: "user", content: "⟦FLEET-WORKER⟧ rq=RQ-panel-v2-e2e module=ui\n做 ui 模块。" } },
  { type: "assistant", cwd, timestamp: "2026-09-11T08:00:05Z", message: { model: "claude-opus-5", content: [{ type: "text", text: "先跑一遍测试" }] } },
  { type: "assistant", cwd, timestamp: "2026-09-11T08:00:06Z", message: { model: "claude-opus-5", content: [{ type: "tool_use", id: "tu1", name: "Bash", input: { command: `cd "${cwd}" && pnpm test` } }] } },
  { type: "user", cwd, timestamp: "2026-09-11T08:00:09Z", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "tu1", content: "12 passed", is_error: false }] } },
  { type: "custom-title", customTitle: "↳ui" },
];
require("fs").writeFileSync(file, L.map((x) => JSON.stringify(x)).join("\n") + "\n");
' "$TDIR/$SID.jsonl" "$WCWD"
OUT="$("$PANEL" --once --plain)"
assert_contains "$OUT" "Fleet ·" "列表标题"
assert_contains "$OUT" "↳ui" "列表有 Claude worker 行"
assert_contains "$OUT" "$ pnpm test" "最近动作取 transcript 最后一次工具调用（剥掉 cd 前缀）"
OUT="$("$PANEL" --once --plain --keys right)"
assert_contains "$OUT" "claude  session $SID · id $SHORT" "详情页头标出 Claude 会话"
assert_contains "$OUT" "📋 任务卡" "详情时间线有任务卡"
assert_contains "$OUT" "💬 回复" "详情时间线有回复"
assert_contains "$OUT" "12 passed" "详情时间线带命令输出"
assert_contains "$OUT" "anthropic/claude-opus-5" "模型取自 transcript"
rm -f "$TDIR/$SID.jsonl"
OUT="$("$PANEL" --once --plain --keys right)"
assert_contains "$OUT" "降级为 claude logs" "transcript 找不到时降级为 claude logs"
assert_contains "$OUT" "fake logs $SHORT" "降级视图展示 claude logs 输出"

CASE="Claude 空闲 ≠ 完成"
set_claude_state "$SHORT" done
P="$("$PANEL" --json)"
assert_eq "$(printf '%s' "$P" | jq_ 'j.jobs.find(x=>x.module==="ui").label')" "需核验" "agents done 但没回执 → 需核验，仍算未完成"
assert_eq "$(printf '%s' "$P" | jq_ 'j.jobs.find(x=>x.module==="ui").bucket')" "pending" "需核验归在未完成"
ATT="$(jq_ 'j.attempt' < "$C/v2/ui.json")"
printf '{"version":2,"rq":"RQ-panel-v2-e2e","module":"ui","attempt":"%s","result":"done","summary":"ui 完成","tests":[{"command":"t","result":"passed","evidence":"e"}],"commit":""}\n' "$ATT" > "$C/ui.receipt.json"
P="$("$PANEL" --json)"
assert_eq "$(printf '%s' "$P" | jq_ 'j.jobs.find(x=>x.module==="ui").label')" "已回执" "落回执 → 已回执"
assert_eq "$(printf '%s' "$P" | jq_ 'j.done')" "2" "两个 worker 都已完成"

CASE="纯 Claude 任务组标题"
INIT2="$("$FLEET" init --cwd "$R" --host claude-code --owner-id main-e2e --rq RQ-panel-v2-e2e-c)"
C2="$(printf '%s' "$INIT2" | jq_ 'j.coord')"
"$FLEET" prepare --coord "$C2" --module solo --task "$T/card.md" > /dev/null
"$FLEET" dispatch --coord "$C2" --module solo > /dev/null
P="$("$PANEL" --json --rq RQ-panel-v2-e2e-c)"
assert_eq "$(printf '%s' "$P" | jq_ 'j.jobs.map(x=>x.module+":"+x.backend).join()')" "solo:claude" "Claude 主端未指定后端 → Claude worker"
assert_eq "$(printf '%s' "$P" | jq_ 'j.title')" "Claude Fleet" "纯 Claude 标题是 Claude Fleet"

echo "==== panel-v2 e2e: $PASS passed, $FAIL failed ===="
[[ $FAIL -eq 0 ]]
