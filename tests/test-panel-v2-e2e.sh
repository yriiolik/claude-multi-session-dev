#!/usr/bin/env bash
# v2 全链路 e2e：`cc-fleet init → prepare → dispatch`（Codex app-server）派发成功即登记面板注册表 + 在 Ghostty
# 分屏拉起面板；面板 `--json` 从 v2 名册看到这个 worker；落 JSON 回执后面板判「已回执」；Claude 后端不动面板。
# 全程假 app-server / 假 osascript，不碰真实 Ghostty 与真实 ~/.claude/fleet。
set -u
export FORCE_COLOR=0 NO_COLOR=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLEET="$ROOT/scripts/cc-fleet"
PANEL="$ROOT/scripts/cc-fleet-panel-codex-app"
T="$(mktemp -d)"
trap 'rm -rf "$T"; rm -rf "${TMPDIR:-/tmp}/fleet-v2-inbox/RQ-panel-v2-e2e"' EXIT
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

export CODEX_APP_CALL_BIN="$FAKE_CALL" CC_GHOSTTY_OSASCRIPT="$FAKE_OSA" CC_FLEET_PANEL=1 \
  CC_FLEET_PANEL_REGISTRY="$T/coords.json" CC_FLEET_PANEL_STATE="$T/panel.json" CC_FLEET_PANEL_PIDFILE="$T/panel.pid" \
  CLAUDE_FLEET_CONFIG="$T/missing.json" CODEX_MULTI_SESSION_CONFIG="$T/absent.json" CLAUDE_CLI_PATH=/usr/bin/false

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

CASE="Claude 后端不动面板"
: > "$OSA_LOG"
"$FLEET" prepare --coord "$C" --module ui --backend claude --task "$T/card.md" > /dev/null
OUT="$("$FLEET" dispatch --coord "$C" --module ui 2>/dev/null)"; RC=$?
[[ $RC -ne 0 ]] && ok || fail "假 claude 二进制派发应失败（这里只看面板没被碰）"
assert_eq "$(wc -c < "$OSA_LOG" | tr -d ' ')" "0" "没有再去分屏"

echo "==== panel-v2 e2e: $PASS passed, $FAIL failed ===="
[[ $FAIL -eq 0 ]]
