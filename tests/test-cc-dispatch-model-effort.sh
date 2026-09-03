#!/usr/bin/env bash
# test-cc-dispatch-model-effort.sh — 验证 cc-dispatch 给 worker 定模型/思考深度的取值链与协议落点（--dry-run，不连 daemon）。
#
# 设计要点：
#   · 走 daemon 协议本身：flag 拼进 launch.args（claude argv）并同步写入 respawnFlags（daemon 自动重拉不丢），
#     ⛔ 不用 ANTHROPIC_MODEL / CLAUDE_CODE_EFFORT_LEVEL 环境变量（会锁死 /model /effort，且不稳定）。
#   · 取值链：--model/--effort > $HOME/.claude/multi-session-dev.json 的 worker.{model,effort} > 内置默认 opus5/high。
#   · prompt 固定留在 args[0]（既有脚本/测试按此读）。
#   · 非法 effort / 坏配置 → exit 5，宁可派不出去也不让 worker 悄悄跑错深度。

export CC_FLEET_PANEL=0
export CC_FLEET_HOME="${CC_FLEET_HOME_TEST_OVERRIDE:-$(mktemp -d)}"
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$HERE/../scripts/cc-dispatch"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || no "$1 （期望 [$3] 实得 [$2]）"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME/.claude"
CFG="$FAKE_HOME/.claude/multi-session-dev.json"
PROMPT='⟦FLEET-WORKER⟧ rq=RQ-T module=m1
你是 worker。'

# dump <字段> [extra args...] → 打印 launch.args 或 respawnFlags（空格连接）
dump(){
  local field="$1"; shift
  HOME="$FAKE_HOME" "$DISPATCH" --cwd "$TMP" --name "↳m1" --prompt "$PROMPT" --dry-run "$@" 2>/dev/null \
  | python3 -c "import sys,json;d=json.load(sys.stdin)['d'];v=d['launch']['args'] if '$field'=='args' else d['respawnFlags'];print(' '.join(v))"
}
rc_of(){ HOME="$FAKE_HOME" "$DISPATCH" --cwd "$TMP" --name "↳m1" --prompt "$PROMPT" --dry-run "$@" >/dev/null 2>"$TMP/err"; echo $?; }
first_arg(){ HOME="$FAKE_HOME" "$DISPATCH" --cwd "$TMP" --name "↳m1" --prompt "$PROMPT" --dry-run "$@" 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['d']['launch']['args'][0])"; }

echo "[1] 无配置文件 → 内置默认 claude-opus-5 + high，同时进 launch.args 与 respawnFlags"
rm -f "$CFG"
eq "launch.args 尾部为 --model claude-opus-5 --effort high" "$(dump args)" "$PROMPT --model claude-opus-5 --effort high"
eq "respawnFlags 与 flag 一致（自动重拉不丢）"                "$(dump respawn)" "--model claude-opus-5 --effort high"
eq "prompt 仍在 args[0]（哨兵首行不变）"                      "$(first_arg | head -1)" "⟦FLEET-WORKER⟧ rq=RQ-T module=m1"

echo "[2] 配置文件 worker.{model,effort} 覆盖内置默认（effort 大小写归一）"
printf '{"version":1,"worker":{"model":"claude-sonnet-5","effort":"Medium"}}\n' > "$CFG"
eq "取配置文件的模型/深度" "$(dump respawn)" "--model claude-sonnet-5 --effort medium"

echo "[3] --model / --effort 命令行覆盖配置文件；可单项覆盖"
eq "两项都覆盖"          "$(dump respawn --model opus --effort xhigh)" "--model opus --effort xhigh"
eq "只覆盖 effort，model 仍取配置" "$(dump respawn --effort max)" "--model claude-sonnet-5 --effort max"
eq "--worker-config 指到别的文件" "$(printf '{"worker":{"model":"claude-fable-5","effort":"low"}}' > "$TMP/alt.json"; dump respawn --worker-config "$TMP/alt.json")" "--model claude-fable-5 --effort low"

