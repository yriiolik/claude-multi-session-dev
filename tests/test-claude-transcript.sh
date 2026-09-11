#!/usr/bin/env bash
# lib/claude-transcript.js：按 sessionId 找 Claude 会话 transcript、压成面板时间线条目、取「此刻在干什么」。
# 条目格式必须与 codex-rollout.js 一致（turn/task/thinking/message/call），面板渲染层不分后端。
set -u
export FORCE_COLOR=0 NO_COLOR=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
fail(){ echo "✗ $1"; FAIL=$((FAIL+1)); }
assert_eq(){ [[ "$1" == "$2" ]] && ok || fail "$3: 期望 [$2] 实得 [$1]"; }

export CLAUDE_CONFIG_DIR="$T/claude-home"
CWD="/wt/fleet-RQ-1-ui/factory"
SLUG_DIR="$CLAUDE_CONFIG_DIR/projects/-wt-fleet-RQ-1-ui-factory"
OTHER_DIR="$CLAUDE_CONFIG_DIR/projects/-somewhere-else"
mkdir -p "$SLUG_DIR" "$OTHER_DIR"

# 夹具：任务卡 → 回复/思考/Bash/Edit/Read → 工具结果（含失败）→ 注入消息与 subagent 旁支（都不进时间线）→ reply 追加指令 → 元数据尾巴
node -e '
const fs = require("fs");
const [file, cwd] = process.argv.slice(1);
const A = (ts, content, extra = {}) => ({ type: "assistant", cwd, timestamp: ts, message: { model: "claude-opus-5", content,
  usage: { input_tokens: 10, cache_creation_input_tokens: 100, cache_read_input_tokens: 1000, output_tokens: 5 } }, ...extra });
const U = (ts, content, extra = {}) => ({ type: "user", cwd, timestamp: ts, message: { role: "user", content }, ...extra });
const L = [
  { type: "permission-mode", permissionMode: "bypassPermissions" },
  U("2026-09-11T08:00:00Z", "⟦FLEET-WORKER⟧ rq=RQ-1 module=ui\n任务卡正文"),
  A("2026-09-11T08:00:01Z", [{ type: "thinking", thinking: "", signature: "sig" }, { type: "text", text: "先确认目录" }]),
  A("2026-09-11T08:00:02Z", [{ type: "tool_use", id: "t1", name: "Bash", input: { command: `cd "${cwd}" && pnpm test`, description: "跑测试" } }]),
  U("2026-09-11T08:00:03Z", [{ type: "tool_result", tool_use_id: "t1", content: "42 passed", is_error: false }]),
  A("2026-09-11T08:00:04Z", [{ type: "tool_use", id: "t2", name: "Edit", input: { file_path: `${cwd}/src/a.ts`, old_string: "a", new_string: "b" } }]),
  U("2026-09-11T08:00:05Z", [{ type: "tool_result", tool_use_id: "t2", content: [{ type: "text", text: "updated" }] }]),
  A("2026-09-11T08:00:06Z", [{ type: "thinking", thinking: "需要看一下配置" }, { type: "tool_use", id: "t3", name: "Read", input: { file_path: `${cwd}/package.json` } }]),
  U("2026-09-11T08:00:07Z", [{ type: "tool_result", tool_use_id: "t3", content: "{}" }]),
  A("2026-09-11T08:00:08Z", [{ type: "tool_use", id: "t4", name: "Bash", input: { command: "false" } }]),
  U("2026-09-11T08:00:09Z", [{ type: "tool_result", tool_use_id: "t4", content: "Exit code 1", is_error: true }]),
  U("2026-09-11T08:00:10Z", "<local-command-caveat>客户端注入</local-command-caveat>"),
  U("2026-09-11T08:00:11Z", "meta 注入", { isMeta: true }),
  A("2026-09-11T08:00:12Z", [{ type: "text", text: "subagent 内部回复" }], { isSidechain: true }),
  U("2026-09-11T08:00:13Z", "本轮 attempt=abc；继续修复"),
  A("2026-09-11T08:00:14Z", [{ type: "text", text: "result: 已完成" }]),
  { type: "custom-title", customTitle: "↳ui" },
  { type: "last-prompt", lastPrompt: "x" },
];
fs.writeFileSync(file, L.map((x) => JSON.stringify(x)).join("\n") + "\n");
' "$SLUG_DIR/sess-1.jsonl" "$CWD"
cp "$SLUG_DIR/sess-1.jsonl" "$OTHER_DIR/sess-2.jsonl"

