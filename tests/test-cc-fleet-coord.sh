#!/usr/bin/env bash
# cc-fleet-coord 分配/防撞单测（确定性，无需 daemon）。
# 验证：--alloc 跨所有通道（canonical + 主树 .fleet + 各 worktree .fleet）扫已占用序号、claim 后单调
#       递增永不复用；ISO 日期前缀归一化；--fresh 撞到往轮工件即 exit 4、干净 RQ 放行；默认解析 +
#       --no-mkdir 向后兼容。
# 测试铁律：断言只增强不削弱；失败一律是脚本 bug，改脚本不改断言。

# 派发脚本现在会自动拉起 Ghostty 分屏面板并写全局注册表。测试里一律关掉：
# 否则跑一次测试就会在真实 Ghostty 上弹出一堆分屏，还会污染 ~/.claude/fleet。
export CC_FLEET_PANEL=0
# RQ 序号池/注册表现在是【跨仓库全局】的（~/.claude/fleet）。测试一律指到临时目录，
# 否则会污染真实全局池、甚至抬高真实高水位。
export CC_FLEET_HOME="${CC_FLEET_HOME_TEST_OVERRIDE:-$(mktemp -d)}"
set -u

COORD_BIN="$(cd "$(dirname "$0")/.." && pwd)/scripts/cc-fleet-coord"
PASS=0; FAIL=0; CASE=""
REPOS=()
trap 'for r in "${REPOS[@]}"; do rm -rf "$r"; done' EXIT
ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ [$CASE] $1"; FAIL=$((FAIL+1)); }

# new_repo —— 建一个干净 git 临时仓库、cd 进去、回显路径（登记以便退出时清理）
new_repo(){
  local d; d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  REPOS+=("$d")
  cd "$d"
  printf '%s' "$d"
}

# ① 空仓库分配：自定义 stem → -001
CASE="空仓库alloc得001"
new_repo >/dev/null
RQ="$("$COORD_BIN" --alloc RQ-TESTALLOC 2>/dev/null)"
[[ "$RQ" == "RQ-TESTALLOC-001" ]] && ok || fail "期望 RQ-TESTALLOC-001 实得 '$RQ'"

# ② claim 后再 alloc 同 stem → -002（证明 claim 占位/单调，不复用）
CASE="claim后再alloc递增到002"
RQ2="$("$COORD_BIN" --alloc RQ-TESTALLOC 2>/dev/null)"
[[ "$RQ2" == "RQ-TESTALLOC-002" ]] && ok || fail "期望 RQ-TESTALLOC-002 实得 '$RQ2'"

# ③ 跨已存在目录扫描：预置 -001(bare) 与 -003(带 .sid) → 取最大+1 = -004
CASE="跨已存在目录跳到最大序号+1"
CM="$(git rev-parse --path-format=absolute --git-common-dir)"
mkdir -p "$CM/fleet/RQ-2026-0605-001"
mkdir -p "$CM/fleet/RQ-2026-0605-003"; printf 'tok\n' > "$CM/fleet/RQ-2026-0605-003/m.sid"
RQ3="$("$COORD_BIN" --alloc RQ-2026-0605 2>/dev/null)"
[[ "$RQ3" == "RQ-2026-0605-004" ]] && ok || fail "期望 RQ-2026-0605-004 实得 '$RQ3'"

# ④ ISO 日期前缀归一化：2026-06-05 → RQ-2026-0605-NNN（YYYY-MMDD，非 ISO 的 YYYY-MM-DD）
CASE="ISO日期归一化为YYYY-MMDD"
new_repo >/dev/null
RQ4="$("$COORD_BIN" --alloc 2026-06-07 2>/dev/null)"
[[ "$RQ4" == "RQ-2026-0607-001" ]] && ok || fail "期望 RQ-2026-0607-001 实得 '$RQ4'"

