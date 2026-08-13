#!/usr/bin/env bash
# cc-fleet-panel-codex-app 面板回归：任务组分组与归属、未完成/已完成两栏、只读约束、
# 时间窗、导航、执行中标记动画、详情走 rollout。
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

# ---- 假的 app-server 调用器：按 threadId 返回 thread 快照，并记录调用 ----
FAKE_CALL="$TMP/fake-app-call"
cat > "$FAKE_CALL" <<'NODE'
#!/usr/bin/env node
const fs = require("fs");
const args = process.argv.slice(2).filter((a) => !a.startsWith("--"));
const method = args[args.length - 2];
const params = JSON.parse(fs.readFileSync(args[args.length - 1], "utf8"));
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
HOME_DIR="$TMP/home"
CODEX="$TMP/codex-home"
REPO_A="$TMP/repoA"
REPO_B="$TMP/repoB"
COORD="$REPO_A/.git/fleet/RQ-TEST-001"
COORD_B="$REPO_B/.git/fleet/RQ-TEST-002"
mkdir -p "$COORD" "$COORD_B" "$HOME_DIR/.claude/sessions" "$CODEX/sessions/2026/08/13"

now(){ date +%s; }

mk_worker(){
  local dir="$1" m="$2" tid="$3" rq="$4"; shift 4
  cat > "$dir/$m.codex-app.env" <<EOF
id=$tid
thread_id=$tid
rq=$rq
module=$m
name=↳$m@$rq
started_at=$(( $(now) - 600 ))
model_provider=deepseek
model=deepseek-v4-flash
branch=fleet-worker/$rq/$m
worktree_cwd=$TMP/wt/$m
summary_file=$dir/$m.summary.md
mode=codex-app
EOF
  for line in "$@"; do echo "$line" >> "$dir/$m.codex-app.env"; done
}

cat > "$THREADS" <<'EOF'
{
  "t-running":  {"status":{"type":"active"},"turns":[{"id":"turn-1","status":"inProgress","items":[]}]},
  "t-blocked":  {"status":{"type":"active","activeFlags":["waitingOnApproval"]},"turns":[{"id":"turn-1","status":"inProgress","items":[]}]},
  "t-idle":     {"status":{"type":"idle"},"turns":[{"id":"turn-1","status":"completed","items":[{"type":"agentMessage","text":"我先跑到这里"}]}]},
  "t-failed":   {"status":{"type":"systemError"},"turns":[{"id":"turn-1","status":"failed","items":[]}]},
  "t-receipt":  {"status":{"type":"idle"},"turns":[]},
  "t-b1":       {"status":{"type":"active"},"turns":[{"id":"turn-1","status":"inProgress","items":[]}]}
}
EOF

mk_worker "$COORD" running-mod t-running RQ-TEST-001
mk_worker "$COORD" blocked-mod t-blocked RQ-TEST-001
mk_worker "$COORD" idle-mod    t-idle    RQ-TEST-001
mk_worker "$COORD" failed-mod  t-failed  RQ-TEST-001
mk_worker "$COORD" done-mod    t-receipt RQ-TEST-001
printf 'result: 库存模块已完成，单测 42 通过\nnotes: 已合回集成分支\n' > "$COORD/done-mod.summary.md"
mk_worker "$COORD_B" other-mod t-b1 RQ-TEST-002

# 任务组一：派发时记下了主 session（owner.meta）
cat > "$HOME_DIR/.claude/sessions/4242.json" <<'EOF'
{"pid":4242,"sessionId":"sess-aaaa","cwd":"/work/repoA","name":"虚拟OMS上线前检查清单","kind":"bg","status":"busy"}
EOF
cat > "$COORD/owner.meta" <<'EOF'
owner_pid=4242
owner_session_id=sess-aaaa
owner_name=派发当时的旧标题
owner_cwd=/work/repoA
EOF

# 任务组二：没有 owner.meta（改造之前派发的历史 RQ），只能靠 task.meta 的 cwd 推断
cat > "$COORD_B/task.meta" <<'EOF'
rq=RQ-TEST-002
cwd=/work/repoB
EOF
cat > "$HOME_DIR/.claude/sessions/5353.json" <<'EOF'
{"pid":5353,"sessionId":"sess-bbbb","cwd":"/work/repoB","name":"出库单收货信息修复","kind":"bg","status":"idle"}
EOF