echo "[4] --no-worker-defaults → 不带 flag（继承 daemon 默认），respawnFlags 为空"
eq "launch.args 只剩 prompt" "$(dump args --no-worker-defaults)" "$PROMPT"
eq "respawnFlags 为空"       "$(dump respawn --no-worker-defaults)" ""

echo "[5] 配置里 model/effort 给空串 = 显式不指定该项"
printf '{"worker":{"model":"","effort":"high"}}\n' > "$CFG"
eq "只带 --effort" "$(dump respawn)" "--effort high"

echo "[6] 非法值 / 坏配置 → exit 5，不派发"
rm -f "$CFG"
eq "--effort ultra → exit 5"          "$(rc_of --effort ultra)" "5"
grep -q 'low|medium|high|xhigh|max' "$TMP/err" && ok "报错列出合法 effort 值" || no "报错未列出合法 effort 值"
printf '{bad json' > "$CFG"
eq "配置文件不是合法 JSON → exit 5"  "$(rc_of)" "5"
printf '{"worker":{"model":123}}\n' > "$CFG"
eq "worker.model 不是字符串 → exit 5" "$(rc_of)" "5"
rm -f "$CFG"
eq "--model 含空白 → exit 5"          "$(rc_of --model 'claude opus')" "5"

echo "[8] --profile spike：「打样先行」段① 骨架 worker 走独立配置档，内置默认 opus5 + xhigh"
rm -f "$CFG"
eq "无配置文件 → spike 内置 claude-opus-5 + xhigh" "$(dump respawn --profile spike)" "--model claude-opus-5 --effort xhigh"
eq "不带 --profile 仍是 worker 档（opus5 + high）"  "$(dump respawn)" "--model claude-opus-5 --effort high"
printf '{"version":1,"worker":{"model":"claude-opus-5","effort":"high"},"spike":{"model":"claude-fable-5-1","effort":"max"}}\n' > "$CFG"
eq "配置文件 spike 块覆盖 spike 内置默认"       "$(dump respawn --profile spike)" "--model claude-fable-5-1 --effort max"
eq "同一文件 worker 块不受 spike 块影响"          "$(dump respawn)" "--model claude-opus-5 --effort high"
eq "配置文件只有 worker 块时 spike 用内置默认"    "$(printf '{"worker":{"model":"claude-sonnet-5","effort":"low"}}' > "$CFG"; dump respawn --profile spike)" "--model claude-opus-5 --effort xhigh"
eq "--effort 命令行仍可临时覆盖 spike 档"         "$(dump respawn --profile spike --effort high)" "--model claude-opus-5 --effort high"
eq "配置文件自定义档 review 可用（无内置也行）"   "$(printf '{"review":{"model":"claude-opus-5","effort":"medium"}}' > "$CFG"; dump respawn --profile review)" "--model claude-opus-5 --effort medium"
rm -f "$CFG"
eq "未知 profile（无内置也无配置块）→ exit 5"     "$(rc_of --profile nope)" "5"
grep -q 'spike' "$TMP/err" && ok "报错列出内置 profile" || no "报错未列出内置 profile"
printf '{"spike":{"effort":42}}\n' > "$CFG"
eq "spike.effort 不是字符串 → exit 5"            "$(rc_of --profile spike)" "5"
rm -f "$CFG"

echo "[7] 不经环境变量：payload 的 env 里不该出现 ANTHROPIC_MODEL / CLAUDE_CODE_EFFORT_LEVEL"
ENVJSON="$(HOME="$FAKE_HOME" "$DISPATCH" --cwd "$TMP" --name "↳m1" --prompt "$PROMPT" --dry-run --env FLEET_ROLE=worker 2>/dev/null \
  | python3 -c "import sys,json;print(json.dumps(json.load(sys.stdin)['d'].get('env',{}),sort_keys=True))")"
eq "env 只含显式 --env 注入的键" "$ENVJSON" '{"FLEET_ROLE": "worker"}'

echo
echo "==== 结果: PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
