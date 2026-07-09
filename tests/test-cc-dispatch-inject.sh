#!/usr/bin/env bash
# test-cc-dispatch-inject.sh — 验证 cc-dispatch 的 CLAUDE.md 注入开关（用 --dry-run，不连 daemon）。
#
# 背景与默认值变更（2.1.181）：旧版后台派发的 session 不保证自动加载 CLAUDE.md（daemon spare 池沿用
# 预热 cwd、约 3/4 miss），曾默认把规范原文塞进 prompt 兜底。2.1.181 实测此 bug 已修复——14/14 spare
# worker 均按【派发 cwd】重新解析并加载三层 CLAUDE.md（用户级 + 项目级 + 目录级，且目录级跟随派发 cwd，
# 见 PROTOCOL.md §11）。故注入**默认关**，避免与自动加载重复烧 token；仅 daemon 版本回归时用
# --inject-claude-md 重开兜底。本测试相应断言：默认不注入；--inject-claude-md 时注入结构正确、哨兵保持
# 首行、intent 不含注入、--no-inject-claude-md 显式关同默认。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$HERE/../scripts/cc-dispatch"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
chk(){ # chk "desc" haystack needle
  case "$2" in *"$3"*) ok "$1";; *) no "$1 （缺: $3）";; esac
}
chkn(){ # 反向：不应包含
  case "$2" in *"$3"*) no "$1 （不该含: $3）";; *) ok "$1";; esac
}

# --- 造临时环境：假 HOME + 仓库根 + 子目录，各放一层 CLAUDE.md ---
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME/.claude"
printf 'USER-LEVEL-MARKER 用户级规范：使用简体中文。\n' > "$FAKE_HOME/.claude/CLAUDE.md"
REPO="$TMP/repo"; mkdir -p "$REPO/.git" "$REPO/sub"
printf 'PROJECT-LEVEL-MARKER 项目级规范（仓库根）。\n'  > "$REPO/CLAUDE.md"
printf 'DIR-LEVEL-MARKER 目录级规范（子目录）：先开 worktree。\n' > "$REPO/sub/CLAUDE.md"

SENTINEL='⟦FLEET-WORKER⟧ rq=RQ-T module=m1'
PROMPT_FILE="$TMP/p.txt"; printf '%s\n你是 worker。任务：改 X。\n' "$SENTINEL" > "$PROMPT_FILE"

run(){ # run <extra-args...> -> 打印 launch.args[0]
  HOME="$FAKE_HOME" "$DISPATCH" --cwd "$REPO/sub" --name "↳m1" \
    --prompt-file "$PROMPT_FILE" --dry-run "$@" 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['d']['launch']['args'][0])"
}
run_intent(){
  HOME="$FAKE_HOME" "$DISPATCH" --cwd "$REPO/sub" --name "↳m1" \
    --prompt-file "$PROMPT_FILE" --dry-run "$@" 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['d']['seed']['intent'])"
}

echo "[1] 默认关闭注入（2.1.181 起：daemon 已自动加载 CLAUDE.md，不再默认注入）"
D="$(run)"
FIRST_D="$(printf '%s' "$D" | head -1)"
[ "$FIRST_D" = "$SENTINEL" ] && ok "哨兵 ⟦FLEET-WORKER⟧ 保持在第一行" || no "首行应为哨兵，实为: $FIRST_D"
chkn "默认无注入块起始标记"      "$D" '⟦INJECTED-CLAUDE-MD⟧'
chkn "默认无用户级原文"          "$D" 'USER-LEVEL-MARKER'
chkn "默认无项目级原文"          "$D" 'PROJECT-LEVEL-MARKER'
chkn "默认无目录级原文"          "$D" 'DIR-LEVEL-MARKER'
chk  "默认仍保留原任务正文"      "$D" '你是 worker'

echo "[2] --inject-claude-md 显式开启注入（兜底逃生口）"
A="$(run --inject-claude-md)"
FIRST="$(printf '%s' "$A" | head -1)"
[ "$FIRST" = "$SENTINEL" ] && ok "哨兵 ⟦FLEET-WORKER⟧ 保持在第一行" || no "首行应为哨兵，实为: $FIRST"
chk "含注入块起始标记"          "$A" '⟦INJECTED-CLAUDE-MD⟧'
chk "含注入块结束标记"          "$A" '⟦/INJECTED-CLAUDE-MD⟧'
chk "注入了用户级 CLAUDE.md"    "$A" 'USER-LEVEL-MARKER'
chk "注入了项目级 CLAUDE.md"    "$A" 'PROJECT-LEVEL-MARKER'
chk "注入了目录级 CLAUDE.md"    "$A" 'DIR-LEVEL-MARKER'
chk "标注了[用户级]"            "$A" '[用户级]'
chk "标注了[项目级]"            "$A" '[项目级]'
chk "标注了[目录级]"            "$A" '[目录级]'
chk "保留原任务正文"            "$A" '你是 worker'

echo "[3] --inject-claude-md 顺序：用户级 → 项目级 → 目录级（越具体越靠后）"
pu=$(printf '%s' "$A" | grep -n 'USER-LEVEL-MARKER'    | head -1 | cut -d: -f1)
pp=$(printf '%s' "$A" | grep -n 'PROJECT-LEVEL-MARKER' | head -1 | cut -d: -f1)
pd=$(printf '%s' "$A" | grep -n 'DIR-LEVEL-MARKER'     | head -1 | cut -d: -f1)
{ [ -n "$pu" ] && [ -n "$pp" ] && [ -n "$pd" ] && [ "$pu" -lt "$pp" ] && [ "$pp" -lt "$pd" ]; } \
  && ok "顺序正确 (用户级<项目级<目录级)" || no "顺序错: user=$pu project=$pp dir=$pd"

echo "[4] intent（FleetView 显示用）始终保持原文、不含注入（即便 --inject-claude-md）"
I="$(run_intent --inject-claude-md)"
chkn "intent 不含注入块"        "$I" '⟦INJECTED-CLAUDE-MD⟧'
chk  "intent 保留哨兵"          "$I" 'FLEET-WORKER'

echo "[5] --no-inject-claude-md 显式关闭（与默认一致）"
B="$(run --no-inject-claude-md)"
chkn "关闭后无注入块"           "$B" '⟦INJECTED-CLAUDE-MD⟧'
chkn "关闭后无用户级原文"       "$B" 'USER-LEVEL-MARKER'
chk  "关闭后仍保留原 prompt"    "$B" '你是 worker'

echo
echo "==== 结果: PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
