#!/usr/bin/env bash
# test-auto-cn-title.sh — auto-cn-title.sh 取名 hook 的端到端测试
#
# 重点回归「子 session 名字退化成 bg」：daemon respawn 会丢掉 seed name，FleetView 退回显示
# 默认 template "bg"；hook 必须在 SessionStart 时从多源恢复出正确显示名。
#
# 隔离方式：用临时 HOME（缓存落临时目录、读不到 deepseek.key → 不触网），payload 经 stdin 投喂，
# 断言 hook 输出的 sessionTitle。纯本地、可重复、零网络。

set -u
HOOK="$HOME/.claude/hooks/auto-cn-title.sh"
[ -f "$HOOK" ] || { echo "❌ 找不到 hook: $HOOK"; exit 1; }

PASS=0; FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
FAKE_HOME="$TMPROOT/home"; mkdir -p "$FAKE_HOME/.claude/.title-cache"
# 隔离 CLAUDE_JOB_DIR（关键）：默认指向一个【无 state.json】的空目录。hook 的 persist_job_name() 会把
# worker 标题原子写进 ${CLAUDE_JOB_DIR}/state.json 的 .name，这是无条件副作用；若不隔离，从一个【真实运行的
# 后台 session】里跑本套件时，worker 夹具（⟦FLEET-WORKER⟧ module=gateway/pay/foo）会把夹具名写进【真实
# session 的 state.json】，把该 session 改名成 ↳gateway@… 等（实测踩过）。空目录无 state.json → persist 直接
# no-op。需要断言 state.json 的用例在 "${@:2}" 里显式传 CLAUDE_JOB_DIR=<临时JD> 覆盖（env 后者生效）。
NOJOB="$TMPROOT/nojob"; mkdir -p "$NOJOB"

# 在隔离 HOME + 隔离 CLAUDE_JOB_DIR 下跑 hook，回显其 stdout
run_hook() { printf '%s' "$1" | env HOME="$FAKE_HOME" CLAUDE_JOB_DIR="$NOJOB" "${@:2}" bash "$HOOK" 2>/dev/null || true; }
title_of() { printf '%s' "$1" | jq -r '.sessionTitle // empty' 2>/dev/null || true; }
nested_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.sessionTitle // empty' 2>/dev/null || true; }

check() {  # $1=用例名 $2=期望 $3=实际
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n    期望=[%s] 实际=[%s]\n' "$1" "$2" "$3"; fi
}
# 同时校验两种输出形态都带上了标题（跨 CC 版本兼容）
check_both() {  # $1=用例名 $2=期望 $3=hook输出
  check "$1 (顶层 sessionTitle)" "$2" "$(title_of "$3")"
  check "$1 (嵌套 hookSpecificOutput)" "$2" "$(nested_of "$3")"
}

# ---- 合成 transcript ----
WORKER_TX="$TMPROOT/worker.jsonl"
printf '%s\n' \
  '{"type":"custom-title","customTitle":"↳gateway","sessionId":"w"}' \
  '{"type":"user","message":{"role":"user","content":"⟦FLEET-WORKER⟧ rq=RQ-2026-0602-001 module=gateway\n⟦INJECTED-CLAUDE-MD⟧ 干扰 rq=RQ-9999-ZZ module=decoy ... module=decoy2"}}' \
  > "$WORKER_TX"

CTITLE_TX="$TMPROOT/ctitle.jsonl"   # 无哨兵、有 custom-title（普通会话缓存被清的兜底）
printf '%s\n' \
  '{"type":"custom-title","customTitle":"我的中文标题","sessionId":"c"}' \
  '{"type":"user","message":{"role":"user","content":"普通问题"}}' \
  > "$CTITLE_TX"

EMPTY_TX="$TMPROOT/empty.jsonl"; : > "$EMPTY_TX"

echo "================= SessionStart 多源恢复（核心：杜绝 bg）================="

# ① 哨兵：respawn 后无缓存的 worker，靠 transcript 哨兵重建（混入干扰 module=decoy 不得带偏）
out=$(run_hook "$(jq -nc --arg tp "$WORKER_TX" '{session_id:"ss-worker-nocache", transcript_path:$tp, hook_event_name:"SessionStart", source:"resume"}')")
check_both "① 哨兵重建 worker → ↳gateway@RQ-2026-0602-001" "↳gateway@RQ-2026-0602-001" "$out"

# ② env 兜底：无 transcript/无缓存，但 FLEET_* 在
out=$(run_hook "$(jq -nc '{session_id:"ss-env-worker", hook_event_name:"SessionStart", source:"resume"}')" FLEET_ROLE=worker FLEET_MODULE=pay FLEET_RQ=RQ-2026-0602-007)
check_both "② env 兜底 → ↳pay@RQ-2026-0602-007" "↳pay@RQ-2026-0602-007" "$out"

# ③ 缓存：无 transcript/无 env，命中 <session_id>.title（原有行为）
printf '%s' "动态工作流解析" > "$FAKE_HOME/.claude/.title-cache/ss-cached.title"
out=$(run_hook "$(jq -nc '{session_id:"ss-cached", hook_event_name:"SessionStart", source:"resume"}')")
check_both "③ 缓存恢复普通会话 → 动态工作流解析" "动态工作流解析" "$out"

