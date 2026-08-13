#!/usr/bin/env bash
# codex-rollout 解析器回归：rollout 定位、事件→时间线、命令/输出配对、cd 前缀剥离、最近活动。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0; CASE="init"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ [$CASE] $1"; FAIL=$((FAIL+1)); }
assert_eq(){ [[ "$1" == "$2" ]] && ok || fail "$3: 期望 [$2] 实得 [$1]"; }
assert_contains(){ [[ "$1" == *"$2"* ]] && ok || fail "$3: 找不到 [$2]"; }

TID="019f0000-1111-2222-3333-444444444444"
DIR="$TMP/codex-home/sessions/2026/08/13"
mkdir -p "$DIR"
ROLL="$DIR/rollout-2026-08-13T10-00-00-$TID.jsonl"

# 真实 rollout 的形状：session_meta / thread_settings_applied / task_started / user_message /
# reasoning（正文在 content 而非 summary）/ agent_message / function_call + function_call_output
cat > "$ROLL" <<'JSONL'
{"type":"session_meta","payload":{"session_id":"019f0000-1111-2222-3333-444444444444","cwd":"/repo","model_provider":"deepseek","timestamp":"2026-08-13T02:00:00.000Z"}}
{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"deepseek-v4-pro","model_provider_id":"deepseek","reasoning_effort":"high","cwd":"/repo/wt/mod"}}}
{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
{"type":"event_msg","payload":{"type":"user_message","message":"L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8\nL9\nL10"}}
{"type":"response_item","payload":{"type":"reasoning","summary":[],"content":[{"type":"reasoning_text","text":"先核对分支再动手"}]}}
{"type":"event_msg","payload":{"type":"agent_message","message":"我先看一下当前状态"}}
{"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call-1","arguments":"{\"cmd\": \"cd \\\"/repo/wt/mod\\\" && pnpm test -- inventory\", \"workdir\": \"/repo/wt/mod\"}"}}
{"type":"response_item","payload":{"type":"function_call_output","call_id":"call-1","output":"Chunk ID: abc\nWall time: 1.2 seconds\nProcess exited with code 0\nOriginal token count: 65\nOutput:\n42 passed\ndone"}}
{"type":"response_item","payload":{"type":"function_call","name":"apply_patch","call_id":"call-2","arguments":"{\"input\": \"*** Begin Patch\\n*** Update File: src/a.ts\\n*** Add File: src/b.ts\\n*** End Patch\"}"}}
{"type":"response_item","payload":{"type":"function_call_output","call_id":"call-2","output":"Process exited with code 0\nOutput:\nok"}}
{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"注入的 CLAUDE.md 全文，几千行，不该进时间线"}]}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":41243}}}}
JSONL

RUN(){ CODEX_HOME="$TMP/codex-home" node -e "$1" "${@:2}"; }

# ---------------------------------------------------------------- 定位
CASE="定位 rollout"
OUT="$(RUN 'const R=require(process.argv[1]+"/scripts/lib/codex-rollout.js");console.log(R.findRollout(process.argv[2]))' "$ROOT" "$TID")"
assert_contains "$OUT" "$TID" "按 thread id 找到 rollout"
OUT="$(RUN 'const R=require(process.argv[1]+"/scripts/lib/codex-rollout.js");console.log(R.findRollout("no-such-thread")||"EMPTY")' "$ROOT")"
assert_eq "$OUT" "EMPTY" "找不到时返回空而不是抛错"

# ---------------------------------------------------------------- 时间线
CASE="时间线"
JSON="$(RUN 'const R=require(process.argv[1]+"/scripts/lib/codex-rollout.js");
const t=R.readTimeline(process.argv[2]);
console.log(JSON.stringify({meta:t.meta,types:t.items.map(i=>i.type),items:t.items}))' "$ROOT" "$ROLL")"
J(){ echo "$JSON" | node -pe "const j=JSON.parse(require('fs').readFileSync(0,'utf8'));$1"; }

