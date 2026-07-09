#!/usr/bin/env bash
# test-cc-fleet-fix-display-all.sh — cc-fleet-fix-display 【全局兜底 --all】模式端到端测试
#
# 回归 2026-06-24 / cli 2.1.187 复发的 "bg/0s"：per-RQ 修复有两个结构盲区——① 跟进 worker 在 watch 退出
# 后才完成、没人再触发；② 名册解析依赖【编排者当前 cwd】，worker 跑在别的仓库路径就解析不到。--all 绕开
# 两者：按【每个 job 自己的 cwd】回溯它自己的 <git-common-dir>/fleet/<RQ>/*.sid（内容==sessionId）还原
# ↳<module>@<RQ>，再兜底 transcript 的 ⟦FLEET-WORKER⟧ 哨兵；完全不要 RQ / 不依赖本进程 cwd / 不连 daemon。
#
# 隔离：临时 jobs-root（伪造 <short>/state.json）+ 临时 git 仓库（伪造 .git/fleet/<RQ>/*.sid 名册）+ 伪造
# transcript。纯本地、可重复、零网络。本测试进程自身 cwd 与各 job 的 cwd【故意不同】，专门验证 cwd 无关性。

set -u
SCRIPT="$(cd "$(dirname "$0")/../scripts" && pwd)/cc-fleet-fix-display"
[ -x "$SCRIPT" ] || { echo "❌ 找不到可执行脚本: $SCRIPT"; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "❌ 需要 jq";  exit 1; }
command -v git >/dev/null 2>&1 || { echo "❌ 需要 git"; exit 1; }

PASS=0; FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
JOBS="$TMP/jobs"; mkdir -p "$JOBS"

T_START="2026-06-24T14:00:00.000Z"
T_END="2026-06-24T15:00:00.000Z"
T_COLLAPSE="2026-06-24T15:00:00.123Z"   # 塌缩点（created==firstTerminal==updated）

check() {  # $1=用例名 $2=期望 $3=实际
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n    期望=[%s] 实际=[%s]\n' "$1" "$2" "$3"; fi
}
field() { jq -r "$2 // \"∅\"" "$JOBS/$1/state.json" 2>/dev/null; }

# 伪造 transcript：多行 JSON，含首/末时间戳；$4 非空时把它作为首行 user 消息正文（用于塞 ⟦FLEET-WORKER⟧ 哨兵）
mk_tx() {  # $1=路径 $2=首ts $3=末ts [$4=首行正文]
  local body="${4:-start}"
  {
    printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"%s"}}\n' "$2" "$body"
    printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":"mid"}}\n' "2026-06-24T14:30:00.000Z"
    printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":"end"}}\n' "$3"
  } > "$1"
}

mk_job() {  # $1=short $2=state.json 内容
  mkdir -p "$JOBS/$1"; printf '%s' "$2" > "$JOBS/$1/state.json"
}

# 临时 git 仓库 + sid 名册：$1=仓库路径 $2=RQ $3=module $4=sessionId
mk_sid() {
  local repo="$1" rq="$2" mod="$3" sid="$4"
  [ -d "$repo/.git" ] || git init -q "$repo"
  mkdir -p "$repo/.git/fleet/$rq"
  printf '%s\n' "$sid" > "$repo/.git/fleet/$rq/$mod.sid"
}

# 两个独立仓库：REPO_SID 有 sid 名册；REPO_BARE 是 git 仓库但【无】fleet 名册（用于哨兵/非 fleet 用例）
REPO_SID="$TMP/repo-sid"; git init -q "$REPO_SID"
REPO_BARE="$TMP/repo-bare"; git init -q "$REPO_BARE"
RQ_A="RQ-2026-0624-077"

