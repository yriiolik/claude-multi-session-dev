#!/usr/bin/env bash
# 面板两项行为：
#   1. 主 session 已退出的任务组不再展示（仍有执行中 worker 的除外；判不了的一律保留；--include-gone 全显示）；
#   2. 列表每行不超过面板宽（状态词「状态未知」比「已回执」宽，曾溢出折行把顶部顶出屏幕），超出屏高时视窗跟随光标、标题常驻。
# 全程临时 HOME / 注册表 / 假 claude，不碰真实 ~/.claude。
set -u
export FORCE_COLOR=0 NO_COLOR=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/codex-app-jobs.js"
PANEL="$ROOT/scripts/cc-fleet-panel-codex-app"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0; CASE="init"
ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ [$CASE] $1"; FAIL=$((FAIL+1)); }
assert_eq(){ [[ "$1" == "$2" ]] && ok || fail "$3: 期望 [$2] 实得 [$1]"; }
assert_contains(){ [[ "$1" == *"$2"* ]] && ok || fail "$3: 找不到 [$2]"; }
assert_not_contains(){ [[ "$1" != *"$2"* ]] && ok || fail "$3: 不应出现 [$2]"; }
jq_(){ node -pe 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); eval(process.argv[1])' "$1"; }
export HOME="$T/home" CC_FLEET_PANEL_REGISTRY="$T/coords.json" CC_FLEET_PANEL_STATE="$T/panel.json" CC_FLEET_PANEL_PIDFILE="$T/panel.pid"
unset CC_FLEET_PANEL_INCLUDE_GONE CC_FLEET_PANEL_HEIGHT CC_FLEET_PANEL_WIDTH
SESS="$HOME/.claude/sessions"
mkdir -p "$SESS"

# 一个必然活着的 pid（本脚本）与一个必然不存在的 pid
LIVE_PID=$$
DEAD_PID=$(node -e 'let p=4000000; while(true){try{process.kill(p,0);p++}catch(e){if(e.code==="ESRCH"){console.log(p);break}p++}}')
UUID_LIVE="11111111-2222-4333-8444-555555555555"
UUID_GONE="99999999-2222-4333-8444-555555555555"
UUID_STALE="77777777-2222-4333-8444-555555555555"
printf '{"pid":%s,"sessionId":"%s","name":"活着的主 session"}\n' "$LIVE_PID" "$UUID_LIVE" > "$SESS/$LIVE_PID.json"
printf '{"pid":%s,"sessionId":"%s","name":"崩溃残留"}\n' "$DEAD_PID" "$UUID_STALE" > "$SESS/$DEAD_PID.json"

F="$T/repo/.git/fleet"
mk(){ # mk <rq> <owner-json|-> ; 建 v2 协调目录并登记
  mkdir -p "$F/$1/v2"
  if [[ "$2" != "-" ]]; then printf '{"version":2,"rq":"%s","owner":%s}\n' "$1" "$2" > "$F/$1/fleet.json"; fi
  node -e 'require(process.argv[1]).registerCoord(process.argv[2], process.argv[3])' "$LIB" "$F/$1" "$1"
}
owner(){ printf '{"host":"%s","id":"%s","identitySource":"%s"}' "$1" "$2" "$3"; }
gone(){ node -e 'console.log(require(process.argv[1]).ownerGone(process.argv[2]))' "$LIB" "$F/$1"; }

