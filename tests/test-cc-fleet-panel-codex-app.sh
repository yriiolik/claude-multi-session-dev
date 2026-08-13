#!/usr/bin/env bash
# cc-fleet-panel-codex-app 面板回归测试：分组语义、只读约束、时间窗、导航、自动关闭判据。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PANEL="$ROOT/scripts/cc-fleet-panel-codex-app"
PASS=0
FAIL=0
CASE="init"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ [$CASE] $1"; FAIL=$((FAIL+1)); }
assert_eq(){ [[ "$1" == "$2" ]] && ok || fail "$3: 期望 [$2] 实得 [$1]"; }
assert_contains(){ [[ "$1" == *"$2"* ]] && ok || fail "$3: 输出里找不到 [$2]"; }
assert_not_contains(){ [[ "$1" != *"$2"* ]] && ok || fail "$3: 输出里不该有 [$2]"; }

# ---- 假的 app-server 调用器：按 threadId 从 THREADS 文件返回 thread 快照，并记录调用次数 ----
FAKE_CALL="$TMP/fake-app-call"
cat > "$FAKE_CALL" <<'NODE'
#!/usr/bin/env node
const fs = require("fs");
const args = process.argv.slice(2).filter((a) => !a.startsWith("--") || a === "--");
const method = args[args.length - 2];
const paramFile = args[args.length - 1];
const params = JSON.parse(fs.readFileSync(paramFile, "utf8"));
fs.appendFileSync(process.env.FAKE_CALL_LOG, `${method} ${params.threadId || ""}\n`);
const threads = JSON.parse(fs.readFileSync(process.env.FAKE_THREADS, "utf8"));
const thread = threads[params.threadId];
if (!thread) { console.error("thread not found"); process.exit(3); }
console.log(JSON.stringify({ thread }));
NODE
chmod +x "$FAKE_CALL"

THREADS="$TMP/threads.json"
CALL_LOG="$TMP/calls.log"
REG="$TMP/registry.json"
COORD="$TMP/repo/.git/fleet/RQ-TEST-001"
mkdir -p "$COORD"

now(){ date +%s; }

# mk_worker <module> <thread-id> [extra env lines...]
mk_worker(){
  local m="$1" tid="$2"; shift 2
  cat > "$COORD/$m.codex-app.env" <<EOF
id=$tid
thread_id=$tid
rq=RQ-TEST-001
module=$m
name=↳$m@RQ-TEST-001
started_at=$(( $(now) - 600 ))
model_provider=deepseek
model=deepseek-v4-flash
branch=fleet-worker/RQ-TEST-001/$m
worktree_cwd=$TMP/repo-wt/$m
summary_file=$COORD/$m.summary.md
mode=codex-app
EOF
  for line in "$@"; do echo "$line" >> "$COORD/$m.codex-app.env"; done
}

cat > "$THREADS" <<'EOF'
{
  "t-running":  {"status":{"type":"active"},"turns":[{"id":"turn-1","status":"inProgress","items":[{"type":"reasoning","summary":["正在核对库存口径"]},{"type":"commandExecution","command":"pnpm test -- inventory","status":"completed","exitCode":0,"aggregatedOutput":"12 passed\n"}]}]},
  "t-blocked":  {"status":{"type":"active","activeFlags":["waitingOnApproval"]},"turns":[{"id":"turn-1","status":"inProgress","items":[]}]},
  "t-idle":     {"status":{"type":"idle"},"turns":[{"id":"turn-1","status":"completed","items":[{"type":"agentMessage","text":"我先跑到这里"}]}]},
  "t-failed":   {"status":{"type":"systemError"},"turns":[{"id":"turn-1","status":"failed","items":[]}]},
  "t-receipt":  {"status":{"type":"idle"},"turns":[]}
}
EOF

mk_worker running-mod t-running
mk_worker blocked-mod t-blocked
mk_worker idle-mod    t-idle
mk_worker failed-mod  t-failed
mk_worker done-mod    t-receipt
printf 'result: 库存模块已完成，单测 42 通过\n' > "$COORD/done-mod.summary.md"

