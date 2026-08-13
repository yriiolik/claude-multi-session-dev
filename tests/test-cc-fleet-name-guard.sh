#!/usr/bin/env bash
# test-cc-fleet-name-guard.sh — cc-fleet-name-guard 的回归测试
#
# 覆盖 2.1.231「内建自动命名器抢走 FleetView 显示名」这条故障线：
#   · state.json 还没出生 → 守护要等到它出现再写（这是竞态的关键窗口）
#   · 已被 nameSource=auto 的英文名占住 → 夺回
#   · 已是期望名 → 幂等不写盘（mtime 不变）
#   · nameSource=user 的用户手改名 → 默认不碰；--force 才覆盖
#   · state.json 不可解析 / 全程不出现 → 静默 no-op，不崩不挂
#   · 其余字段原样保留（只动 name / nameSource）
#   · --detach 立刻返回、后台仍完成夺回
#   · 单例锁：同一 job 第二个守护直接让位

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/scripts/cc-fleet-name-guard"
[ -x "$BIN" ] || { echo "❌ 找不到可执行 $BIN"; exit 1; }

PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

check() {  # $1=用例 $2=期望 $3=实际
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n    期望=[%s] 实际=[%s]\n' "$1" "$2" "$3"; fi
}

mkjob() {  # $1=jobdir $2=name(可空) $3=nameSource(可空)
  mkdir -p "$1"
  if [ -z "${2:-}" ]; then
    cat > "$1/state.json" <<'EOF'
{"state":"working","detail":"d","template":"bg","intent":"x","sessionId":"s1","cwd":"/tmp","createdAt":"2026-08-13T08:00:00.000Z","updatedAt":"2026-08-13T08:01:00.000Z"}
EOF
  else
    jq -n --arg n "$2" --arg s "${3:-auto}" \
      '{state:"working",detail:"d",template:"bg",intent:"x",sessionId:"s1",cwd:"/tmp",name:$n,nameSource:$s,createdAt:"2026-08-13T08:00:00.000Z",updatedAt:"2026-08-13T08:01:00.000Z"}' \
      > "$1/state.json"
  fi
}
nameof() { jq -r '.name // "∅"' "$1/state.json" 2>/dev/null; }
srcof()  { jq -r '.nameSource // "∅"' "$1/state.json" 2>/dev/null; }
mtimeof() { stat -f %m "$1/state.json" 2>/dev/null || stat -c %Y "$1/state.json" 2>/dev/null; }

WANT='↳factory-warehouse-code@RQ-2026-0813-004'

echo "==== cc-fleet-name-guard ===="

# ---- 1. 夺回被自动命名器占住的英文名 ----
J="$TMP/j1"; mkjob "$J" "fleet warehouse config" auto
out="$("$BIN" --job-dir "$J" --name "$WANT" --window 2 --interval 1 --stable 1 2>&1)"
check "auto 名被夺回" "$WANT" "$(nameof "$J")"
check "夺回后 nameSource=user" "user" "$(srcof "$J")"
check "夺回时有输出" "1" "$(printf '%s' "$out" | grep -c 'cc-fleet-name-guard')"

# ---- 2. 其余字段原样保留 ----
check "其余字段不丢(detail)" "d" "$(jq -r '.detail' "$J/state.json")"
check "其余字段不丢(createdAt)" "2026-08-13T08:00:00.000Z" "$(jq -r '.createdAt' "$J/state.json")"

# ---- 3. 幂等：已是期望名 → 不写盘 ----
J="$TMP/j2"; mkjob "$J" "$WANT" user
before="$(mtimeof "$J")"
sleep 1
out="$("$BIN" --job-dir "$J" --name "$WANT" --window 2 --interval 1 --stable 1 2>&1)"
check "幂等：mtime 不变" "$before" "$(mtimeof "$J")"
check "幂等：无输出" "" "$out"

# ---- 4. 用户手改名（nameSource=user）默认不碰 ----
J="$TMP/j3"; mkjob "$J" "我手动改的名字" user
"$BIN" --job-dir "$J" --name "$WANT" --window 2 --interval 1 --stable 1 >/dev/null 2>&1
check "手改名默认不覆盖" "我手动改的名字" "$(nameof "$J")"

# ---- 5. --force 才覆盖手改名 ----
J="$TMP/j4"; mkjob "$J" "我手动改的名字" user
"$BIN" --job-dir "$J" --name "$WANT" --window 2 --interval 1 --stable 1 --force >/dev/null 2>&1
check "--force 覆盖手改名" "$WANT" "$(nameof "$J")"

# ---- 6. name 为空（daemon 刚建好还没命名）→ 写入 ----
J="$TMP/j5"; mkjob "$J" "" ""
"$BIN" --job-dir "$J" --name "$WANT" --window 2 --interval 1 --stable 1 >/dev/null 2>&1
check "空 name 被填上" "$WANT" "$(nameof "$J")"

