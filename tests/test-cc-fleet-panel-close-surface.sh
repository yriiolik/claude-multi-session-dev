#!/usr/bin/env bash
# cc-fleet-panel-close-surface 回归测试：什么时候真关分屏、什么时候必须留着。
# 全程用假的 osascript，不会真的动 Ghostty。
#
# 这个脚本的两条安全线是重点：退出码非 0 要留现场、nonce 对不上绝不关（那可能是用户自己的终端）。
set -u

# Claude Code 之类的环境会注入 FORCE_COLOR，node -pe 会给输出套 ANSI 颜色码，
# 精确等值断言就会撞出 "期望 [0] 实得 [^[[33m0^[[39m]" 这种假失败。测试里一律关掉着色。
export FORCE_COLOR=0 NO_COLOR=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/scripts/cc-fleet-panel-close-surface"
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
: > "$OSA_STDIN_LOG"
cat > "$OSA_STDIN_LOG"
for a in "$@"; do printf '%s\037' "$a" >> "$OSA_ARGV_LOG"; done
printf '\n' >> "$OSA_ARGV_LOG"
[ "${OSA_FAIL:-0}" = "1" ] && { echo "execution error: Ghostty got an error" >&2; exit 1; }
echo "${OSA_OUT:-closed}"
SH
chmod +x "$FAKE_OSA"

STATE="$TMP/panel.json"

write_state(){  # $1=terminalId $2=nonce
  node -e '
    const fs=require("fs");
    fs.writeFileSync(process.argv[1], JSON.stringify({terminalId:process.argv[2], nonce:process.argv[3], openedAt:1}));
  ' "$STATE" "$1" "$2"
}
state_keys(){ node -pe 'Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))).length' "$STATE"; }

run(){
  : > "$ARGV_LOG"
  CC_GHOSTTY_OSASCRIPT="$FAKE_OSA" \
  OSA_ARGV_LOG="$ARGV_LOG" OSA_STDIN_LOG="$STDIN_LOG" \
  CC_FLEET_PANEL_STATE="$STATE" \
  "$BIN" "$@" 2>&1
}
osa_called(){ [[ -s "$ARGV_LOG" ]] && echo yes || echo no; }

# ---------------------------------------------------------------- 正常关闭
CASE="正常关闭"
write_state "TERM-1" "nonce-abc"
OUT="$(run --nonce nonce-abc --rc 0)"; RC=$?
assert_eq "$RC" "0" "退出 0"
assert_eq "$(osa_called)" "yes" "nonce 对得上就关"
assert_contains "$(cat "$ARGV_LOG")" "TERM-1" "关的是状态文件里记录的那块分屏"
assert_contains "$(cat "$STDIN_LOG")" "close target" "走 AppleScript close"
# 边遍历 terminals 边 close 会让集合失效（-1719 无效的索引），必须先找齐再关
assert_contains "$(cat "$STDIN_LOG")" "exit repeat" "关闭前先退出遍历，避免集合失效"
assert_eq "$(state_keys)" "0" "关掉后清空状态文件，免得下次 --close 去关一个不存在的 surface"

CASE="缺省 rc"
write_state "TERM-1" "nonce-abc"
OUT="$(run --nonce nonce-abc)"
assert_eq "$(osa_called)" "yes" "不传 --rc 视为正常退出"

# ---------------------------------------------------------------- 安全线 1：异常退出留现场
CASE="异常退出留现场"
write_state "TERM-1" "nonce-abc"
OUT="$(run --nonce nonce-abc --rc 1)"; RC=$?
assert_eq "$RC" "0" "仍然退出 0——它是命令串最后一环，非 0 只会让 Ghostty 觉得命令异常"
assert_eq "$(osa_called)" "no" "面板异常退出时不关分屏：那是唯一能看到报错的地方"
assert_contains "$OUT" "保留分屏" "明确告诉用户为什么没关"
assert_eq "$(state_keys)" "3" "没关就不动状态文件"

# ---------------------------------------------------------------- 安全线 2：nonce 归属
CASE="nonce 不匹配"
write_state "TERM-1" "nonce-abc"
OUT="$(run --nonce 别人的-nonce --rc 0)"
assert_eq "$(osa_called)" "no" "nonce 对不上绝不关——那可能是用户自己的终端"
assert_contains "$OUT" "不是本次面板" "说明为什么不关"

CASE="缺 nonce"
write_state "TERM-1" "nonce-abc"
OUT="$(run --rc 0)"
assert_eq "$(osa_called)" "no" "没传 nonce 时同样不关"

CASE="显式指定 terminal"
write_state "TERM-1" "nonce-abc"
OUT="$(run --terminal TERM-9 --rc 0)"
assert_eq "$(osa_called)" "yes" "--terminal 是调用方自己负责，跳过 nonce 校验"
assert_contains "$(cat "$ARGV_LOG")" "TERM-9" "关的是显式指定的那块"
assert_eq "$(state_keys)" "3" "显式指定时不动状态文件（它描述的是另一块分屏）"

# ---------------------------------------------------------------- 开关与兜底
CASE="全局开关"
write_state "TERM-1" "nonce-abc"
OUT="$(CC_FLEET_PANEL_CLOSE_SPLIT=0 run --nonce nonce-abc --rc 0)"
assert_eq "$(osa_called)" "no" "CC_FLEET_PANEL_CLOSE_SPLIT=0 时保持 Ghostty 原生行为"
assert_contains "$OUT" "保留分屏" "提示已跳过"

CASE="没有状态"
rm -f "$STATE"
OUT="$(run --nonce nonce-abc --rc 0)"; RC=$?
assert_eq "$RC" "0" "状态文件不存在也不报错"
assert_eq "$(osa_called)" "no" "没有分屏 id 时什么都不做"

CASE="osascript 失败"
write_state "TERM-1" "nonce-abc"
OUT="$(OSA_FAIL=1 run --nonce nonce-abc --rc 0)"; RC=$?
assert_eq "$RC" "0" "Ghostty 关不掉也只提示，不以非 0 退出"
assert_contains "$OUT" "失败" "把失败原因说出来"
assert_eq "$(state_keys)" "3" "没关成功就不清状态，兜底的 --close 还要用"

CASE="surface 已不在"
write_state "TERM-1" "nonce-abc"
OUT="$(OSA_OUT=not-found run --nonce nonce-abc --rc 0)"; RC=$?
assert_eq "$RC" "0" "分屏已经没了也算收尾成功"
assert_eq "$(state_keys)" "0" "照样清掉过期状态"

echo
if [[ $FAIL -eq 0 ]]; then
  echo "==== cc-fleet-panel-close-surface: $PASS 项全部通过 ===="
  exit 0
fi
echo "==== cc-fleet-panel-close-surface: $PASS 通过 / $FAIL 失败 ===="
exit 1