# ---- G: 退化 worker（无 name + 时间戳塌缩），cwd 自带 sid 名册 → 应靠 sid 还原 ↳moduleG@RQ_A + 修时间 ----
mk_tx "$TMP/tx-G.jsonl" "$T_START" "$T_END"
mk_sid "$REPO_SID" "${RQ_A}" "moduleG" "sid-G"
mk_job gsid0001 "$(jq -nc --arg tx "$TMP/tx-G.jsonl" --arg t "$T_COLLAPSE" --arg cwd "$REPO_SID" \
  '{state:"done",template:"bg",detail:"G 完成",intent:"",sessionId:"sid-G",cwd:$cwd,
    linkScanPath:$tx,createdAt:$t,updatedAt:$t,firstTerminalAt:$t}')"

# ---- H: 退化 worker，cwd【无】sid 名册，但 transcript 首行有 ⟦FLEET-WORKER⟧ 哨兵 → 应靠哨兵还原 ----
mk_tx "$TMP/tx-H.jsonl" "$T_START" "$T_END" "⟦FLEET-WORKER⟧ rq=RQ-2026-0624-088 module=moduleH 任务卡正文…"
mk_job hsen0001 "$(jq -nc --arg tx "$TMP/tx-H.jsonl" --arg t "$T_COLLAPSE" --arg cwd "$REPO_BARE" \
  '{state:"done",template:"bg",sessionId:"sid-H",cwd:$cwd,
    linkScanPath:$tx,createdAt:$t,updatedAt:$t,firstTerminalAt:$t}')"

# ---- I: 非 fleet 会话（name 可读非空、时间戳塌缩，但 cwd 无名册、transcript 无哨兵）→ 绝不能碰 ----
mk_tx "$TMP/tx-I.jsonl" "$T_START" "$T_END"   # 普通 transcript，无哨兵
mk_job inon0001 "$(jq -nc --arg tx "$TMP/tx-I.jsonl" --arg t "$T_COLLAPSE" --arg cwd "$REPO_BARE" \
  '{state:"done",template:"claude",name:"我的普通会话",nameSource:"user",sessionId:"sid-I",cwd:$cwd,
    linkScanPath:$tx,createdAt:$t,updatedAt:$t,firstTerminalAt:$t}')"

# ---- J: 纯外观（name 可读但缺 ↳、时间戳正常）→ 非 bg/0s 退化，应原样不动（不制造 churn）----
mk_job jcos0001 "$(jq -nc --arg s "$T_START" --arg e "$T_END" --arg cwd "$REPO_SID" \
  '{state:"done",template:"bg",name:"moduleJ@RQ-old",sessionId:"sid-J",cwd:$cwd,
    createdAt:$s,updatedAt:$e,firstTerminalAt:$e}')"

# ---- K: 运行中（塌缩+无 name），cwd 自带名册 → 终态守卫，绝不能碰 ----
mk_sid "$REPO_SID" "${RQ_A}" "moduleK" "sid-K"
mk_job krun0001 "$(jq -nc --arg t "$T_COLLAPSE" --arg cwd "$REPO_SID" \
  '{state:"running",template:"bg",tempo:"active",sessionId:"sid-K",cwd:$cwd,
    createdAt:$t,updatedAt:$t,firstTerminalAt:$t}')"

echo "================= --all --dry-run 不落盘 ================="
out="$("$SCRIPT" --all --jobs-root "$JOBS" --dry-run 2>&1)"
check "dry-run 命中 G（schedule 类退化）" "yes" "$(echo "$out" | grep -q 'moduleG' && echo yes || echo no)"
check "dry-run 命中 H（哨兵还原）"        "yes" "$(echo "$out" | grep -q 'moduleH' && echo yes || echo no)"
check "dry-run 不碰 I（非 fleet）"        "no"  "$(echo "$out" | grep -q 'sid-I\|我的普通会话\|inon0001' && echo yes || echo no)"
check "dry-run 不碰 J（纯外观）"          "no"  "$(echo "$out" | grep -q 'moduleJ' && echo yes || echo no)"
check "dry-run 不落盘：G 仍 ∅"           "∅"   "$(field gsid0001 .name)"

echo "================= --all 实跑 ================="
out="$("$SCRIPT" --all --jobs-root "$JOBS" 2>&1)"

