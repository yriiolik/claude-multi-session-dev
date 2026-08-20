#!/usr/bin/env bash
# cc-fleet-panel-open 回归测试：分屏拉起的幂等、参数传递、失败不阻断派发、关闭路径。
# 全程用假的 osascript，不会真的动 Ghostty。
set -u

# Claude Code 之类的环境会注入 FORCE_COLOR，node -pe 会给输出套 ANSI 颜色码，
# 精确等值断言就会撞出 "期望 [0] 实得 [^[[33m0^[[39m]" 这种假失败。测试里一律关掉着色。
export FORCE_COLOR=0 NO_COLOR=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPEN="$ROOT/scripts/cc-fleet-panel-open"
PASS=0
FAIL=0
CASE="init"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ [$CASE] $1"; FAIL=$((FAIL+1)); }
assert_eq(){ [[ "$1" == "$2" ]] && ok || fail "$3: 期望 [$2] 实得 [$1]"; }
assert_contains(){ [[ "$1" == *"$2"* ]] && ok || fail "$3: 找不到 [$2]"; }
assert_not_contains(){ [[ "$1" != *"$2"* ]] && ok || fail "$3: 不该出现 [$2]"; }

ARGV_LOG="$TMP/osa-argv.log"
STDIN_LOG="$TMP/osa-stdin.log"
FAKE_OSA="$TMP/fake-osascript"
cat > "$FAKE_OSA" <<'SH'
#!/bin/sh
# 记录 argv（每次一行，字段用 \x1f 分隔）与 AppleScript 正文，然后返回一个假的 terminal id
: > "$OSA_STDIN_LOG"
cat > "$OSA_STDIN_LOG"
first=1
for a in "$@"; do
  [ "$first" = 1 ] && { first=0; continue; }   # 跳过 "-"
  printf '%s\037' "$a" >> "$OSA_ARGV_LOG"
done
printf '\n' >> "$OSA_ARGV_LOG"
[ "${OSA_FAIL:-0}" = "1" ] && { echo "execution error: Ghostty got an error" >&2; exit 1; }
echo "FAKE-TERM-0001"
SH
chmod +x "$FAKE_OSA"

REG="$TMP/registry.json"
STATE="$TMP/panel.json"
PIDF="$TMP/panel.pid"

run_open(){
  : > "$ARGV_LOG"
  # run-all.sh 会全局 export CC_FLEET_PANEL=0（防止测试去动真实 Ghostty）。本文件测的就是拉起逻辑本身，
  # 所以这里默认顶回 1；要测"全局开关"那条用例时用 TEST_PANEL_FLAG=0 覆盖。
  CC_FLEET_PANEL="${TEST_PANEL_FLAG:-1}" \
  CC_GHOSTTY_OSASCRIPT="$FAKE_OSA" \
  OSA_ARGV_LOG="$ARGV_LOG" OSA_STDIN_LOG="$STDIN_LOG" \
  CC_FLEET_PANEL_REGISTRY="$REG" \
  CC_FLEET_PANEL_STATE="$STATE" \
  CC_FLEET_PANEL_PIDFILE="$PIDF" \
  "$OPEN" "$@" 2>&1
}

argv_field(){ awk -F'\037' -v n="$1" 'NR==1{print $n}' "$ARGV_LOG"; }

# ---------------------------------------------------------------- 正常拉起
CASE="正常拉起"
rm -f "$STATE" "$PIDF"
OUT="$(run_open)"
assert_contains "$OUT" "已在 Ghostty right 侧分屏拉起" "提示分屏已拉起"
assert_contains "$(cat "$STDIN_LOG")" "split src direction right" "AppleScript 用 split 而不是模拟按键"
assert_contains "$(argv_field 1)" "cc-fleet-panel-codex-app" "命令指向面板脚本"
# 分屏的 PATH 是 Ghostty 的登录环境，pyenv/nvm 的 node 不在里面。靠 shebang 会 env: node not found，
# 分屏一闪而过——图形界面上只会表现为"面板没开出来"，极难排查。
assert_contains "$(argv_field 1)" "\"$(node -pe 'process.execPath')\" \"" "用绝对 node 路径启动，不依赖分屏的 PATH"
assert_contains "$(cat "$ARGV_LOG")" "PATH=" "PATH 带进分屏（面板要 spawn cc-codex-app-call 和 git）"
assert_eq "$(argv_field 3)" "right" "方向参数正确"
assert_eq "$(argv_field 4)" "1" "默认把焦点还给原终端，不打断正在打字的 session"
assert_eq "$(node -pe 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).terminalId' "$STATE")" "FAKE-TERM-0001" "记录新 surface 的 id"

