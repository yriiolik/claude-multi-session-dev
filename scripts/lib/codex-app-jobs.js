// codex-app-jobs — Codex App worker 元数据的读取、状态判定与全局登记。
//
// 抽出来的原因：`cc-fleet-status-codex-app` 与 `cc-fleet-panel-codex-app` 必须对
// 「这个 worker 现在算什么状态」给出**完全一致**的答案，否则面板和编排者会各说各话。
// 判定逻辑只允许存在于本文件。
//
// 关键区分：
//   - status 脚本是**编排视角**，读状态时顺带做副作用（unarchive/resume/取消 pin/写回元数据）；
//   - panel 是**旁观视角**，必须只读——面板每几秒刷一次，任何副作用都会被放大成刷屏级写入。
//   本文件只提供纯函数 + 只读快照，副作用留在 status 脚本自己那边。

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync, spawnSync } = require("child_process");

const TERMINAL_STATES = new Set(["done", "failed", "stopped", "lost"]);
const ACTIVE_STATES = new Set(["running", "blocked"]);

function gitOut(args, cwd) {
  try {
    return execFileSync("git", args, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      cwd: cwd || process.cwd(),
    }).trim();
  } catch {
    return "";
  }
}

function gitCommonDir(cwd) {
  return gitOut(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd);
}

function defaultCoord(rq, cwd) {
  const common = gitCommonDir(cwd);
  return common ? path.join(common, "fleet", rq) : "";
}

function parseEnv(file) {
  const out = {};
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch {
    return out;
  }
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim() || line.trim().startsWith("#")) continue;
    const idx = line.indexOf("=");
    if (idx > 0) out[line.slice(0, idx)] = line.slice(idx + 1);
  }
  return out;
}

// 回执契约：summary 文件第一行必须以 `result:` 开头才算 worker 真正交付。
// 「thread 空闲」不等于完成——Codex 的 turn 跑完就 idle，可能只是在等追加指令。
function receiptDone(file) {
  if (!file) return false;
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch {
    return false;
  }
  const lines = text.replace(/^﻿/, "").split(/\r?\n/);
  const first = lines.find((line) => line.trim());
  return !!first && /^result:/i.test(first.trim());
}

function appendDetail(job, text) {
  job.detail = job.detail ? `${job.detail}；${text}` : text;
}

// 纯函数：把 app-server 的 thread 快照翻译成 fleet 状态词。无副作用、不碰磁盘。
function classifyFromThread(job, thread) {
  job.appStatus = thread?.status?.type || "unknown";
  const turns = Array.isArray(thread?.turns) ? thread.turns : [];
  const latestTurn = turns.length ? turns[turns.length - 1] : null;
  job.turnStatus = latestTurn?.status || "";

  if (latestTurn?.status === "inProgress" || thread?.status?.type === "active") {
    const flags = thread?.status?.activeFlags || [];
    if (flags.includes("waitingOnApproval")) {
      job.state = "blocked";
      job.detail = "Codex App thread 等待 approval / 输入";
    } else {
      job.state = "running";
      job.detail = `Codex App thread active turn=${latestTurn?.id || job.turn_id || "-"}`;
    }
    return job;
  }
  if (job.terminated === "1") {
    job.state = "stopped";
    job.detail = `Codex App session 已由主控停止${job.terminated_turn_id ? ` turn=${job.terminated_turn_id}` : ""}`;
    return job;
  }
  if (latestTurn?.status === "failed" || thread?.status?.type === "systemError") {
    job.state = "failed";
    job.detail = "Codex App thread failed/systemError";
    return job;
  }
  if (latestTurn?.status === "interrupted") {
    job.state = "failed";
    job.detail = "Codex App turn interrupted";
    return job;
  }
  if (latestTurn?.status === "completed" || ["idle", "notLoaded"].includes(thread?.status?.type)) {
    job.state = "done";
    job.detail = "Codex App thread 已空闲/完成；如无回执请读最后消息核验";
    return job;
  }
  job.state = "unknown";
  job.detail = `Codex App thread 状态未知: ${job.appStatus}`;
  return job;
}