# 大尾巴：最后一条 assistant 之后跟一条 300KB 的附件行，第一轮 256KB 尾巴里找不到，要扩大再找
node -e '
const fs = require("fs");
const [src, dst] = process.argv.slice(1);
const big = { type: "attachment", attachment: { content: "x".repeat(300 * 1024) } };
fs.writeFileSync(dst, fs.readFileSync(src, "utf8") + JSON.stringify(big) + "\n");
' "$SLUG_DIR/sess-1.jsonl" "$SLUG_DIR/sess-big.jsonl"

OUT="$(cd "$ROOT" && node -e '
const t = require("./scripts/lib/claude-transcript.js");
const [cwd, slugDir] = process.argv.slice(1);
const f = t.findTranscript("sess-1", { cwd });
const tl = t.readTimeline(f);
const fmt = (i) => i.type === "call" ? `call:${i.kind}:${i.text}:${i.exitCode}` : i.type === "turn" ? "turn" : `${i.type}:${i.text.split("\n")[0]}`;
const out = {
  slug: t.projectSlug(cwd),
  byCwd: f === `${slugDir}/sess-1.jsonl`,
  byScan: t.findTranscript("sess-2", { cwd }).endsWith("/-somewhere-else/sess-2.jsonl"),
  noCwd: t.findTranscript("sess-2").endsWith("/sess-2.jsonl"),
  missing: t.findTranscript("nope", { cwd }) === "",
  items: tl.items.map(fmt).join(" | "),
  bashOut: tl.items.find((i) => i.kind === "shell").output,
  meta: [tl.meta.model, tl.meta.provider, tl.meta.tokens, tl.meta.workdir].join("|"),
  truncated: tl.truncated,
  last: JSON.stringify(t.lastActivity(f)),
  lastBig: JSON.stringify(t.lastActivity(`${slugDir}/sess-big.jsonl`)),
  lastBigSmall: JSON.stringify(t.lastActivity(`${slugDir}/sess-big.jsonl`, { tailBytes: 1024, maxTailBytes: 1024 })),
  tailTrunc: t.readTimeline(f, { maxBytes: 600 }).truncated,
  missingFile: JSON.stringify(t.readTimeline("/nope.jsonl")),
  tool: t.describeToolUse({ name: "Grep", input: { pattern: "foo", path: "/x" } }).text,
  patch: t.describeToolUse({ name: "Write", input: { file_path: "/wt/a/b.ts" } }, "/wt/a").text,
};
for (const [k, v] of Object.entries(out)) console.log(`${k}=${v}`);
' "$CWD" "$SLUG_DIR" 2>&1)"
get(){ printf '%s\n' "$OUT" | awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}'; }

assert_eq "$(get slug)" "-wt-fleet-RQ-1-ui-factory" "项目目录名 = cwd 非字母数字换成 -"
assert_eq "$(get byCwd)" "true" "按 cwd 推算的项目目录直接命中"
assert_eq "$(get byScan)" "true" "推算不中时扫描全部项目目录"
assert_eq "$(get noCwd)" "true" "不给 cwd 也能找到"
assert_eq "$(get missing)" "true" "找不到返回空串"
assert_eq "$(get items)" "turn | task:⟦FLEET-WORKER⟧ rq=RQ-1 module=ui | message:先确认目录 | call:shell:pnpm test:0 | call:patch:src/a.ts:0 | thinking:需要看一下配置 | call:tool:Read package.json:0 | call:shell:false:1 | turn | task:本轮 attempt=abc；继续修复 | message:result: 已完成" "时间线：空思考/注入消息/isMeta/subagent 旁支/元数据都不进；reply 另起一个 turn"
assert_eq "$(get bashOut)" "42 passed" "工具结果回填到对应调用"
assert_eq "$(get meta)" "claude-opus-5|anthropic|1115|$CWD" "meta：模型、provider、当前上下文 token、工作目录"
assert_eq "$(get truncated)" "false" "整份读完不算截断"
assert_eq "$(get last)" '{"kind":"message","text":"result: 已完成"}' "此刻在干什么 = 最后一条 assistant 块"
assert_eq "$(get lastBig)" '{"kind":"message","text":"result: 已完成"}' "尾部有超大行时扩大读取范围再找"
assert_eq "$(get lastBigSmall)" "null" "扩大到上限仍找不到返回 null"
assert_eq "$(get tailTrunc)" "true" "只读末尾时标记截断"
assert_eq "$(get missingFile)" '{"items":[],"meta":{},"truncated":false}' "文件不存在返回空时间线"
assert_eq "$(get tool)" "Grep foo" "其它工具取主参数"
assert_eq "$(get patch)" "b.ts" "改文件路径相对 cwd"

echo "claude-transcript: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
