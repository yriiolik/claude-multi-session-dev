#!/usr/bin/env bash
# e2e：派发 Codex worker → 自动登记 + 自动分屏拉起面板 → 面板看到 worker → 全部收工后面板自动关闭。
# 全程假 codex app-server + 假 osascript，不碰真实 Ghostty / Codex。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISPATCH="$ROOT/scripts/cc-dispatch-codex-app"
PANEL="$ROOT/scripts/cc-fleet-panel-codex-app"
COORD_BIN="$ROOT/scripts/cc-fleet-coord"

PASS=0; FAIL=0; CASE="init"
DIRS=()
trap 'for d in "${DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done' EXIT
ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ [$CASE] $1"; FAIL=$((FAIL+1)); }
assert_eq(){ [[ "$1" == "$2" ]] && ok || fail "$3: 期望 [$2] 实得 [$1]"; }
assert_contains(){ [[ "$1" == *"$2"* ]] && ok || fail "$3: 找不到 [$2]"; }

T="$(mktemp -d)"; DIRS+=("$T")
R="$T/repo"; mkdir -p "$R/pkg"
git -C "$R" init -q -b main
git -C "$R" config user.email t@t
git -C "$R" config user.name t
printf 'root\n' > "$R/README.md"
printf 'pkg\n' > "$R/pkg/main.txt"
printf '# card\n\n做库存模块。\n' > "$R/card.md"
git -C "$R" add -A
git -C "$R" commit -qm init
git -C "$R" checkout -q -b dev/test

RQ="$(cd "$R" && "$COORD_BIN" --alloc 2>/dev/null)"
INT="$(cd "$R" && "$COORD_BIN" --init-base "$RQ" 2>/dev/null)"
CDIR="$(cd "$R" && "$COORD_BIN" "$RQ" 2>/dev/null)"

# ---- 假 app-server：thread/start + turn/start 建线程，thread/read 按状态文件返回 ----
STATE_FILE="$T/thread-state"; echo active > "$STATE_FILE"
CALL_LOG="$T/calls.jsonl"; : > "$CALL_LOG"
FAKE_CALL="$T/fake-app-call"
cat > "$FAKE_CALL" <<'NODE'
#!/usr/bin/env node
const fs = require("fs");
const args = process.argv.slice(2);
let method = "", paramsPath = "";
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--codex-bin") { i++; continue; }
  if (args[i].startsWith("--")) continue;
  if (!method) method = args[i]; else if (!paramsPath) paramsPath = args[i];
}
const params = paramsPath ? JSON.parse(fs.readFileSync(paramsPath, "utf8")) : {};
fs.appendFileSync(process.env.FAKE_CALL_LOG, `${JSON.stringify({ method })}\n`);
if (method === "thread/start") { console.log(JSON.stringify({ thread: { id: "thread-e2e" } })); }
else if (method === "turn/start" || method === "turn/steer") { console.log(JSON.stringify({ turn: { id: "turn-e2e" } })); }
else if (method === "thread/read") {
  const state = fs.readFileSync(process.env.FAKE_STATE_FILE, "utf8").trim();
  const active = state === "active";
  console.log(JSON.stringify({ thread: { id: "thread-e2e",
    status: { type: active ? "active" : "idle", activeFlags: [] },
    turns: [{ id: "turn-e2e", status: active ? "inProgress" : "completed",
      items: [{ type: "commandExecution", command: "pnpm test", status: "completed", exitCode: 0, aggregatedOutput: "42 passed" }] }] } }));
} else console.log("{}");
NODE
chmod +x "$FAKE_CALL"

# ---- 假 osascript：记录分屏请求，返回一个 terminal id ----
OSA_LOG="$T/osa.log"; : > "$OSA_LOG"
FAKE_OSA="$T/fake-osascript"
cat > "$FAKE_OSA" <<'SH'
#!/bin/sh
cat > /dev/null
first=1
for a in "$@"; do
  [ "$first" = 1 ] && { first=0; continue; }
  printf '%s\037' "$a" >> "$OSA_ARGV_LOG"
done
printf '\n' >> "$OSA_ARGV_LOG"
echo "FAKE-TERM-E2E"
SH
chmod +x "$FAKE_OSA"

REG="$T/registry.json"
PSTATE="$T/panel.json"
PIDF="$T/panel.pid"

