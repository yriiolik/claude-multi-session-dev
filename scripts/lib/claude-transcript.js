// claude-transcript — 解析 Claude Code 会话 transcript，还原一个 Claude worker 的执行时间线。
//
// 与 codex-rollout.js 对位：面板的列表摘要列与详情页只认 { type: turn|task|thinking|message|call }
// 这一套条目，Codex worker 从 rollout 来，Claude worker 从这里来，渲染层不分后端。
//
// transcript 路径：$CLAUDE_CONFIG_DIR(默认 ~/.claude)/projects/<cwd 把非字母数字换成 -> /<sessionId>.jsonl
// 每行一条记录：user / assistant 是对话，其余（attachment、custom-title、worktree-state…）是元数据。
// assistant.message.content[] 有 text / thinking / tool_use；工具结果在下一条 user 的 tool_result 里。

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { stripCdPrefix } = require("./codex-rollout.js");

function claudeHome() {
  return process.env.CLAUDE_CONFIG_DIR || path.join(process.env.HOME || os.homedir(), ".claude");
}

function projectsRoot() {
  return path.join(claudeHome(), "projects");
}

// Claude 按启动目录落项目目录：路径里非字母数字一律换成 `-`。
function projectSlug(cwd) {
  return String(cwd || "").replace(/[^A-Za-z0-9]/g, "-");
}

// 先按 cwd 推算的目录直接命中；推算不中（worker 中途 EnterWorktree、路径规则变化）再扫一遍项目目录。
// 结果由调用方缓存——面板每 2 秒刷一次，不能每次都遍历。
function findTranscript(sessionId, { cwd = "" } = {}) {
  if (!sessionId) return "";
  const root = projectsRoot();
  const name = `${sessionId}.jsonl`;
  if (cwd) {
    const guess = path.join(root, projectSlug(cwd), name);
    if (fs.existsSync(guess)) return guess;
  }
  let dirs;
  try { dirs = fs.readdirSync(root); } catch { return ""; }
  for (const d of dirs) {
    const f = path.join(root, d, name);
    if (fs.existsSync(f)) return f;
  }
  return "";
}

function readTail(file, bytes) {
  const st = fs.statSync(file);
  const start = Math.max(0, st.size - bytes);
  const fd = fs.openSync(file, "r");
  const buf = Buffer.alloc(st.size - start);
  fs.readSync(fd, buf, 0, buf.length, start);
  fs.closeSync(fd);
  let text = buf.toString("utf8");
  // 从中间截断时首行多半是半条 JSON，丢掉
  if (start > 0) text = text.slice(text.indexOf("\n") + 1);
  return { text, truncated: start > 0 };
}

function rel(p, cwd) {
  const s = String(p || "");
  if (cwd && s.startsWith(`${cwd}/`)) return s.slice(cwd.length + 1);
  return s;
}

const EDIT_TOOLS = new Set(["Edit", "Write", "MultiEdit", "NotebookEdit"]);

// tool_use 的人读形式。Bash 与 Codex 的 shell 同形（剥掉 `cd <worktree> &&`），改文件的归为 patch。
function describeToolUse(block, cwd = "") {
  const name = block.name || "tool";
  const input = block.input && typeof block.input === "object" ? block.input : {};
  if (name === "Bash" && input.command) {
    const { text, workdir } = stripCdPrefix(input.command);
    return { kind: "shell", text, workdir };
  }
  if (EDIT_TOOLS.has(name)) {
    const file = rel(input.file_path || input.notebook_path || "", cwd);
    return { kind: "patch", text: file || name, files: file ? [file] : [] };
  }
  // Grep/Glob 同时带 pattern 与 path 时，搜索模式才是看点；path 只在没有别的主参数时兜底
  const main = input.file_path || input.pattern || input.query || input.url || input.path
    || input.description || input.prompt || input.skill || "";
  const brief = main ? rel(main, cwd) : Object.keys(input).slice(0, 3).map((k) => `${k}=${JSON.stringify(input[k])}`).join(" ");
  return { kind: "tool", text: `${name} ${String(brief).split(/\r?\n/)[0]}`.trim() };
}

function resultText(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.map((c) => (c && c.type === "text" ? c.text : "")).filter(Boolean).join("\n");
}

// 用户侧真正的输入（任务卡 / reply 追加指令）。<local-command…>、<system-reminder> 这类由客户端注入的
// 标签消息与 isMeta 记录不是人写的，不进时间线。
function userInput(ev) {
  if (ev.isMeta) return "";
  const c = ev.message?.content;
  let text = "";
  if (typeof c === "string") text = c;
  else if (Array.isArray(c) && !c.some((b) => b && b.type === "tool_result")) text = resultText(c);
  text = String(text || "").trim();
  return text && !text.startsWith("<") ? text : "";
}

