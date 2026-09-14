#!/usr/bin/env bash
# 多个任务组并行上同一块面板：注册表并发登记不丢条目（与剔除失效条目交错）、自动发现已知仓库里漏登记的近期 v2 任务组、
# Codex + Claude 混合时标题报数且行内标后端、组标题按 fleet.json 的主 session id 反查实时名字、登记脚本参数顺序无关。
# 全程临时注册表 / 假 app-server / 假 claude，不碰真实 ~/.claude。
set -u
export FORCE_COLOR=0 NO_COLOR=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/codex-app-jobs.js"
PANEL="$ROOT/scripts/cc-fleet-panel-codex-app"
REGISTER="$ROOT/scripts/cc-fleet-panel-register"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0; CASE="init"
ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ [$CASE] $1"; FAIL=$((FAIL+1)); }
assert_eq(){ [[ "$1" == "$2" ]] && ok || fail "$3: 期望 [$2] 实得 [$1]"; }
assert_contains(){ [[ "$1" == *"$2"* ]] && ok || fail "$3: 找不到 [$2]"; }
assert_not_contains(){ [[ "$1" != *"$2"* ]] && ok || fail "$3: 不应出现 [$2]"; }
jq_(){ node -pe 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); eval(process.argv[1])' "$1"; }
export CC_FLEET_PANEL_REGISTRY="$T/coords.json" CC_FLEET_PANEL_STATE="$T/panel.json" CC_FLEET_PANEL_PIDFILE="$T/panel.pid"

CASE="并发登记与剔除交错不丢条目"
F="$T/repo/.git/fleet"
for i in $(seq 1 16); do mkdir -p "$F/RQ-c$i"; done
pids=()
for i in $(seq 1 16); do
  node -e '
    const lib = require(process.argv[1]);
    lib.registerCoord(process.argv[2], process.argv[3]);
    lib.registerCoord(process.argv[4], "RQ-gone");   // 已消失的目录：让并发的 listCoords 反复触发剔除写
  ' "$LIB" "$F/RQ-c$i" "RQ-c$i" "$T/gone-$i" &
  pids+=($!)
done
for i in $(seq 1 6); do
  node -e 'const lib = require(process.argv[1]); for (let k = 0; k < 40; k++) lib.listCoords();' "$LIB" &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || fail "并发进程 $p 异常退出"; done
N="$(node -e 'const l=require(process.argv[1]).listCoords();console.log(l.filter(c=>/RQ-c\d+$/.test(c.rq)).length+"|"+l.filter(c=>c.rq==="RQ-gone").length)' "$LIB")"
assert_eq "$N" "16|0" "16 个任务组全部在册，失效条目剔净"
assert_eq "$(ls -d "$T"/coords.json.lock 2>/dev/null | wc -l | tr -d ' ')" "0" "锁已释放"

CASE="陈旧锁回收"
mkdir "$T/coords.json.lock"; touch -t 202001010000 "$T/coords.json.lock"
node -e 'require(process.argv[1]).registerCoord(process.argv[2], "RQ-c1")' "$LIB" "$F/RQ-c1"
assert_eq "$?" "0" "持锁进程崩溃留下的锁超时后回收"

CASE="自动发现漏登记的近期任务组"
R2="$T/qzc/.git/fleet"
GEN_OWNER='{"host":"claude-code","id":"x","identitySource":"generated-controller"}'
mk_v2(){ local owner="${2:-$GEN_OWNER}"; mkdir -p "$R2/$1/v2"; printf '{"version":2,"rq":"%s","repo":"%s/qzc","owner":%s}\n' "$1" "$T" "$owner" > "$R2/$1/fleet.json"; }
mk_v2 RQ-reg; mk_v2 RQ-miss; mk_v2 RQ-old
touch -t 202001010000 "$R2/RQ-old/v2"
mkdir -p "$R2/RQ-legacy"                      # 无 fleet.json 的旧式协调目录不收
mkdir -p "$T/other/.git/fleet/RQ-foreign/v2"   # 注册表里没出现过的仓库不扫
printf '{"version":2,"rq":"RQ-foreign"}\n' > "$T/other/.git/fleet/RQ-foreign/fleet.json"
node -e 'require(process.argv[1]).registerCoord(process.argv[2], "RQ-reg")' "$LIB" "$R2/RQ-reg"
D="$(node -e '
  const lib = require(process.argv[1]);
  const since = Math.floor(Date.now() / 1000) - 24 * 3600;
  console.log(lib.discoverCoords(lib.listCoords(), { sinceSec: since }).map((c) => c.rq).filter((r) => !/^RQ-c/.test(r)).sort().join(","));
' "$LIB")"
assert_eq "$D" "RQ-miss,RQ-reg" "只收已知仓库里时间窗内有名册写入的 v2 任务组"

