#!/usr/bin/env bash
# cc-fleet-init 一次性任务初始化单测（确定性，无需 daemon）。
# 验证：一句调用完成 GC + 取全新单调 RQ（持久池，永不重号）+ 解析 COORD + 建集成分支 + 落 task.meta；
#       stdout 只吐【可 eval 的三行】RQ=/COORD=/INT=（诊断全走 stderr，eval 干净）；
#       --no-init-base / --no-gc / --base / 自定义 stem 各选项生效；重复 init 序号单调递增。
# 测试铁律：断言只增强不削弱；失败一律是脚本 bug，改脚本不改断言。
set -u

SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)/scripts"
INIT_BIN="$SCRIPTS/cc-fleet-init"
COORD_BIN="$SCRIPTS/cc-fleet-coord"
PASS=0; FAIL=0; CASE=""
REPOS=()
trap 'for r in "${REPOS[@]}"; do rm -rf "$r"; done' EXIT
ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ [$CASE] $1"; FAIL=$((FAIL+1)); }

new_repo(){
  local d; d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  REPOS+=("$d")
  cd "$d"
  git checkout -q -b dev/langyi
  git -C "$d" commit -q --allow-empty -m init
  printf '%s' "$d"
}

# ① 基本：一次 init 打印可 eval 的三行，eval 后三变量就绪、目录/分支/meta 都建好
CASE="init打印可eval三行且资源就绪"
new_repo >/dev/null
OUT="$("$INIT_BIN" 2>/dev/null)"
eval "$OUT"
{ [[ "$RQ" == "RQ-"* ]] && [[ -d "$COORD" ]] && [[ "$INT" == "fleet/$RQ" ]] \
  && git show-ref --verify --quiet "refs/heads/$INT" \
  && [[ -f "$COORD/task.meta" ]]; } \
  && ok || fail "三变量/目录/分支/meta 应齐备：RQ=$RQ COORD=$COORD INT=$INT"

# ② stdout 只有三行且都是 KEY=VALUE 形态（诊断没漏进 stdout，否则 eval 会炸）
CASE="stdout只三行KEY=VALUE"
LINES="$(printf '%s\n' "$OUT" | grep -c .)"
BADLINES="$(printf '%s\n' "$OUT" | grep -vcE '^(RQ|COORD|INT)=')"
{ [[ "$LINES" == "3" ]] && [[ "$BADLINES" == "0" ]]; } \
  && ok || fail "stdout 应恰 3 行 KEY=VALUE，行数=$LINES 非法行=$BADLINES"

# ③ task.meta 记录了 rq / base_branch / integration_branch
CASE="task.meta记录关键信息"
{ grep -q "^rq=$RQ$" "$COORD/task.meta" \
  && grep -q "^base_branch=dev/langyi$" "$COORD/task.meta" \
  && grep -q "^integration_branch=fleet/$RQ$" "$COORD/task.meta"; } \
  && ok || fail "task.meta 缺关键字段：$(cat "$COORD/task.meta")"

# ④ 连续两次 init：序号单调递增（不重号）
CASE="连续init序号递增"
R1="$RQ"
OUT2="$("$INIT_BIN" --no-gc 2>/dev/null)"; eval "$OUT2"; R2="$RQ"
{ [[ "$R1" != "$R2" ]] && [[ "$R2" > "$R1" ]]; } \
  && ok || fail "第二次 init 应得更大序号，R1=$R1 R2=$R2"

# ⑤ 持久池：把已 claim 的目录全删后再 init，序号仍不回退
CASE="init删目录后不回退重号"
CM="$(git rev-parse --path-format=absolute --git-common-dir)"
rm -rf "$CM/fleet/RQ-"*
OUT3="$("$INIT_BIN" --no-gc 2>/dev/null)"; eval "$OUT3"; R3="$RQ"
[[ "$R3" > "$R2" ]] && ok || fail "删目录后 init 应续号不回退，R2=$R2 R3=$R3"

