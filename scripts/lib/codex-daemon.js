// codex-daemon.js — Codex app-server 进程生命周期：活性探测、陈旧 pid 自愈、配置漂移判定。
//
// 存在理由（2026-08-06 实测踩坑）：app-server 的 pid 文件指向已死进程时，
// `codex app-server daemon start` 会认为"已经在跑"而不重启，只是空等 socket 直到超时，
// 并且把**前一天的**旧 stderr 贴出来当报错——极具误导性。这里把这套自愈做成脚本内部行为，
// 让上层命令无感。

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

function daemonPaths(codexHome) {
  const dir = path.join(codexHome, "app-server-daemon");
  return {
    dir,
    pidFile: path.join(dir, "app-server.pid"),
    stderrLog: path.join(dir, "app-server.stderr.log"),
    sockPath: path.join(codexHome, "app-server-control", "app-server-control.sock"),
    // 记录"当前这个 server 进程是带着哪份配置启动的"，用于漂移判定。
    stateFile: path.join(dir, ".msd-server-state.json"),
  };
}

function readPidFile(pidFile) {
  try {
    const parsed = JSON.parse(fs.readFileSync(pidFile, "utf8"));
    const pid = Number(parsed.pid);
    return Number.isFinite(pid) && pid > 0 ? { pid, raw: parsed } : null;
  } catch {
    return null;
  }
}

function pidAlive(pid) {
  try { process.kill(pid, 0); return true; } catch (error) { return error.code === "EPERM"; }
}

function timestampSuffix() {
  // 不用 Date 的本地化格式，避免不同 locale 产生奇怪文件名。
  return String(Math.floor(Date.now() / 1000));
}

// 陈旧 pid 自愈：pid 文件指向已死进程时移走它，并清掉残留的 pid-update-loop 辅助进程。
// 只在 server 已确认不可用时调用——绝不碰一个活着的 daemon。
function reapStaleDaemon(paths) {
  const actions = [];
  const record = readPidFile(paths.pidFile);

  // ⚠ 只有"pid 文件指向一个已经死掉的进程"才是确凿的陈旧现场。其余情况（pid 还活着、
  // 压根没有 pid 文件）一律**什么都不做**——否则会把一个健康的 daemon 连同它的 socket 一起打死。
  if (!record) return actions;
  if (pidAlive(record.pid)) return actions;

  const dest = `${paths.pidFile}.stale-${timestampSuffix()}`;
  try {
    fs.renameSync(paths.pidFile, dest);
    actions.push(`移走指向已死进程 ${record.pid} 的 pid 文件`);
  } catch (error) {
    actions.push(`无法移走陈旧 pid 文件: ${error.message || error}`);
  }

  // 残留的 `codex app-server daemon pid-update-loop` 会让新 daemon 误判"已在运行"。
  // 走到这里说明主进程已死，这些 loop 就是孤儿。
  const found = spawnSync("pgrep", ["-f", "codex app-server daemon"], { encoding: "utf8" });
  const pids = String(found.stdout || "")
    .split(/\s+/)
    .map((v) => Number(v))
    .filter((v) => Number.isFinite(v) && v > 0 && v !== process.pid);
  for (const pid of pids) {
    try { process.kill(pid, "SIGTERM"); actions.push(`终止残留 daemon 辅助进程 ${pid}`); } catch { /* 已退出 */ }
  }

  // 主进程已死，遗留的 socket 文件只会让连接报出误导性错误。
  try {
    if (fs.existsSync(paths.sockPath)) {
      fs.unlinkSync(paths.sockPath);
      actions.push("清理陈旧 control socket");
    }
  } catch { /* socket 可能刚被新 daemon 接管 */ }

  return actions;
}

function startDaemon(bin, timeoutMs) {
  const attempts = [["app-server", "daemon", "start"], ["remote-control", "start", "--json"]];
  const errors = [];
  for (const args of attempts) {
    const rc = spawnSync(bin, args, { encoding: "utf8", timeout: timeoutMs, stdio: ["ignore", "pipe", "pipe"] });
    if (rc.status === 0) return { ok: true, via: args.join(" ") };
    errors.push(`${args.join(" ")}: ${(rc.stderr || rc.stdout || rc.error || "").toString().trim().split("\n")[0] || "failed"}`);
  }
  return { ok: false, error: errors.join(" | ") };
}

