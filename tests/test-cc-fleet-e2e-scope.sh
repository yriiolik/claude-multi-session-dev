#!/usr/bin/env bash
# cc-fleet-e2e-scope 单测（确定性，自造临时 git 仓库，不碰真实项目、不跑真实 e2e）：
#   改动 → 候选 spec 推导 / 过宽词干剔除 / 预算截断 / 改动 spec 直进候选 /
#   无 e2e 目录降级 / record 登记 / plan 汇总与全量升级判据 / 用法与退出码。
# 测试铁律：断言只增强不削弱；失败一律是脚本 bug，改脚本不改断言。
set -u

SCOPE="$(cd "$(dirname "$0")/.." && pwd)/scripts/cc-fleet-e2e-scope"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || no "$1 （期望 [$3] 实得 [$2]）"; }
has(){ printf '%s' "$2" | command grep -qF -- "$3" && ok "$1" || no "$1 （输出里没有 [$3]）"; }
hasnt(){ printf '%s' "$2" | command grep -qF -- "$3" && no "$1 （输出里不该有 [$3]）" || ok "$1"; }

# ── 造一个假项目：仓库根 = 项目根，14 个 spec，其中 10 个带公共词 shop（用来验过宽词干剔除）──
P="$TMP/proj"
mkdir -p "$P/src/modules/pricing" "$P/src/modules/invoice" "$P/tests/e2e" "$P/scripts"
echo '{"name":"fake"}' > "$P/package.json"
printf '#!/usr/bin/env bash\necho run "$@"\n' > "$P/scripts/run-tests.sh"
for n in pricing-gate invoice-export shop-a shop-b shop-c shop-d shop-e shop-f shop-g shop-h shop-i shop-j; do
  printf "import { test } from '@playwright/test'\ntest('%s', async () => {})\n" "$n" > "$P/tests/e2e/$n.spec.ts"
done
printf "test('pricing gate rule')\n" >> "$P/tests/e2e/pricing-gate.spec.ts"
git -C "$P" init -q
git -C "$P" -c user.email=t@t -c user.name=t add -A >/dev/null
git -C "$P" -c user.email=t@t -c user.name=t commit -qm base
BASE="$(git -C "$P" rev-parse HEAD)"

echo "[1] 改一个模块源文件 → 同名 spec 进候选，命令用本项目 run-tests.sh"
echo 'export const gate = 2' > "$P/src/modules/pricing/pricing-gate.service.ts"
OUT="$(cd "$P" && "$SCOPE" suggest --base "$BASE" 2>&1)"; eq "suggest rc" "$?" 0
has "命中同名 spec" "$OUT" "tests/e2e/pricing-gate.spec.ts"
has "给出项目适配命令" "$OUT" "bash scripts/run-tests.sh"
hasnt "无关 spec 不进建议" "$(printf '%s' "$OUT" | sed -n '/建议本轮跑/,/建议命令/p')" "invoice-export"

echo "[2] 过宽词干（命中 spec 数超阈值）被剔除，不把候选撑成全量"
mkdir -p "$P/src/modules/shop"; echo 'export const s = 1' > "$P/src/modules/shop/shop.ts"
OUT="$(cd "$P" && "$SCOPE" suggest --base "$BASE" 2>&1)"
has "提示已忽略过宽词干" "$OUT" "已忽略过宽词干"
has "被忽略的是 shop" "$OUT" "shop("
rm -rf "$P/src/modules/shop"

echo "[3] 本次改到的 spec 直接进候选且排最前（+10 分）"
printf "test('extra')\n" >> "$P/tests/e2e/invoice-export.spec.ts"
OUT="$(cd "$P" && "$SCOPE" suggest --base "$BASE" 2>&1)"
has "改到的 spec 标注来源" "$OUT" "本次改到"
eq "改到的 spec 排第一" \
  "$(printf '%s' "$OUT" | sed -n '/建议本轮跑/,$p' | sed -n '2p' | awk '{print $1}')" \
  "tests/e2e/invoice-export.spec.ts"
git -C "$P" checkout -- tests/e2e/invoice-export.spec.ts

echo "[4] 预算上限截断，超出的列到「建议纳入回归」"
for n in pricing-gate-b pricing-gate-c pricing-gate-d; do
  printf "test('%s')\n" "$n" > "$P/tests/e2e/$n.spec.ts"