CASE="分屏比例"
# Ghostty 的 split 固定对半；比例由面板自己收敛，open 只负责把目标值传下去
assert_contains "$(argv_field 1)" '"--target-ratio" "0.33"' "默认把面板收窄到 1/3 而不是对半"
OUT="$(run_open --ratio 0.25)"
assert_contains "$(argv_field 1)" '"--target-ratio" "0.25"' "--ratio 生效"
OUT="$(CC_FLEET_PANEL_RATIO=0.4 run_open)"
assert_contains "$(argv_field 1)" '"--target-ratio" "0.4"' "CC_FLEET_PANEL_RATIO 生效"
OUT="$(run_open --ratio 0)"
assert_not_contains "$(argv_field 1)" "--target-ratio" "--ratio 0 时保持 Ghostty 默认的对半"

CASE="方向与焦点"
OUT="$(run_open --direction down --focus)"
assert_eq "$(argv_field 3)" "down" "--direction 生效"
assert_eq "$(argv_field 4)" "0" "--focus 把焦点留在面板"

CASE="环境透传"
# 分屏里的进程继承的是 Ghostty 的登录环境而不是本进程的，Codex 相关变量必须显式带过去
OUT="$(CODEX_HOME="$TMP/my-codex-home" run_open)"
# envBlob 内部用换行分隔，argv_field 的按行解析看不全，直接在整份 argv 记录里找
assert_contains "$(cat "$ARGV_LOG")" "CODEX_HOME=$TMP/my-codex-home" "CODEX_HOME 带进分屏"
assert_contains "$(cat "$ARGV_LOG")" "CC_FLEET_PANEL_REGISTRY=$REG" "注册表路径带进分屏"
assert_contains "$(cat "$STDIN_LOG")" "set environment variables of cfg" "AppleScript 真的把环境写进 surface 配置"

CASE="参数透传"
OUT="$(run_open -- --rq RQ-2026-0813-001 --no-auto-close)"
assert_contains "$(argv_field 1)" '"--rq" "RQ-2026-0813-001"' "-- 之后的参数原样传给面板且各自加引号"
assert_contains "$(argv_field 1)" '"--no-auto-close"' "多个透传参数都在"

# ---------------------------------------------------------------- 分屏收尾
# Ghostty 1.3.1 不会在命令退出后收掉 split，只会停在 "Process exited. Press any key to close
# the terminal."。所以命令串尾部挂一个 close-surface helper 主动关。以下断言全部来自实测，
# 换掉任何一处引号形式都会让收尾静默失效（而分屏照样开得出来，故障完全不可见）。
CASE="分屏收尾"
rm -f "$STATE" "$PIDF"
OUT="$(run_open)"
CMD_FIELD="$(argv_field 1)"
assert_contains "$CMD_FIELD" "/bin/sh -c '" "串联要生效必须显式包一层 sh —— Ghostty 的 command 不经过 shell"
assert_contains "$CMD_FIELD" "cc-fleet-panel-close-surface" "命令串尾部挂上关分屏的 helper"
# `$?` 必须落在**单引号**里：Ghostty 会展开双引号中的变量，写在外面会被它提前吃成 0，
# helper 便永远看不到面板的真实退出码，异常退出的分屏也会被误关。
assert_contains "$CMD_FIELD" '"--rc" "$?"' 'helper 拿到的是面板的真实退出码（$? 留在单引号内）'
assert_contains "$CMD_FIELD" '"; ' "用 ; 而不是 && —— 面板异常退出时也要走到收尾这一步"
NONCE_STATE="$(node -pe 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).nonce || ""' "$STATE")"
[[ -n "$NONCE_STATE" ]] && ok || fail "状态文件要记下 nonce（helper 的归属凭证）"
assert_contains "$CMD_FIELD" "\"--nonce\" \"$NONCE_STATE\"" "命令串里的 nonce 与状态文件一致，helper 才认得出这块分屏是本次开的"