# ⑤ 核心 bug 复现：worktree 内的 .fleet 也算占用（跨 worktree 撞号 → 必须扫到并跳过）
CASE="扫worktree内.fleet占用并跳过"
new_repo >/dev/null
git commit -q --allow-empty -m init
WT="$(mktemp -d)"; rmdir "$WT"     # git worktree add 要求目标路径不存在
git worktree add -q "$WT" -b wtbranch
mkdir -p "$WT/.fleet/RQ-WT-005"
RQ5="$("$COORD_BIN" --alloc RQ-WT 2>/dev/null)"
[[ "$RQ5" == "RQ-WT-006" ]] && ok || fail "期望 RQ-WT-006（应扫到 worktree 里的 -005）实得 '$RQ5'"
rm -rf "$WT"

# ⑥ --fresh 撞到往轮工件 → exit 4
CASE="fresh撞已用工件exit4"
new_repo >/dev/null
CM6="$(git rev-parse --path-format=absolute --git-common-dir)"
mkdir -p "$CM6/fleet/RQ-USED-001"; printf 'result: done\n' > "$CM6/fleet/RQ-USED-001/m.summary.md"
"$COORD_BIN" RQ-USED-001 --fresh >/dev/null 2>&1
[[ $? -eq 4 ]] && ok || fail "期望 exit 4"

# ⑦ --fresh 干净 RQ → exit 0 且打印 canonical 路径
CASE="fresh干净RQ放行打印路径"
OUT="$("$COORD_BIN" RQ-CLEAN-001 --fresh 2>/dev/null)"; RC=$?
{ [[ $RC -eq 0 ]] && [[ "$OUT" == "$CM6/fleet/RQ-CLEAN-001" ]]; } && ok || fail "期望 exit0+canonical 路径，rc=$RC out=$OUT"

# ⑧ 默认解析向后兼容：打印 canonical 且建目录
CASE="默认解析向后兼容打印并建目录"
OUT8="$("$COORD_BIN" RQ-RESV-001 2>/dev/null)"
{ [[ "$OUT8" == "$CM6/fleet/RQ-RESV-001" ]] && [[ -d "$OUT8" ]]; } && ok || fail "期望打印并建 canonical，得 '$OUT8'"

# ⑨ --no-mkdir 只打印不建目录
CASE="no-mkdir只打印不建目录"
OUT9="$("$COORD_BIN" RQ-NOMK-001 --no-mkdir 2>/dev/null)"
{ [[ "$OUT9" == "$CM6/fleet/RQ-NOMK-001" ]] && [[ ! -d "$OUT9" ]]; } && ok || fail "期望打印但不建，得 '$OUT9'"

# ===== 复用兜底闸 --check-join（根治"丢了 $RQ 手拼旧编号→静默复用别任务协调目录"）=====
# 不依赖 git：直接喂一个绝对协调目录。stale 用 touch -t 打老时间戳（远超默认 1800s 新鲜窗口）。
# 故意 cd 到【非 git 目录】跑，锁死 git 无关性（cc-dispatch 的 cwd 常不是 git 仓库，曾因此漏拦）。
NONGIT="$(mktemp -d)"; REPOS+=("$NONGIT"); cd "$NONGIT"
CJDIR="$(mktemp -d)"; REPOS+=("$CJDIR")   # 复用 EXIT trap 清理

# ⑩ 全新/空目录 → 放行（exit 0）
CASE="checkjoin空目录放行"
"$COORD_BIN" --check-join "$CJDIR" newmod >/dev/null 2>&1
[[ $? -eq 0 ]] && ok || fail "空目录应 exit 0"

# ⑪ 别模块 fresh 工件（刚建，窗口内）→ 放行：模拟并行批派第 2 个模块
CASE="checkjoin别模块fresh放行"
printf 'sid\n' > "$CJDIR/alpha.sid"            # mtime≈now
"$COORD_BIN" --check-join "$CJDIR" beta >/dev/null 2>&1
[[ $? -eq 0 ]] && ok || fail "别模块 fresh 应 exit 0（同一活跃批次）"

# ⑫ 别模块 STALE 工件（老时间戳，超窗）→ 拦截 exit 6：正是 2026-06-09 下午手拼 001 复用上午目录的情形
CASE="checkjoin别模块stale拦截exit6"
touch -t 202601010000 "$CJDIR/alpha.sid"       # 远早于 now → age≫1800s
"$COORD_BIN" --check-join "$CJDIR" beta >/dev/null 2>&1
[[ $? -eq 6 ]] && ok || fail "别模块 stale 应 exit 6"