done
OUT="$(cd "$P" && "$SCOPE" suggest --base "$BASE" --max 2 2>&1)"
eq "建议只列 2 个" "$(printf '%s' "$OUT" | sed -n '/建议本轮跑/,/^$/p' | command grep -c 'spec\.ts')" "2"
has "超预算交回归卡" "$OUT" "超预算未列入"
rm -f "$P/tests/e2e/pricing-gate-b.spec.ts" "$P/tests/e2e/pricing-gate-c.spec.ts" "$P/tests/e2e/pricing-gate-d.spec.ts"

echo "[5] 没有改动 / 没有 e2e 目录时给出可执行的下一步，而不是沉默"
OUT="$(cd "$P" && git stash -u -q && "$SCOPE" suggest --base "$BASE" 2>&1; git stash pop -q 2>/dev/null)"
has "空改动时提示给对 base" "$OUT" "没有改动文件"
NOE="$TMP/noe2e"; mkdir -p "$NOE/tests/unit"; echo '{}' > "$NOE/package.json"
git -C "$NOE" init -q; git -C "$NOE" -c user.email=t@t -c user.name=t add -A >/dev/null
git -C "$NOE" -c user.email=t@t -c user.name=t commit -qm base
echo 'x' > "$NOE/tests/unit/a.ts"
OUT="$(cd "$NOE" && "$SCOPE" suggest 2>&1)"
has "无 e2e 项目降级到单测" "$OUT" "vitest related"

echo "[6] record 登记落盘、可追加，缺参数报用法"
C="$TMP/coord"; mkdir -p "$C"
"$SCOPE" record "$C" m1 tests/e2e/pricing-gate.spec.ts --minutes 4 >/dev/null; eq "record rc" "$?" 0
[ -f "$C/e2e-scope/m1.txt" ] && ok "登记文件已建" || no "登记文件未建"
has "记了 spec" "$(cat "$C/e2e-scope/m1.txt")" "tests/e2e/pricing-gate.spec.ts"
has "记了耗时" "$(cat "$C/e2e-scope/m1.txt")" "minutes=4"
"$SCOPE" record "$C" m1 tests/e2e/invoice-export.spec.ts >/dev/null
eq "追加不覆盖" "$(command grep -c 'spec\.ts' "$C/e2e-scope/m1.txt")" "2"
"$SCOPE" record "$C" m2 >/dev/null 2>&1; eq "缺 spec 参数 rc=2" "$?" 2

echo "[7] plan 汇总各 worker 登记，默认判定「不要全量」"
printf 'rq=RQ-TEST\nbase_branch=%s\n' "$BASE" > "$C/task.meta"
OUT="$(cd "$P" && "$SCOPE" plan "$C" 2>&1)"; eq "plan rc" "$?" 0
has "列出 worker 已测范围" "$OUT" "tests/e2e/pricing-gate.spec.ts"
has "含 diff 反推段" "$OUT" "集成分支相对 base"
has "默认不升级全量" "$OUT" "不要**跑全量"

echo "[8] plan 命中公共基座改动时建议升级全量"
mkdir -p "$P/prisma"; echo 'model A {}' > "$P/prisma/schema.prisma"
OUT="$(cd "$P" && "$SCOPE" plan "$C" 2>&1)"
has "提示升级全量" "$OUT" "建议升级为全量"
has "指出命中的文件" "$OUT" "schema.prisma"
rm -rf "$P/prisma"

echo "[9] 用法错与环境错的退出码"
"$SCOPE" >/dev/null 2>&1; eq "无子命令 rc=2" "$?" 2
"$SCOPE" bogus >/dev/null 2>&1; eq "未知子命令 rc=2" "$?" 2
"$SCOPE" plan "$TMP/不存在的目录" >/dev/null 2>&1; eq "COORD 不存在 rc=3" "$?" 3
(cd "$TMP" && "$SCOPE" suggest --project-dir "$TMP" >/dev/null 2>&1); eq "找不到项目根 rc=3" "$?" 3
OUT="$(cd "$P" && "$SCOPE" suggest --bogus 2>&1)"; eq "未知参数 rc=2" "$?" 2

echo
printf '结果: %d 通过 / %d 失败\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