export CC_FLEET_PANEL_REGISTRY="$REG"
export CC_FLEET_PANEL_STATE="$PSTATE"
export CC_FLEET_PANEL_PIDFILE="$PIDF"
# 本文件要真的走"派发即拉起面板"这条路径——用上面那个假 osascript 顶掉真实 Ghostty。
export CC_FLEET_PANEL=1
export CC_GHOSTTY_OSASCRIPT="$FAKE_OSA"
export OSA_ARGV_LOG="$OSA_LOG"
export CODEX_APP_CALL_BIN="$FAKE_CALL"
export FAKE_CALL_LOG="$CALL_LOG"
export FAKE_STATE_FILE="$STATE_FILE"

# ---------------------------------------------------------------- ① 派发
CASE="派发即拉起面板"
OUT="$(cd "$R" && CODEX_HOME="$T/codex-home" "$DISPATCH" \
  --cwd "$R/pkg" --name "↳库存@$RQ" \
  --env FLEET_ROLE=worker --env FLEET_RQ="$RQ" --env FLEET_MODULE=库存 --env FLEET_BASE_BRANCH="$INT" \
  --sid-file "$CDIR/库存.sid" --prompt-file "$R/card.md" \
  --codex-bin /usr/bin/true --pin-policy never 2>&1)"; RC=$?
assert_eq "$RC" "0" "派发应成功（实际输出: ${OUT:0:200}）"
assert_contains "$OUT" "codex app thread dispatched" "派发成功回显"
assert_contains "$(cat "$REG")" "$CDIR" "协调目录被自动登记进全局注册表"
assert_contains "$(cat "$OSA_LOG")" "cc-fleet-panel-codex-app" "自动分屏，且分屏里跑的是面板程序"
assert_contains "$(cat "$OSA_LOG")" "right" "默认右侧分屏"
assert_eq "$(node -pe 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).terminalId' "$PSTATE")" "FAKE-TERM-E2E" "记下分屏 surface id 以便收尾关闭"

# ---------------------------------------------------------------- ② 面板看得见
CASE="面板看得见 worker"
OUT="$("$PANEL" --json)"
assert_contains "$OUT" "库存" "面板列出刚派发的 worker"
assert_eq "$(echo "$OUT" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).jobs[0].group')" "working" "在跑的 worker 归入 Working"
assert_eq "$(echo "$OUT" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).jobs[0].receipt')" "0" "还没落回执"

# 跨 session：另一个仓库派发的 worker 也要出现在同一个面板里
CASE="跨 session 汇总"
R2="$T/repo2"; mkdir -p "$R2/pkg"
git -C "$R2" init -q -b main; git -C "$R2" config user.email t@t; git -C "$R2" config user.name t
printf 'root2\n' > "$R2/README.md"; printf 'pkg\n' > "$R2/pkg/main.txt"; printf '# card2\n\n做出库模块。\n' > "$R2/card.md"
git -C "$R2" add -A; git -C "$R2" commit -qm init; git -C "$R2" checkout -q -b dev/test
RQ2="$(cd "$R2" && "$COORD_BIN" --alloc 2>/dev/null)"
INT2="$(cd "$R2" && "$COORD_BIN" --init-base "$RQ2" 2>/dev/null)"
CDIR2="$(cd "$R2" && "$COORD_BIN" "$RQ2" 2>/dev/null)"
: > "$OSA_LOG"
OUT="$(cd "$R2" && CODEX_HOME="$T/codex-home" "$DISPATCH" \
  --cwd "$R2/pkg" --name "↳出库@$RQ2" \
  --env FLEET_ROLE=worker --env FLEET_RQ="$RQ2" --env FLEET_MODULE=出库 --env FLEET_BASE_BRANCH="$INT2" \
  --sid-file "$CDIR2/出库.sid" --prompt-file "$R2/card.md" \
  --codex-bin /usr/bin/true --pin-policy never 2>&1)"; RC=$?
assert_eq "$RC" "0" "第二个仓库派发应成功"
N="$("$PANEL" --json | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).jobs.length')"
assert_eq "$N" "2" "同一个面板同时看到两个仓库/两个 RQ 的 worker"