cat > "$REG" <<EOF
{"proto":1,"coords":[{"coord":"$COORD","rq":"RQ-TEST-001","firstSeen":1,"lastSeen":1}]}
EOF

run_panel(){
  : > "$CALL_LOG"
  CC_FLEET_PANEL_REGISTRY="$REG" \
  CODEX_APP_CALL_BIN="$FAKE_CALL" \
  FAKE_THREADS="$THREADS" \
  FAKE_CALL_LOG="$CALL_LOG" \
  "$PANEL" "$@" 2>&1
}

group_of(){ echo "$1" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const j=JSON.parse(s);const job=j.jobs.find(x=>x.module===process.argv[1]);
  console.log(job?job.group:"MISSING");
});' "$2"; }

# ---------------------------------------------------------------- 分组语义
CASE="分组语义"
OUT="$(run_panel --json)"
assert_eq "$(group_of "$OUT" running-mod)" "working"     "running → Working"
assert_eq "$(group_of "$OUT" blocked-mod)" "blocked"     "waitingOnApproval → 待输入"
assert_eq "$(group_of "$OUT" done-mod)"    "completed"   "有 result: 回执 → Completed"
assert_eq "$(group_of "$OUT" failed-mod)"  "attention"   "systemError → 异常"
# 这条是本技能最容易踩的坑：thread 空闲但没落回执，绝不能算完成
assert_eq "$(group_of "$OUT" idle-mod)"    "needs-check" "idle 且无回执 → 需核验（不算完成）"

# ---------------------------------------------------------------- 只读约束
CASE="只读约束"
run_panel --json >/dev/null
assert_not_contains "$(cat "$CALL_LOG")" "thread/resume"    "面板不得调用 thread/resume"
assert_not_contains "$(cat "$CALL_LOG")" "thread/unarchive" "面板不得调用 thread/unarchive"
assert_eq "$(grep -c 'thread/read' "$CALL_LOG")" "4"        "只对无回执的 4 个 worker 发起 read"
assert_not_contains "$(cat "$CALL_LOG")" "t-receipt"        "有回执的 worker 不打扰 app-server"
BEFORE="$(cat "$COORD/running-mod.codex-app.env")"
run_panel --json >/dev/null
assert_eq "$(cat "$COORD/running-mod.codex-app.env")" "$BEFORE" "面板不得写回 worker 元数据"

# ---------------------------------------------------------------- 时间窗
CASE="时间窗"
OLD="$(( $(now) - 90000 ))"   # 25 小时前
STAMP="$(date -r "$OLD" +%Y%m%d%H%M.%S)"
# 时间窗看的是 max(started_at, 元数据/回执文件 mtime)，三者都要拨老才算真的"超窗"
sed -i '' "s/^started_at=.*/started_at=$OLD/" "$COORD/done-mod.codex-app.env"
touch -t "$STAMP" "$COORD/done-mod.summary.md" "$COORD/done-mod.codex-app.env"
OUT="$(run_panel --json --max-age-hours 24)"
assert_eq "$(group_of "$OUT" done-mod)" "MISSING" "超窗且有回执的 worker 不再展示"
assert_not_contains "$(cat "$CALL_LOG")" "t-receipt" "超窗 worker 不触发 app 调用"
# 长跑 worker 的磁盘文件不会动——不能因为 mtime 老就把它从面板上抹掉
sed -i '' "s/^started_at=.*/started_at=$OLD/" "$COORD/running-mod.codex-app.env"
touch -t "$STAMP" "$COORD/running-mod.codex-app.env"
OUT="$(run_panel --json --max-age-hours 24)"
assert_eq "$(group_of "$OUT" running-mod)" "working" "状态未定的老 worker 仍要去问 app-server"
sed -i '' "s/^started_at=.*/started_at=$(( $(now) - 600 ))/" "$COORD/done-mod.codex-app.env" "$COORD/running-mod.codex-app.env"
touch "$COORD/done-mod.summary.md" "$COORD/done-mod.codex-app.env" "$COORD/running-mod.codex-app.env"