# ⑬ stale + --join → 放行（确认同一任务后续批次，如契约先行二次派发）
CASE="checkjoin_stale加join放行"
"$COORD_BIN" --check-join "$CJDIR" beta --join >/dev/null 2>&1
[[ $? -eq 0 ]] && ok || fail "stale + --join 应 exit 0"

# ⑭ stale + FLEET_NO_REUSE_GUARD=1 → 整闸关闭放行
CASE="checkjoin_stale整闸关闭放行"
FLEET_NO_REUSE_GUARD=1 "$COORD_BIN" --check-join "$CJDIR" beta >/dev/null 2>&1
[[ $? -eq 0 ]] && ok || fail "stale + FLEET_NO_REUSE_GUARD=1 应 exit 0"

# ⑮ 目录里【只有本模块自己】的 stale 工件 → 放行（同模块重派不该被自己挡）
CASE="checkjoin仅本模块stale放行"
CJDIR2="$(mktemp -d)"; REPOS+=("$CJDIR2")
printf 'sid\n' > "$CJDIR2/beta.sid"; touch -t 202601010000 "$CJDIR2/beta.sid"
"$COORD_BIN" --check-join "$CJDIR2" beta >/dev/null 2>&1
[[ $? -eq 0 ]] && ok || fail "仅本模块自身 stale 工件应 exit 0"

# ⑯ 自定义新鲜窗口：把窗口设到极大 → 即便 stale 也算"窗口内"放行（证明 FLEET_JOIN_FRESH_SECS 生效）
CASE="checkjoin自定义大窗口放行"
FLEET_JOIN_FRESH_SECS=999999999 "$COORD_BIN" --check-join "$CJDIR" beta >/dev/null 2>&1
[[ $? -eq 0 ]] && ok || fail "超大新鲜窗口应 exit 0"

# ---- --init-base：集成分支创建 / base.ref 记录 / 幂等不重置 / detached 报错 ----
# ⑰ --init-base 在当前分支(dev/langyi)上建集成分支 fleet/<RQ>，stdout 打印分支名
CASE="initbase建分支打印名"
new_repo >/dev/null
git checkout -q -b dev/langyi 2>/dev/null || git checkout -q dev/langyi
printf 'base\n' > f.txt; git add -A; git commit -qm base
OUT="$("$COORD_BIN" --init-base RQ-2026-0613-901 2>/dev/null)"
[[ "$OUT" == "fleet/RQ-2026-0613-901" ]] && ok || fail "应打印 fleet/RQ-... 实得 '$OUT'"
git show-ref --verify --quiet refs/heads/fleet/RQ-2026-0613-901 && ok || fail "集成分支未创建"

# ⑱ base.ref 记录了 base 分支名
CASE="initbase记base.ref"
CDIR="$(git rev-parse --path-format=absolute --git-common-dir)/fleet/RQ-2026-0613-901"
[[ "$(cat "$CDIR/base.ref" 2>/dev/null)" == "dev/langyi" ]] && ok || fail "base.ref 应为 dev/langyi"

# ⑲ 集成分支以 base 当前 tip 为起点
CASE="initbase起点=base_tip"
[[ "$(git rev-parse fleet/RQ-2026-0613-901)" == "$(git rev-parse dev/langyi)" ]] && ok || fail "集成分支起点应=base tip"

# ⑳ 幂等：集成分支已推进后再 --init-base 不重置它（保留已落地模块）
CASE="initbase幂等不重置"
git checkout -q fleet/RQ-2026-0613-901; echo more >> f.txt; git commit -qam advanced
ADV="$(git rev-parse fleet/RQ-2026-0613-901)"; git checkout -q dev/langyi
"$COORD_BIN" --init-base RQ-2026-0613-901 >/dev/null 2>&1
[[ "$(git rev-parse fleet/RQ-2026-0613-901)" == "$ADV" ]] && ok || fail "已存在集成分支被重置了"

# ㉑ 显式 base 参数
CASE="initbase显式base"
git checkout -q -b feat/x; echo z>z.txt; git add -A; git commit -qm z; git checkout -q dev/langyi
"$COORD_BIN" --init-base RQ-2026-0613-902 feat/x >/dev/null 2>&1
[[ "$(git rev-parse fleet/RQ-2026-0613-902)" == "$(git rev-parse feat/x)" ]] && ok || fail "显式 base=feat/x 未生效"