CASE="主 session 存活判定"
mk RQ-live "$(owner claude-code "$UUID_LIVE" session)"
mk RQ-gone "$(owner claude-code "$UUID_GONE" session)"
mk RQ-stale "$(owner claude-code "$UUID_STALE" session)"
mk RQ-fake "$(owner claude-code controller-bg-16a707c5 session)"
mk RQ-gen "$(owner claude-code controller-abc generated-controller)"
mk RQ-codex "$(owner codex-app 019a0000-0000-4000-8000-000000000000 session)"
mk RQ-meta-dead -
printf 'owner_pid=%s\nowner_session_id=x\n' "$DEAD_PID" > "$F/RQ-meta-dead/owner.meta"
mk RQ-meta-live -
printf 'owner_pid=%s\nowner_session_id=%s\n' "$LIVE_PID" "$UUID_LIVE" > "$F/RQ-meta-live/owner.meta"
mk RQ-meta-reused -
printf 'owner_pid=%s\nowner_session_id=another-session\n' "$LIVE_PID" > "$F/RQ-meta-reused/owner.meta"
mk RQ-none -
assert_eq "$(gone RQ-live)" "false" "UUID 会话活着"
assert_eq "$(gone RQ-gone)" "true" "UUID 会话注册表里找不到"
assert_eq "$(gone RQ-stale)" "true" "注册文件残留但进程已死"
assert_eq "$(gone RQ-fake)" "false" "非 UUID 的手填 id 判不了，保留"
assert_eq "$(gone RQ-gen)" "false" "生成的 controller id 判不了，保留"
assert_eq "$(gone RQ-codex)" "false" "Codex 主端判不了，保留"
assert_eq "$(gone RQ-meta-dead)" "true" "owner.meta 的 pid 已退出"
assert_eq "$(gone RQ-meta-live)" "false" "owner.meta 的 pid 活着且会话一致"
assert_eq "$(gone RQ-meta-reused)" "true" "owner.meta 的 pid 已被别的会话复用"
assert_eq "$(gone RQ-none)" "false" "没有归属记录，保留"

CASE="隐藏主 session 已退出的任务组"
NOW=$(date +%s)
job(){ # job <rq> <module> <shortId> <sessionId>
  printf '{"version":2,"module":"%s","backend":"claude","transport":"claude-bg","state":"running","name":"↳%s@%s","startedAt":%s,"shortId":"%s","sessionId":"%s"}\n' \
    "$2" "$2" "$1" "$NOW" "$3" "$4" > "$F/$1/v2/$2.json"
}
job RQ-live done-a aa000001 sid-a
job RQ-gone done-b aa000002 sid-b
job RQ-meta-dead run-c aa000003 sid-c
job RQ-fake lost-d aa000004 sid-d
FAKE_CLAUDE="$T/claude"
AGENTS='[{"id":"aa000001","sessionId":"sid-a","state":"done"},{"id":"aa000002","sessionId":"sid-b","state":"done"},{"id":"aa000003","sessionId":"sid-c","state":"working"}]'
printf '#!/bin/sh\n[ "$1" = agents ] && { cat %s; exit 0; }\necho fake\n' "$T/agents.json" > "$FAKE_CLAUDE"; chmod +x "$FAKE_CLAUDE"
printf '%s\n' "$AGENTS" > "$T/agents.json"
export CLAUDE_CLI_PATH="$FAKE_CLAUDE" CLAUDE_CONFIG_DIR="$T/claude-home"
P="$("$PANEL" --json --no-start-app-server --no-discover)"
assert_eq "$(printf '%s' "$P" | jq_ 'j.groups.map(g=>g.rq).sort().join()')" "RQ-fake,RQ-live,RQ-meta-dead" "已退出且无在跑 worker 的组隐藏，在跑的保留"
assert_eq "$(printf '%s' "$P" | jq_ 'j.hiddenGone')" "1" "隐藏计数"
assert_eq "$(printf '%s' "$P" | jq_ 'j.groups.find(g=>g.rq==="RQ-meta-dead").ownerGone')" "true" "保留的孤儿组标 ownerGone"
OUT="$("$PANEL" --once --plain --no-start-app-server --no-discover)"
assert_contains "$OUT" "已隐藏 1 个主 session 已退出的任务组" "列表提示隐藏数"
P="$("$PANEL" --json --no-start-app-server --no-discover --include-gone)"
assert_eq "$(printf '%s' "$P" | jq_ 'j.groups.length+"|"+j.hiddenGone')" "4|0" "--include-gone 全部展示"
P="$(CC_FLEET_PANEL_INCLUDE_GONE=1 "$PANEL" --json --no-start-app-server --no-discover)"
assert_eq "$(printf '%s' "$P" | jq_ 'j.groups.length')" "4" "CC_FLEET_PANEL_INCLUDE_GONE=1 同效"
printf '[]\n' > "$T/agents.json"   # 孤儿 worker 也收工了（且从 claude agents 里被删），组随之隐藏
P="$("$PANEL" --json --no-start-app-server --no-discover)"
assert_eq "$(printf '%s' "$P" | jq_ 'j.groups.map(g=>g.rq).sort().join()+"|"+j.hiddenGone')" "RQ-fake,RQ-live|2" "孤儿 worker 收工后组隐藏"