assert_eq "$(J 'j.meta.model')" "deepseek-v4-pro" "从 thread_settings 取到真实模型"
assert_eq "$(J 'j.meta.effort')" "high" "取到 reasoning effort"
assert_eq "$(J 'j.meta.workdir')" "/repo/wt/mod" "取到 worker 实际工作目录"
assert_eq "$(J 'j.meta.tokens')" "41243" "取到累计 token"
assert_eq "$(J 'j.types.join(",")')" "turn,task,thinking,message,call,call" "事件按序压成时间线"
# reasoning 的正文常常在 content 而不是 summary（reasoning_summary=none 时 summary 是空数组）
assert_eq "$(J 'j.items[2].text')" "先核对分支再动手" "reasoning 取 content 正文"
# 注入的 developer 消息是几千行 CLAUDE.md，绝不能进时间线
assert_eq "$(J 'j.items.filter(i=>String(i.text).includes("不该进时间线")).length')" "0" "developer 注入内容不进时间线"

CASE="命令与输出配对"
assert_eq "$(J 'j.items[4].text')" "pnpm test -- inventory" "剥掉 Codex 给每条命令加的 cd 前缀"
assert_eq "$(J 'j.items[4].workdir')" "/repo/wt/mod" "cd 的路径回填到 workdir"
assert_eq "$(J 'j.items[4].exitCode')" "0" "按 call_id 配上 exit code"
assert_contains "$(J 'j.items[4].output')" "42 passed" "配上命令输出"
# 输出头部那段 Chunk ID / Wall time / token count 是包装，不该混进正文
assert_eq "$(J 'j.items[4].output.includes("Chunk ID")')" "false" "剥掉输出的包装头"
assert_eq "$(J 'j.items[5].kind')" "patch" "apply_patch 识别为改文件"
assert_contains "$(J 'j.items[5].text')" "src/a.ts" "列出被改的文件"
assert_contains "$(J 'j.items[5].text')" "src/b.ts" "新增的文件也列出"

CASE="cd 前缀剥离"
OUT="$(RUN 'const R=require(process.argv[1]+"/scripts/lib/codex-rollout.js");
const cases=[["cd \"/a b/c\" && ls","ls","/a b/c"],["cd /x && pwd","pwd","/x"],["ls -la","ls -la",""]];
for(const [inp,text,wd] of cases){const r=R.stripCdPrefix(inp);
if(r.text!==text||r.workdir!==wd){console.log("BAD "+inp+" -> "+JSON.stringify(r));process.exit(1)}}
console.log("OK")' "$ROOT")"
assert_eq "$OUT" "OK" "带引号/不带引号/无前缀三种都处理对"

# ---------------------------------------------------------------- 最近活动
CASE="最近活动"
OUT="$(RUN 'const R=require(process.argv[1]+"/scripts/lib/codex-rollout.js");
console.log(JSON.stringify(R.lastActivity(process.argv[2])))' "$ROOT" "$ROLL")"
assert_contains "$OUT" '"kind":"patch"' "最近一条活动是最后那次改文件"
# 反向扫描要能跳过 token_count 这类噪声事件
assert_eq "$(echo "$OUT" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).text.includes("src/a.ts")')" "true" "最近活动带上文件名"

CASE="空/坏文件"
: > "$TMP/empty.jsonl"
OUT="$(RUN 'const R=require(process.argv[1]+"/scripts/lib/codex-rollout.js");
const t=R.readTimeline(process.argv[2]);console.log(t.items.length+"/"+String(R.lastActivity(process.argv[2])))' "$ROOT" "$TMP/empty.jsonl")"
assert_eq "$OUT" "0/null" "空文件不崩"
printf 'not json\n{"type":"event_msg","payload":{"type":"agent_message","message":"活着"}}\n' > "$TMP/broken.jsonl"
OUT="$(RUN 'const R=require(process.argv[1]+"/scripts/lib/codex-rollout.js");
const t=R.readTimeline(process.argv[2]);console.log(t.items.length)' "$ROOT" "$TMP/broken.jsonl")"
assert_eq "$OUT" "1" "坏行跳过、好行照读"

echo
if [[ $FAIL -eq 0 ]]; then
  echo "==== codex-rollout: $PASS 项全部通过 ===="
  exit 0
fi
echo "==== codex-rollout: $PASS 通过 / $FAIL 失败 ===="
exit 1