CASE="分屏收尾开关"
OUT="$(run_open --no-close-split)"
assert_not_contains "$(argv_field 1)" "cc-fleet-panel-close-surface" "--no-close-split 时不挂 helper"
assert_eq "$(node -pe 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).nonce' "$STATE")" "" "不自动关时不写 nonce（免得后来的 helper 误认）"
OUT="$(CC_FLEET_PANEL_CLOSE_SPLIT=0 run_open)"
assert_not_contains "$(argv_field 1)" "cc-fleet-panel-close-surface" "CC_FLEET_PANEL_CLOSE_SPLIT=0 时不挂 helper"
assert_contains "$(cat "$ARGV_LOG")" "CC_FLEET_PANEL_CLOSE_SPLIT=0" "开关本身也带进分屏（手动跑的面板同样不自动关）"

# ---------------------------------------------------------------- 幂等
CASE="幂等"
# 造一个"活着的面板进程"：用一个真实存在的长命进程 pid
node -e 'setTimeout(()=>{},60000)' & LIVE=$!
disown 2>/dev/null || true
echo "$LIVE" > "$PIDF"
OUT="$(run_open)"
kill "$LIVE" 2>/dev/null
assert_contains "$OUT" "已在运行" "面板活着时提示复用"
assert_eq "$(wc -l < "$ARGV_LOG" | tr -d ' ')" "0" "面板活着时不再调 osascript（不会开出第二个分屏）"

CASE="陈旧 pidfile"
echo "999999" > "$PIDF"   # 几乎不可能存在的 pid
OUT="$(run_open)"
assert_contains "$OUT" "已在 Ghostty" "pid 已死时照常拉起，不被陈旧 pidfile 卡住"
rm -f "$PIDF"

# ---------------------------------------------------------------- 开关
CASE="全局开关"
OUT="$(TEST_PANEL_FLAG=0 run_open)"
assert_contains "$OUT" "跳过拉起" "CC_FLEET_PANEL=0 时跳过"
assert_eq "$(wc -l < "$ARGV_LOG" | tr -d ' ')" "0" "跳过时不调 osascript"

# ---------------------------------------------------------------- 失败不阻断
CASE="失败不阻断"
rm -f "$STATE" "$PIDF"
OUT="$(OSA_FAIL=1 run_open)"; RC=$?
assert_eq "$RC" "0" "Ghostty 不可用时默认退出 0——面板开不出来绝不能让派发失败"
assert_contains "$OUT" "手动运行" "给出手动兜底命令"
OSA_FAIL=1 run_open --strict >/dev/null 2>&1; RC=$?
assert_eq "$RC" "4" "--strict 时以非 0 退出"

# ---------------------------------------------------------------- 关闭
CASE="关闭"
rm -f "$STATE" "$PIDF"
run_open >/dev/null
node -e 'setTimeout(()=>{},60000)' & LIVE=$!
disown 2>/dev/null || true
echo "$LIVE" > "$PIDF"
OUT="$(run_open --close)"
assert_contains "$OUT" "已请求关闭面板进程" "先 SIGTERM 面板进程"
assert_contains "$(argv_field 1)" "FAKE-TERM-0001" "再兜底关掉记录在案的 surface"
assert_contains "$(cat "$STDIN_LOG")" "close target" "关闭走 AppleScript close"
# 边遍历 terminals 边 close 会让集合失效（-1719 无效的索引），必须先找齐再关
assert_contains "$(cat "$STDIN_LOG")" "exit repeat" "关闭前先退出遍历，避免集合失效"
sleep 0.3 2>/dev/null || true
kill -0 "$LIVE" 2>/dev/null && { fail "面板进程应已被终止"; kill "$LIVE" 2>/dev/null; } || ok
assert_eq "$(node -pe 'Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))).length' "$STATE")" "0" "关闭后清空状态文件"

CASE="状态查询"
OUT="$(run_open --status)"
assert_contains "$OUT" "pidFile" "--status 输出 pidfile 路径"

echo
if [[ $FAIL -eq 0 ]]; then
  echo "==== cc-fleet-panel-open: $PASS 项全部通过 ===="
  exit 0
fi
echo "==== cc-fleet-panel-open: $PASS 通过 / $FAIL 失败 ===="
exit 1