// 列出一个协调目录下登记过的所有 Codex App worker（只读元数据，不连 app-server）。
function listJobs(coord) {
  let files;
  try {
    files = fs.readdirSync(coord).filter((f) => f.endsWith(".codex-app.env")).sort();
  } catch {
    return [];
  }
  return files.map((f) => {
    const full = path.join(coord, f);
    const meta = parseEnv(full);
    meta.module = meta.module || f.replace(/\.codex-app\.env$/, "");
    meta.meta = full;
    meta.coord = coord;
    meta.summary_file = meta.summary_file || path.join(coord, `${meta.module}.summary.md`);
    return meta;
  });
}

function makeAppCaller({ coord, codexBin = "", startAppServer = true, callBin = "" } = {}) {
  const bin = callBin || process.env.CODEX_APP_CALL_BIN || path.join(__dirname, "..", "cc-codex-app-call");
  return function callApp(method, params) {
    const tmpDir = path.join(coord, "app-json");
    fs.mkdirSync(tmpDir, { recursive: true });
    const tmp = path.join(tmpDir, `.jobs-${process.pid}-${Math.random().toString(16).slice(2)}.json`);
    fs.writeFileSync(tmp, JSON.stringify(params));
    const args = [];
    if (codexBin) args.push("--codex-bin", codexBin);
    if (startAppServer) args.push("--start-app-server");
    else args.push("--no-start-app-server");
    args.push(method, tmp);
    const res = spawnSync(bin, args, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      maxBuffer: 64 * 1024 * 1024,
    });
    try { fs.unlinkSync(tmp); } catch {}
    if (res.status !== 0) {
      throw new Error((res.stderr || res.stdout || `app call failed ${res.status}`).trim());
    }
    return JSON.parse(res.stdout);
  };
}

// 只读快照：面板专用。有回执直接定案（不必打扰 app-server），否则读一次 thread。
// 绝不 unarchive / resume / unpin / 写回元数据。
function readOnlySnapshot(coord, opts = {}) {
  const callApp = opts.callApp || makeAppCaller({ coord, ...opts });
  // filter 在**发起 app 调用之前**生效：注册表里躺着的历史 RQ 可能有几十个早已收工的
  // worker，逐个 thread/read 会让面板每一次刷新都 spawn 一堆进程。
  const keep = typeof opts.filter === "function" ? opts.filter : () => true;
  const jobs = listJobs(coord).filter(keep);
  let appUnavailable = false;
  for (const job of jobs) {
    if (receiptDone(job.summary_file)) {
      job.receipt = 1;
      job.state = "done";
      job.detail = `🧾回执在案 ${job.summary_file}`;
      continue;
    }
    job.receipt = 0;
    const threadId = job.thread_id || job.id;
    if (!threadId) {
      job.state = "lost";
      job.detail = "缺少 thread_id";
      continue;
    }
    try {
      const data = callApp("thread/read", { threadId, includeTurns: true });
      classifyFromThread(job, data.thread);
    } catch (e) {
      appUnavailable = true;
      job.state = "unknown";
      job.detail = `无法读取 Codex App thread: ${String(e.message || e).slice(0, 160)}`;
    }
  }
  return { coord, jobs, appUnavailable };
}

// ---------------------------------------------------------------------------
// 全局协调目录注册表
//
// 面板要跨 session、跨仓库看到「所有」codex worker，但满盘扫 .git/fleet 又慢又不可靠。
// 所以派发时主动登记一行，面板只读注册表。条目里的 coord 目录没了就自动剔除。
// ---------------------------------------------------------------------------

function registryPath() {
  return process.env.CC_FLEET_PANEL_REGISTRY
    || path.join(process.env.HOME || os.homedir(), ".claude", "fleet", "codex-coords.json");
}