# ④ custom-title 兜底：无缓存、transcript 无哨兵但有 custom-title
out=$(run_hook "$(jq -nc --arg tp "$CTITLE_TX" '{session_id:"ss-ctitle", transcript_path:$tp, hook_event_name:"SessionStart", source:"resume"}')")
check_both "④ custom-title 兜底 → 我的中文标题" "我的中文标题" "$out"

# 全 miss → no-op（输出为空，且 exit 0）
out=$(run_hook "$(jq -nc --arg tp "$EMPTY_TX" '{session_id:"ss-miss", transcript_path:$tp, hook_event_name:"SessionStart", source:"startup"}')")
check "全 miss → no-op 空输出" "" "$(title_of "$out")"

echo "================= UserPromptSubmit ================="

# worker 首条 prompt 带哨兵 + 注入块同名键干扰 → 锚定取首个匹配，重建 ↳<module>@<RQ>
ups='⟦FLEET-WORKER⟧ rq=RQ-2026-0602-009 module=foo
⟦INJECTED-CLAUDE-MD⟧ 干扰 rq=RQ-9999-XX module=decoy 又一个 module=decoy2
任务卡正文'
out=$(run_hook "$(jq -nc --arg p "$ups" '{session_id:"ups-worker", prompt:$p, hook_event_name:"UserPromptSubmit"}')")
check_both "UPS worker(抗干扰) → ↳foo@RQ-2026-0602-009" "↳foo@RQ-2026-0602-009" "$out"

# worker 缓存命中第二条 prompt（沿用首条写入的缓存）
out=$(run_hook "$(jq -nc --arg p "$ups" '{session_id:"ups-worker", prompt:"第二条", hook_event_name:"UserPromptSubmit"}')")
check_both "UPS worker 第二条沿用缓存 → ↳foo@RQ-2026-0602-009" "↳foo@RQ-2026-0602-009" "$out"

# 普通会话命中既有缓存
printf '%s' "已有中文标题" > "$FAKE_HOME/.claude/.title-cache/ups-cached.title"
out=$(run_hook "$(jq -nc '{session_id:"ups-cached", prompt:"问题", hook_event_name:"UserPromptSubmit"}')")
check_both "UPS 普通会话命中缓存 → 已有中文标题" "已有中文标题" "$out"

# 缺 session_id：安全 exit 0、无输出
out=$(run_hook '{"hook_event_name":"UserPromptSubmit","prompt":"x"}')
check "缺 session_id → 空输出" "" "$(title_of "$out")"

echo "================= state.json.name 持久化（核心：FleetView 任务列表读这个字段，根治 bg）================="
# CC 2.1.16x+ 任务列表显示名只读 state.json.name（缺失回退 template="bg"）。hook 必须把 worker 名字
# 直接写进 state.json.name，否则 spare 池 respawn 完成的 worker 永远显示 "bg"。普通/主 session 不碰。
name_in() { jq -r '.name // empty'       "$1" 2>/dev/null || true; }
nsrc_in() { jq -r '.nameSource // empty' "$1" 2>/dev/null || true; }
mk_job() {  # $1=job目录名 $2=初始 state.json 内容 → 回显 job 目录绝对路径
  local jd="$TMPROOT/jobs/$1"; mkdir -p "$jd"; printf '%s' "$2" > "$jd/state.json"; printf '%s' "$jd"
}

# ① worker SessionStart：state.json 原本 template=bg 无 name → 哨兵恢复出 ↳名并落进 state.json.name
JD=$(mk_job worker-ss '{"state":"done","template":"bg","tempo":"idle"}')
out=$(run_hook "$(jq -nc --arg tp "$WORKER_TX" '{session_id:"ss-w1", transcript_path:$tp, hook_event_name:"SessionStart", source:"resume"}')" CLAUDE_JOB_DIR="$JD")
check "① worker SessionStart 写 state.json.name → ↳gateway@RQ-2026-0602-001" "↳gateway@RQ-2026-0602-001" "$(name_in "$JD/state.json")"
check "① 同时打 nameSource=user（贴近 daemon 权威名、抗再次回退）" "user" "$(nsrc_in "$JD/state.json")"
check "① template 等其它字段保持不变（read-modify-write 不丢字段）" "bg" "$(jq -r '.template // empty' "$JD/state.json" 2>/dev/null)"

# ② worker UserPromptSubmit：首条带哨兵 → 名字落 state.json.name
JD=$(mk_job worker-ups '{"state":"working","template":"bg"}')
out=$(run_hook "$(jq -nc --arg p "$ups" '{session_id:"ups-w2", prompt:$p, hook_event_name:"UserPromptSubmit"}')" CLAUDE_JOB_DIR="$JD")
check "② worker UPS 写 state.json.name → ↳foo@RQ-2026-0602-009" "↳foo@RQ-2026-0602-009" "$(name_in "$JD/state.json")"

