#!/usr/bin/env bash
# Codex 0.146 app-server proxy handshake, large payload, and auto-start regression tests.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CALL="$ROOT/scripts/cc-codex-app-call"
PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ [$CASE] $1"; FAIL=$((FAIL+1)); }

FAKE="$TMP/fake-codex"
LOG="$TMP/messages.jsonl"
MARKER="$TMP/started"
cat > "$FAKE" <<'NODE'
#!/usr/bin/env node
const fs = require("fs");
const crypto = require("crypto");
const args = process.argv.slice(2);

if (args[0] === "--version") {
  console.log("codex-cli 0.146.0");
  process.exit(0);
}
if (args[0] === "remote-control" && args[1] === "start") {
  fs.writeFileSync(process.env.FAKE_MARKER, "started\n");
  console.log('{"ok":true}');
  process.exit(0);
}
if (args[0] === "app-server" && args[1] === "daemon" && args[2] === "start") {
  fs.writeFileSync(process.env.FAKE_MARKER, "started\n");
  process.exit(0);
}
if (args[0] !== "app-server" || args[1] !== "proxy") process.exit(7);
if (process.env.REQUIRE_MARKER === "1" && !fs.existsSync(process.env.FAKE_MARKER)) {
  console.error("daemon unavailable");
  process.exit(9);
}

let buffer = Buffer.alloc(0), upgraded = false;
function serverFrame(value, opcode = 1, fin = true) {
  const payload = Buffer.isBuffer(value) ? value : Buffer.from(JSON.stringify(value));
  let head;
  if (payload.length < 126) head = Buffer.from([(fin ? 0x80 : 0) | opcode, payload.length]);
  else if (payload.length <= 0xffff) { head=Buffer.alloc(4); head[0]=(fin?0x80:0)|opcode; head[1]=126; head.writeUInt16BE(payload.length,2); }
  else { head=Buffer.alloc(10); head[0]=(fin?0x80:0)|opcode; head[1]=127; head.writeBigUInt64BE(BigInt(payload.length),2); }
  return Buffer.concat([head,payload]);
}
function onMessage(payload) {
  const msg = JSON.parse(payload.toString("utf8"));
  fs.appendFileSync(process.env.FAKE_LOG, `${JSON.stringify(msg)}\n`);
  if (msg.id === 1 && msg.method === "initialize") {
    const response = Buffer.from('{"id":1,"result":{"serverInfo":{"name":"fake"}}}');
    const middle = Math.floor(response.length / 2);
    process.stdout.write(serverFrame(response.subarray(0,middle), 1, false));
    process.stdout.write(serverFrame(response.subarray(middle), 0, true));
  } else if (msg.id === 2) {
    if (process.env.FAKE_RPC_ERROR === "1") {
      // 服务端正常应答、业务上失败（如 thread not found）——连接本身是好的
      process.stdout.write(serverFrame({ id: 2, error: { code: -32600, message: "thread not found: x" } }));
      return;
    }
    process.stdout.write(serverFrame({
      id: 2,
      result: { method: msg.method, paramBytes: Buffer.byteLength(JSON.stringify(msg.params)) },
    }));
  }
}
function parseFrames() {
  while (buffer.length >= 2) {
    const b0=buffer[0], b1=buffer[1]; let len=b1&0x7f, off=2;
    if (len===126) { if(buffer.length<4)return; len=buffer.readUInt16BE(2); off=4; }
    else if (len===127) { if(buffer.length<10)return; len=Number(buffer.readBigUInt64BE(2)); off=10; }
    const masked=!!(b1&0x80); let mask;
    if(masked){if(buffer.length<off+4)return;mask=buffer.subarray(off,off+4);off+=4;}
    if(buffer.length<off+len)return;
    let payload=buffer.subarray(off,off+len);buffer=buffer.subarray(off+len);
    if(masked){const clear=Buffer.alloc(len);for(let i=0;i<len;i++)clear[i]=payload[i]^mask[i%4];payload=clear;}
    if((b0&0x0f)===1)onMessage(payload);
  }
}
process.stdin.on("data", chunk => {
  buffer=Buffer.concat([buffer,chunk]);
  if(!upgraded){
    const end=buffer.indexOf("\r\n\r\n"); if(end<0)return;
    const header=buffer.subarray(0,end).toString("utf8");buffer=buffer.subarray(end+4);
    const key=header.match(/^Sec-WebSocket-Key:\s*(.+)$/im)?.[1]?.trim();
    const accept=crypto.createHash("sha1").update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
    process.stdout.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    upgraded=true;
  }
  parseFrames();
});
NODE
chmod +x "$FAKE"