function hhmm(ts) {
  const d = new Date(ts);
  if (Number.isNaN(d.getTime())) return "";
  const p = (n) => String(n).padStart(2, "0");
  return `${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

function parse(line) {
  if (!line.trim()) return null;
  try { return JSON.parse(line); } catch { return null; }
}

// 把 transcript 压成一串按时间排列的展示条目；只解析末尾 maxBytes，长任务也不会越读越慢。
function readTimeline(file, { maxBytes = 4 * 1024 * 1024 } = {}) {
  let text;
  let truncated = false;
  try {
    ({ text, truncated } = readTail(file, maxBytes));
  } catch {
    return { items: [], meta: {}, truncated: false };
  }
  const items = [];
  const meta = {};
  const pending = new Map();
  let orphan = false;

  for (const line of text.split("\n")) {
    const ev = parse(line);
    // isSidechain 是 worker 内部 subagent 的对话，不属于 worker 自己的主线
    if (!ev || ev.isSidechain || (ev.type !== "user" && ev.type !== "assistant")) continue;
    const ts = ev.timestamp || "";
    if (ev.cwd) meta.workdir = ev.cwd;
    if (ev.type === "user") {
      const input = userInput(ev);
      if (input) {
        items.push({ type: "turn", ts, text: `turn ${hhmm(ts)}` });
        items.push({ type: "task", ts, text: input });
        continue;
      }
      for (const b of Array.isArray(ev.message?.content) ? ev.message.content : []) {
        if (!b || b.type !== "tool_result") continue;
        const target = pending.get(b.tool_use_id);
        const body = resultText(b.content);
        const exitCode = b.is_error ? 1 : 0;
        if (target) { target.output = body; target.exitCode = exitCode; }
        else { orphan = true; items.push({ type: "call", ts, kind: "shell", text: "(调用已滚出缓冲区)", output: body, exitCode }); }
      }
      continue;
    }
    const m = ev.message || {};
    if (m.model && m.model !== "<synthetic>") meta.model = m.model;
    const u = m.usage;
    if (u) meta.tokens = (u.input_tokens || 0) + (u.cache_creation_input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.output_tokens || 0);
    for (const b of Array.isArray(m.content) ? m.content : []) {
      if (!b) continue;
      if (b.type === "text" && b.text && b.text.trim()) items.push({ type: "message", ts, text: b.text.trim() });
      else if (b.type === "thinking" && b.thinking && b.thinking.trim()) items.push({ type: "thinking", ts, text: b.thinking.trim() });
      else if (b.type === "tool_use") {
        const item = { type: "call", ts, callId: b.id || "", ...describeToolUse(b, meta.workdir), output: "", exitCode: null };
        items.push(item);
        if (item.callId) pending.set(item.callId, item);
      }
    }
  }
  meta.provider = meta.model ? "anthropic" : meta.provider;
  return { items, meta, truncated: truncated || orphan };
}

// 列表列要的是「此刻在干什么」：反向找最近一条有意义的 assistant 块。transcript 单行可能很大
// （大段工具输出、附件），小尾巴里找不到就扩大一次再找。
function lastActivity(file, { tailBytes = 256 * 1024, maxTailBytes = 2 * 1024 * 1024 } = {}) {
  for (let bytes = tailBytes; ; bytes = maxTailBytes) {
    let text;
    let truncated;
    try { ({ text, truncated } = readTail(file, bytes)); } catch { return null; }
    const lines = text.split("\n");
    for (let i = lines.length - 1; i >= 0; i--) {
      const ev = parse(lines[i]);
      if (!ev || ev.isSidechain || ev.type !== "assistant") continue;
      const blocks = Array.isArray(ev.message?.content) ? ev.message.content : [];
      for (let j = blocks.length - 1; j >= 0; j--) {
        const b = blocks[j];
        if (!b) continue;
        if (b.type === "tool_use") {
          const d = describeToolUse(b, ev.cwd || "");
          return { kind: d.kind, text: d.text };
        }
        if (b.type === "text" && b.text && b.text.trim()) return { kind: "message", text: b.text.trim() };
        if (b.type === "thinking" && b.thinking && b.thinking.trim()) return { kind: "thinking", text: b.thinking.trim() };
      }
    }
    if (!truncated || bytes >= maxTailBytes) return null;
  }
}

module.exports = {
  claudeHome,
  projectsRoot,
  projectSlug,
  findTranscript,
  describeToolUse,
  readTimeline,
  lastActivity,
};
