#!/usr/bin/env bash
# test-name-guard-e2e.sh — 「子 session 丢 ↳ 标识符」这条故障的端到端回归（cc-dispatch → 守护 → 抢名竞态）
#
# 复现的是 2026-08-13 / cli 2.1.231 的真实时序（见 cc-fleet-name-guard 头注释）：
#   t=0    cc-dispatch 经 daemon control socket 派发 worker（source=fleet，daemon 不落 state.json 种子）
#   t≈1s   worker 起来，daemon 才建出 ~/.claude/jobs/<short>/state.json，此时 `.name` 还是空的
#   t≈2s   CC 内建 LLM 自动取名器写 `.name="<英文小写短语>"` + `.nameSource="auto"`
#          —— 但它写回前会重读，**发现 `.name` 已非空就永久放弃**
#   ⇒ 谁先把名字写进去谁赢。cc-dispatch 派发后拉起的守护就是来赢这一局的。
#
# 隔离：假 daemon control socket（本地 UNIX socket，回一条 ok 应答）+ 假 jobs-root + 假"daemon 建文件"
# 与"自动取名器"两个后台模拟进程。全程不连真 daemon、不动真 ~/.claude/jobs。
#
# 断言三条链路：
#   ① 有守护 → ↳名 胜出（真正的修复）
#   ② 无守护 → 自动取名器胜出（证明这个测试确实复现了故障，不是自欺欺人的假绿）
#   ③ 故障已经发生后 → cc-fleet-fix-display --all 能事后夺回（兜底链路）

export CC_FLEET_PANEL=0
# RQ 序号池/注册表现在是【跨仓库全局】的（~/.claude/fleet）。测试一律指到临时目录，
# 否则会污染真实全局池、甚至抬高真实高水位。
export CC_FLEET_HOME="${CC_FLEET_HOME_TEST_OVERRIDE:-$(mktemp -d)}"
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$HERE/../scripts"
DISPATCH="$SCRIPTS/cc-dispatch"
GUARD="$SCRIPTS/cc-fleet-name-guard"
FIXER="$SCRIPTS/cc-fleet-fix-display"
for f in "$DISPATCH" "$GUARD" "$FIXER"; do [ -x "$f" ] || { echo "❌ 缺可执行 $f"; exit 1; }; done
command -v jq >/dev/null 2>&1 || { echo "❌ 需要 jq"; exit 1; }

PASS=0; FAIL=0
check() {  # $1=用例 $2=期望 $3=实际
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n    期望=[%s] 实际=[%s]\n' "$1" "$2" "$3"; fi
}

