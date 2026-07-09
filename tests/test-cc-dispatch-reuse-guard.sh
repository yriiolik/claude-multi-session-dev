#!/usr/bin/env bash
# test-cc-dispatch-reuse-guard.sh — 验证 cc-dispatch 的【复用兜底闸】（用 --dry-run，不连 daemon）。
#
# 根治事故（2026-06-09）：主 session 丢了 $RQ、凭"今天日期+NNN"手拼旧编号 → 普通解析静默复用别任务的
# 协调目录 → 两个任务的 .sid/回执混进同一目录、Monitor 盯错 RQ、主 session 串台。
# 第一道防线是 cc-fleet-coord --alloc（永不发已用号）；本闸是第二道：即便手拼了旧号，只要 --sid-file 指向
# 的协调目录【已被别的模块占用且超出新鲜窗口】，cc-dispatch 在派发前就 exit 6 拦下，而不是静默混入。
#
# 测试铁律：断言只增强不削弱；失败一律是脚本 bug，改脚本不改断言。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$HERE/../scripts/cc-dispatch"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PROMPT_FILE="$TMP/p.txt"; printf '⟦FLEET-WORKER⟧ rq=RQ-T module=beta\nworker.\n' > "$PROMPT_FILE"

# dispatch_guard <coord> <module> [extra...] -> 回显 cc-dispatch 退出码（--dry-run 不连 daemon；
#   --no-inject-claude-md 让用例不去读真实 ~/.claude/CLAUDE.md，保持 hermetic）。闸在 dry-run 打印前先跑。
dispatch_rc(){
  local coord="$1" module="$2"; shift 2
  "$DISPATCH" --cwd "$TMP" --name "↳$module" --prompt-file "$PROMPT_FILE" \
    --no-inject-claude-md --dry-run --sid-file "$coord/$module.sid" "$@" >/dev/null 2>&1
  echo $?
}

# ① 全新/空协调目录 → 放行（exit 0，打印 JSON）
COORD="$TMP/c1"; mkdir -p "$COORD"
RC="$(dispatch_rc "$COORD" beta)"
[[ "$RC" == 0 ]] && ok "空协调目录派发放行 (exit 0)" || no "空目录应 exit 0，实得 $RC"

# ② 别模块 fresh 工件（刚建，窗口内）→ 放行：模拟并行批派/连派第 2 个模块
printf 'sid\n' > "$COORD/alpha.sid"   # mtime≈now
RC="$(dispatch_rc "$COORD" beta)"
[[ "$RC" == 0 ]] && ok "别模块 fresh→放行 (exit 0)" || no "别模块 fresh 应 exit 0，实得 $RC"

# ③ 别模块 STALE 工件（超窗）→ 拦截 exit 6：正是下午手拼 001 复用上午协调目录的情形
touch -t 202601010000 "$COORD/alpha.sid"
RC="$(dispatch_rc "$COORD" beta)"
[[ "$RC" == 6 ]] && ok "别模块 stale→拦截 (exit 6)" || no "别模块 stale 应 exit 6，实得 $RC"

# ④ stale + --join → 放行（确认同一任务后续批次，如契约先行二次派发）
RC="$(dispatch_rc "$COORD" beta --join)"
[[ "$RC" == 0 ]] && ok "stale + --join→放行 (exit 0)" || no "stale + --join 应 exit 0，实得 $RC"

# ⑤ stale + FLEET_NO_REUSE_GUARD=1 → 整闸关闭放行
RC="$(FLEET_NO_REUSE_GUARD=1 dispatch_rc "$COORD" beta)"
[[ "$RC" == 0 ]] && ok "stale + 关闸→放行 (exit 0)" || no "stale + FLEET_NO_REUSE_GUARD 应 exit 0，实得 $RC"

# ⑥ 同模块自己的 stale 工件不算冲突（同模块重派不该被自己挡）
COORD2="$TMP/c2"; mkdir -p "$COORD2"
printf 'sid\n' > "$COORD2/beta.sid"; touch -t 202601010000 "$COORD2/beta.sid"
RC="$(dispatch_rc "$COORD2" beta)"
[[ "$RC" == 0 ]] && ok "仅本模块 stale→放行 (exit 0)" || no "仅本模块自身 stale 应 exit 0，实得 $RC"

echo
echo "==== cc-dispatch 复用兜底闸测试：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] && echo "✅ 全绿" || { echo "❌ 有失败"; exit 1; }