# ③ 普通会话绝不碰 state.json.name（标题不带 ↳ → 不写；保护用户对普通会话的手动改名）
JD=$(mk_job normal '{"state":"working","template":"claude","name":"我的手动改名","nameSource":"user"}')
out=$(run_hook "$(jq -nc --arg tp "$CTITLE_TX" '{session_id:"ss-normal", transcript_path:$tp, hook_event_name:"SessionStart", source:"resume"}')" CLAUDE_JOB_DIR="$JD")
check "③ 普通会话 state.json.name 不被改写（仍为手动名）" "我的手动改名" "$(name_in "$JD/state.json")"

# ④ 缺 state.json：CLAUDE_JOB_DIR 指向无 state.json 的目录 → 不崩、仍正常 emit sessionTitle
JD="$TMPROOT/jobs/no-state"; mkdir -p "$JD"
out=$(run_hook "$(jq -nc --arg tp "$WORKER_TX" '{session_id:"ss-nofile", transcript_path:$tp, hook_event_name:"SessionStart", source:"resume"}')" CLAUDE_JOB_DIR="$JD")
check "④ 缺 state.json 不崩，sessionTitle 仍照常输出" "↳gateway@RQ-2026-0602-001" "$(title_of "$out")"
check "④ 缺 state.json 时不会凭空创建文件" "no" "$([ -f "$JD/state.json" ] && echo yes || echo no)"

# ⑤ 幂等：name 已一致 → 不重写文件（mtime 不变，把与 daemon 的竞态收敛到仅首次自愈）
JD=$(mk_job idem '{"state":"running","template":"bg","name":"↳gateway@RQ-2026-0602-001","nameSource":"user"}')
before=$(stat -f %m "$JD/state.json" 2>/dev/null || stat -c %Y "$JD/state.json" 2>/dev/null)
sleep 1
out=$(run_hook "$(jq -nc --arg tp "$WORKER_TX" '{session_id:"ss-idem", transcript_path:$tp, hook_event_name:"SessionStart", source:"resume"}')" CLAUDE_JOB_DIR="$JD")
after=$(stat -f %m "$JD/state.json" 2>/dev/null || stat -c %Y "$JD/state.json" 2>/dev/null)
check "⑤ name 已一致 → 文件未被重写（幂等，mtime 不变）" "$before" "$after"

echo "================= SessionStart 全局自愈 sweep（非 worker 节流触发 cc-fleet-fix-display --all）================="
# 把 fixer stub 装到 FAKE_HOME 的预期路径（真实 HOME 下才是 cc-fleet-fix-display；此前各用例因该路径在
# FAKE_HOME 不存在而天然 no-op，故不受影响）。stub 记录每次调用入参，便于断言"调起了 --all"。
FIXER_DIR="$FAKE_HOME/.claude/skills/multi-session-dev/scripts"; mkdir -p "$FIXER_DIR"
REC="$TMPROOT/fixer-invocations.log"
cat > "$FIXER_DIR/cc-fleet-fix-display" <<EOF
#!/usr/bin/env bash
echo "invoked: \$*" >> "$REC"
EOF
chmod +x "$FIXER_DIR/cc-fleet-fix-display"
STAMP="$FAKE_HOME/.claude/.title-cache/fix-display-sweep.stamp"
mt_of() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# ① 非 worker 会话启动 → 写节流戳 + 后台调起 fixer --all
rm -f "$STAMP" "$REC"
printf '%s' "普通主会话" > "$FAKE_HOME/.claude/.title-cache/ss-sweep-main.title"
run_hook "$(jq -nc '{session_id:"ss-sweep-main", hook_event_name:"SessionStart", source:"resume"}')" >/dev/null
check "① 非 worker 启动 → 写 sweep 节流戳" "yes" "$([ -f "$STAMP" ] && echo yes || echo no)"
sleep 1   # 等后台 fire-and-forget 的 stub 落记录
check "① 非 worker 启动 → 实际后台调起 fixer --all" "yes" "$(grep -q -- '--all' "$REC" 2>/dev/null && echo yes || echo no)"

# ② 节流：120s 内二次非 worker 启动 → 不重跑（戳的 mtime 不变）
m1="$(mt_of "$STAMP")"; sleep 1
run_hook "$(jq -nc '{session_id:"ss-sweep-main", hook_event_name:"SessionStart", source:"resume"}')" >/dev/null
check "② 节流：120s 内二次启动不重写戳（mtime 不变）" "$m1" "$(mt_of "$STAMP")"

# ③ worker 会话启动（↳ 名）→ 绝不触发 sweep（交主会话统一扫）
rm -f "$STAMP" "$REC"
run_hook "$(jq -nc --arg tp "$WORKER_TX" '{session_id:"ss-sweep-worker", transcript_path:$tp, hook_event_name:"SessionStart", source:"resume"}')" >/dev/null
check "③ worker 启动 → 不写节流戳（被 ↳ 门控跳过）" "no" "$([ -f "$STAMP" ] && echo yes || echo no)"
sleep 1
check "③ worker 启动 → 未调起 fixer" "" "$(cat "$REC" 2>/dev/null)"

echo
echo "==== auto-cn-title 测试：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] && { echo "✅ 全绿"; exit 0; } || { echo "❌ 有失败"; exit 1; }