TMP="$(mktemp -d)"
SOCK="$TMP/control.sock"
JOBS="$TMP/jobs"; mkdir -p "$JOBS"
cleanup() { [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

WANT='↳factory-warehouse-code@RQ-2026-0813-004'
AUTO_LABEL='fleet warehouse config'
PROMPT="⟦FLEET-WORKER⟧ rq=RQ-2026-0813-004 module=factory-warehouse-code

任务卡正文……"

# ── 假 daemon：收一行 JSON，回一条固定 ok 应答，并把请求存盘供断言 ──
REQ_LOG="$TMP/dispatch-request.json"
cat > "$TMP/fake-daemon.pl" <<'PERL'
use strict; use warnings; use IO::Socket::UNIX;
my ($path, $reqlog) = @ARGV;
unlink $path;
my $srv = IO::Socket::UNIX->new(Local => $path, Type => SOCK_STREAM, Listen => 8) or die "listen: $!";
while (my $c = $srv->accept) {
  binmode($c, ':raw');
  my $line = <$c>;
  if (open(my $fh, '>>', $reqlog)) { print {$fh} ($line // ''); close $fh; }
  print $c qq({"ok":true,"short":"e2e00001","pid":4242,"via":"fake"}\n);
  close $c;
}
PERL
perl "$TMP/fake-daemon.pl" "$SOCK" "$REQ_LOG" & SRV_PID=$!
disown 2>/dev/null || true   # 收工时 kill 它不要在 stdout 打 "Terminated"，免得污染 run-all 的末行摘要
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$SOCK" ] && break; sleep 0.3; done
[ -S "$SOCK" ] || { echo "❌ 假 daemon socket 没起来"; exit 1; }

# ── 模拟 daemon 迟建 state.json（t≈1s）+ 自动取名器抢名（t≈2.5s，只在 name 为空时写）──
# $1=job目录  $2=建文件延迟  $3=抢名延迟
simulate_daemon_and_namer() {
  local jd="$1" d1="$2" d2="$3"
  (
    sleep "$d1"
    mkdir -p "$jd"
    jq -nc --arg i "$PROMPT" \
      '{state:"working",detail:"启动中",template:"bg",intent:$i,sessionId:"sid-e2e",cwd:"/tmp",
        createdAt:"2026-08-13T08:00:00.000Z",updatedAt:"2026-08-13T08:00:00.000Z",firstTerminalAt:null}' \
      > "$jd/state.json"
    sleep "$d2"
    # 自动取名器：重读，发现 .name 已非空就放弃（这正是 CC 2.1.231 的实际行为）
    if [ -z "$(jq -r '.name // empty' "$jd/state.json" 2>/dev/null)" ]; then
      jq --arg n "$AUTO_LABEL" '.name=$n | .nameSource="auto"' "$jd/state.json" > "$jd/state.json.tmp" \
        && mv -f "$jd/state.json.tmp" "$jd/state.json"
    fi
  ) &
}

nameof() { jq -r '.name // "∅"' "$1/state.json" 2>/dev/null; }

echo "==== name-guard e2e：cc-dispatch → 守护 → 抢名竞态 ===="

# ─────────────────────────────────────────────────────────────
echo "---- ① 有守护：cc-dispatch 派发后 ↳名 应当胜出 ----"
JD="$JOBS/e2e00001"
simulate_daemon_and_namer "$JD" 1 1.5
out="$(CC_FLEET_JOBS_ROOT="$JOBS" "$DISPATCH" --cwd "$TMP" --name "$WANT" --prompt "$PROMPT" --socket "$SOCK" 2>&1)"
rc=$?
check "cc-dispatch 派发成功" "0" "$rc"
check "派发回执含 short" "yes" "$(printf '%s' "$out" | grep -q 'short=e2e00001' && echo yes || echo no)"
check "请求里带上了 seed.name" "$WANT" "$(jq -r '.d.seed.name // "∅"' "$REQ_LOG" 2>/dev/null)"
# 等竞态窗口过完（建文件 1s + 抢名 1.5s + 余量）
sleep 4
check "⭐↳名胜出（守护抢在自动取名器之前）" "$WANT" "$(nameof "$JD")"
check "nameSource=user" "user" "$(jq -r '.nameSource // "∅"' "$JD/state.json")"
check "intent 等其它字段没被守护弄丢" "sid-e2e" "$(jq -r '.sessionId' "$JD/state.json")"

# ─────────────────────────────────────────────────────────────
echo "---- ② 无守护（CC_FLEET_NAME_GUARD=0）：应当复现故障，自动取名器胜出 ----"
: > "$REQ_LOG"
JD2="$JOBS/e2e00002"
simulate_daemon_and_namer "$JD2" 1 1.5
CC_FLEET_JOBS_ROOT="$JOBS" CC_FLEET_NAME_GUARD=0 \
  "$DISPATCH" --cwd "$TMP" --name "$WANT" --prompt "$PROMPT" --socket "$SOCK" >/dev/null 2>&1
# 假 daemon 固定回 short=e2e00001，这里手工把模拟落在 e2e00002 上，直接看结果即可
sleep 4
check "无守护 → 故障复现（名字被英文短语占住）" "$AUTO_LABEL" "$(nameof "$JD2")"

# ─────────────────────────────────────────────────────────────
echo "---- ③ 事后兜底：cc-fleet-fix-display --all 夺回被抢走的名字 ----"
"$FIXER" --all --jobs-root "$JOBS" --quiet >/dev/null 2>&1
check "⭐--all 事后夺回 ↳名" "$WANT" "$(nameof "$JD2")"
check "夺回后 nameSource=user" "user" "$(jq -r '.nameSource // "∅"' "$JD2/state.json")"
check "运行中的 job 时间戳没被动" "2026-08-13T08:00:00.000Z" "$(jq -r '.createdAt' "$JD2/state.json")"
check "①的 job 幂等（仍是 ↳名）" "$WANT" "$(nameof "$JD")"

echo "==== name-guard e2e：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] || exit 1
