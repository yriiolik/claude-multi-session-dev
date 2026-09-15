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
"$LOCK" acquire "$C" m1 --mode both >/dev/null 2>&1; eq "非法 --mode rc=2" "$?" 2

# ---- 共享模式：造一个「主检出 + worktree」的仓库，项目 proj/ 声明了 .e2e-isolated
REPO="$TMP/repo"; WT="$TMP/wt"; S="$TMP/coord-shared"; mkdir -p "$REPO/proj/schema" "$S"
git -C "$REPO" init -q
printf '# 声明\nschema/schema.prisma  # 共享生成产物\n' > "$REPO/proj/.e2e-isolated"
printf 'model A {}\n' > "$REPO/proj/schema/schema.prisma"
git -C "$REPO" add -A && git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm init
git -C "$REPO" worktree add -q "$WT" -b wt >/dev/null 2>&1
mkdir -p "$WT/proj/sub"

echo "[8] 声明隔离且 schema 与主检出一致 → 共享：两个模块同时持有，互不等待"
OUT="$(cd "$WT/proj/sub" && "$LOCK" acquire "$S" s1 --wait 0 --poll 0 2>&1)"; eq "s1 共享 acquire rc=0" "$?" 0
printf '%s' "$OUT" | grep -q '以共享方式持有' && ok "s1 走共享模式" || no "s1 未走共享: $OUT"
"$LOCK" acquire "$S" s2 --wait 0 --poll 0 --project-dir "$WT/proj" >/dev/null 2>&1; eq "s2 共享 acquire rc=0（不等 s1）" "$?" 0
[ ! -d "$S/e2e.lock" ] && ok "共享模式不占独占锁目录" || no "共享模式占了独占锁目录"
"$LOCK" status "$S" | grep -q '共享持有者：s1,s2' && ok "status 列出共享持有者" || no "status 未列共享持有者: $("$LOCK" status "$S")"

echo "[9] 有共享持有者时，独占申请等到超时 exit 1、点名共享者，且不残留独占位"
OUT="$("$LOCK" acquire "$S" x1 --wait 0 --poll 0 --mode exclusive 2>&1)"; eq "x1 独占 rc=1" "$?" 1
printf '%s' "$OUT" | grep -q '共享持有者 s1,s2' && ok "报错点名共享持有者" || no "报错未点名共享者: $OUT"
[ ! -d "$S/e2e.lock" ] && ok "超时后撤掉了独占占位" || no "超时后独占占位残留"

echo "[10] 共享者全放锁后独占成功；此时新的共享申请让路（超时 exit 1）"
"$LOCK" release "$S" s1 | grep -q '已释放共享' && ok "s1 释放共享锁" || no "s1 释放共享锁失败"
"$LOCK" release "$S" s2 >/dev/null
"$LOCK" acquire "$S" x1 --wait 0 --poll 0 --mode exclusive >/dev/null 2>&1; eq "x1 独占 rc=0" "$?" 0
OUT="$("$LOCK" acquire "$S" s3 --wait 0 --poll 0 --project-dir "$WT/proj" 2>&1)"; eq "s3 共享让路 rc=1" "$?" 1
printf '%s' "$OUT" | grep -q '独占锁仍被 x1 持有' && ok "报错点名独占持有者" || no "报错未点名独占者: $OUT"
[ ! -f "$S/e2e.shared/s3" ] && ok "让路时不留共享登记" || no "让路时残留共享登记"
"$LOCK" release "$S" s3 >/dev/null 2>&1; eq "s3 release 他人独占锁 rc=3" "$?" 3
"$LOCK" release "$S" x1 >/dev/null; [ ! -d "$S/e2e.lock" ] && ok "x1 释放独占锁" || no "x1 未释放"

echo "[11] worktree 改了声明里列出的文件 → 自动改走独占"
printf 'model A { id Int }\n' > "$WT/proj/schema/schema.prisma"
OUT="$("$LOCK" acquire "$S" x2 --wait 0 --poll 0 --project-dir "$WT/proj" 2>&1)"; eq "x2 acquire rc=0" "$?" 0
printf '%s' "$OUT" | grep -q 'proj/schema/schema.prisma 与主检出不同' && ok "独占原因点名改动文件" || no "未说明独占原因: $OUT"
[ -d "$S/e2e.lock" ] && ok "改了 schema 走独占锁目录" || no "改了 schema 仍未占独占锁"
"$LOCK" release "$S" x2 >/dev/null

echo "[12] 共享登记过期被回收：独占申请不被死掉的共享者卡住"
mkdir -p "$S/e2e.shared"; printf 'ghost %s\n' "$(( $(date +%s) - 10000 ))" > "$S/e2e.shared/ghost"
"$LOCK" acquire "$S" x3 --wait 0 --poll 0 --mode exclusive --stale 5400 >/dev/null 2>&1; eq "x3 独占 rc=0" "$?" 0
[ ! -f "$S/e2e.shared/ghost" ] && ok "过期共享登记已回收" || no "过期共享登记未回收"
"$LOCK" release "$S" x3 >/dev/null

echo "[13] 无声明的项目（不在 git 里）仍走独占（旧行为）"
OUT="$("$LOCK" acquire "$S" x4 --wait 0 --poll 0 --project-dir "$TMP" 2>&1)"; eq "x4 rc=0" "$?" 0
[ -d "$S/e2e.lock" ] && ok "无声明走独占锁目录" || no "无声明未走独占"
"$LOCK" release "$S" x4 >/dev/null
git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1

echo
echo "==== cc-fleet-e2e-lock 测试：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] && echo "✅ 全绿" || { echo "❌ 有失败"; exit 1; }