# ㉒ detached HEAD 无显式 base → exit 2
CASE="initbase_detached报错"
git checkout -q --detach
"$COORD_BIN" --init-base RQ-2026-0613-903 >/dev/null 2>&1
[[ $? -eq 2 ]] && ok || fail "detached 无 base 应 exit 2"

# ㉓ 不存在的 base 分支 → exit 2
CASE="initbase_base不存在报错"
git checkout -q dev/langyi
"$COORD_BIN" --init-base RQ-2026-0613-904 no/such/branch >/dev/null 2>&1
[[ $? -eq 2 ]] && ok || fail "base 不存在应 exit 2"

# ---- --put：把文件落进协调目录（绕开后台 job Write/Edit 隔离闸）----
# ㉔ 从 srcfile 落盘：内容一致、打印目标绝对路径、自动建嵌套父目录
CASE="put从srcfile落盘并建嵌套目录"
new_repo >/dev/null
CMP="$(git rev-parse --path-format=absolute --git-common-dir)"
SRC="$(mktemp)"; printf 'contract-body\n' > "$SRC"; REPOS+=("$SRC")
DEST="$("$COORD_BIN" RQ-PUT-001 --put contracts/api.contract.md "$SRC" 2>/dev/null)"
{ [[ "$DEST" == "$CMP/fleet/RQ-PUT-001/contracts/api.contract.md" ]] \
  && [[ -f "$DEST" ]] && [[ "$(cat "$DEST")" == "contract-body" ]]; } \
  && ok || fail "期望落盘到嵌套路径且内容一致，dest='$DEST'"

# ㉕ 从 stdin 落盘
CASE="put从stdin落盘"
DEST2="$(printf 'from-stdin\n' | "$COORD_BIN" RQ-PUT-001 --put prompts/m.md 2>/dev/null)"
{ [[ -f "$DEST2" ]] && [[ "$(cat "$DEST2")" == "from-stdin" ]]; } \
  && ok || fail "stdin 落盘失败，dest='$DEST2'"

# ㉖ relpath 含 .. → 拒绝 exit 2（越界保护）
CASE="put含..越界拒绝exit2"
"$COORD_BIN" RQ-PUT-001 --put ../escape.md "$SRC" >/dev/null 2>&1
[[ $? -eq 2 ]] && ok || fail "含 .. 的 relpath 应 exit 2"

# ㉗ 绝对 relpath → 拒绝 exit 2
CASE="put绝对路径越界拒绝exit2"
"$COORD_BIN" RQ-PUT-001 --put /etc/evil.md "$SRC" >/dev/null 2>&1
[[ $? -eq 2 ]] && ok || fail "绝对 relpath 应 exit 2"

# ㉘ 缺源文件 → exit 2
CASE="put源文件不存在exit2"
"$COORD_BIN" RQ-PUT-001 --put x.md /no/such/src.md >/dev/null 2>&1
[[ $? -eq 2 ]] && ok || fail "源文件不存在应 exit 2"

# ===== 持久序号池 .seq —— 目录被清也永不回退重号（根治「编号重复」核心）=====
# ㉙ claim 目录被删后再 alloc，序号仍单调递增（不回退到已发过的号）
CASE="seq持久池删目录后不回退"
new_repo >/dev/null
CMS="$(git rev-parse --path-format=absolute --git-common-dir)"
A1="$("$COORD_BIN" --alloc RQ-SEQ 2>/dev/null)"   # -001
A2="$("$COORD_BIN" --alloc RQ-SEQ 2>/dev/null)"   # -002
rm -rf "$CMS/fleet/RQ-SEQ-"*                        # 模拟目录被 GC/手删，目录扫描将回到 max=0
A3="$("$COORD_BIN" --alloc RQ-SEQ 2>/dev/null)"    # 若无持久池会退回 -001；有池则 -003
{ [[ "$A1" == "RQ-SEQ-001" ]] && [[ "$A2" == "RQ-SEQ-002" ]] && [[ "$A3" == "RQ-SEQ-003" ]]; } \
  && ok || fail "删目录后应续到 -003（持久池），实得 A1=$A1 A2=$A2 A3=$A3"

