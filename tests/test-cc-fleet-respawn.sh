#!/usr/bin/env bash
# cc-fleet-respawn 单测（确定性，无需 daemon）。
# 用 --dry-run + --coord + 桩 prompt-file 断言三步计划正确：
#   kill 命令、旧回执归档判定、重派命令（↳名/FLEET_* env/--join/--sid-file/--prompt-file/dispatch 选择）、参数校验退出码。
# 测试铁律：断言只增强不削弱；失败一律是脚本 bug，改脚本不改断言。
set -u

BIN="$(cd "$(dirname "$0")/.." && pwd)/scripts/cc-fleet-respawn"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; CASE=""
ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ [$CASE] $1"; FAIL=$((FAIL+1)); }

COORD="$TMP/coord"; mkdir -p "$COORD"
PF="$TMP/card.md"; echo "⟦FLEET-WORKER⟧ rq=RQ-T module=demand" > "$PF"

# ① 基本 dry-run：三步计划齐全（无旧回执时 archive 跳过）
CASE="dry-run三步计划(无旧回执)"
OUT="$("$BIN" RQ-T demand --prompt-file "$PF" --coord "$COORD" --dry-run 2>&1)"; RC=$?
{ [[ $RC -eq 0 ]] \
  && grep -q "cc-fleet-kill RQ-T demand --signal SIGTERM" <<<"$OUT" \
  && grep -q "无旧回执" <<<"$OUT" \
  && grep -q -- "--name ↳demand@RQ-T" <<<"$OUT" \
  && grep -q "FLEET_ROLE=worker" <<<"$OUT" \
  && grep -q "FLEET_RQ=RQ-T" <<<"$OUT" \
  && grep -q "FLEET_MODULE=demand" <<<"$OUT" \
  && grep -q "FLEET_BASE_BRANCH=fleet/RQ-T" <<<"$OUT" \
  && grep -q -- "--sid-file $COORD/demand.sid" <<<"$OUT" \
  && grep -q -- "--join" <<<"$OUT" \
  && grep -q -- "--prompt-file $PF" <<<"$OUT" \
  && grep -q "/cc-dispatch " <<<"$OUT"; } \
  && ok || fail "rc=$RC out=$OUT"

# ② 有旧回执 → 计划里出现归档动作
CASE="有旧回执→计划含归档"
echo "result: 假装做完了(坏 worker)" > "$COORD/demand.summary.md"
OUT2="$("$BIN" RQ-T demand --prompt-file "$PF" --coord "$COORD" --dry-run 2>&1)"
grep -q "superseded" <<<"$OUT2" && grep -q "归档" <<<"$OUT2" && ok || fail "out=$OUT2"
rm -f "$COORD/demand.summary.md"

# ③ --signal SIGKILL 透传到 kill 命令
CASE="signal SIGKILL 透传"
OUT3="$("$BIN" RQ-T demand --prompt-file "$PF" --coord "$COORD" --signal SIGKILL --dry-run 2>&1)"
grep -q "cc-fleet-kill RQ-T demand --signal SIGKILL" <<<"$OUT3" && ok || fail "out=$OUT3"

# ④ --dispatch cc-dispatch-codex-app 选择 codex 派发脚本
CASE="dispatch 选 codex-app"
OUT4="$("$BIN" RQ-T demand --prompt-file "$PF" --coord "$COORD" --dispatch cc-dispatch-codex-app --dry-run 2>&1)"
grep -q "/cc-dispatch-codex-app " <<<"$OUT4" && ok || fail "out=$OUT4"

# ⑤ --base 覆盖 FLEET_BASE_BRANCH
CASE="base 覆盖"
OUT5="$("$BIN" RQ-T demand --prompt-file "$PF" --coord "$COORD" --base dev/langyi --dry-run 2>&1)"
grep -q "FLEET_BASE_BRANCH=dev/langyi" <<<"$OUT5" && ok || fail "out=$OUT5"

# ⑥ --no-kill → 计划里 kill 步跳过
CASE="no-kill 跳过 kill 步"
OUT6="$("$BIN" RQ-T demand --prompt-file "$PF" --coord "$COORD" --no-kill --dry-run 2>&1)"
{ grep -q "kill     → (跳过" <<<"$OUT6" && ! grep -q "cc-fleet-kill RQ-T demand" <<<"$OUT6"; } && ok || fail "out=$OUT6"

# ⑦ --no-join → 重派不带 --join
CASE="no-join 不带 --join"
OUT7="$("$BIN" RQ-T demand --prompt-file "$PF" --coord "$COORD" --no-join --dry-run 2>&1)"
{ grep -q "dispatch →" <<<"$OUT7" && ! grep -q -- " --join" <<<"$OUT7"; } && ok || fail "out=$OUT7"

# ⑧ -- 之后额外参数原样转发（且落在 --prompt-file 之前）
CASE="passthru 转发额外参数"
OUT8="$("$BIN" RQ-T demand --prompt-file "$PF" --coord "$COORD" --dry-run -- --isolation worktree --env FOO=bar 2>&1)"
{ grep -q -- "--isolation worktree" <<<"$OUT8" && grep -q -- "--env FOO=bar" <<<"$OUT8"; } && ok || fail "out=$OUT8"

# ⑨ 缺 module → exit 5
CASE="缺module exit5"
"$BIN" RQ-T --prompt-file "$PF" --coord "$COORD" --dry-run >/dev/null 2>&1
[[ $? -eq 5 ]] && ok || fail "期望 exit 5"

# ⑩ 非法 --signal → exit 5
CASE="非法signal exit5"
"$BIN" RQ-T demand --signal BOGUS --coord "$COORD" --dry-run >/dev/null 2>&1
[[ $? -eq 5 ]] && ok || fail "期望 exit 5"

# ⑪ 非法 --dispatch → exit 5
CASE="非法dispatch exit5"
"$BIN" RQ-T demand --dispatch cc-nope --coord "$COORD" --dry-run >/dev/null 2>&1
[[ $? -eq 5 ]] && ok || fail "期望 exit 5"

# ⑫ 真跑但缺 --prompt-file → exit 5（非 dry-run 必给）
CASE="真跑缺prompt-file exit5"
"$BIN" RQ-T demand --coord "$COORD" >/dev/null 2>&1
[[ $? -eq 5 ]] && ok || fail "期望 exit 5"

# ⑬ 真跑但 --prompt-file 指向不存在文件 → exit 5
CASE="prompt-file不存在 exit5"
"$BIN" RQ-T demand --coord "$COORD" --prompt-file "$TMP/nope.md" --no-kill >/dev/null 2>&1
[[ $? -eq 5 ]] && ok || fail "期望 exit 5"

# ⑭ --help → exit 0 且打印用法
CASE="help exit0"
OUTH="$("$BIN" --help 2>&1)"; RC=$?
{ [[ $RC -eq 0 ]] && grep -q "cc-fleet-respawn" <<<"$OUTH" && grep -q "灰度坏模型" <<<"$OUTH"; } && ok || fail "rc=$RC"

echo
echo "==== cc-fleet-respawn 测试：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] && echo "✅ 全绿" || { echo "❌ 有失败"; exit 1; }