# ---------------------------------------------------------------- 渲染
CASE="渲染"
OUT="$(run_panel --once --plain)"
assert_contains "$OUT" "Codex Fleet"        "有标题"
assert_contains "$OUT" "↳running-mod@RQ-TEST-001" "worker 名按 ↳module@RQ 展示"
assert_contains "$OUT" "Working"            "有 Working 分组"
assert_contains "$OUT" "需核验"             "有需核验分组"
assert_contains "$OUT" "Completed"          "有 Completed 分组"
assert_contains "$OUT" "🧾回执在案"          "回执 worker 的 detail 标出回执"
# 一行不能超过终端宽度（ANSI 不参与列宽计算的回归）
LONGEST="$(COLUMNS=80 run_panel --once --plain | awk '{ print length($0) }' | sort -rn | head -1)"
[[ "$LONGEST" -le 200 ]] && ok || fail "行宽失控: $LONGEST"

# ---------------------------------------------------------------- 导航
CASE="导航"
OUT="$(run_panel --json --keys down)"
assert_eq "$(echo "$OUT" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).cursor')" "1" "↓ 移动光标"
OUT="$(run_panel --json --keys down,down,up)"
assert_eq "$(echo "$OUT" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).cursor')" "1" "↑ 回退光标"
OUT="$(run_panel --json --keys right)"
assert_eq "$(echo "$OUT" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).view')" "detail" "→ 进入详情"
OUT="$(run_panel --json --keys right,left)"
assert_eq "$(echo "$OUT" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).view')" "list" "← 退回列表"
OUT="$(run_panel --json --keys up,up,up,up)"
assert_eq "$(echo "$OUT" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).cursor')" "0" "光标不越界（上）"
OUT="$(run_panel --json --keys down,down,down,down,down,down,down,down)"
CUR="$(echo "$OUT" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).cursor')"
N="$(echo "$OUT" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).jobs.length')"
assert_eq "$CUR" "$(( N - 1 ))" "光标不越界（下）"

# ---------------------------------------------------------------- 详情内容
CASE="详情内容"
# 分组顺序把「待输入」排在最前，光标 0 不是 running-mod——按模块名定位再进详情
keys_to(){
  local idx; idx="$(run_panel --json | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).jobs.findIndex(j=>j.module===process.argv[1])' "$1")"
  node -pe '"down,".repeat(Number(process.argv[1]))+"right"' "$idx"
}
OUT="$(run_panel --once --plain --keys "$(keys_to running-mod)")"
assert_contains "$OUT" "正在核对库存口径"        "详情展示 reasoning"
assert_contains "$OUT" "pnpm test -- inventory" "详情展示执行的命令"
assert_contains "$OUT" "12 passed"              "详情展示命令输出"
assert_contains "$OUT" "deepseek"               "详情展示实际模型（不能信 worker 自述）"
assert_contains "$OUT" "← 返回"                 "详情有返回提示"
# 选中有回执的 worker 时，回执正文要直接摊开
OUT="$(run_panel --once --plain --keys "$(keys_to done-mod)")"
assert_contains "$OUT" "库存模块已完成" "详情摊开回执正文"

# ---------------------------------------------------------------- 空注册表
CASE="空注册表"
OUT="$(CC_FLEET_PANEL_REGISTRY="$TMP/none.json" "$PANEL" --once --plain 2>&1)"
assert_contains "$OUT" "派发后会自动出现在这里" "没有 worker 时给出提示而不是报错"

# ---------------------------------------------------------------- app-server 不可达
CASE="app-server 不可达"
BROKEN="$TMP/broken-call"; printf '#!/bin/sh\nexit 9\n' > "$BROKEN"; chmod +x "$BROKEN"
OUT="$(CC_FLEET_PANEL_REGISTRY="$REG" CODEX_APP_CALL_BIN="$BROKEN" "$PANEL" --once --plain 2>&1)"
assert_contains "$OUT" "app-server 不可达" "读不到 thread 时明确告警"
assert_contains "$OUT" "🧾回执在案"        "app-server 挂了也仍能显示已落回执的 worker"

echo
if [[ $FAIL -eq 0 ]]; then
  echo "==== cc-fleet-panel-codex-app: $PASS 项全部通过 ===="
  exit 0
fi
echo "==== cc-fleet-panel-codex-app: $PASS 通过 / $FAIL 失败 ===="
exit 1
