#!/usr/bin/env bash
# cc-codex-ensure 预检自愈测试（hermetic：假 codex CLI + 假 app-call，不碰真实 Codex）。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENSURE="$ROOT/scripts/cc-codex-ensure"
PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ [$CASE] $1"; FAIL=$((FAIL+1)); }

# ---- 假 codex CLI：daemon start 成功即可 ----
FAKE_CODEX="$TMP/codex"
cat > "$FAKE_CODEX" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "codex-cli 0.146.1"; exit 0; fi
if [[ "${1:-}" == "app-server" && "${2:-}" == "daemon" ]]; then
  echo "{\"status\":\"started\"}"
  [[ -n "${FAKE_START_LOG:-}" ]] && echo "start" >> "$FAKE_START_LOG"
  exit 0
fi
exit 0
SH
chmod +x "$FAKE_CODEX"

# ---- 假 app-call：由 FAKE_APP_OK 决定 server 活/不活 ----
FAKE_APP="$TMP/app-call"
cat > "$FAKE_APP" <<'SH'
#!/usr/bin/env bash
if [[ "${FAKE_APP_OK:-1}" == "1" ]]; then echo '{}'; exit 0; fi
echo "connection refused" >&2
exit 9
SH
chmod +x "$FAKE_APP"

make_home() {
  local home="$1" provider="${2:-deepseek}" withcatalog="${3:-1}"
  mkdir -p "$home"
  cat > "$home/config.toml" <<EOF
model = "gpt-5.6-sol"
model_catalog_json = "$home/models.json"

[model_providers.$provider]
base_url = "https://api.deepseek.com/"
wire_api = "responses"
experimental_bearer_token = "sk-real-token-value"
EOF
  if [[ "$withcatalog" == "1" ]]; then
    cat > "$home/models.json" <<'EOF'
{"models":[{"slug":"deepseek-v4-flash"}]}
EOF
  fi
  cat > "$home/multi-session-dev.json" <<'EOF'
{"version":1,"active":"ds","targets":{"ds":{"mode":"fixed","modelProvider":"deepseek","model":"deepseek-v4-flash","providerType":"deepseek"}}}
EOF
}

run_ensure() {
  CODEX_HOME="$1" CODEX_APP_CALL_BIN="$FAKE_APP" FAKE_APP_OK="${2:-1}" FAKE_START_LOG="${3:-}" \
    "$ENSURE" --codex-bin "$FAKE_CODEX" "${@:4}" 2>&1
}

# ---- 1. 一切正常 → rc=0 且完全静默 ----
CASE="healthy-silent"
H="$TMP/h1"; make_home "$H"
OUT="$(run_ensure "$H" 1)"; RC=$?
[ "$RC" -eq 0 ] && ok || fail "期望 rc=0，实得 $RC"
[ -z "$OUT" ] && ok || fail "正常路径应零输出，实得: $OUT"

# ---- 2. server 不活 → 自动拉起 ----
CASE="autostart"
H="$TMP/h2"; make_home "$H"; LOG="$TMP/start2.log"
# 假 app-call 先失败、被拉起后仍失败 → 应报 9；这里验证"确实尝试过启动"
OUT="$(run_ensure "$H" 0 "$LOG")"; RC=$?
[ "$RC" -eq 9 ] && ok || fail "server 起不来应 rc=9，实得 $RC"
[ -s "$LOG" ] && ok || fail "应尝试过 daemon start"
echo "$OUT" | grep -q "app-server" && ok || fail "错误信息应提到 app-server: $OUT"

# ---- 3. provider 未在 config.toml 定义 → rc=2，且不去启动 server ----
CASE="provider-undefined"
H="$TMP/h3"; make_home "$H" "someother"; LOG="$TMP/start3.log"
OUT="$(run_ensure "$H" 1 "$LOG")"; RC=$?
[ "$RC" -eq 2 ] && ok || fail "provider 未定义应 rc=2，实得 $RC"
echo "$OUT" | grep -q "未在" && ok || fail "应说明 provider 未定义: $OUT"
[ ! -s "$LOG" ] && ok || fail "配置不过关时不应启动 server"