# G：sid 名册还原（cwd 无关——本测试进程 cwd 不在 REPO_SID）
check "G name → ↳moduleG@${RQ_A}（sid 还原）" "↳moduleG@${RQ_A}" "$(field gsid0001 .name)"
check "G nameSource → user"                 "user"           "$(field gsid0001 .nameSource)"
check "G createdAt → transcript 首ts"       "$T_START"       "$(field gsid0001 .createdAt)"
check "G firstTerminalAt → transcript 末ts" "$T_END"         "$(field gsid0001 .firstTerminalAt)"
check "G updatedAt → transcript 末ts"       "$T_END"         "$(field gsid0001 .updatedAt)"
check "G 其它字段保留（detail 不丢）"       "G 完成"          "$(field gsid0001 .detail)"

# H：哨兵还原（RQ 来自 transcript，与 RQ_A 不同，证明确实读的是哨兵）
check "H name → ↳moduleH@RQ-2026-0624-088（哨兵还原）" "↳moduleH@RQ-2026-0624-088" "$(field hsen0001 .name)"
check "H createdAt → transcript 首ts"       "$T_START"       "$(field hsen0001 .createdAt)"

# I：非 fleet → 一动不动
check "I（非 fleet）name 不变"              "我的普通会话"    "$(field inon0001 .name)"
check "I（非 fleet）createdAt 仍塌缩"        "$T_COLLAPSE"    "$(field inon0001 .createdAt)"

# J：纯外观 → 一动不动
check "J（纯外观）name 不变"                "moduleJ@RQ-old"  "$(field jcos0001 .name)"
check "J（纯外观）createdAt 不变"           "$T_START"        "$(field jcos0001 .createdAt)"

# K：运行中 → 一动不动
check "K（running）name 仍 ∅"               "∅"              "$(field krun0001 .name)"
check "K（running）createdAt 仍塌缩"         "$T_COLLAPSE"    "$(field krun0001 .createdAt)"

echo "================= --max-age-hours 过滤 ================="
# L：退化 worker，但把 state.json mtime 设到很早 → --max-age-hours 1 应跳过；--max-age-hours 0 应修复
mk_tx "$TMP/tx-L.jsonl" "$T_START" "$T_END"
mk_sid "$REPO_SID" "${RQ_A}" "moduleL" "sid-L"
mk_job lage0001 "$(jq -nc --arg tx "$TMP/tx-L.jsonl" --arg t "$T_COLLAPSE" --arg cwd "$REPO_SID" \
  '{state:"done",template:"bg",sessionId:"sid-L",cwd:$cwd,
    linkScanPath:$tx,createdAt:$t,updatedAt:$t,firstTerminalAt:$t}')"
touch -t 202601010000 "$JOBS/lage0001/state.json" 2>/dev/null
"$SCRIPT" --all --jobs-root "$JOBS" --max-age-hours 1 >/dev/null 2>&1
check "L 超龄被 --max-age-hours 1 跳过（仍 ∅）" "∅" "$(field lage0001 .name)"
"$SCRIPT" --all --jobs-root "$JOBS" --max-age-hours 0 >/dev/null 2>&1
check "L 在 --max-age-hours 0 下被修复" "↳moduleL@${RQ_A}" "$(field lage0001 .name)"

echo "================= 幂等：再跑一次不应改动已修好的 G ================="
before="$(cat "$JOBS/gsid0001/state.json")"
sleep 1
mt_before="$(stat -f %m "$JOBS/gsid0001/state.json" 2>/dev/null || stat -c %Y "$JOBS/gsid0001/state.json" 2>/dev/null)"
out2="$("$SCRIPT" --all --jobs-root "$JOBS" 2>&1)"
mt_after="$(stat -f %m "$JOBS/gsid0001/state.json" 2>/dev/null || stat -c %Y "$JOBS/gsid0001/state.json" 2>/dev/null)"
check "幂等：G 内容不变" "$before" "$(cat "$JOBS/gsid0001/state.json")"
check "幂等：G 文件未被重写（mtime 不变）" "$mt_before" "$mt_after"

echo
echo "==== cc-fleet-fix-display --all 测试：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] && { echo "✅ 全绿"; exit 0; } || { echo "❌ 有失败"; exit 1; }
