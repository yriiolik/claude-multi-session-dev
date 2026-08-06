// codex-config.js — Codex CLI 发现 + config.toml 解析 + 路由目标校验（纯函数，无副作用）。
//
// 被 cc-codex-ensure / cc-codex-doctor 共用。这里只回答"配置本身对不对"，
// 不负责 app-server 进程生命周期（那在 codex-daemon.js）。

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

function homeDir() {
  return process.env.HOME || os.homedir();
}

function codexHome() {
  return process.env.CODEX_HOME || path.join(homeDir(), ".codex");
}

function executable(file) {
  if (!file) return false;
  try { fs.accessSync(file, fs.constants.X_OK); return true; } catch { return false; }
}

// 与 cc-codex-app-call / cc-codex-doctor 保持同一套发现顺序，避免不同脚本连到不同 CLI。
function discoverCodexBin(preferred) {
  const pick = preferred || process.env.CODEX_CLI_PATH || "";
  if (pick) return executable(pick) ? pick : "";
  const home = homeDir();
  const bundled = [
    path.join(home, ".local", "bin", "codex"),
    "/Applications/ChatGPT.app/Contents/Resources/codex",
    "/Applications/Codex.app/Contents/Resources/codex",
    path.join(home, ".codex", "plugins", ".plugin-appserver", "codex"),
  ].find(executable);
  if (bundled) return bundled;
  const which = spawnSync("sh", ["-c", "command -v codex"], { encoding: "utf8" });
  if (which.status === 0 && executable(which.stdout.trim())) return which.stdout.trim();
  return "";
}

function codexVersion(bin) {
  if (!bin) return "";
  const result = spawnSync(bin, ["--version"], { encoding: "utf8" });
  const match = `${result.stdout || ""} ${result.stderr || ""}`.match(/codex-cli\s+(\d+\.\d+\.\d+)/);
  return match ? match[1] : "";
}

function semverAtLeast(actual, minimum) {
  const a = String(actual || "").split(".").map(Number);
  const b = String(minimum || "").split(".").map(Number);
  for (let i = 0; i < 3; i++) {
    if ((a[i] || 0) > (b[i] || 0)) return true;
    if ((a[i] || 0) < (b[i] || 0)) return false;
  }
  return true;
}

function stripComment(line) {
  let quote = "";
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if ((c === '"' || c === "'") && line[i - 1] !== "\\") {
      quote = quote === c ? "" : (quote || c);
    } else if (c === "#" && !quote) {
      return line.slice(0, i);
    }
  }
  return line;
}

function unquote(value) {
  const v = String(value).trim();
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) return v.slice(1, -1);
  return v;
}

// 够用的 TOML 子集解析：只取 `section.key = value`，足以覆盖 model_providers.* 的判断。
function parseSimpleToml(text) {
  const values = {};
  let section = "";
  for (const raw of String(text).split(/\r?\n/)) {
    const line = stripComment(raw).trim();
    if (!line) continue;
    const sectionMatch = line.match(/^\[([^\]]+)\]$/);
    if (sectionMatch) { section = sectionMatch[1].trim(); continue; }
    const keyMatch = line.match(/^([A-Za-z0-9_.-]+)\s*=\s*(.+)$/);
    if (!keyMatch) continue;
    values[section ? `${section}.${keyMatch[1]}` : keyMatch[1]] = unquote(keyMatch[2]);
  }
  return values;
}

function expandUser(value) {
  if (!value) return "";
  if (value === "~") return homeDir();
  if (value.startsWith("~/")) return path.join(homeDir(), value.slice(2));
  return value;
}

function readCodexConfig(home) {
  const dir = home || codexHome();
  const file = path.join(dir, "config.toml");
  if (!fs.existsSync(file)) return { path: file, exists: false, values: {} };
  try {
    return { path: file, exists: true, values: parseSimpleToml(fs.readFileSync(file, "utf8")) };
  } catch (error) {
    return { path: file, exists: true, values: {}, error: error.message || String(error) };
  }
}

