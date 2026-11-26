import { execFileSync, spawn } from "node:child_process";
import { closeSync, existsSync, openSync } from "node:fs";
import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
export const skillRoot = resolve(here, "..");
export const repoRoot = resolve(skillRoot, "../../..");
export const dataRoot = process.env.AGENT_BROWSER_DATA_DIR
  ? resolve(process.env.AGENT_BROWSER_DATA_DIR)
  : join(repoRoot, ".data");
export const environmentsRoot = join(dataRoot, "environments");
export const trajectoriesRoot = join(dataRoot, "trajectories");
export const currentFile = join(dataRoot, "current-run.json");
export const cdpPort = Number(process.env.AGENT_BROWSER_CDP_PORT ?? 9222);
export const formalWebSkill = join(repoRoot, "formal-web", ".agents", "skills", "browser-debug", "scripts", "cdp.mjs");

export function environmentDir(name) {
  return join(environmentsRoot, name);
}

export function siteDir(name) {
  return join(environmentDir(name), "site");
}

export async function readJSON(path, fallback = null) {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch {
    return fallback;
  }
}

export async function writeJSON(path, value) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, JSON.stringify(value, null, 2));
}

export async function currentRun() {
  return await readJSON(currentFile);
}

export async function setCurrentRun(value) {
  await mkdir(dataRoot, { recursive: true });
  await writeFile(currentFile, JSON.stringify(value, null, 2));
}

export async function connectCDP() {
  const module = await import(formalWebSkill);
  const client = await module.connect(cdpPort);
  return { ...module, client };
}

export async function waitForCDP(timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${cdpPort}/json/version`);
      if (response.ok) return true;
    } catch {
      // not up yet
    }
    await sleep(250);
  }
  return false;
}

export async function waitForPageTarget(timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${cdpPort}/json/list`);
      if (response.ok) {
        const targets = await response.json();
        if (targets.some((target) => target.type === "page")) return true;
      }
    } catch {
      // not up yet
    }
    await sleep(250);
  }
  return false;
}

function stopExistingApps() {
  for (const pattern of [
    "Agent Browser.app/Contents/MacOS/agent-browser",
    ".build/out/Products/Debug/agent-browser",
    ".build/out/Products/Release/agent-browser",
    ".build/debug/agent-browser",
    ".build/release/agent-browser",
    "formal-web-content",
    "formal-web-net",
    "formal-web-graphics",
    "formal-web-media",
  ]) {
    try {
      execFileSync("pkill", ["-f", pattern], { stdio: "ignore" });
    } catch {
      // No matching process.
    }
  }
}

export async function ensureApp() {
  if (await waitForCDP(800)) {
    return { reused: true, process: null };
  }
  // A stale window without the requested CDP port must not leave two apps
  // running. Stop every known agent-browser binary before starting one.
  stopExistingApps();
  await sleep(300);
  const appBundle = join(repoRoot, "dist", "Agent Browser.app");
  const candidates = [
    join(appBundle, "Contents", "MacOS", "agent-browser"),
    join(repoRoot, ".build", "out", "Products", "Debug", "agent-browser"),
    join(repoRoot, ".build", "debug", "agent-browser"),
  ];
  const binary = candidates.find((candidate) => existsSync(candidate));
  if (!binary) {
    throw new Error("The agent browser binary is missing. Run scripts/build-app.sh first.");
  }
  const log = join(dataRoot, "app.log");
  await mkdir(dataRoot, { recursive: true });
  const model = process.env.AGENT_BROWSER_MODEL
    || join(homedir(), "Projects", "Models", "Qwen3.5-4B-MLX-4bit");
  const training = Boolean(process.env.AGENT_BROWSER_TRAINING);

  // LaunchServices starts the app outside this sandbox. That matters for
  // MLX: Metal's kernel cache and the model snapshot live outside the
  // directories the coding agent's sandbox can reach. The app writes its own
  // app.log under the data directory, which the skill reads. Fall back to a
  // direct spawn when the bundle is not available.
  if (existsSync(appBundle)) {
    const openArgs = [
      "-n", appBundle, "--args",
      "--cdp-port", String(cdpPort),
      "--data-dir", dataRoot,
      "--model", model,
    ];
    if (training) openArgs.push("--training");
    try {
      execFileSync("open", openArgs, { stdio: "ignore" });
    } catch {
      // Fall through to the direct spawn below.
    }
    if (await waitForCDP()) {
      return { reused: false, process: null, log, launchedWithOpen: true };
    }
  }

  const logFD = openSync(log, "a");
  const args = ["--cdp-port", String(cdpPort), "--data-dir", dataRoot, "--model", model];
  if (training) args.push("--training");
  const appEnvironment = { ...process.env };
  const developmentExtensions = join(repoRoot, "formal-web", "target", "release");
  if (!appEnvironment.AGENT_BROWSER_EXTENSIONS && existsSync(developmentExtensions)) {
    appEnvironment.AGENT_BROWSER_EXTENSIONS = developmentExtensions;
  }
  const child = spawn(binary, args, {
    env: appEnvironment,
    detached: true,
    stdio: ["ignore", logFD, logFD],
  });
  closeSync(logFD);
  child.unref();
  const up = await waitForCDP();
  if (!up) throw new Error(`The agent browser did not start. See ${log}`);
  return { reused: false, process: child, log };
}

export function fileURLFor(site) {
  return pathToFileURL(join(site, "index.html")).href;
}

export async function installTrace(site) {
  await copyFile(join(skillRoot, "trace.js"), join(site, "trace.js"));
}

export async function dumpBrowserLog(client, jsEval) {
  try {
    const entries = await jsEval(client, "window.__agentBrowserLog || []");
    return Array.isArray(entries) ? entries : [];
  } catch {
    return [];
  }
}

export function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function parseArgs(argv) {
  const positional = [];
  const options = new Map();
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument.startsWith("--")) {
      const name = argument.slice(2);
      const next = argv[index + 1];
      if (next !== undefined && !next.startsWith("--")) {
        options.set(name, next);
        index += 1;
      } else {
        options.set(name, true);
      }
    } else {
      positional.push(argument);
    }
  }
  return { positional, options };
}