# ---- 4. 模型不在目录里 → rc=2 ----
CASE="model-missing"
H="$TMP/h4"; make_home "$H" "deepseek" 0
OUT="$(run_ensure "$H" 1)"; RC=$?
[ "$RC" -eq 2 ] && ok || fail "模型目录缺失应 rc=2，实得 $RC"

# ---- 5. 陈旧 pid 文件（指向不存在的进程）被移走 ----
CASE="stale-pid-reaped"
H="$TMP/h5"; make_home "$H"
mkdir -p "$H/app-server-daemon"
printf '{"pid":999124}' > "$H/app-server-daemon/app-server.pid"
# server 探测失败 → 走 bringUp → 应先收陈旧 pid
OUT="$(run_ensure "$H" 0 "$TMP/start5.log")"; RC=$?
[ ! -f "$H/app-server-daemon/app-server.pid" ] && ok || fail "陈旧 pid 文件应被移走"
ls "$H/app-server-daemon/" | grep -q 'app-server.pid.stale-' && ok || fail "应保留 .stale- 备份"
echo "$OUT" | grep -q "已死进程 999124" && ok || fail "应说明移走了哪个 pid: $OUT"

# ---- 6. 找不到 codex CLI → rc=8 ----
CASE="no-codex-bin"
H="$TMP/h6"; make_home "$H"
OUT="$(CODEX_HOME="$H" CODEX_APP_CALL_BIN="$FAKE_APP" "$ENSURE" --codex-bin "$TMP/nope" 2>&1)"; RC=$?
[ "$RC" -eq 8 ] && ok || fail "找不到 CLI 应 rc=8，实得 $RC"

# ---- 7. 配置指纹：改了 config.toml 且允许重启 → 重启一次使其生效 ----
CASE="config-drift-restart"
H="$TMP/h7"; make_home "$H"
run_ensure "$H" 1 >/dev/null 2>&1           # 首次：采纳当前指纹
STATE="$H/app-server-daemon/.msd-server-state.json"
[ -f "$STATE" ] && ok || fail "应记录 server 配置指纹"
sleep 1
echo '# changed' >> "$H/config.toml"          # 制造漂移
LOG="$TMP/start7.log"
OUT="$(run_ensure "$H" 1 "$LOG" --allow-restart)"; RC=$?
[ "$RC" -eq 0 ] && ok || fail "漂移重启应 rc=0，实得 $RC"
echo "$OUT" | grep -q "配置已变更" && ok || fail "应说明因配置变更重启: $OUT"
[ -s "$LOG" ] && ok || fail "漂移时应重新启动 server"

# ---- 8. 漂移但不允许重启 → 只警告，不重启 ----
CASE="config-drift-warn-only"
H="$TMP/h8"; make_home "$H"
run_ensure "$H" 1 >/dev/null 2>&1
sleep 1
echo '# changed again' >> "$H/config.toml"
LOG="$TMP/start8.log"
OUT="$(run_ensure "$H" 1 "$LOG")"; RC=$?
[ "$RC" -eq 0 ] && ok || fail "只警告应 rc=0，实得 $RC"
echo "$OUT" | grep -q "仍是旧配置" && ok || fail "应警告配置未生效: $OUT"
[ ! -s "$LOG" ] && ok || fail "未授权重启时不应重启 server"

# 回归（2026-08-06）：自愈曾无条件删 control socket + 杀 daemon 辅助进程，把健康的 server 打死。
# 只有 pid 文件指向【已死】进程才算陈旧现场；pid 还活着时必须一动不动。
CASE="live_pid_is_never_reaped"
H="$TMP/h9"; make_home "$H"
mkdir -p "$H/app-server-daemon" "$H/app-server-control"
printf '{"pid":%s}' "$$" > "$H/app-server-daemon/app-server.pid"   # 指向本测试进程 = 活的
: > "$H/app-server-control/app-server-control.sock"
run_ensure "$H" 0 "$TMP/start9.log" >/dev/null 2>&1
[ -f "$H/app-server-daemon/app-server.pid" ] && ok || fail "pid 还活着时不该移走 pid 文件"
[ -f "$H/app-server-control/app-server-control.sock" ] && ok || fail "pid 还活着时不该删 control socket"

echo "==== cc-codex-ensure: PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] && echo "✅ 全绿" || exit 1