function stopDaemon(bin, timeoutMs) {
  const attempts = [["app-server", "daemon", "stop"], ["remote-control", "stop"]];
  for (const args of attempts) {
    const rc = spawnSync(bin, args, { encoding: "utf8", timeout: timeoutMs, stdio: ["ignore", "pipe", "pipe"] });
    if (rc.status === 0) return { ok: true, via: args.join(" ") };
  }
  return { ok: false };
}

// 活性探测走真实 JSON-RPC（config/read），而不是看 pid/socket 文件是否存在——
// 文件存在但进程已死正是本模块要解决的那类假象。
function probeAppServer(scriptsDir, bin, timeoutMs) {
  const helper = process.env.CODEX_APP_CALL_BIN || path.join(scriptsDir, "cc-codex-app-call");
  const args = ["--timeout-ms", String(Math.max(1000, timeoutMs))];
  if (bin) args.push("--codex-bin", bin);
  args.push("config/read", "-");
  const rc = spawnSync(helper, args, {
    input: "{}", encoding: "utf8", stdio: ["pipe", "pipe", "pipe"], timeout: timeoutMs + 5000,
  });
  return { ok: rc.status === 0, detail: (rc.stderr || rc.stdout || "").toString().trim() };
}

function fileStamp(file) {
  try {
    const st = fs.statSync(file);
    return `${path.basename(file)}:${st.size}:${Math.floor(st.mtimeMs)}`;
  } catch {
    return `${path.basename(file)}:absent`;
  }
}

// config.toml 按内容取指纹，剔除 Codex 运行时自己追加的 `[projects."<目录>"]` 信任记录：
// 每个新 worktree 都会追加一段，按 mtime/大小判断会让 fleet 每派一张卡就误判「配置已变更」而重启 daemon（2026-10-26 实测）。
function configContentStamp(file) {
  let text;
  try { text = fs.readFileSync(file, "utf8"); } catch { return `${path.basename(file)}:absent`; }
  const kept = [];
  let skipping = false;
  for (const line of text.split(/\r?\n/)) {
    const header = line.match(/^\s*\[\[?\s*([^\]]+?)\s*\]\]?\s*(#.*)?$/);
    if (header) skipping = /^projects\./.test(header[1]);
    if (!skipping) kept.push(line);
  }
  const digest = require("crypto").createHash("sha256").update(kept.join("\n")).digest("hex").slice(0, 16);
  return `${path.basename(file)}#${digest}`;
}

// 指纹只覆盖 **app-server 进程启动时读取** 的文件：config.toml（provider 定义 / base_url /
// 认证）与模型目录 json。逐 session 的 model/provider 选择是 thread/start 参数，改了不用重启，
// 因此 multi-session-dev.json 故意不进指纹。
function configFingerprint(config, catalogPath) {
  const parts = [configContentStamp(config.path)];
  if (catalogPath) parts.push(fileStamp(catalogPath));
  return parts.join("|");
}

function readServerState(paths) {
  try { return JSON.parse(fs.readFileSync(paths.stateFile, "utf8")); } catch { return null; }
}

function writeServerState(paths, state) {
  try {
    fs.mkdirSync(paths.dir, { recursive: true });
    fs.writeFileSync(paths.stateFile, `${JSON.stringify(state, null, 2)}\n`);
    return true;
  } catch { return false; }
}

// 只取 server 本次启动之后写入的 stderr。旧日志混进报错是最常见的误导来源。
function freshStderr(paths, sinceMs, maxLines = 8) {
  try {
    const st = fs.statSync(paths.stderrLog);
    if (sinceMs && st.mtimeMs < sinceMs) return "";
    const lines = fs.readFileSync(paths.stderrLog, "utf8").trim().split(/\r?\n/);
    const recent = lines.slice(-maxLines).filter((line) => {
      if (!sinceMs) return true;
      const match = line.match(/"timestamp"\s*:\s*"([^"]+)"/);
      if (!match) return true;
      const ts = Date.parse(match[1]);
      return !Number.isFinite(ts) || ts >= sinceMs - 1000;
    });
    return recent.join("\n");
  } catch {
    return "";
  }
}