function readRegistry() {
  try {
    const data = JSON.parse(fs.readFileSync(registryPath(), "utf8"));
    return Array.isArray(data?.coords) ? data.coords : [];
  } catch {
    return [];
  }
}

function writeRegistry(coords) {
  const file = registryPath();
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp-${process.pid}-${Math.random().toString(16).slice(2)}`;
  fs.writeFileSync(tmp, `${JSON.stringify({ proto: 1, coords }, null, 2)}\n`);
  fs.renameSync(tmp, file);
}

// 幂等登记。并发派发已被派发脚本的目录锁串行化，这里再做一次 read-modify-write 收敛即可。
function registerCoord(coord, rq, extra = {}) {
  if (!coord) return readRegistry();
  const abs = path.resolve(coord);
  const now = Math.floor(Date.now() / 1000);
  const coords = readRegistry().filter((c) => c && c.coord);
  const found = coords.find((c) => path.resolve(c.coord) === abs);
  if (found) {
    found.rq = rq || found.rq;
    found.lastSeen = now;
    Object.assign(found, extra);
  } else {
    coords.push({ coord: abs, rq: rq || path.basename(abs), firstSeen: now, lastSeen: now, ...extra });
  }
  writeRegistry(coords);
  return coords;
}

// 读注册表并剔除已消失的目录（worktree 被清理、仓库被删等）。
function listCoords({ prune = true } = {}) {
  const coords = readRegistry().filter((c) => c && c.coord);
  const alive = coords.filter((c) => {
    try {
      return fs.statSync(c.coord).isDirectory();
    } catch {
      return false;
    }
  });
  if (prune && alive.length !== coords.length) {
    try { writeRegistry(alive); } catch {}
  }
  return alive;
}

// ---------------------------------------------------------------------------
// 面板进程/分屏状态
//
// 幂等靠 pidfile 而不是 pgrep：拉起面板时 osascript 的命令行里也带着面板脚本路径，
// 用 `pgrep -f` 会把 osascript 自己也算成"面板已在跑"，于是永远开不出第一个面板。
// ---------------------------------------------------------------------------

function panelDir() {
  return path.dirname(registryPath());
}

function panelPidFile() {
  return process.env.CC_FLEET_PANEL_PIDFILE || path.join(panelDir(), "codex-panel.pid");
}

function panelStateFile() {
  return process.env.CC_FLEET_PANEL_STATE || path.join(panelDir(), "codex-panel.json");
}

function panelPid() {
  try {
    const pid = Number(fs.readFileSync(panelPidFile(), "utf8").trim());
    return Number.isFinite(pid) && pid > 0 ? pid : 0;
  } catch {
    return 0;
  }
}

function panelAlive() {
  const pid = panelPid();
  if (!pid) return 0;
  try {
    process.kill(pid, 0);
    return pid;
  } catch {
    return 0;
  }
}

function writePanelPid(pid) {
  const file = panelPidFile();
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${pid}\n`);
}

function clearPanelPid(pid) {
  try {
    if (pid && panelPid() !== pid) return;
    fs.unlinkSync(panelPidFile());
  } catch {}
}

function readPanelState() {
  try {
    return JSON.parse(fs.readFileSync(panelStateFile(), "utf8"));
  } catch {
    return {};
  }
}

function writePanelState(state) {
  const file = panelStateFile();
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, `${JSON.stringify(state, null, 2)}\n`);
  fs.renameSync(tmp, file);
}

module.exports = {
  TERMINAL_STATES,
  ACTIVE_STATES,
  gitOut,
  gitCommonDir,
  defaultCoord,
  parseEnv,
  receiptDone,
  appendDetail,
  classifyFromThread,
  listJobs,
  makeAppCaller,
  readOnlySnapshot,
  registryPath,
  readRegistry,
  writeRegistry,
  registerCoord,
  listCoords,
  panelDir,
  panelPidFile,
  panelStateFile,
  panelPid,
  panelAlive,
  writePanelPid,
  clearPanelPid,
  readPanelState,
  writePanelState,
};
