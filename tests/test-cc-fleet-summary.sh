#!/usr/bin/env bash
# cc-fleet-summary 回执机械核验单测（确定性，临时 git 仓库，无需 daemon）：
#   落地核验（sha 在/不在 fleet/<RQ> 上）/ 改动统计 / 结果文件存在性 / 只读角色缺 sha 的提示 / 主 session 只读铁律提示。
# 测试铁律：断言只增强不削弱；失败一律是脚本 bug，改脚本不改断言。
set -u
export CC_FLEET_NAME_GUARD=0

SUMMARY="$(cd "$(dirname "$0")/.." && pwd)/scripts/cc-fleet-summary"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
assert_has() { if printf '%s' "$OUT" | grep -qF -- "$1"; then PASS=$((PASS+1)); else echo "✗ [$CASE] 缺少: $1"; echo "$OUT"; FAIL=$((FAIL+1)); fi; }
assert_no()  { if printf '%s' "$OUT" | grep -qF -- "$1"; then echo "✗ [$CASE] 不该出现: $1"; echo "$OUT"; FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi; }

RQ="RQ-T-SUMMARY"
REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
git -C "$REPO" branch "fleet/${RQ}"
# 已落地的 commit：在 fleet/<RQ> 上（走 detached 提交再推进分支 ref，模拟 cc-fleet-land）
git -C "$REPO" checkout -q "fleet/${RQ}"
mkdir -p "$REPO/mod1"; printf 'a\nb\n' > "$REPO/mod1/x.txt"
git -C "$REPO" add -A && git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m "m1 change"
LANDED="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
# 没落地的 commit：在别的分支上
git -C "$REPO" checkout -q -b orphan
printf 'z\n' > "$REPO/orphan.txt"; git -C "$REPO" add -A && git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m "m2 lost"
LOST="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
mkdir -p "$REPO/test-results"; printf '{"passed":3}' > "$REPO/test-results/m1.json"

COORD="$TMP/${RQ}"; mkdir -p "$COORD"
cat > "$COORD/m1.summary.md" <<EOF
result: m1 完成 — 自测全绿
# 会话回执: m1
- 自测结果: 3 pass
- 测试结果文件: test-results/m1.json
- 集成分支落地: 已 cc-fleet-land 到 fleet/${RQ}，落地后 sha ${LANDED:0:12}
- 关键 commit: ${LANDED}
EOF
cat > "$COORD/m2.summary.md" <<EOF
result: m2 完成 — 已 land
# 会话回执: m2
- 测试结果文件: test-results/nope.json
- 关键 commit: ${LOST}
EOF
cat > "$COORD/verify.summary.md" <<EOF
result: verify 完成 — 5/5 场景通过
# 会话回执: verify
- 自测结果: 5 pass
EOF

CASE="落地核验与结果文件"
OUT="$(cd "$REPO" && "$SUMMARY" "$COORD" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && PASS=$((PASS+1)) || { echo "✗ [$CASE] 退出码 期望=0 实际=$RC"; echo "$OUT"; FAIL=$((FAIL+1)); }
assert_has "🧷 落地核验 ✓ ${LANDED:0:12} ∈ fleet/${RQ}"
assert_has "改动统计: 1 file changed, 2 insertions(+)"
assert_has "📄 结果文件 ✓ test-results/m1.json"
assert_has "⛔ 落地核验 ✗ ${LOST:0:12} 不在 fleet/${RQ} 上"
assert_has "📄 结果文件 ✗ 不存在: test-results/nope.json"
assert_has "⚠ 回执没写「关键 commit」sha"
assert_has "⚠ 回执没列「测试结果文件」"
assert_has "⛔ 主 session 验收只读"
assert_no "🧷 落地核验 ✓ ${LOST:0:12}"

CASE="集成分支不存在时跳过落地核验"
git -C "$REPO" branch -D "fleet/${RQ}" >/dev/null 2>&1
OUT="$(cd "$REPO" && "$SUMMARY" "$COORD" 2>&1)"
assert_has "⚠ 集成分支 fleet/${RQ} 不存在，跳过落地核验"
assert_no "🧷 落地核验 ✓"
assert_has "📄 结果文件 ✓ test-results/m1.json"

echo
echo "==== cc-fleet-summary 测试：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] && echo "✅ 全绿" || { echo "❌ 有失败"; exit 1; }