# ---- 7. ⭐关键窗口：state.json 稍后才出生，守护要等到它 ----
J="$TMP/j6"; mkdir -p "$J"
( sleep 2; mkjob "$J" "late auto label" auto ) &
LATE=$!
"$BIN" --job-dir "$J" --name "$WANT" --window 8 --interval 1 --stable 1 >/dev/null 2>&1
wait $LATE 2>/dev/null
check "迟到的 state.json 也被写上" "$WANT" "$(nameof "$J")"

# ---- 8. state.json 全程不出现 → 静默 no-op，退出码 0 ----
J="$TMP/j7"; mkdir -p "$J"
out="$("$BIN" --job-dir "$J" --name "$WANT" --window 2 --interval 1 --stable 1 2>&1)"; rc=$?
check "无 state.json：退出码 0" "0" "$rc"
check "无 state.json：无输出" "" "$out"

# ---- 9. state.json 不可解析 → 不动它、不崩 ----
J="$TMP/j8"; mkdir -p "$J"; printf 'not json{{{' > "$J/state.json"
"$BIN" --job-dir "$J" --name "$WANT" --window 2 --interval 1 --stable 1 >/dev/null 2>&1
check "坏 JSON：退出码 0" "0" "$?"
check "坏 JSON：内容不变" "not json{{{" "$(cat "$J/state.json")"

# ---- 10. --short + --jobs-root 定位 ----
JR="$TMP/jobs"; mkdir -p "$JR"; mkjob "$JR/ab12cd34" "auto name" auto
"$BIN" --short ab12cd34 --jobs-root "$JR" --name "$WANT" --window 2 --interval 1 --stable 1 >/dev/null 2>&1
check "--short 定位 job" "$WANT" "$(nameof "$JR/ab12cd34")"

# ---- 11. --detach 立刻返回，后台完成夺回 ----
J="$TMP/j9"; mkjob "$J" "auto detached" auto
t0=$(date +%s)
"$BIN" --job-dir "$J" --name "$WANT" --window 6 --interval 1 --stable 1 --detach >/dev/null 2>&1
t1=$(date +%s)
check "--detach 立刻返回(<3s)" "1" "$([ $((t1-t0)) -lt 3 ] && echo 1 || echo 0)"
for _ in 1 2 3 4 5 6 7 8; do [ "$(nameof "$J")" = "$WANT" ] && break; sleep 1; done
check "--detach 后台完成夺回" "$WANT" "$(nameof "$J")"

# ---- 12. 单例锁：锁在【job 目录之外】（job 目录还没出生时也要能加锁），锁在时第二个守护让位 ----
J="$TMP/j10"; mkjob "$J" "auto locked" auto
LOCK_ROOT="${TMPDIR:-/tmp}/cc-fleet-name-guard-$(id -u)"
LOCK="$LOCK_ROOT/$(printf '%s' "$J" | tr -c 'A-Za-z0-9._-' '_').lock"
mkdir -p "$LOCK"
"$BIN" --job-dir "$J" --name "$WANT" --window 2 --interval 1 --stable 1 >/dev/null 2>&1
check "有锁时让位不改名" "auto locked" "$(nameof "$J")"
check "锁不落在 job 目录里（否则 job 目录未出生时加不上锁）" "0" "$([ -e "$J/.name-guard.lock" ] && echo 1 || echo 0)"
rm -rf "$LOCK"
"$BIN" --job-dir "$J" --name "$WANT" --window 2 --interval 1 --stable 1 >/dev/null 2>&1
check "锁释放后正常夺回" "$WANT" "$(nameof "$J")"
check "守护退出后锁已清" "0" "$([ -d "$LOCK" ] && echo 1 || echo 0)"

# ---- 12b. ⭐job 目录整个还不存在（fleet 派发不落种子的常态）→ 守护必须能起、能等、能写 ----
JD_LATE="$TMP/jobs-late/abcd1234"      # 父目录都不存在
( sleep 2; mkjob "$JD_LATE" "" "" ) &
LATE2=$!
"$BIN" --job-dir "$JD_LATE" --name "$WANT" --window 8 --interval 1 --stable 1 >/dev/null 2>&1
wait $LATE2 2>/dev/null
check "job 目录后建也能写上名字" "$WANT" "$(nameof "$JD_LATE")"

# ---- 13. 参数校验 ----
"$BIN" --name x >/dev/null 2>&1; check "缺 job 定位 → rc=2" "2" "$?"
"$BIN" --job-dir "$TMP" >/dev/null 2>&1; check "缺 --name → rc=2" "2" "$?"

echo "==== cc-fleet-name-guard 测试：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] || exit 1
