#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT/scripts/cc-codex-session-config"
PASS=0; FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ [$CASE] $1"; FAIL=$((FAIL+1)); }

CASE="missing_config_inherits"
OUT="$(CODEX_HOME="$TMP/home" "$CONFIG" resolve --json 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok || fail "rc=$RC $OUT"
node -e 'const x=JSON.parse(process.argv[1]);if(x.configExists||x.mode!=="inherit"||x.active!=="inherit")process.exit(1)' "$OUT"
[ "$?" -eq 0 ] && ok || fail "缺配置时没有安全继承: $OUT"

CASE="init_and_select"
OUT="$(CODEX_HOME="$TMP/home" "$CONFIG" init 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok || fail "init rc=$RC $OUT"
[ "$(stat -f '%Lp' "$TMP/home/multi-session-dev.json" 2>/dev/null || stat -c '%a' "$TMP/home/multi-session-dev.json")" = "600" ] && ok || fail "配置权限不是 600"
OUT="$(CODEX_HOME="$TMP/home" "$CONFIG" select deepseek-flash 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '已激活路由: deepseek-flash' && ok || fail "select rc=$RC $OUT"
printf '%s' "$OUT" | grep -q 'model: deepseek-v4-flash' && ok || fail "select 未显示模型: $OUT"
printf '%s' "$OUT" | grep -q 'reasoningEffort: high' && ok || fail "select 未显示思考强度: $OUT"
printf '%s' "$OUT" | grep -q 'thinking: enabled' && ok || fail "select 未显示思考状态: $OUT"
OUT="$(CODEX_HOME="$TMP/home" DEEPSEEK_API_KEY=secret "$CONFIG" resolve --json 2>&1)"
node -e 'const x=JSON.parse(process.argv[1]);if(x.modelProvider!=="deepseek"||x.model!=="deepseek-v4-flash"||x.reasoningEffort!=="high"||x.authEnv!=="DEEPSEEK_API_KEY"||x.authEnvSet!==true)process.exit(1)' "$OUT"
[ "$?" -eq 0 ] && ok || fail "resolve 内容不对: $OUT"
if printf '%s' "$OUT" | grep -q 'secret'; then fail "resolve 泄漏 key"; else ok; fi

CASE="reject_secrets_and_unknown_fields"
cat > "$TMP/bad.json" <<'EOF'
{"version":1,"active":"bad","targets":{"bad":{"mode":"fixed","modelProvider":"deepseek","model":"deepseek-v4-flash","apiKey":"sk-nope"}}}
EOF
OUT="$(CODEX_MULTI_SESSION_CONFIG="$TMP/bad.json" "$CONFIG" validate 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok || fail "含 key 字段应拒绝，rc=$RC $OUT"
printf '%s' "$OUT" | grep -q 'forbidden/unknown field apiKey' && ok || fail "缺安全错误: $OUT"

CASE="select_unknown_is_atomic"
BEFORE="$(shasum -a 256 "$TMP/home/multi-session-dev.json" | awk '{print $1}')"
OUT="$(CODEX_HOME="$TMP/home" "$CONFIG" select missing 2>&1)"; RC=$?
AFTER="$(shasum -a 256 "$TMP/home/multi-session-dev.json" | awk '{print $1}')"
[ "$RC" -eq 2 ] && [ "$BEFORE" = "$AFTER" ] && ok || fail "未知 target 不应改文件: rc=$RC"

echo
echo "==== Codex session routing config 测试：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] && echo "✅ 全绿" || { echo "❌ 有失败"; exit 1; }
