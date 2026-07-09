#!/usr/bin/env bash
# cc-fleet-land 单测（确定性，无需 daemon；纯 git 临时仓 + 真实 worktree）。
# 验证 worker 把改动安全合入集成分支 fleet/<RQ> 的核心契约：
#   ff 落地推进集成分支 / 幂等 no-op / 两 worker 串行零丢更新（CAS+merge）/ 缺集成分支报错 /
#   工作树脏报错 / 与集成分支冲突报错且集成分支不变 / 当前就在集成分支上报错 / --dry-run 不改 ref /
#   --push-backup 无 origin 仍本地落地。
# 测试铁律：断言只增强不削弱；失败一律是脚本 bug，改脚本不改断言。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAND="$ROOT/scripts/cc-fleet-land"
COORD="$ROOT/scripts/cc-fleet-coord"
PASS=0; FAIL=0; CASE=""
DIRS=()
trap 'for d in "${DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done' EXIT
ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ [$CASE] $1"; FAIL=$((FAIL+1)); }
eq(){ [ "$1" = "$2" ] && ok || fail "期望 '$2' 实得 '$1' ($3)"; }

# new_repo —— 干净 git 仓库（dev/langyi 一个 base commit），打印仓库根路径。
new_repo(){
  local d; d="$(mktemp -d)"; DIRS+=("$d")
  git -C "$d" init -q
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  git -C "$d" checkout -q -b dev/langyi
  printf 'base\n' > "$d/base.txt"
  git -C "$d" add -A; git -C "$d" commit -qm base
  printf '%s' "$d"
}
# add_worker <repo> <wtname> <startref> —— 建一个 worker 隔离 worktree（独立分支），打印 worktree 路径。
add_worker(){
  local repo="$1" name="$2" start="$3" wt="$1/wt-$2"
  git -C "$repo" worktree add -q -b "wk-$name" "$wt" "$start" >/dev/null 2>&1
  printf '%s' "$wt"
}
intsha(){ git -C "$1" rev-parse "fleet/$2"; }

# ---------- 1. ff 落地：单 worker 落地推进集成分支 ----------
CASE="ff-land"
R="$(new_repo)"
( cd "$R" && "$COORD" --init-base RQ-1 >/dev/null 2>&1 )
before="$(intsha "$R" RQ-1)"
WT="$(add_worker "$R" a "fleet/RQ-1")"
( cd "$WT" && printf 'A\n' > a.txt && git add -A && git commit -qm "module A" && "$LAND" RQ-1 >/dev/null 2>&1 )
eq "$?" "0" "落地退出码"
after="$(intsha "$R" RQ-1)"
[ "$before" != "$after" ] && ok || fail "集成分支未推进"
[ -n "$(git -C "$R" ls-tree --name-only fleet/RQ-1 a.txt)" ] && ok || fail "a.txt 未进集成分支"

# ---------- 2. 幂等 no-op：同一 worker 再落地一次 ----------
CASE="idempotent"
mid="$(intsha "$R" RQ-1)"
( cd "$WT" && "$LAND" RQ-1 >/dev/null 2>&1 ); eq "$?" "0" "再落地退出码"
eq "$(intsha "$R" RQ-1)" "$mid" "集成分支应不变"

# ---------- 3. 两 worker 串行：零丢更新 ----------
CASE="serial-no-lost-update"
R3="$(new_repo)"; ( cd "$R3" && "$COORD" --init-base RQ-3 >/dev/null 2>&1 )
WA="$(add_worker "$R3" A "fleet/RQ-3")"
( cd "$WA" && printf 'A\n' > a.txt && git add -A && git commit -qm A && "$LAND" RQ-3 >/dev/null 2>&1 )
# B 从 base 起（不含 A），改不同文件，落地时应自动 merge 进 A
WB="$(add_worker "$R3" B "dev/langyi")"
( cd "$WB" && printf 'B\n' > b.txt && git add -A && git commit -qm B && "$LAND" RQ-3 >/dev/null 2>&1 )
eq "$?" "0" "B 落地退出码"
[ -n "$(git -C "$R3" ls-tree --name-only fleet/RQ-3 a.txt)" ] && ok || fail "A 丢了"
[ -n "$(git -C "$R3" ls-tree --name-only fleet/RQ-3 b.txt)" ] && ok || fail "B 丢了"

# ---------- 4. 缺集成分支 → exit 2 ----------
CASE="missing-int-branch"
( cd "$WB" && "$LAND" RQ-nope >/dev/null 2>&1 ); eq "$?" "2" "缺集成分支退出码"

# ---------- 5. 工作树脏 → exit 3 ----------
CASE="dirty-tree"
( cd "$WB" && printf 'x\n' > uncommitted.txt && "$LAND" RQ-3 >/dev/null 2>&1 ); eq "$?" "3" "脏树退出码"
( cd "$WB" && rm -f uncommitted.txt )

# ---------- 6. 与集成分支冲突 → exit 7，集成分支不变 ----------
CASE="merge-conflict"
R6="$(new_repo)"; ( cd "$R6" && "$COORD" --init-base RQ-6 >/dev/null 2>&1 )
WX="$(add_worker "$R6" X "fleet/RQ-6")"
( cd "$WX" && printf 'fromX\n' > shared.txt && git add -A && git commit -qm X && "$LAND" RQ-6 >/dev/null 2>&1 )
intafterX="$(intsha "$R6" RQ-6)"
WY="$(add_worker "$R6" Y "dev/langyi")"   # 不含 X，改同一文件不同内容
( cd "$WY" && printf 'fromY\n' > shared.txt && git add -A && git commit -qm Y && "$LAND" RQ-6 >/dev/null 2>&1 )
eq "$?" "7" "冲突退出码"
eq "$(intsha "$R6" RQ-6)" "$intafterX" "冲突时集成分支应不变"

# ---------- 7. 当前就在集成分支上 → exit 2（guard）----------
CASE="on-int-branch"
R7="$(new_repo)"; ( cd "$R7" && "$COORD" --init-base RQ-7 >/dev/null 2>&1 )
WI="$R7/wt-int"; git -C "$R7" worktree add -q "$WI" "fleet/RQ-7" >/dev/null 2>&1
( cd "$WI" && "$LAND" RQ-7 >/dev/null 2>&1 ); eq "$?" "2" "在集成分支上退出码"

# ---------- 8. --dry-run 不改 ref ----------
CASE="dry-run"
R8="$(new_repo)"; ( cd "$R8" && "$COORD" --init-base RQ-8 >/dev/null 2>&1 )
WD="$(add_worker "$R8" D "fleet/RQ-8")"
b8="$(intsha "$R8" RQ-8)"
( cd "$WD" && printf 'D\n' > d.txt && git add -A && git commit -qm D && "$LAND" RQ-8 --dry-run >/dev/null 2>&1 )
eq "$?" "0" "dry-run 退出码"
eq "$(intsha "$R8" RQ-8)" "$b8" "dry-run 不应改集成分支"

# ---------- 9. --push-backup 无 origin 仍本地落地 ----------
CASE="push-backup-no-origin"
( cd "$WD" && "$LAND" RQ-8 --push-backup mymod >/dev/null 2>&1 ); eq "$?" "0" "无 origin 落地退出码"
[ -n "$(git -C "$R8" ls-tree --name-only fleet/RQ-8 d.txt)" ] && ok || fail "d.txt 未进集成分支"

echo
if [ "$FAIL" -eq 0 ]; then echo "✅ cc-fleet-land: 全部 $PASS 条断言通过"; exit 0
else echo "❌ cc-fleet-land: $FAIL 失败 / $PASS 通过"; exit 1; fi