CASE="混合后端同屏"
# RQ-reg：Codex worker；RQ-miss（未登记）：Claude worker，主 session 身份记在 fleet.json
cat > "$R2/RQ-reg/v2/api.json" <<J
{"version":2,"module":"api","backend":"codex","transport":"app-server","state":"running","name":"↳api@RQ-reg","startedAt":$(date +%s),"sessionId":"thread-api","turnId":"turn-1"}
J
mk_v2 RQ-miss '{"host":"claude-code","id":"sess-second","identitySource":"session"}'
cat > "$R2/RQ-miss/v2/ui.json" <<J
{"version":2,"module":"ui","backend":"claude","transport":"claude-bg","state":"running","name":"↳ui@RQ-miss","startedAt":$(date +%s),"shortId":"c0ffee01","sessionId":"sid-ui"}
J
FAKE_CALL="$T/app-call"
printf '#!/bin/sh\necho %s\n' "'{\"thread\":{\"id\":\"thread-api\",\"status\":{\"type\":\"active\"},\"turns\":[{\"id\":\"turn-1\",\"status\":\"inProgress\"}]}}'" > "$FAKE_CALL"; chmod +x "$FAKE_CALL"
FAKE_CLAUDE="$T/claude"
printf '#!/bin/sh\n[ "$1" = agents ] && { echo %s; exit 0; }\necho fake\n' "'[{\"id\":\"c0ffee01\",\"sessionId\":\"sid-ui\",\"state\":\"working\"}]'" > "$FAKE_CLAUDE"; chmod +x "$FAKE_CLAUDE"
mkdir -p "$T/home/.claude/sessions"
printf '{"pid":4242,"sessionId":"sess-second","name":"第二个编排主 session","cwd":"%s/qzc"}\n' "$T" > "$T/home/.claude/sessions/4242.json"
export CODEX_APP_CALL_BIN="$FAKE_CALL" CLAUDE_CLI_PATH="$FAKE_CLAUDE" CLAUDE_CONFIG_DIR="$T/claude-home"
P="$(HOME="$T/home" "$PANEL" --json --no-start-app-server)"
assert_eq "$(printf '%s' "$P" | jq_ 'j.groups.map(g=>g.rq).filter(r=>!/^RQ-c/.test(r)).sort().join()')" "RQ-miss,RQ-reg" "登记的与自动发现的任务组同屏"
assert_eq "$(printf '%s' "$P" | jq_ 'j.title')" "Fleet" "混合后端标题"
assert_eq "$(printf '%s' "$P" | jq_ 'JSON.stringify(j.backends)')" '{"claude":1,"codex":1}' "按后端报数"
assert_eq "$(printf '%s' "$P" | jq_ 'j.groups.find(g=>g.rq==="RQ-miss").title')" "第二个编排主 session" "组标题按 fleet.json 主 session id 取实时名字"
assert_eq "$(printf '%s' "$P" | jq_ 'j.groups.find(g=>g.rq==="RQ-miss").ownerSource')" "fleet" "归属来源标 fleet"
P="$(HOME="$T/home" "$PANEL" --json --no-start-app-server --no-discover)"
assert_eq "$(printf '%s' "$P" | jq_ 'j.groups.map(g=>g.rq).filter(r=>!/^RQ-c/.test(r)).join()')" "RQ-reg" "--no-discover 只看注册表"
OUT="$(HOME="$T/home" "$PANEL" --once --plain --no-start-app-server)"
assert_contains "$OUT" "Fleet · 全局 · 2 任务组 · 2 worker · Claude 1 · Codex 1" "列表标题报数"
assert_contains "$(printf '%s\n' "$OUT" | grep '↳api')" "Codex" "Codex 行标后端"
assert_contains "$(printf '%s\n' "$OUT" | grep '↳ui')" "Claude" "Claude 行标后端"
rm -f "$R2/RQ-miss/v2/ui.json"; touch "$R2/RQ-miss/v2"
OUT="$(HOME="$T/home" "$PANEL" --once --plain --no-start-app-server)"
assert_contains "$OUT" "Codex Fleet · 全局" "纯 Codex 仍叫 Codex Fleet"
# detail 列本身可能含「Codex App thread」，按列位置判：名字列后面紧跟的是状态词，不是后端名
assert_eq "$(printf '%s\n' "$OUT" | grep -cE '↳api +(Codex|Claude) +执行中')" "0" "单一后端不加后端列"

CASE="登记脚本参数顺序无关"
mkdir -p "$F/RQ-flag"
OUT="$(node "$REGISTER" --no-owner "$F/RQ-flag" RQ-flag)"
assert_contains "$OUT" "$F/RQ-flag (rq=RQ-flag)" "--no-owner 放前面也按位置参数取目录"
assert_eq "$([[ -e "$F/RQ-flag/owner.meta" ]] && echo yes || echo no)" "no" "--no-owner 不写归属"
assert_contains "$(node "$REGISTER" --list)" "RQ-flag" "--list 列出"
node "$REGISTER" >/dev/null 2>&1; assert_eq "$?" "5" "缺参数退出 5"

echo "panel-multi-rq: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