// 活动路由目标 = cc-codex-session-config resolve 的输出（单一事实源）。
function resolveRouting(scriptsDir) {
  const resolver = path.join(scriptsDir, "cc-codex-session-config");
  const result = spawnSync(resolver, ["resolve", "--json"], { encoding: "utf8" });
  if (result.status !== 0) {
    return { ok: false, error: (result.stderr || result.stdout || "routing config invalid").trim() };
  }
  try {
    return { ok: true, routing: JSON.parse(result.stdout) };
  } catch (error) {
    return { ok: false, error: `无法解析 resolver 输出: ${error.message || error}` };
  }
}

function catalogPathOf(config) {
  return expandUser(config.values.model_catalog_json || "");
}

// 校验"这个路由目标现在真能派出去"：provider 有定义、认证可用、model 在目录里。
// 返回 problems（阻断派发）与 warnings（只提示）。
function validateRouting(config, routing, options = {}) {
  const problems = [];
  const warnings = [];
  if (!routing || routing.mode !== "fixed") return { problems, warnings };

  const providerId = routing.modelProvider || "";
  const prefix = `model_providers.${providerId}.`;
  const baseUrl = config.values[`${prefix}base_url`] || "";
  if (!providerId) {
    problems.push(`路由目标 ${routing.active} 未指定 modelProvider`);
    return { problems, warnings };
  }
  if (!baseUrl) {
    problems.push(`路由目标 ${routing.active} 的 provider=${providerId} 未在 ${config.path} 中定义（缺 [model_providers.${providerId}]）`);
  }

  const envKey = config.values[`${prefix}env_key`] || "";
  const bearer = config.values[`${prefix}experimental_bearer_token`] || "";
  if (envKey && !process.env[envKey]) {
    problems.push(`provider=${providerId} 声明 env_key=${envKey}，但当前环境未设置该变量`);
  } else if (!envKey && (!bearer || /[<>]|your|你的/i.test(bearer))) {
    problems.push(`provider=${providerId} 没有可用认证（env_key 未设置且 experimental_bearer_token 缺失/占位）`);
  } else if (!envKey && bearer) {
    warnings.push(`provider=${providerId} 使用 experimental_bearer_token；改用 env_key 可降低明文密钥暴露`);
  }

  const model = routing.model || "";
  const catalog = catalogPathOf(config);
  if (model && catalog) {
    if (!fs.existsSync(catalog)) {
      problems.push(`model_catalog_json 指向的文件不存在: ${catalog}`);
    } else {
      try {
        const parsed = JSON.parse(fs.readFileSync(catalog, "utf8"));
        const models = Array.isArray(parsed.models) ? parsed.models : [];
        const entry = models.find((item) => item && item.slug === model);
        if (!entry) {
          problems.push(`模型目录 ${catalog} 中没有 ${model}`);
        } else if (entry.minimal_client_version && options.version && !semverAtLeast(options.version, entry.minimal_client_version)) {
          problems.push(`${model} 要求 Codex >= ${entry.minimal_client_version}，当前 ${options.version}`);
        }
      } catch (error) {
        problems.push(`模型目录 JSON 无效: ${error.message || error}`);
      }
    }
  }

  if (routing.providerType === "deepseek") {
    const wireApi = config.values[`${prefix}wire_api`] || "";
    if (wireApi !== "responses") {
      problems.push(`DeepSeek provider=${providerId} 需要 wire_api="responses"，实为 ${wireApi || "<missing>"}`);
    }
  }

  return { problems, warnings };
}

module.exports = {
  homeDir,
  codexHome,
  executable,
  discoverCodexBin,
  codexVersion,
  semverAtLeast,
  stripComment,
  unquote,
  parseSimpleToml,
  expandUser,
  readCodexConfig,
  resolveRouting,
  catalogPathOf,
  validateRouting,
};
