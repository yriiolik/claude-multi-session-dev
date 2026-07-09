#!/usr/bin/env bash
# 端到端流程测试：集成分支隔离模型的完整链路（cc-fleet-coord --init-base + cc-fleet-land + 促进回 base）。
# 证明两件用户痛点都被解决：
#   ① "过早污染共享分支"：worker 落地期间共享分支 dev/langyi 一行不动；只有"主 session 验收后促进"才动一次。
#   ② "从 main 拉出来合回当前分支出问题"：模拟 bg EnterWorktree 默认从 origin/main(无 followup/) 生 worktree，
#      worker reset --hard 到集成分支后拿到完整 base 内容，落地+促进后 followup/ 与各模块改动都在、零丢失。
# 测试铁律：断言只增强不削弱；失败一律是脚本 bug。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAND="$ROOT/scripts/cc-fleet-land"
COORD="$ROOT/scripts/cc-fleet-coord"
PASS=0; FAIL=0; CASE="e2e"
DIRS=()
trap 'for d in "${DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done' EXIT
ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ [$CASE] $1"; FAIL=$((FAIL+1)); }
has(){ [ -n "$(git -C "$1" ls-tree -r --name-only "$2" -- "$3" 2>/dev/null)" ]; }

# ---- 建仓：main(无 followup/) 与 dev/langyi(有 followup/，领先 main) 分叉 ----
R="$(mktemp -d)"; DIRS+=("$R")
git -C "$R" init -q -b main
git -C "$R" config user.email t@t; git -C "$R" config user.name t
printf 'root\n' > "$R/README.md"; git -C "$R" add -A; git -C "$R" commit -qm "main: root（无 followup/）"
MAIN_SHA="$(git -C "$R" rev-parse main)"
git -C "$R" checkout -q -b dev/langyi
mkdir -p "$R/followup"; printf 'followup base\n' > "$R/followup/base.ts"
git -C "$R" add -A; git -C "$R" commit -qm "dev/langyi: 加 followup/（领先 main）"

# ---- 主 session：alloc + init-base（base=当前分支 dev/langyi）----
RQ="$(cd "$R" && "$COORD" --alloc 2>/dev/null)"
INT="$(cd "$R" && "$COORD" --init-base "$RQ" 2>/dev/null)"
[ "$INT" = "fleet/$RQ" ] && ok || fail "init-base 应打印 fleet/$RQ，实得 $INT"
DEV_BEFORE="$(git -C "$R" rev-parse dev/langyi)"

# ---- worker mA：模拟 bg EnterWorktree 从 origin/main 生 worktree（血缘=main，无 followup/）----
WA="$R/wt-A"; git -C "$R" worktree add -q -b wk-A "$WA" main >/dev/null 2>&1
has "$R" wk-A followup/base.ts && fail "前提错误：main 血缘的 worktree 不该有 followup/" || ok
# worker 第一动作：reset --hard 到集成分支 → 拿到完整 base 内容
git -C "$WA" reset --hard "$INT" >/dev/null 2>&1
[ -f "$WA/followup/base.ts" ] && ok || fail "reset 后 followup/ 应出现（拿到 base 内容）"
# 开发 + 提交 + 落地
printf 'A\n' > "$WA/followup/moduleA.ts"; git -C "$WA" add -A; git -C "$WA" commit -qm "module A"
( cd "$WA" && "$LAND" "$RQ" >/dev/null 2>&1 ); [ $? -eq 0 ] && ok || fail "A 落地失败"

# ---- worker mB：同样从 main 血缘出发、reset 锚定、落地（与 A 并发，不含 A）----
WB="$R/wt-B"; git -C "$R" worktree add -q -b wk-B "$WB" main >/dev/null 2>&1
git -C "$WB" reset --hard "$INT" >/dev/null 2>&1   # 注意：此刻 INT 已含 A；B reset 时会带上 A
printf 'B\n' > "$WB/followup/moduleB.ts"; git -C "$WB" add -A; git -C "$WB" commit -qm "module B"
( cd "$WB" && "$LAND" "$RQ" >/dev/null 2>&1 ); [ $? -eq 0 ] && ok || fail "B 落地失败"

# ---- 痛点①验证：worker 落地全程，共享分支 dev/langyi 一行没动 ----
[ "$(git -C "$R" rev-parse dev/langyi)" = "$DEV_BEFORE" ] && ok || fail "共享分支 dev/langyi 被 worker 改动了（污染！）"
# 集成分支已含 A、B 两模块 + base
has "$R" "$INT" followup/moduleA.ts && ok || fail "集成分支缺 moduleA"
has "$R" "$INT" followup/moduleB.ts && ok || fail "集成分支缺 moduleB"
has "$R" "$INT" followup/base.ts && ok || fail "集成分支缺 base.ts"

# ---- 主 session 验收通过 → 促进：fleet/<RQ> 合回 base ----
COORD_DIR="$(cd "$R" && "$COORD" "$RQ" --no-mkdir 2>/dev/null)"
BASE="$(cat "$COORD_DIR/base.ref")"
[ "$BASE" = "dev/langyi" ] && ok || fail "base.ref 应为 dev/langyi，实得 $BASE"
git -C "$WA" worktree remove --force "$WA" 2>/dev/null; git -C "$R" worktree remove --force "$WB" 2>/dev/null
git -C "$R" switch -q "$BASE"
git -C "$R" merge --no-ff -q -m "merge $INT" "$INT"
# 痛点②验证：促进后 base 上 followup/base.ts(原有) + 两模块都在，零丢失
has "$R" "$BASE" followup/base.ts && ok || fail "促进后 base 丢了 followup/base.ts"
has "$R" "$BASE" followup/moduleA.ts && ok || fail "促进后 base 缺 moduleA"
has "$R" "$BASE" followup/moduleB.ts && ok || fail "促进后 base 缺 moduleB"
# main 没被牵连（始终无 followup/）
has "$R" main followup/base.ts && fail "main 不该被改" || ok
[ "$(git -C "$R" rev-parse main)" = "$MAIN_SHA" ] && ok || fail "main 被动了"

# ---- 收尾：删集成分支 ----
git -C "$R" branch -D "$INT" >/dev/null 2>&1 && ok || fail "删集成分支失败"

echo
if [ "$FAIL" -eq 0 ]; then echo "✅ 集成分支隔离 e2e：全部 $PASS 条断言通过"; exit 0
else echo "❌ 集成分支隔离 e2e：$FAIL 失败 / $PASS 通过"; exit 1; fi
