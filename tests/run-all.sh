#!/usr/bin/env bash
# 跑全部测试并打印一行一个的结果表。全绿退出 0，任一失败退出 1。
#
#   bash tests/run-all.sh              # 全部
#   bash tests/run-all.sh codex        # 只跑名字含 codex 的
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 兜底：任何测试都不该去动真实 Ghostty / 真实 ~/.claude/fleet。
# 需要走面板路径的测试（test-panel-codex-e2e.sh）会自己带假 osascript 再打开。
export CC_FLEET_PANEL=0
FILTER="${1:-}"
FAILED=()
TOTAL=0

for t in "$ROOT"/tests/test-*.sh; do
  name="$(basename "$t")"
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
  TOTAL=$((TOTAL + 1))
  out="$(bash "$t" 2>&1)"; rc=$?
  last="$(printf '%s' "$out" | tail -1 | cut -c1-58)"
  if [[ $rc -eq 0 ]]; then
    printf '  %-44s ✅ %s\n' "$name" "$last"
  else
    printf '  %-44s ❌ rc=%s %s\n' "$name" "$rc" "$last"
    FAILED+=("$name")
    printf '%s\n' "$out" | grep -E '^✗' | sed 's/^/       /'
  fi
done

echo
if [[ ${#FAILED[@]} -eq 0 ]]; then
  echo "==== 全部 $TOTAL 个测试文件通过 ===="
  exit 0
fi
echo "==== $TOTAL 个测试文件中 ${#FAILED[@]} 个失败: ${FAILED[*]} ===="
exit 1