// ---- 版本对齐：daemon 与本机 Codex 安装、Codex App 内置 codex ----
// 桌面端（ChatGPT.app / Codex.app）用内置 codex 起**自己的** app-server（进程内管道，外部连不上），
// fleet 走共享 daemon。两边同库不同进程：版本可能不一致，桌面端也收不到 daemon 上的推送。
const APP_BUNDLED_CODEX = [
  "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
  "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
];

function coreVersion(v) {
  const m = String(v || "").match(/(\d+)\.(\d+)\.(\d+)/);
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}

// a<b → -1；只比核心版本号，0.164.0-alpha.11.1 与 0.164.0 视为同版。任一不可解析 → 0（不判）。
function compareCore(a, b) {
  const x = coreVersion(a), y = coreVersion(b);
  if (!x || !y) return 0;
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] < y[i] ? -1 : 1;
  return 0;
}

function cliVersion(bin, timeoutMs = 5000) {
  if (!bin) return "";
  const rc = spawnSync(bin, ["--version"], { encoding: "utf8", timeout: timeoutMs });
  const m = `${rc.stdout || ""} ${rc.stderr || ""}`.match(/codex-cli\s+(\S+)/);
  return m ? m[1] : "";
}

// 正在运行的 daemon 是哪个版本、由哪个二进制托管（`app-server daemon version` 的公开 JSON）。
function daemonInfo(bin, timeoutMs = 8000) {
  const rc = spawnSync(bin, ["app-server", "daemon", "version"], { encoding: "utf8", timeout: timeoutMs });
  try {
    const j = JSON.parse(String(rc.stdout || "").trim().split("\n").pop());
    return { status: j.status || "", version: j.appServerVersion || "", managedPath: j.managedCodexPath || "",
             managedVersion: j.managedCodexVersion || "" };
  } catch { return null; }
}

// 测试可用 CC_CODEX_APP_BUNDLED_BIN 指定（none = 没装 App）、CC_CODEX_APP_RUNNING=0/1/file:<路径> 覆盖进程探测。
function appInfo() {
  const override = process.env.CC_CODEX_APP_BUNDLED_BIN;
  const bin = override === "none" ? "" : (override || APP_BUNDLED_CODEX.find((p) => {
    try { fs.accessSync(p, fs.constants.X_OK); return true; } catch { return false; }
  }) || "");
  if (!bin) return null;
  let running = process.env.CC_CODEX_APP_RUNNING;
  if (running?.startsWith("file:")) running = fs.existsSync(running.slice(5)) ? "1" : "0";
  if (running === undefined) {
    const rc = spawnSync("pgrep", ["-f", "CodexCLI.app/Contents/MacOS/codex.* app-server"], { encoding: "utf8" });
    running = rc.status === 0 ? "1" : "0";
  }
  const bundle = (bin.match(/^(.*?\.app)\/Contents\//) || [])[1] || "";
  return { path: bin, bundle, version: cliVersion(bin), running: running === "1" };
}

// Codex App 被关掉时在后台把它拉起来（open -g 不抢焦点），等它自带的 app-server 起来。
// 测试用 CC_CODEX_APP_OPEN_BIN 替换 open。
function launchApp(app, timeoutMs = 45000) {
  if (!app?.bundle) return { ok: false, error: "找不到 Codex App 安装位置" };
  const opener = process.env.CC_CODEX_APP_OPEN_BIN || "open";
  const rc = spawnSync(opener, ["-g", "-a", app.bundle], { encoding: "utf8", timeout: 15000 });
  if (rc.status !== 0) return { ok: false, error: String(rc.stderr || rc.error || "open failed").trim().split("\n")[0] };
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    if (appInfo()?.running) return { ok: true };
    spawnSync("sleep", ["1"]);
  }
  return { ok: false, error: `已发出启动，${Math.round(timeoutMs / 1000)} 秒内未见 App 的 app-server 进程` };
}

module.exports = {
  APP_BUNDLED_CODEX,
  compareCore,
  cliVersion,
  daemonInfo,
  appInfo,
  launchApp,
  daemonPaths,
  readPidFile,
  pidAlive,
  reapStaleDaemon,
  startDaemon,
  stopDaemon,
  probeAppServer,
  configFingerprint,
  readServerState,
  writeServerState,
  freshStderr,
};