# ㉚ .seq 高水位文件确实写了当前序号
CASE="seq文件记录高水位"
[[ "$(cat "$CMS/fleet/.seq/RQ-SEQ" 2>/dev/null)" == "3" ]] && ok || fail ".seq/RQ-SEQ 应为 3，实得 '$(cat "$CMS/fleet/.seq/RQ-SEQ" 2>/dev/null)'"

# ㉛ 目录扫描值高于 .seq 时以目录为准（兼容历史遗留、别 worktree 手建目录）
CASE="seq与目录取更大者"
mkdir -p "$CMS/fleet/RQ-SEQ-009"                    # 外部手建更高序号目录
A4="$("$COORD_BIN" --alloc RQ-SEQ 2>/dev/null)"
[[ "$A4" == "RQ-SEQ-010" ]] && ok || fail "应取 max(目录=9,池=3)+1=010，实得 $A4"

# ===== --gc 清理 =====
# ㉜ --gc 删 >7 天目录、保留新目录；过期 .seq 清、近期 .seq 留
CASE="gc删旧目录留新目录与近期seq"
new_repo >/dev/null
CMG="$(git rev-parse --path-format=absolute --git-common-dir)"; FG="$CMG/fleet"; mkdir -p "$FG/.seq"
mkdir -p "$FG/RQ-2026-0601-001" "$FG/RQ-OLD-001" "$FG/RQ-2026-0703-001"
printf '1\n' > "$FG/.seq/RQ-2026-0601"; printf '1\n' > "$FG/.seq/RQ-2026-0703"
OLDTS="$(date -v-10d '+%Y%m%d%H%M' 2>/dev/null || date -d '10 days ago' '+%Y%m%d%H%M')"
touch -t "$OLDTS" "$FG/RQ-2026-0601-001" "$FG/RQ-OLD-001" "$FG/.seq/RQ-2026-0601"
"$COORD_BIN" --gc 7 >/dev/null 2>&1
{ [[ ! -d "$FG/RQ-2026-0601-001" ]] && [[ ! -d "$FG/RQ-OLD-001" ]] \
  && [[ -d "$FG/RQ-2026-0703-001" ]] \
  && [[ ! -f "$FG/.seq/RQ-2026-0601" ]] && [[ -f "$FG/.seq/RQ-2026-0703" ]]; } \
  && ok || fail "gc 应删>7天目录+过期seq、留近期"

# ㉝ --gc 自定义天数：--gc 30 → 10 天前的目录应保留
CASE="gc自定义天数保留10天前"
mkdir -p "$FG/RQ-2026-0601-002"; touch -t "$OLDTS" "$FG/RQ-2026-0601-002"
"$COORD_BIN" --gc 30 >/dev/null 2>&1
[[ -d "$FG/RQ-2026-0601-002" ]] && ok || fail "--gc 30 不应删 10 天前目录"

# ===== 并发 alloc 原子锁 —— 20 个并发绝不重号 =====
CASE="并发alloc无重号"
new_repo >/dev/null
for i in $(seq 1 20); do "$COORD_BIN" --alloc RQ-CONC 2>/dev/null & done > "$PWD/.conc.out"; wait
TOTALC="$(wc -l < "$PWD/.conc.out" | tr -d ' ')"
DISTC="$(sort -u "$PWD/.conc.out" | wc -l | tr -d ' ')"
{ [[ "$TOTALC" == "20" ]] && [[ "$DISTC" == "20" ]]; } \
  && ok || fail "20 并发应得 20 个不同 RQ，实得 total=$TOTALC distinct=$DISTC"