cat > "$REG" <<EOF
{"proto":1,"coords":[
  {"coord":"$COORD","rq":"RQ-TEST-001","firstSeen":1,"lastSeen":1},
  {"coord":"$COORD_B","rq":"RQ-TEST-002","firstSeen":1,"lastSeen":1}]}
EOF

run_panel(){
  : > "$CALL_LOG"
  HOME="$HOME_DIR" \
  CODEX_HOME="$CODEX" \
  CC_FLEET_PANEL_REGISTRY="$REG" \
  CODEX_APP_CALL_BIN="$FAKE_CALL" \
  FAKE_THREADS="$THREADS" \
  FAKE_CALL_LOG="$CALL_LOG" \
  "$PANEL" "$@" 2>&1
}

J(){ echo "$1" | node -pe "const j=JSON.parse(require('fs').readFileSync(0,'utf8'));$2"; }
bucket_of(){ J "$1" "(j.jobs.find(x=>x.module==='$2')||{}).bucket||'MISSING'"; }
label_of(){ J "$1" "(j.jobs.find(x=>x.module==='$2')||{}).label||'MISSING'"; }

# ---------------------------------------------------------------- 任务组
CASE="任务组"
OUT="$(run_panel --json)"
assert_eq "$(J "$OUT" 'j.groups.length')" "2" "按 RQ 分成两个任务组"
assert_eq "$(J "$OUT" 'j.groups[0].rq')" "RQ-TEST-001" "有未完成的任务组排前面"
# owner.meta 只存 pid/session id；名字要按 pid 取实时值，否则主 session 改过标题后组名就是旧的
assert_eq "$(J "$OUT" 'j.groups[0].title')" "虚拟OMS上线前检查清单" "组标题取主 session 的实时名字"
assert_not_contains "$OUT" "派发当时的旧标题" "不使用 owner.meta 里的过期名字快照"
assert_eq "$(J "$OUT" 'j.groups[0].ownerSource')" "meta" "有 owner.meta 时来源标为 meta"
assert_eq "$(J "$OUT" 'j.groups[1].title')" "出库单收货信息修复" "没有 owner.meta 时按 task.meta 的 cwd 推断"
assert_eq "$(J "$OUT" 'j.groups[1].ownerSource')" "inferred" "推断出来的来源标为 inferred"
assert_eq "$(J "$OUT" 'j.groups[0].modules.length')" "5" "worker 归到各自的任务组"
assert_eq "$(J "$OUT" 'j.groups[0].done')" "1" "组内已完成计数"
assert_eq "$(J "$OUT" 'j.groups[0].pending')" "4" "组内未完成计数"

CASE="归属兜底"
mv "$COORD_B/task.meta" "$COORD_B/task.meta.bak"
OUT2="$(run_panel --json)"
assert_eq "$(J "$OUT2" 'j.groups.find(g=>g.rq==="RQ-TEST-002").ownerSource')" "none" "既无 owner.meta 又推断不出时标为 none"
assert_contains "$(J "$OUT2" 'j.groups.find(g=>g.rq==="RQ-TEST-002").title')" "repoB" "兜底用仓库名，不留空标题"
mv "$COORD_B/task.meta.bak" "$COORD_B/task.meta"

# ---------------------------------------------------------------- 两栏语义
CASE="未完成/已完成"
OUT="$(run_panel --json)"
assert_eq "$(bucket_of "$OUT" running-mod)" "pending"   "执行中 → 未完成"
assert_eq "$(bucket_of "$OUT" blocked-mod)" "pending"   "待输入 → 未完成"
assert_eq "$(bucket_of "$OUT" failed-mod)"  "pending"   "失败 → 未完成"
assert_eq "$(bucket_of "$OUT" done-mod)"    "done"      "有 result: 回执 → 已完成"
# 这条是本技能最容易踩的坑：thread 空闲但没落回执，绝不能算完成
assert_eq "$(bucket_of "$OUT" idle-mod)"    "pending"   "idle 且无回执 → 未完成（需核验）"
assert_eq "$(label_of "$OUT" idle-mod)"     "需核验"     "需核验的状态词要单独标出来"
assert_eq "$(label_of "$OUT" running-mod)"  "执行中"     "执行中的状态词"
assert_eq "$(label_of "$OUT" blocked-mod)"  "待输入"     "待输入的状态词"
# 未完成排在已完成前面
assert_eq "$(J "$OUT" 'j.jobs.findIndex(x=>x.module==="done-mod")>j.jobs.findIndex(x=>x.module==="running-mod")')" "true" "组内未完成排在已完成之前"

