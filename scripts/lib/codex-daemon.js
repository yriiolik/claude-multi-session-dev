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

// 指纹只覆盖 **app-server 进程启动时读取** 的文件：config.toml（provider 定义 / base_url /
// 认证）与模型目录 json。逐 session 的 model/provider 选择是 thread/start 参数，改了不用重启，
// 因此 multi-session-dev.json 故意不进指纹。
function configFingerprint(config, catalogPath) {
  const parts = [fileStamp(config.path)];
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

module.exports = {
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