# ===== 跨仓库全局唯一（2026-08-20 事故：两个主 session 在不同仓库同日都发出 RQ-2026-0820-001）=====
# 关键：序号池/注册表在 ~/.claude/fleet（本测试已重定向到临时 CC_FLEET_HOME），两个【互不相干的仓库】
#       共享同一个高水位，所以第二个仓库必须拿到 -002 而不是又一个 -001。
CASE="跨仓库alloc编号不重复"
new_repo >/dev/null; RA_DIR="$PWD"
RA="$("$COORD_BIN" --alloc RQ-XREPO 2>/dev/null)"
new_repo >/dev/null; RB_DIR="$PWD"
RB="$("$COORD_BIN" --alloc RQ-XREPO 2>/dev/null)"
cd "$RA_DIR"; RA2="$("$COORD_BIN" --alloc RQ-XREPO 2>/dev/null)"
{ [[ "$RA" == "RQ-XREPO-001" ]] && [[ "$RB" == "RQ-XREPO-002" ]] && [[ "$RA2" == "RQ-XREPO-003" ]]; } \
  && ok || fail "跨仓库应单调递增 001/002/003，实得 A=$RA B=$RB A2=$RA2"

# 全局注册表登记了 owner 协调目录（判定"这个号是谁的"的唯一依据）
CASE="alloc写全局注册表owner"
CMA="$(git -C "$RA_DIR" rev-parse --path-format=absolute --git-common-dir)"
REG_COORD="$(grep -m1 '^coord=' "$CC_FLEET_HOME/registry/$RA" 2>/dev/null)"; REG_COORD="${REG_COORD#coord=}"
EXP_COORD="$(cd "$CMA/fleet/$RA" 2>/dev/null && pwd -P)"      # /var → /private/var 归一
[[ -n "$REG_COORD" ]] && [[ "$(cd "$REG_COORD" 2>/dev/null && pwd -P)" == "$EXP_COORD" ]] \
  && ok || fail "注册表 owner coord 应=$EXP_COORD，实得 '$REG_COORD'"

# --fresh：另一个仓库想用别人已注册的号 → exit 4
CASE="fresh跨仓库同号拒绝exit4"
cd "$RB_DIR"
"$COORD_BIN" "$RA" --fresh >/dev/null 2>&1
[[ $? -eq 4 ]] && ok || fail "B 仓库复用 A 仓库的 $RA 应 exit 4"

# --fresh：owner 自己用自己的号 → 放行
CASE="fresh本仓自己的号放行"
cd "$RA_DIR"
"$COORD_BIN" "$RA" --fresh >/dev/null 2>&1
[[ $? -eq 0 ]] && ok || fail "owner 自己的号应 exit 0"

# --check-join：派发侧兜底闸也拦跨仓库同号（协调目录是空的也拦——注册表说了它归别人）
CASE="checkjoin跨仓库同号拦截exit6"
cd "$RB_DIR"
CMB="$(git rev-parse --path-format=absolute --git-common-dir)"
"$COORD_BIN" --check-join "$CMB/fleet/$RA" mod >/dev/null 2>&1
[[ $? -eq 6 ]] && ok || fail "跨仓库同号 check-join 应 exit 6"

CASE="checkjoin跨仓库同号加join放行"
"$COORD_BIN" --check-join "$CMB/fleet/$RA" mod --join >/dev/null 2>&1
[[ $? -eq 0 ]] && ok || fail "跨仓库同号 + --join 应放行"

# 全局池不可写 → 降级到"本仓唯一"，只告警不阻断（绝不能让 alloc 挂掉）
CASE="全局池不可写降级仍能分配"
UNWRITABLE="$(mktemp -d)"; REPOS+=("$UNWRITABLE"); chmod 500 "$UNWRITABLE"
OUTD="$(CC_FLEET_HOME="$UNWRITABLE/nope" "$COORD_BIN" --alloc RQ-DEGRADE 2>/dev/null)"
[[ "$OUTD" == "RQ-DEGRADE-001" ]] && ok || fail "全局池不可写时应仍能分配，实得 '$OUTD'"
chmod 700 "$UNWRITABLE"

# ===== --seed-global：老仓库升级时把已有 RQ 灌进全局池 =====
CASE="seed-global灌种后别的仓库不再撞号"
SEED_HOME="$(mktemp -d)"; REPOS+=("$SEED_HOME")
new_repo >/dev/null; SR1="$PWD"        # 老仓库①：手工造出已用到 -003 的历史
CMS1="$(git rev-parse --path-format=absolute --git-common-dir)"
mkdir -p "$CMS1/fleet/RQ-SEED-001" "$CMS1/fleet/RQ-SEED-003"
CC_FLEET_HOME="$SEED_HOME" "$COORD_BIN" --seed-global >/dev/null 2>&1
new_repo >/dev/null; SR2="$PWD"        # 老仓库②：灌种后再分配必须跳过 001~003
RS="$(CC_FLEET_HOME="$SEED_HOME" "$COORD_BIN" --alloc RQ-SEED 2>/dev/null)"
[[ "$RS" == "RQ-SEED-004" ]] && ok || fail "灌种后应得 RQ-SEED-004，实得 '$RS'"

