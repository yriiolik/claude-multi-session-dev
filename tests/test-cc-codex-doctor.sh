#!/usr/bin/env bash
# DeepSeek Responses API/model-catalog preflight tests.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCTOR="$ROOT/scripts/cc-codex-doctor"
PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ [$CASE] $1"; FAIL=$((FAIL+1)); }

FAKE="$TMP/codex"
cat > "$FAKE" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "codex-cli 0.146.0"; exit 0; fi
if [[ "${1:-}" == "app-server" && "${2:-}" == "proxy" && "${3:-}" == "--help" ]]; then exit 0; fi
exit 7
SH
chmod +x "$FAKE"

mkdir -p "$TMP/home"
cat > "$TMP/home/config.toml" <<EOF
model = "deepseek-v4-flash"
model_provider = "deepseek"
model_catalog_json = "$TMP/home/models.json"
[model_providers.deepseek]
name = "deepseek"
base_url = "https://api.deepseek.com/"
wire_api = "responses"
env_key = "DEEPSEEK_API_KEY"
EOF
cat > "$TMP/home/models.json" <<'JSON'
{"models":[{"slug":"deepseek-v4-flash","minimal_client_version":"0.144.0"}]}
JSON

CASE="valid_deepseek_config"
OUT="$(CODEX_HOME="$TMP/home" DEEPSEEK_API_KEY=secret "$DOCTOR" --codex-bin "$FAKE" --deepseek --json 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok || fail "rc=$RC $OUT"
printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",b=>s+=b);process.stdin.on("end",()=>process.exit(JSON.parse(s).ok?0:1))'
[ "$?" -eq 0 ] && ok || fail "doctor JSON 未通过: $OUT"

CASE="service_tier_is_rejected_for_deepseek"
perl -0pi -e 's/^model =/service_tier = "default"\nmodel =/' "$TMP/home/config.toml"
OUT="$(CODEX_HOME="$TMP/home" DEEPSEEK_API_KEY=secret "$DOCTOR" --codex-bin "$FAKE" --deepseek --json 2>&1)"
RC=$?
[ "$RC" -eq 2 ] && ok || fail "rc 应为 2，实得 $RC: $OUT"
printf '%s' "$OUT" | grep -q 'deepseek-service-tier' && ok || fail "缺 service-tier 诊断"

CASE="per_session_provider_allows_global_service_tier"
cat >> "$TMP/home/config.toml" <<'EOF'
[model_providers.deepseek_work]
name = "deepseek-work"
base_url = "https://api.deepseek.com/"
wire_api = "responses"
env_key = "DEEPSEEK_API_KEY_WORK"
EOF
OUT="$(CODEX_HOME="$TMP/home" DEEPSEEK_API_KEY_WORK=secret "$DOCTOR" --codex-bin "$FAKE" \
  --deepseek-provider deepseek_work --model deepseek-v4-flash --json 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok || fail "逐 session provider 应通过，rc=$RC $OUT"
printf '%s' "$OUT" | grep -q '逐 session DeepSeek 派发会显式清除' && ok || fail "缺 service-tier 清除提示"

CASE="automatic_session_routing"
cat > "$TMP/home/multi-session-dev.json" <<'JSON'
{
  "version": 1,
  "active": "deepseek-work",
  "targets": {
    "inherit": {"mode": "inherit"},
    "deepseek-work": {
      "mode": "fixed",
      "modelProvider": "deepseek_work",
      "model": "deepseek-v4-flash",
      "providerType": "deepseek",
      "authEnv": "DEEPSEEK_API_KEY_WORK"
    }
  }
}
JSON
OUT="$(CODEX_HOME="$TMP/home" DEEPSEEK_API_KEY_WORK=secret "$DOCTOR" --codex-bin "$FAKE" --json 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok || fail "自动路由应通过，rc=$RC $OUT"
printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",b=>s+=b);process.stdin.on("end",()=>{const x=JSON.parse(s);process.exit(x.routing?.active==="deepseek-work"&&x.routing?.modelProvider==="deepseek_work"?0:1)})'
[ "$?" -eq 0 ] && ok || fail "doctor 未读取统一路由: $OUT"

echo
echo "==== cc-codex-doctor 测试：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] && echo "✅ 全绿" || { echo "❌ 有失败"; exit 1; }