# ---------------------------------------------------------------- ③ 幂等
CASE="面板幂等"
node -e 'setTimeout(()=>{},60000)' & LIVE=$!
disown 2>/dev/null || true
echo "$LIVE" > "$PIDF"
: > "$OSA_LOG"
(cd "$R" && CODEX_HOME="$T/codex-home" "$DISPATCH" \
  --cwd "$R/pkg" --name "↳库存二批@$RQ" \
  --env FLEET_ROLE=worker --env FLEET_RQ="$RQ" --env FLEET_MODULE=库存二批 --env FLEET_BASE_BRANCH="$INT" \
  --sid-file "$CDIR/库存二批.sid" --prompt-file "$R/card.md" \
  --codex-bin /usr/bin/true --pin-policy never --join >/dev/null 2>&1)
assert_eq "$(wc -c < "$OSA_LOG" | tr -d ' ')" "0" "面板已开着时不再开第二个分屏"
kill "$LIVE" 2>/dev/null; rm -f "$PIDF"

# ---------------------------------------------------------------- ④ --no-panel
CASE="--no-panel"
: > "$OSA_LOG"; rm -f "$REG"
(cd "$R" && CODEX_HOME="$T/codex-home" "$DISPATCH" \
  --cwd "$R/pkg" --name "↳三批@$RQ" \
  --env FLEET_ROLE=worker --env FLEET_RQ="$RQ" --env FLEET_MODULE=三批 --env FLEET_BASE_BRANCH="$INT" \
  --sid-file "$CDIR/三批.sid" --prompt-file "$R/card.md" \
  --codex-bin /usr/bin/true --pin-policy never --join --no-panel >/dev/null 2>&1)
assert_eq "$(wc -c < "$OSA_LOG" | tr -d ' ')" "0" "--no-panel 时不拉起分屏"
[[ ! -f "$REG" ]] && ok || fail "--no-panel 时不写注册表"

# ---------------------------------------------------------------- ⑤ 收工自动关闭
CASE="收工自动关闭"
cat > "$REG" <<EOF
{"proto":1,"coords":[{"coord":"$CDIR","rq":"$RQ","firstSeen":1,"lastSeen":1}]}
EOF
echo active > "$STATE_FILE"
"$PANEL" --plain --interval 400 --close-grace 0 --idle-timeout 0 > "$T/panel-out.log" 2>&1 &
PANEL_PID=$!
disown 2>/dev/null || true
# 等面板起来并看到"有 worker 在跑"（自动关闭必须先见过活跃 worker，否则刚拉起就自己关了）
for _ in $(seq 1 30); do [[ -f "$PIDF" ]] && break; sleep 0.2; done
sleep 1
kill -0 "$PANEL_PID" 2>/dev/null && ok || fail "有 worker 在跑时面板不该退出"
# 全部收工：落回执 + thread 转 idle
for m in 库存 库存二批 三批; do
  printf 'result: %s 模块完成\n' "$m" > "$CDIR/$m.summary.md"
done
echo idle > "$STATE_FILE"
GONE=0
for _ in $(seq 1 40); do
  kill -0 "$PANEL_PID" 2>/dev/null || { GONE=1; break; }
  sleep 0.25
done
assert_eq "$GONE" "1" "全部 worker 收工后面板自动退出（分屏随之关闭）"
assert_contains "$(cat "$T/panel-out.log")" "全部收工" "退出时打印收工提示"
[[ ! -f "$PIDF" ]] && ok || fail "退出时清理 pidfile"
kill "$PANEL_PID" 2>/dev/null || true

# ---------------------------------------------------------------- ⑥ 需核验时不自动关
CASE="需核验时不自动关"
rm -f "$CDIR"/*.summary.md
echo idle > "$STATE_FILE"   # thread 空闲但没有回执 = 需核验
"$PANEL" --plain --interval 300 --close-grace 0 --idle-timeout 0 > "$T/panel2.log" 2>&1 &
P2=$!
disown 2>/dev/null || true
sleep 2
if kill -0 "$P2" 2>/dev/null; then ok; else fail "有 worker 停在「需核验」时面板不该自动关闭——那正是最需要你看一眼的时候"; fi
kill "$P2" 2>/dev/null || true

echo
if [[ $FAIL -eq 0 ]]; then
  echo "==== panel-codex e2e: $PASS 项全部通过 ===="
  exit 0
fi
echo "==== panel-codex e2e: $PASS 通过 / $FAIL 失败 ===="
exit 1