CASE="seed-global幂等可重复跑"
cd "$SR1"
CC_FLEET_HOME="$SEED_HOME" "$COORD_BIN" --seed-global >/dev/null 2>&1
RC_SEED=$?
RS2="$(CC_FLEET_HOME="$SEED_HOME" "$COORD_BIN" --alloc RQ-SEED 2>/dev/null)"
{ [[ $RC_SEED -eq 0 ]] && [[ "$RS2" == "RQ-SEED-005" ]]; } \
  && ok || fail "重复灌种应幂等且高水位不回退，rc=$RC_SEED 实得 '$RS2'"

CASE="seed-global报出历史撞号"
new_repo >/dev/null; SR3="$PWD"        # 老仓库③：也有一个 RQ-SEED-001 → 正是历史撞号
CMS3="$(git rev-parse --path-format=absolute --git-common-dir)"
mkdir -p "$CMS3/fleet/RQ-SEED-001"
ERRTXT="$(CC_FLEET_HOME="$SEED_HOME" "$COORD_BIN" --seed-global 2>&1 >/dev/null)"
printf '%s' "$ERRTXT" | grep -q "历史撞号" && ok || fail "应报出 RQ-SEED-001 历史撞号，实得：$ERRTXT"

# ===== 解析时补登记：手工建的协调目录（绕过 --alloc）也要被全局池看见 =====
# 场景：有人手拼编号/旧脚本直接建了 <common-dir>/fleet/RQ-XXX-007。这个号对全局池是隐身的，
#       别的仓库照样能再发一次 → 又一次跨仓库重号。解析是所有路径的必经之地，在那里补登记堵死它。
CASE="解析补登记抬高全局高水位"
REG_HOME="$(mktemp -d)"; REPOS+=("$REG_HOME")
new_repo >/dev/null; RG1="$PWD"
CC_FLEET_HOME="$REG_HOME" "$COORD_BIN" RQ-HAND-007 >/dev/null 2>&1     # 手工编号，走普通解析
new_repo >/dev/null                                                     # 换一个仓库再取号
RH="$(CC_FLEET_HOME="$REG_HOME" "$COORD_BIN" --alloc RQ-HAND 2>/dev/null)"
[[ "$RH" == "RQ-HAND-008" ]] && ok || fail "手工编号 007 应被补登记并抬高水位（期望 008），实得 '$RH'"

CASE="解析补登记不覆盖已有owner"
cd "$RG1"
OWNER_BEFORE="$(grep -m1 '^coord=' "$REG_HOME/registry/RQ-HAND-007")"
cd "$(mktemp -d)" 2>/dev/null || true
new_repo >/dev/null
CC_FLEET_HOME="$REG_HOME" "$COORD_BIN" RQ-HAND-007 >/dev/null 2>&1     # 另一个仓库解析同号
OWNER_AFTER="$(grep -m1 '^coord=' "$REG_HOME/registry/RQ-HAND-007")"
[[ "$OWNER_BEFORE" == "$OWNER_AFTER" ]] && ok || fail "已有 owner 不该被后来者覆盖：'$OWNER_BEFORE' → '$OWNER_AFTER'"

CASE="no-mkdir只读解析不写注册表"
new_repo >/dev/null
CC_FLEET_HOME="$REG_HOME" "$COORD_BIN" RQ-HAND-099 --no-mkdir >/dev/null 2>&1
[[ ! -f "$REG_HOME/registry/RQ-HAND-099" ]] && ok || fail "--no-mkdir 是只读解析，不该写全局注册表"

echo
echo "==== cc-fleet-coord 测试：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] && echo "✅ 全绿" || { echo "❌ 有失败"; exit 1; }