CASE="窄屏每行不溢出（含「状态未知」行）"
for i in $(seq 1 12); do job RQ-fake "m$i" "bb0000$i" "sid-m$i"; done
WIDTH_CHECK='
const w = (s) => { let n = 0; for (const ch of s) { const c = ch.codePointAt(0); n += (c >= 0x2e80 && c <= 0xa4cf) || (c >= 0xff00 && c <= 0xff60) || (c >= 0x1f300 && c <= 0x1f9ff) ? 2 : 1; } return n; };
const max = Number(process.argv[1]);
const lines = require("fs").readFileSync(0, "utf8").replace(/\n$/, "").split("\n");
const bad = lines.filter((l) => w(l) > max);
console.log(bad.length ? bad.join("\n") : "OK");'
for W in 40 56 80; do
  OUT="$(CC_FLEET_PANEL_WIDTH=$W "$PANEL" --once --plain --no-start-app-server --no-discover)"
  assert_contains "$OUT" "状态未知" "宽 $W 有状态未知行"
  assert_eq "$(printf '%s\n' "$OUT" | node -e "$WIDTH_CHECK" "$W")" "OK" "宽 $W 无超宽行"
done
# 带颜色时也不能超宽（去掉 ANSI 后量），且截断处补了复位码
OUT="$(CC_FLEET_PANEL_WIDTH=40 "$PANEL" --once --no-start-app-server --no-discover | sed $'s/\x1b\\[[0-9;?]*[A-Za-z]//g')"
assert_eq "$(printf '%s\n' "$OUT" | node -e "$WIDTH_CHECK" 40)" "OK" "彩色输出去 ANSI 后无超宽行"

CASE="超出屏高时视窗跟随光标、标题常驻"
FULL="$(CC_FLEET_PANEL_WIDTH=80 "$PANEL" --once --plain --no-start-app-server --no-discover)"
TOTAL=$(printf '%s\n' "$FULL" | wc -l | tr -d ' ')
[[ $TOTAL -gt 12 ]] && ok || fail "构造的列表应超过 12 行，实得 $TOTAL"
LAST="$(printf '%s' "$(CC_FLEET_PANEL_WIDTH=80 "$PANEL" --json --no-start-app-server --no-discover)" | jq_ 'j.jobs[j.jobs.length-1].module')"
FIRST="$(printf '%s' "$(CC_FLEET_PANEL_WIDTH=80 "$PANEL" --json --no-start-app-server --no-discover)" | jq_ 'j.jobs[0].module')"
OUT="$(CC_FLEET_PANEL_WIDTH=80 CC_FLEET_PANEL_HEIGHT=12 "$PANEL" --once --plain --no-start-app-server --no-discover --keys end)"
assert_eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "12" "只输出屏高行数"
assert_contains "$(printf '%s\n' "$OUT" | head -1)" "Claude Fleet · 全局" "总标题常驻首行"
assert_contains "$OUT" "↳$LAST " "光标在末行时末行可见"
assert_not_contains "$OUT" "↳$FIRST " "首个 worker 被滚出视窗"
OUT="$(CC_FLEET_PANEL_WIDTH=80 CC_FLEET_PANEL_HEIGHT=12 "$PANEL" --once --plain --no-start-app-server --no-discover)"
assert_contains "$OUT" "↳$FIRST " "光标在首行时首个 worker 可见"
assert_eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "12" "光标在首行也不超过屏高"

echo "panel-owner-gone-overflow: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
