#!/usr/bin/env bash
# cc-fleet-e2e-lock 单测（确定性，无需 daemon）：抢占 / 互斥 / 重入 / 超时 / 过期回收 / 只放自己的锁。
# 测试铁律：断言只增强不削弱；失败一律是脚本 bug，改脚本不改断言。
set -u

LOCK="$(cd "$(dirname "$0")/.." && pwd)/scripts/cc-fleet-e2e-lock"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || no "$1 （期望 [$3] 实得 [$2]）"; }

C="$TMP/coord"; mkdir -p "$C"

echo "[1] 空闲时抢锁成功，status 显示持有者"
"$LOCK" acquire "$C" m1 >/dev/null; eq "acquire rc" "$?" 0
[ -d "$C/e2e.lock" ] && ok "锁目录已建" || no "锁目录未建"
eq "owner 文件记模块名" "$(cut -d' ' -f1 "$C/e2e.lock/owner")" "m1"
"$LOCK" status "$C" | grep -q '🔒 e2e 锁被 m1 持有' && ok "status 显示 m1 持有" || no "status 未显示持有者"

echo "[2] 互斥：别的模块抢不到 → 等到超时 exit 1，锁仍归 m1"
OUT="$("$LOCK" acquire "$C" m2 --wait 0 --poll 0 2>&1)"; eq "m2 acquire rc=1" "$?" 1
printf '%s' "$OUT" | grep -q '仍被 m1 持有' && ok "报错指出持有者" || no "报错未指出持有者: $OUT"
eq "锁仍归 m1" "$(cut -d' ' -f1 "$C/e2e.lock/owner")" "m1"

echo "[3] 重入：m1 再 acquire 直接成功"
"$LOCK" acquire "$C" m1 --wait 0 --poll 0 | grep -q '重入' && ok "重入成功" || no "重入失败"

echo "[4] 只放自己的锁：m2 release → exit 3 且锁还在；m1 release → 释放"
"$LOCK" release "$C" m2 >/dev/null 2>&1; eq "m2 release rc=3" "$?" 3
[ -d "$C/e2e.lock" ] && ok "锁未被误放" || no "锁被 m2 误放"
"$LOCK" release "$C" m1 >/dev/null; eq "m1 release rc=0" "$?" 0
[ ! -d "$C/e2e.lock" ] && ok "锁已释放" || no "锁未释放"
"$LOCK" release "$C" m1 | grep -q '本就空闲' && ok "重复 release 幂等" || no "重复 release 非幂等"

echo "[5] 过期回收：持有时间 ≥ stale 的锁被后来者强制回收"
mkdir "$C/e2e.lock"; printf 'dead %s\n' "$(( $(date +%s) - 10000 ))" > "$C/e2e.lock/owner"
OUT="$("$LOCK" acquire "$C" m3 --wait 0 --poll 0 --stale 5400 2>&1)"; eq "m3 回收后抢到 rc=0" "$?" 0
printf '%s' "$OUT" | grep -q '强制回收' && ok "提示强制回收" || no "未提示回收: $OUT"
eq "锁归 m3" "$(cut -d' ' -f1 "$C/e2e.lock/owner")" "m3"
"$LOCK" release "$C" m3 >/dev/null

echo "[6] 未过期的锁不被回收（stale 很大）"
mkdir "$C/e2e.lock"; printf 'busy %s\n' "$(( $(date +%s) - 100 ))" > "$C/e2e.lock/owner"
"$LOCK" acquire "$C" m4 --wait 0 --poll 0 --stale 5400 >/dev/null 2>&1; eq "m4 抢不到 rc=1" "$?" 1
eq "锁仍归 busy" "$(cut -d' ' -f1 "$C/e2e.lock/owner")" "busy"
rm -rf "$C/e2e.lock"

echo "[7] 用法错：缺 COORD / 未知子命令 → exit 2"
"$LOCK" acquire "$TMP/nope" m1 >/dev/null 2>&1; eq "COORD 不存在 rc=2" "$?" 2
"$LOCK" frob "$C" >/dev/null 2>&1; eq "未知子命令 rc=2" "$?" 2

echo
echo "==== cc-fleet-e2e-lock 测试：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] && echo "✅ 全绿" || { echo "❌ 有失败"; exit 1; }