# ---------------------------------------------------------------- detail 列
CASE="detail 列"
OUT="$(run_panel --json)"
# 原始 detail 是 `Codex App thread active turn=<uuid>` 和回执文件路径，两条都没有信息量
assert_contains "$(J "$OUT" '(j.jobs.find(x=>x.module==="done-mod")||{}).detail')" "库存模块已完成" "已回执的显示回执首行而不是文件路径"
assert_not_contains "$(J "$OUT" '(j.jobs.find(x=>x.module==="done-mod")||{}).detail')" ".summary.md" "已回执的不显示文件路径"

# 给在跑的 worker 造一份 rollout，detail 列应显示"此刻在干什么"
ROLL="$CODEX/sessions/2026/08/13/rollout-2026-08-13T10-00-00-t-running.jsonl"
cat > "$ROLL" <<'JSONL'
{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
{"type":"event_msg","payload":{"type":"user_message","message":"任务卡正文"}}
{"type":"response_item","payload":{"type":"reasoning","summary":[],"content":[{"type":"reasoning_text","text":"先看库存口径"}]}}
{"type":"event_msg","payload":{"type":"agent_message","message":"开始核对"}}
{"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"c1","arguments":"{\"cmd\": \"cd \\\"/wt/mod\\\" && pnpm test -- inventory\"}"}}
{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"Process exited with code 0\nOutput:\n42 passed"}}
JSONL
OUT="$(run_panel --json)"
assert_contains "$(J "$OUT" '(j.jobs.find(x=>x.module==="running-mod")||{}).detail')" "pnpm test -- inventory" "执行中的显示 rollout 里最近一条活动"
assert_not_contains "$(J "$OUT" '(j.jobs.find(x=>x.module==="running-mod")||{}).detail')" "turn=" "不再显示没有信息量的 turn uuid"
assert_not_contains "$(J "$OUT" '(j.jobs.find(x=>x.module==="running-mod")||{}).detail')" "cd \"/wt/mod\"" "命令列剥掉 cd 前缀"

# ---------------------------------------------------------------- 只读约束
CASE="只读约束"
run_panel --json >/dev/null
assert_not_contains "$(cat "$CALL_LOG")" "thread/resume"    "面板不得调用 thread/resume"
assert_not_contains "$(cat "$CALL_LOG")" "thread/unarchive" "面板不得调用 thread/unarchive"
assert_not_contains "$(cat "$CALL_LOG")" "t-receipt"        "有回执的 worker 不打扰 app-server"
BEFORE="$(cat "$COORD/running-mod.codex-app.env")"
run_panel --json >/dev/null
assert_eq "$(cat "$COORD/running-mod.codex-app.env")" "$BEFORE" "面板不得写回 worker 元数据"

# ---------------------------------------------------------------- 时间窗
CASE="时间窗"
OLD="$(( $(now) - 90000 ))"
STAMP="$(date -r "$OLD" +%Y%m%d%H%M.%S)"
sed -i '' "s/^started_at=.*/started_at=$OLD/" "$COORD/done-mod.codex-app.env"
touch -t "$STAMP" "$COORD/done-mod.summary.md" "$COORD/done-mod.codex-app.env"
OUT="$(run_panel --json --max-age-hours 24)"
assert_eq "$(bucket_of "$OUT" done-mod)" "MISSING" "超窗且有回执的 worker 不再展示"
assert_not_contains "$(cat "$CALL_LOG")" "t-receipt" "超窗 worker 不触发 app 调用"
# 长跑 worker 的磁盘文件不会动——不能因为 mtime 老就把它从面板上抹掉
sed -i '' "s/^started_at=.*/started_at=$OLD/" "$COORD/running-mod.codex-app.env"
touch -t "$STAMP" "$COORD/running-mod.codex-app.env"
OUT="$(run_panel --json --max-age-hours 24)"
assert_eq "$(bucket_of "$OUT" running-mod)" "pending" "状态未定的老 worker 仍要去问 app-server"
sed -i '' "s/^started_at=.*/started_at=$(( $(now) - 600 ))/" "$COORD/done-mod.codex-app.env" "$COORD/running-mod.codex-app.env"
touch "$COORD/done-mod.summary.md" "$COORD/done-mod.codex-app.env" "$COORD/running-mod.codex-app.env"

