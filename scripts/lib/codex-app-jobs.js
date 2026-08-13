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
// 任务组归属：这个 RQ 是哪个主 session 派出去的
//
// 面板按 RQ 分组，组标题要显示"发起这批 worker 的主 session 叫什么"。协调目录的 task.meta
// 只有 cwd/分支，没有 session 身份，所以由派发脚本在派发时落一份 owner.meta。
//
// 只存 pid / session id / 当时的名字快照；**展示时按 pid 去 `~/.claude/sessions/<pid>.json`
// 取实时名字**——主 session 的标题会被取名 hook 改写（"bg" → 中文标题），快照会过期。
// ---------------------------------------------------------------------------

function claudeSessionRegistry(pid) {
  if (!pid) return null;
  try {
    return JSON.parse(fs.readFileSync(path.join(process.env.HOME || os.homedir(), ".claude", "sessions", `${pid}.json`), "utf8"));
  } catch {
    return null;
  }
}

// 派发脚本跑在主 session 的进程树里：优先信 CLAUDE_PID，拿不到就沿父进程链找注册文件。
function detectOwner(env = process.env) {
  const out = { pid: 0, sessionId: env.CLAUDE_CODE_SESSION_ID || "", name: "" };
  const direct = Number(env.CLAUDE_PID) || 0;
  const candidates = [];
  if (direct) candidates.push(direct);
  let pid = process.pid;
  for (let i = 0; i < 8 && pid > 1; i++) {
    candidates.push(pid);
    const ppid = Number(gitFreeParentPid(pid));
    if (!ppid || ppid === pid) break;
    pid = ppid;
  }
  for (const c of candidates) {
    const reg = claudeSessionRegistry(c);
    if (reg && reg.sessionId) {
      out.pid = c;
      out.sessionId = reg.sessionId;
      out.name = reg.name || "";
      return out;
    }
  }
  return out;
}