CASE="large_payload_uses_official_proxy_and_ordered_handshake"
PARAMS="$TMP/large.json"
node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({text:"x".repeat(100000)}))' "$PARAMS"
OUT="$(FAKE_LOG="$LOG" FAKE_MARKER="$MARKER" "$CALL" --codex-bin "$FAKE" thread/read "$PARAMS" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok || fail "退出码应为 0，实得 $RC: $OUT"
METHOD="$(printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",b=>s+=b);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).method||""))')"
BYTES="$(printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",b=>s+=b);process.stdin.on("end",()=>process.stdout.write(String(JSON.parse(s).paramBytes||0)))')"
[ "$METHOD" = "thread/read" ] && ok || fail "method=$METHOD"
[ "$BYTES" -gt 65536 ] && ok || fail "大 payload 被截断: $BYTES"
ORDER="$(node - "$LOG" <<'NODE'
const fs = require("fs");
const rows = fs.readFileSync(process.argv[2], "utf8").trim().split(/\n/).map(JSON.parse);
process.stdout.write(rows.map((r) => r.method).join(" "));
NODE
)"
[ "$ORDER" = "initialize initialized thread/read" ] && ok || fail "握手顺序错误: $ORDER"

CASE="auto_start_then_retry_proxy"
: > "$LOG"
OUT="$(REQUIRE_MARKER=1 FAKE_LOG="$LOG" FAKE_MARKER="$MARKER" "$CALL" --codex-bin "$FAKE" --start-app-server config/read - <<<'{}' 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok || fail "auto-start 失败 rc=$RC: $OUT"
[ -f "$MARKER" ] && ok || fail "未调用 remote-control start"
printf '%s' "$OUT" | grep -q '"method":"config/read"' && ok || fail "返回值错误: $OUT"

# 面板 / status / read / watch / kill 在"只连已有 app-server"时传的就是 --no-start-app-server。
# 以前这里不认这个 flag：它被当成 method、真 method 又被当成 params 文件，报
# `unknown argument: <路径>` 退出 5——表现为一整屏 worker 全变「状态未知」。
CASE="no_start_app_server_flag_is_accepted"
: > "$LOG"
OUT="$(FAKE_LOG="$LOG" FAKE_MARKER="$MARKER" "$CALL" --codex-bin "$FAKE" --no-start-app-server thread/read - <<<'{}' 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok || fail "--no-start-app-server 应被接受，rc=$RC: $OUT"
printf '%s' "$OUT" | grep -q '"method":"thread/read"' && ok || fail "method 被 flag 挤掉了: $OUT"
printf '%s' "$OUT" | grep -qv 'unknown argument' && ok || fail "不该再报 unknown argument: $OUT"

CASE="auto_discovery_prefers_working_local_codex"
mkdir -p "$TMP/home/.local/bin"
cp "$FAKE" "$TMP/home/.local/bin/codex"
: > "$LOG"
OUT="$(HOME="$TMP/home" FAKE_LOG="$LOG" FAKE_MARKER="$MARKER" "$CALL" thread/read - <<<'{}' 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok || fail "应优先使用 ~/.local/bin/codex，rc=$RC: $OUT"
printf '%s' "$OUT" | grep -q '"method":"thread/read"' && ok || fail "自动发现返回值错误: $OUT"

# 回归（2026-08-06）：曾把 JSON-RPC 业务错误当成"连不上"，触发自愈路径去重启/清 socket，
# 把一个健康的 app-server 打死。业务错误必须原样返回，绝不碰 daemon。
CASE="rpc_business_error_must_not_trigger_autostart"
: > "$LOG"
rm -f "$MARKER"
OUT="$(FAKE_RPC_ERROR=1 FAKE_LOG="$LOG" FAKE_MARKER="$MARKER" "$CALL" --codex-bin "$FAKE" --start-app-server turn/start - <<<'{}' 2>&1)"
RC=$?
[ "$RC" -eq 9 ] && ok || fail "业务错误应 rc=9，实得 $RC: $OUT"
printf '%s' "$OUT" | grep -q "thread not found" && ok || fail "应原样透出业务错误: $OUT"
[ ! -f "$MARKER" ] && ok || fail "业务错误不该触发 app-server 启动/自愈"

echo
echo "==== cc-codex-app-call 测试：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ] && echo "✅ 全绿" || { echo "❌ 有失败"; exit 1; }