# ---------------------------------------------------------------- 耗时口径
# 时间列回答的是"这个 worker 干了多久"，不是"派发到现在过了多久"——后者对已收工的 worker 会一直
# 往上涨，昨天派的写成 20h，看不出它其实只跑了几分钟。元数据里没有结束时间（thread 收工时没人
# 往磁盘写），所以拿最后一次真实活动来算：回执 mtime > rollout mtime > meta mtime。
CASE="耗时口径"
assert_near(){ # $1=实得 $2=期望 $3=容差 $4=说明
  local d=$(( $1 - $2 )); d=${d#-}
  [[ $d -le $3 ]] && ok || fail "$4: 期望 ≈$2（±$3）实得 $1"
}
set_mtime(){ touch -t "$(date -r "$2" +%Y%m%d%H%M.%S)" "$1"; }

NOW="$(now)"
# 已回执：600 秒前派发，300 秒前落的回执 → 实际跑了 300 秒，而不是 600
sed -i '' "s/^started_at=.*/started_at=$(( NOW - 600 ))/" "$COORD/done-mod.codex-app.env"
set_mtime "$COORD/done-mod.summary.md" "$(( NOW - 300 ))"
# meta 被编排者写过（status 脚本会往里追加 detail），mtime 比回执新——它不能算 worker 在干活
touch "$COORD/done-mod.codex-app.env"
OUT="$(run_panel --json)"
assert_near "$(J "$OUT" '(j.jobs.find(x=>x.module==="done-mod")||{}).elapsed_sec')" 300 5 "已收工的显示实际执行耗时"
assert_near "$(J "$OUT" '(j.jobs.find(x=>x.module==="done-mod")||{}).ended_at')" "$(( NOW - 300 ))" 5 "结束时间取回执落盘那一刻"

# 还在跑：没有结束时间，耗时一直算到现在
assert_eq "$(J "$OUT" '(j.jobs.find(x=>x.module==="running-mod")||{}).ended_at')" "0" "执行中的没有结束时间"
assert_near "$(J "$OUT" '(j.jobs.find(x=>x.module==="running-mod")||{}).elapsed_sec')" 600 5 "执行中的算到此刻为止"

# 需核验（idle 但没落回执）：没有回执可用，退回 rollout 日志的最后写入时间
sed -i '' "s/^started_at=.*/started_at=$(( NOW - 600 ))/" "$COORD/idle-mod.codex-app.env"
ROLL_IDLE="$CODEX/sessions/2026/08/13/rollout-2026-08-13T10-00-00-t-idle.jsonl"
echo '{"type":"event_msg","payload":{"type":"agent_message","message":"我先跑到这里"}}' > "$ROLL_IDLE"
set_mtime "$ROLL_IDLE" "$(( NOW - 120 ))"
touch "$COORD/idle-mod.codex-app.env"   # meta 更新，同样不该被优先采信
OUT="$(run_panel --json)"
assert_near "$(J "$OUT" '(j.jobs.find(x=>x.module==="idle-mod")||{}).elapsed_sec')" 480 5 "没有回执时按 rollout 最后活动算耗时"
assert_near "$(J "$OUT" '(j.jobs.find(x=>x.module==="idle-mod")||{}).ended_at')" "$(( NOW - 120 ))" 5 "结束时间取 rollout 最后写入时刻"

# 详情页把两头摊开，免得一个数字分不清"跑了多久"和"什么时候跑的"
DETAIL_IDX="$(J "$OUT" "j.jobs.findIndex(x=>x.module==='done-mod')")"
KEYS="$(printf 'down,%.0s' $(seq 1 "$DETAIL_IDX"))right"
OUT="$(run_panel --once --plain --keys "$KEYS")"
assert_contains "$OUT" "耗时   5m" "详情页显示耗时"
assert_contains "$OUT" "→" "详情页把开始/结束两头都摊开"

set_mtime "$COORD/done-mod.summary.md" "$NOW"
rm -f "$ROLL_IDLE"

# ---------------------------------------------------------------- 渲染
CASE="渲染"
OUT="$(run_panel --once --plain)"
assert_contains "$OUT" "Codex Fleet"              "有标题"
assert_contains "$OUT" "虚拟OMS上线前检查清单"      "任务组标题是主 session 名字"
assert_contains "$OUT" "RQ-TEST-001"             "组标题带 RQ"
assert_contains "$OUT" "1/5 完成"                 "组标题带完成度"
assert_contains "$OUT" "未完成"                   "有未完成栏"
assert_contains "$OUT" "已完成"                   "有已完成栏"
assert_contains "$OUT" "↳running-mod"            "worker 行只留模块名（RQ 已在组标题）"
assert_not_contains "$OUT" "Working"             "不再按 Working/Completed 分组"
LONGEST="$(COLUMNS=80 run_panel --once --plain | awk '{ print length($0) }' | sort -rn | head -1)"
[[ "$LONGEST" -le 220 ]] && ok || fail "行宽失控: $LONGEST"

# ---------------------------------------------------------------- 执行中标记动画
CASE="标记动画"
FRAMES="$(for k in "" down down,down down,down,down; do
  if [[ -z "$k" ]]; then run_panel --once --plain | grep -F "↳running-mod"; fi
done)"
# 帧序列由 --keys 无关的 ui.frame 驱动，这里直接校验字符集与"非执行中不动"
MARK="$(run_panel --once --plain | grep -F "↳running-mod" | sed 's/^ *\(.\).*/\1/')"
[[ "·✢✳∗✻✽" == *"$MARK"* ]] && ok || fail "执行中的标记应取自动画帧集合，实得 [$MARK]"
MARK_DONE="$(run_panel --once --plain | grep -F "↳done-mod" | sed 's/^ *\(.\).*/\1/')"
assert_eq "$MARK_DONE" "✓" "已完成的标记固定为 ✓，不参与动画"
MARK_BLOCKED="$(run_panel --once --plain | grep -F "↳blocked-mod" | sed 's/^ *\(.\).*/\1/')"
assert_eq "$MARK_BLOCKED" "⏳" "待输入的标记固定为 ⏳"
OUT="$(run_panel --once --plain --no-spin)"
assert_contains "$(echo "$OUT" | grep -F "↳running-mod")" "✳" "--no-spin 时退回静态 ✳"