# ⑥ --no-init-base：不建集成分支，INT 为空，但 RQ/COORD 仍就绪
CASE="no-init-base跳过建分支"
new_repo >/dev/null
OUT4="$("$INIT_BIN" --no-init-base 2>/dev/null)"; eval "$OUT4"
{ [[ "$RQ" == "RQ-"* ]] && [[ -d "$COORD" ]] && [[ -z "$INT" ]] \
  && ! git show-ref --verify --quiet "refs/heads/fleet/$RQ"; } \
  && ok || fail "--no-init-base 应不建分支且 INT 空，INT='$INT'"

# ⑦ 自定义 stem：前缀原样、序号从 001 起
CASE="自定义stem前缀生效"
new_repo >/dev/null
OUT5="$("$INIT_BIN" --no-init-base RQ-CUSTOM 2>/dev/null)"; eval "$OUT5"
[[ "$RQ" == "RQ-CUSTOM-001" ]] && ok || fail "自定义 stem 应得 RQ-CUSTOM-001，实得 $RQ"

# ⑧ 显式 --base：集成分支以指定 base 为起点
CASE="显式base生效"
new_repo >/dev/null
git checkout -q -b feat/x; echo z>z.txt; git add -A; git commit -qm z; git checkout -q dev/langyi
OUT6="$("$INIT_BIN" --base feat/x 2>/dev/null)"; eval "$OUT6"
[[ "$(git rev-parse "$INT")" == "$(git rev-parse feat/x)" ]] \
  && ok || fail "集成分支起点应=feat/x tip"

# ⑨ --gc 天数：init 时删 >7 天旧目录，保留新目录（含本次 claim 的）
CASE="init自带GC删旧留新"
new_repo >/dev/null
CMG="$(git rev-parse --path-format=absolute --git-common-dir)"
mkdir -p "$CMG/fleet/RQ-OLD-001"
OLDTS="$(date -v-10d '+%Y%m%d%H%M' 2>/dev/null || date -d '10 days ago' '+%Y%m%d%H%M')"
touch -t "$OLDTS" "$CMG/fleet/RQ-OLD-001"
OUT7="$("$INIT_BIN" --no-init-base 2>/dev/null)"; eval "$OUT7"
{ [[ ! -d "$CMG/fleet/RQ-OLD-001" ]] && [[ -d "$COORD" ]]; } \
  && ok || fail "init 应 GC 掉 RQ-OLD-001 且保留本次 $COORD"

# ⑩ --no-gc：不清理旧目录
CASE="no-gc保留旧目录"
mkdir -p "$CMG/fleet/RQ-OLD2-001"; touch -t "$OLDTS" "$CMG/fleet/RQ-OLD2-001"
"$INIT_BIN" --no-init-base --no-gc >/dev/null 2>&1
[[ -d "$CMG/fleet/RQ-OLD2-001" ]] && ok || fail "--no-gc 不应删旧目录"

# ⑪ detached HEAD 且未给 --base → 建分支失败 exit 2（不静默产出半初始化）
CASE="detached无base_exit2"
new_repo >/dev/null
git checkout -q --detach
"$INIT_BIN" >/dev/null 2>&1
[[ $? -eq 2 ]] && ok || fail "detached 无 --base 应 exit 2"

# ⑫ 并发 init 10 个（--no-init-base 免同名分支争用）：RQ 全不同
CASE="并发init无重号"
new_repo >/dev/null
CONCF="$PWD/.initconc"
for i in $(seq 1 10); do ( "$INIT_BIN" --no-init-base --no-gc 2>/dev/null | sed -n "s/^RQ=//p" ) & done > "$CONCF"; wait
TOT="$(grep -c . "$CONCF")"; DIS="$(sort -u "$CONCF" | grep -c .)"
{ [[ "$TOT" == "10" ]] && [[ "$DIS" == "10" ]]; } \
  && ok || fail "10 并发 init 应得 10 个不同 RQ，total=$TOT distinct=$DIS"

echo
echo "==== cc-fleet-init 测试：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] && echo "✅ 全绿" || { echo "❌ 有失败"; exit 1; }
