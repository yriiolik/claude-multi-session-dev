// codex-rollout — 解析 Codex 的 rollout 事件日志，还原一个 worker thread 的完整执行时间线。
//
// 为什么不用 app-server 的 `thread/read`：它只返回**消息级** item。实测一个跑了 27 次命令、
// 11 段推理的 thread，`thread/read` 只给出 3 条（1 userMessage + 2 agentMessage）——拿它做
// "实时看执行情况"的详情页，看到的必然是残缺的。rollout 是 append-only 的事件全量，
// 思考、每一次命令调用及其输出、文件改动都在里面，而且读文件比走 app-server 便宜得多。
//
// rollout 路径：$CODEX_HOME/sessions/<YYYY>/<MM>/<DD>/rollout-<ISO>-<thread-id>.jsonl

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");

function codexHome() {
  return process.env.CODEX_HOME || path.join(process.env.HOME || os.homedir(), ".codex");
}

function sessionsRoot() {
  return path.join(codexHome(), "sessions");
}

// 按 thread id 找 rollout 文件。日期目录未知（thread 可能跨天），所以从新到旧扫有限几层，
// 命中即停。扫描结果由调用方缓存——面板每 2 秒刷一次，不能每次都遍历目录树。
function findRollout(threadId, { maxDays = 7 } = {}) {
  if (!threadId) return "";
  const root = sessionsRoot();
  const listDesc = (dir) => {
    try {
      return fs.readdirSync(dir).filter((n) => /^\d+$/.test(n)).sort().reverse();
    } catch {
      return [];
    }
  };
  let scanned = 0;
  for (const y of listDesc(root)) {
    for (const m of listDesc(path.join(root, y))) {
      for (const d of listDesc(path.join(root, y, m))) {
        if (scanned++ >= maxDays) return "";
        const dir = path.join(root, y, m, d);
        let names;
        try { names = fs.readdirSync(dir); } catch { continue; }
        const hit = names.find((n) => n.includes(threadId) && n.endsWith(".jsonl"));
        if (hit) return path.join(dir, hit);
      }
    }
  }
  return "";
}

// Codex 给每条 shell 命令都加了 `cd "<worktree>" && ` 前缀。worktree 路径又长又是每条都一样，
// 留着会把命令列挤没（真正在跑什么反而看不见）。剥掉，路径另行放回 workdir。
function stripCdPrefix(cmd) {
  const m = String(cmd).match(/^\s*cd\s+("([^"]+)"|'([^']+)'|([^\s&]+))\s*&&\s*/);
  if (!m) return { text: String(cmd).trim(), workdir: "" };
  return { text: String(cmd).slice(m[0].length).trim(), workdir: m[2] || m[3] || m[4] || "" };
}

function parseArgs(raw) {
  if (!raw) return {};
  try {
    return typeof raw === "string" ? JSON.parse(raw) : raw;
  } catch {
    return {};
  }
}

// exec_command 的实际命令藏在 arguments JSON 里；apply_patch 之类各有各的形状。
function describeCall(payload) {
  const args = parseArgs(payload.arguments);
  const name = payload.name || "call";
  if (args.cmd || args.command) {
    const c = args.cmd || args.command;
    const raw = Array.isArray(c) ? c.join(" ") : String(c);
    const { text, workdir } = stripCdPrefix(raw);
    return { kind: "shell", text, workdir: args.workdir || workdir || "" };
  }
  if (name === "apply_patch" || args.patch) {
    const patch = String(args.input || args.patch || "");
    const files = [...patch.matchAll(/^\*\*\* (?:Add|Update|Delete) File: (.+)$/gm)].map((m) => m[1]);
    return { kind: "patch", text: files.length ? files.join(", ") : "(patch)", files };
  }
  const brief = Object.entries(args)
    .filter(([k]) => !["justification", "max_output_tokens", "yield_time_ms", "prefix_rule", "sandbox_permissions"].includes(k))
    .map(([k, v]) => `${k}=${typeof v === "string" ? v : JSON.stringify(v)}`)
    .join(" ");
  return { kind: "tool", text: `${name} ${brief}`.trim() };
}

// function_call_output 的正文前面裹了一段 Chunk ID / Wall time / exit code 的表头，
// 展示时把它剥掉，只留真正的输出，并把 exit code 提出来。
function splitOutput(raw) {
  const text = String(raw || "");
  const m = text.match(/Process exited with code (-?\d+)/);
  const exitCode = m ? Number(m[1]) : null;
  const idx = text.indexOf("\nOutput:\n");
  const body = idx >= 0 ? text.slice(idx + "\nOutput:\n".length) : text;
  return { exitCode, body };
}