# ---------------------------------------------------------------- 导航
CASE="导航"
OUT="$(run_panel --json --keys down)"
assert_eq "$(J "$OUT" 'j.cursor')" "1" "↓ 移动光标"
OUT="$(run_panel --json --keys down,down,up)"
assert_eq "$(J "$OUT" 'j.cursor')" "1" "↑ 回退光标"
OUT="$(run_panel --json --keys right)"
assert_eq "$(J "$OUT" 'j.view')" "detail" "→ 进入详情"
OUT="$(run_panel --json --keys right,left)"
assert_eq "$(J "$OUT" 'j.view')" "list" "← 退回列表"
OUT="$(run_panel --json --keys up,up,up,up)"
assert_eq "$(J "$OUT" 'j.cursor')" "0" "光标不越界（上）"
OUT="$(run_panel --json --keys down,down,down,down,down,down,down,down,down,down)"
assert_eq "$(J "$OUT" 'j.cursor')" "$(J "$OUT" 'j.jobs.length-1')" "光标不越界（下）"
# 光标要能跨任务组走到第二组
OUT="$(run_panel --json --keys down,down,down,down,down)"
assert_eq "$(J "$OUT" 'j.selected.rq')" "RQ-TEST-002" "光标可以跨任务组移动"

# ---------------------------------------------------------------- 详情
CASE="详情走 rollout"
keys_to(){
  local idx; idx="$(J "$(run_panel --json)" "j.jobs.findIndex(x=>x.module==='$1')")"
  node -pe '"down,".repeat(Number(process.argv[1]))+"right"' "$idx"
}
OUT="$(run_panel --once --plain --keys "$(keys_to running-mod)")"
# app-server 的 thread/read 只给消息级 item，命令和思考只有 rollout 里有
assert_contains "$OUT" "pnpm test -- inventory" "详情展示执行的命令"
assert_contains "$OUT" "42 passed"              "详情展示命令输出"
assert_contains "$OUT" "exit=0"                 "详情展示退出码"
assert_contains "$OUT" "先看库存口径"            "详情展示思考"
assert_contains "$OUT" "开始核对"                "详情展示回复"
assert_contains "$OUT" "任务卡"                  "详情展示任务卡"
assert_contains "$OUT" "deepseek"               "详情展示实际模型（不能信 worker 自述）"
assert_contains "$OUT" "← 返回"                 "详情有返回提示"