function gitFreeParentPid(pid) {
  try {
    return execFileSync("ps", ["-o", "ppid=", "-p", String(pid)], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return "";
  }
}

function ownerMetaPath(coord) {
  return path.join(coord, "owner.meta");
}

function writeOwnerMeta(coord, owner) {
  const file = ownerMetaPath(coord);
  const lines = [
    `owner_pid=${owner.pid || ""}`,
    `owner_session_id=${owner.sessionId || ""}`,
    `owner_name=${(owner.name || "").replace(/\n/g, " ")}`,
    `owner_cwd=${owner.cwd || ""}`,
    `recorded_at=${Math.floor(Date.now() / 1000)}`,
  ];
  fs.writeFileSync(file, `${lines.join("\n")}\n`);
  return file;
}

function readOwnerMeta(coord) {
  const meta = parseEnv(ownerMetaPath(coord));
  return {
    pid: Number(meta.owner_pid) || 0,
    sessionId: meta.owner_session_id || "",
    name: meta.owner_name || "",
    cwd: meta.owner_cwd || "",
  };
}

// 实时名字优先，主 session 已退出则回落到快照，都没有就交给调用方兜底。
function resolveOwnerName(owner) {
  if (owner && owner.pid) {
    const reg = claudeSessionRegistry(owner.pid);
    if (reg && reg.sessionId === (owner.sessionId || reg.sessionId) && reg.name) return reg.name;
  }
  return owner && owner.name ? owner.name : "";
}

// 回退推断：owner.meta 出现之前派发的历史 RQ 没有归属记录。协调目录的 task.meta 里有派发时的
// cwd，拿它去活着的 claude session 注册表里找同 cwd 的会话。同 cwd 多开时可能猜错，所以调用方
// 要把来源标成 inferred，不要当成确凿信息。
function inferOwnerByCwd(coord) {
  const task = parseEnv(path.join(coord, "task.meta"));
  const cwd = task.cwd;
  if (!cwd) return null;
  const dir = path.join(process.env.HOME || os.homedir(), ".claude", "sessions");
  let files;
  try {
    files = fs.readdirSync(dir).filter((f) => /^\d+\.json$/.test(f));
  } catch {
    return null;
  }
  const hits = [];
  for (const f of files) {
    try {
      const reg = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8"));
      if (reg && reg.cwd === cwd && reg.name) hits.push(reg);
    } catch {}
  }
  if (!hits.length) return null;
  // 忙着的优先（多半就是正在盯这批 worker 的那个），否则取最近启动的
  hits.sort((a, b) => {
    const ba = a.status === "busy" ? 0 : 1;
    const bb = b.status === "busy" ? 0 : 1;
    if (ba !== bb) return ba - bb;
    return (b.startedAt || 0) - (a.startedAt || 0);
  });
  return { pid: hits[0].pid || 0, sessionId: hits[0].sessionId || "", name: hits[0].name, cwd };
}

// ---------------------------------------------------------------------------
// 分屏比例自校正
//
// Ghostty 的 split 固定对半，没有"按比例分"的配置项，能程序化调整的只有
// `resize_split:<方向>,<像素>`（相对移动分割线）。像素与列的换算取决于字号，事先算不出来。
//
// 所以由**面板自己**收敛：它知道自己的列数（对半切出来时 = 源面板的一半），据此推出源面板总列数
// 与目标列数，发一次 resize，再用实际列数变化反推出每列多少像素，下一次就能一步到位。
// ---------------------------------------------------------------------------

const DEFAULT_PX_PER_COL = 8; // 14pt 等宽字体的经验值，只作为第一次试探的起点

// currentCols：面板当前列数；ratio：面板应占**被切开的那个面板**的比例。
// 刚 split 出来是对半，所以源面板总列数 ≈ currentCols / 0.5。
function planSplitResize({ currentCols, ratio, pxPerCol = DEFAULT_PX_PER_COL, totalCols = 0 }) {
  const total = totalCols || Math.round(currentCols * 2);
  const target = Math.max(20, Math.round(total * ratio));
  const deltaCols = currentCols - target;
  const px = Math.round(Math.abs(deltaCols) * (pxPerCol > 0 ? pxPerCol : DEFAULT_PX_PER_COL));
  return {
    totalCols: total,
    targetCols: target,
    deltaCols,
    // 面板在右侧：把自己的左边界往右推（direction=right）就是缩小
    direction: deltaCols > 0 ? "right" : "left",
    pixels: px,
    done: Math.abs(deltaCols) <= 1 || px <= 0,
  };
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

// ---------------------------------------------------------------------------
// 关闭分屏
//
// 为什么必须由我们主动关：Ghostty 1.3.1 **不会**在分屏里的命令退出后收掉 surface，即便
// `new surface configuration` 里把 `wait after command` 设成了 false（2026-08-13 实测：
// 命令 exit 0 七秒后 surface 仍 alive）。表现就是面板收工后留下一块
// "Process exited. Press any key to close the terminal."，还要用户手动敲一下键。
// 实测同时确认：`close` 一个 surface —— 无论里面的进程已退出还是仍在跑，甚至就是从**该
// surface 自己内部**发起 —— 都会立即生效，不弹确认框。所以关闭一律走 AppleScript close。
//
// 先找齐再关：在 `repeat with t in terminals` 里直接 close 会让正在遍历的集合当场失效，
// 报「不能获得 item N of every terminal。无效的索引 (-1719)」。
const GHOSTTY_CLOSE_SCRIPT = `on run argv
  set theId to item 1 of argv
  tell application "Ghostty"
    set target to missing value
    repeat with t in terminals
      if (id of t as text) is theId then
        set target to t
        exit repeat
      end if
    end repeat
    if target is missing value then return "not-found"
    close target
    return "closed"
  end tell
end run`;

// timeout 是保命用的：关闭动作常常发生在「面板已经不在了」的收尾路径上，osascript 万一
// 挂住（Ghostty 无响应 / 弹了别的对话框），不能把调用方一起拖住。
function closeGhosttySurface(terminalId, opts = {}) {
  const bin = opts.osascript || process.env.CC_GHOSTTY_OSASCRIPT || "/usr/bin/osascript";
  const res = spawnSync(bin, ["-", String(terminalId)], {
    input: GHOSTTY_CLOSE_SCRIPT,
    encoding: "utf8",
    stdio: ["pipe", "pipe", "pipe"],
    timeout: opts.timeoutMs || 6000,
  });
  const out = String(res.stdout || "").trim();
  return {
    ok: res.status === 0,
    out,
    closed: res.status === 0 && out !== "not-found",
    err: String(res.stderr || "").trim() || (res.error ? String(res.error.message || res.error) : `osascript exit ${res.status}`),
  };
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
  claudeSessionRegistry,
  detectOwner,
  ownerMetaPath,
  writeOwnerMeta,
  readOwnerMeta,
  resolveOwnerName,
  inferOwnerByCwd,
  DEFAULT_PX_PER_COL,
  planSplitResize,
  panelDir,
  panelPidFile,
  panelStateFile,
  panelPid,
  panelAlive,
  writePanelPid,
  clearPanelPid,
  readPanelState,
  writePanelState,
  GHOSTTY_CLOSE_SCRIPT,
  closeGhosttySurface,
};