// 把 rollout 事件流压成一串按时间排列的展示条目。
// 只解析末尾 maxBytes，避免长任务的 rollout 越读越慢（面板每 2 秒刷一次）。
function readTimeline(file, { maxBytes = 4 * 1024 * 1024 } = {}) {
  let text;
  try {
    const st = fs.statSync(file);
    const start = Math.max(0, st.size - maxBytes);
    const fd = fs.openSync(file, "r");
    const buf = Buffer.alloc(st.size - start);
    fs.readSync(fd, buf, 0, buf.length, start);
    fs.closeSync(fd);
    text = buf.toString("utf8");
    // 从中间截断时首行多半是半条 JSON，丢掉
    if (start > 0) text = text.slice(text.indexOf("\n") + 1);
  } catch {
    return { items: [], meta: {}, truncated: false };
  }

  const items = [];
  const meta = {};
  const pendingCalls = new Map();
  let truncated = false;

  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    let ev;
    try { ev = JSON.parse(line); } catch { continue; }
    const p = ev.payload || {};
    const ts = ev.timestamp || p.timestamp || "";

    if (ev.type === "session_meta") {
      meta.cwd = p.cwd || meta.cwd;
      meta.model_provider = p.model_provider || meta.model_provider;
      meta.startedAt = p.timestamp || meta.startedAt;
      continue;
    }
    if (ev.type === "event_msg" && p.type === "thread_settings_applied") {
      const s = p.thread_settings || {};
      meta.model = s.model || meta.model;
      meta.provider = s.model_provider_id || meta.provider;
      meta.effort = s.reasoning_effort || meta.effort;
      meta.workdir = s.cwd || meta.workdir;
      continue;
    }
    if (ev.type === "event_msg" && p.type === "task_started") {
      meta.turnId = p.turn_id || meta.turnId;
      items.push({ type: "turn", ts, text: `turn ${p.turn_id || ""}` });
      continue;
    }
    if (ev.type === "event_msg" && p.type === "token_count") {
      const t = p.info?.total_token_usage;
      if (t) meta.tokens = t.total_tokens;
      continue;
    }
    if (ev.type === "event_msg" && p.type === "user_message") {
      items.push({ type: "task", ts, text: String(p.message || "") });
      continue;
    }
    if (ev.type === "event_msg" && p.type === "agent_message") {
      items.push({ type: "message", ts, text: String(p.message || "") });
      continue;
    }
    if (ev.type === "response_item" && p.type === "reasoning") {
      // summary 常常是空数组（reasoning_summary=none 时），真正的正文在 content[].text
      const parts = [];
      for (const s of p.summary || []) parts.push(typeof s === "string" ? s : s?.text || "");
      for (const c of p.content || []) if (c?.text) parts.push(c.text);
      const body = parts.filter(Boolean).join("\n").trim();
      if (body) items.push({ type: "thinking", ts, text: body });
      continue;
    }
    if (ev.type === "response_item" && p.type === "function_call") {
      const desc = describeCall(p);
      const item = { type: "call", ts, callId: p.call_id || "", ...desc, output: "", exitCode: null };
      items.push(item);
      if (item.callId) pendingCalls.set(item.callId, item);
      continue;
    }
    if (ev.type === "response_item" && p.type === "function_call_output") {
      const { exitCode, body } = splitOutput(p.output);
      const target = pendingCalls.get(p.call_id);
      if (target) {
        target.output = body;
        target.exitCode = exitCode;
      } else {
        // 调用本身落在截断区之外
        truncated = true;
        items.push({ type: "call", ts, kind: "shell", text: "(命令已滚出缓冲区)", output: body, exitCode });
      }
      continue;
    }
    // response_item/message 里 role=developer/user 的是注入的 CLAUDE.md 与上下文，几千行，
    // 不进时间线；assistant 的正文已由 event_msg/agent_message 覆盖。
  }

  return { items, meta, truncated };
}

// 列表列要的是"这个 worker 此刻在干什么"，不是完整时间线。只读末尾一小段反向找最近一条
// 有意义的事件——列表每几秒刷一次、worker 可能有十几个，不能为一列摘要去解析整个 rollout。
function lastActivity(file, { tailBytes = 96 * 1024 } = {}) {
  let text;
  try {
    const st = fs.statSync(file);
    const start = Math.max(0, st.size - tailBytes);
    const fd = fs.openSync(file, "r");
    const buf = Buffer.alloc(st.size - start);
    fs.readSync(fd, buf, 0, buf.length, start);
    fs.closeSync(fd);
    text = buf.toString("utf8");
    if (start > 0) text = text.slice(text.indexOf("\n") + 1);
  } catch {
    return null;
  }

  const lines = text.split("\n");
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i];
    if (!line.trim()) continue;
    let ev;
    try { ev = JSON.parse(line); } catch { continue; }
    const p = ev.payload || {};
    if (ev.type === "event_msg" && p.type === "agent_message" && p.message) {
      return { kind: "message", text: String(p.message) };
    }
    if (ev.type === "response_item" && p.type === "function_call") {
      const d = describeCall(p);
      return { kind: d.kind === "patch" ? "patch" : "shell", text: d.text };
    }
    if (ev.type === "response_item" && p.type === "reasoning") {
      const parts = [];
      for (const c of p.content || []) if (c?.text) parts.push(c.text);
      for (const s of p.summary || []) parts.push(typeof s === "string" ? s : s?.text || "");
      const body = parts.filter(Boolean).join(" ").trim();
      if (body) return { kind: "thinking", text: body };
    }
  }
  return null;
}

module.exports = {
  codexHome,
  sessionsRoot,
  findRollout,
  stripCdPrefix,
  describeCall,
  splitOutput,
  readTimeline,
  lastActivity,
};