CASE="详情兜底"
# 没有 rollout 时退回 app-server，并且要明说这是降级视图
OUT="$(run_panel --once --plain --keys "$(keys_to idle-mod)")"
assert_contains "$OUT" "找不到 rollout" "无 rollout 时明确告知是降级视图"
assert_contains "$OUT" "我先跑到这里"   "降级视图仍展示 app-server 拿到的回复"

CASE="详情含回执"
OUT="$(run_panel --once --plain --keys "$(keys_to done-mod)")"
assert_contains "$OUT" "库存模块已完成" "详情摊开回执正文"
assert_contains "$OUT" "已合回集成分支" "回执正文完整展示（不止首行）"

# ---------------------------------------------------------------- 分屏比例换算
CASE="分屏比例换算"
OUT="$(node -e '
const L=require(process.argv[1]+"/scripts/lib/codex-app-jobs.js");
const out=[];
// 刚 split 出来是对半：当前 100 列 ⇒ 源面板 200 列，目标 1/3 ≈ 66 列，要缩 34 列
const a=L.planSplitResize({currentCols:100,ratio:1/3});
out.push(["a",a.totalCols,a.targetCols,a.deltaCols,a.direction,a.done].join("|"));
// 右侧面板变窄 = 把左边界往右推
const b=L.planSplitResize({currentCols:100,ratio:0.7,totalCols:200});
out.push(["b",b.targetCols,b.direction,b.done].join("|"));
// 已经到位就别再动（避免来回抖）
const c=L.planSplitResize({currentCols:66,ratio:1/3,totalCols:200});
out.push(["c",c.done].join("|"));
// 像素 = 列差 × 每列像素；每列像素由上一轮实测反推
const d=L.planSplitResize({currentCols:100,ratio:0.5,totalCols:150,pxPerCol:12});
out.push(["d",d.deltaCols,d.pixels].join("|"));
// 再小也要留出可读宽度
const e=L.planSplitResize({currentCols:100,ratio:0.01,totalCols:200});
out.push(["e",e.targetCols].join("|"));
console.log(out.join("\n"));' "$ROOT")"
assert_contains "$OUT" "a|200|67|33|right|false" "对半推总宽、算目标列、算方向"
assert_contains "$OUT" "b|140|left|false"        "要变宽时方向相反"
assert_contains "$OUT" "c|true"                  "已到位就不再发 resize"
assert_contains "$OUT" "d|25|300"                "像素按实测的每列像素换算"
assert_contains "$OUT" "e|20"                    "比例过小时仍保底 20 列"

# ---------------------------------------------------------------- 边界
CASE="空注册表"
OUT="$(HOME="$HOME_DIR" CC_FLEET_PANEL_REGISTRY="$TMP/none.json" "$PANEL" --once --plain 2>&1)"
assert_contains "$OUT" "派发后会自动出现在这里" "没有 worker 时给出提示而不是报错"

CASE="app-server 不可达"
BROKEN="$TMP/broken-call"; printf '#!/bin/sh\nexit 9\n' > "$BROKEN"; chmod +x "$BROKEN"
OUT="$(HOME="$HOME_DIR" CODEX_HOME="$CODEX" CC_FLEET_PANEL_REGISTRY="$REG" CODEX_APP_CALL_BIN="$BROKEN" "$PANEL" --once --plain 2>&1)"
assert_contains "$OUT" "app-server 不可达" "读不到 thread 时明确告警"
assert_contains "$OUT" "库存模块已完成"    "app-server 挂了也仍能显示已落回执的 worker"

echo
if [[ $FAIL -eq 0 ]]; then
  echo "==== cc-fleet-panel-codex-app: $PASS 项全部通过 ===="
  exit 0
fi
echo "==== cc-fleet-panel-codex-app: $PASS 通过 / $FAIL 失败 ===="
exit 1
