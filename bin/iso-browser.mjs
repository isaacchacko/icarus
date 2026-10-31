#!/usr/bin/env node
// `iso browser`: one isovim Chrome per host for agents to drive over CDP. It runs with its own
// profile (your Chrome cookies copied in on first start), opens in the background and never
// takes keyboard focus; you reach it with cmd+tab. Each workspace keeps its own tabs in
// ~/.isovim/run/<ws>/browser.json. No dependencies: Node's built-in fetch and WebSocket.
import { spawn } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir, platform } from "node:os";
import { dirname, join } from "node:path";

const HOME = process.env.ISOVIM_HOME || join(homedir(), ".isovim");
const PORT = Number(process.env.ISOVIM_BROWSER_PORT || 9333);
const BASE = `http://127.0.0.1:${PORT}`;
const PROFILE = join(HOME, "browser", "profile");

const USAGE = `usage: iso browser <command> [--ws <id>] [--tab <id>]
  start                 launch the isovim Chrome (in the background) if it isn't running
  tabs                  this workspace's tabs: id, url, title
  open <url>            open a tab for this workspace (in a background window), print its id
  go <url>              navigate the tab
  text                  the page's visible text
  eval <js>             evaluate JS in the page, print the result as JSON
  click <selector>      click the first element matching a CSS selector
  fill <selector> <text>  set an input's value the way typing would
  shot <file.png>       screenshot the tab
  close                 close the tab
The workspace defaults to $ISOVIM_WS (agents have it); the tab to the workspace's newest.
CDP endpoint for other tools: ${BASE}`;

function fail(message) {
  process.stderr.write(`iso browser: ${message}\n`);
  process.exit(1);
}

function option(args, name) {
  const i = args.indexOf(name);
  if (i === -1) return undefined;
  const [, value] = args.splice(i, 2);
  return value ?? fail(`${name} needs a value`);
}

async function version() {
  try {
    const response = await fetch(`${BASE}/json/version`);
    return response.ok ? response.json() : null;
  } catch {
    return null;
  }
}

function chromeBinary() {
  if (platform() === "darwin") return "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  for (const bin of ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"]) {
    for (const dir of (process.env.PATH || "").split(":")) {
      if (existsSync(join(dir, bin))) return join(dir, bin);
    }
  }
  fail("no Chrome or Chromium found");
}

// Copies your signed-in Chrome's cookies into the fresh profile. On macOS cookies are encrypted
// with Chrome's keychain key, which every profile of the same Chrome shares.
function seedCookies() {
  const source =
    platform() === "darwin"
      ? join(homedir(), "Library/Application Support/Google/Chrome/Default")
      : join(homedir(), ".config/google-chrome/Default");
  for (const file of ["Network/Cookies", "Cookies"]) {
    const from = join(source, file);
    if (existsSync(from)) {
      const to = join(PROFILE, "Default", file);
      mkdirSync(dirname(to), { recursive: true });
      copyFileSync(from, to);
    }
  }
}

const FLAGS = [
  `--remote-debugging-port=${PORT}`,
  `--user-data-dir=${PROFILE}`,
  "--no-first-run",
  "--no-default-browser-check",
  // Background windows keep rendering, so screenshots and timers work while you're elsewhere.
  "--disable-backgrounding-occluded-windows",
  "--disable-renderer-backgrounding",
  "--disable-background-timer-throttling",
  // A first window would activate Chrome; tabs bring their own background windows.
  "--no-startup-window",
];

async function start() {
  if (await version()) return;
  if (!existsSync(PROFILE)) {
    mkdirSync(PROFILE, { recursive: true });
    seedCookies();
  }
  // -g keeps it in the background, -n makes a separate instance from your own Chrome.
  const [cmd, args] =
    platform() === "darwin"
      ? ["open", ["-g", "-n", "-a", "Google Chrome", "--args", ...FLAGS]]
      : [chromeBinary(), FLAGS];
  spawn(cmd, args, { detached: true, stdio: "ignore" }).unref();
  for (let i = 0; i < 100; i++) {
    if (await version()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  fail(`Chrome did not open its debugging port ${PORT} within 10s`);
}

function tabsFile(ws) {
  return join(HOME, "run", ws, "browser.json");
}

function readTabs(ws) {
  try {
    return JSON.parse(readFileSync(tabsFile(ws), "utf8"));
  } catch {
    return [];
  }
}

function writeTabs(ws, tabs) {
  mkdirSync(dirname(tabsFile(ws)), { recursive: true });
  writeFileSync(tabsFile(ws), JSON.stringify(tabs));
}

async function targets() {
  const response = await fetch(`${BASE}/json/list`);
  return (await response.json()).filter((target) => target.type === "page");
}

// The workspace's tabs that still exist, newest last.
async function liveTabs(ws) {
  const live = new Map((await targets()).map((target) => [target.id, target]));
  const tabs = readTabs(ws).filter((id) => live.has(id));
  writeTabs(ws, tabs);
  return tabs.map((id) => live.get(id));
}

async function pickTab(ws, id) {
  const tabs = await liveTabs(ws);
  const tab = id ? tabs.find((t) => t.id.startsWith(id)) : tabs.at(-1);
  return tab || fail(id ? `no tab ${id} in workspace ${ws}` : `workspace ${ws} has no tab; iso browser open <url>`);
}

// One CDP session over a WebSocket: send(method, params) resolves with the result.
async function connect(wsUrl) {
  const socket = new WebSocket(wsUrl);
  await new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = () => reject(new Error(`could not connect to ${wsUrl}`));
  });
  let next = 0;
  const pending = new Map();
  socket.onmessage = (event) => {
    const message = JSON.parse(event.data);
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    message.error ? waiter.reject(new Error(message.error.message)) : waiter.resolve(message.result);
  };
  return {
    send(method, params = {}) {
      const id = ++next;
      socket.send(JSON.stringify({ id, method, params }));
      return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
    },
    close: () => socket.close(),
  };
}

async function onTab(tab, fn) {
  const session = await connect(tab.webSocketDebuggerUrl);
  try {
    return await fn(session);
  } finally {
    session.close();
  }
}

async function evaluate(tab, expression) {
  return onTab(tab, async (cdp) => {
    const { result, exceptionDetails } = await cdp.send("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (exceptionDetails) fail(exceptionDetails.exception?.description || exceptionDetails.text);
    return result.value;
  });
}

async function waitForLoad(tab) {
  for (let i = 0; i < 150; i++) {
    if ((await evaluate(tab, "document.readyState")) === "complete") return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
}

const commands = {
  async start() {
    await start();
    console.log(BASE);
  },
  async tabs(ws) {
    for (const tab of await liveTabs(ws)) console.log(`${tab.id.slice(0, 8)}  ${tab.url}  ${tab.title}`);
  },
  async open(ws, _tab, [url]) {
    if (!url) fail("usage: iso browser open <url>");
    await start();
    const browser = await connect((await version()).webSocketDebuggerUrl);
    const { targetId } = await browser.send("Target.createTarget", { url, newWindow: true, background: true });
    browser.close();
    writeTabs(ws, [...readTabs(ws), targetId]);
    await waitForLoad(await pickTab(ws, targetId));
    console.log(targetId.slice(0, 8));
  },
  async go(ws, id, [url]) {
    const tab = await pickTab(ws, id);
    await onTab(tab, (cdp) => cdp.send("Page.navigate", { url }));
    await waitForLoad(tab);
  },
  async text(ws, id) {
    console.log(await evaluate(await pickTab(ws, id), "document.body.innerText"));
  },
  async eval(ws, id, rest) {
    console.log(JSON.stringify(await evaluate(await pickTab(ws, id), rest.join(" ")), null, 2));
  },
  async click(ws, id, [selector]) {
    const found = await evaluate(
      await pickTab(ws, id),
      `(() => { const el = document.querySelector(${JSON.stringify(selector)}); if (!el) return false; el.click(); return true; })()`,
    );
    if (!found) fail(`nothing matches ${selector}`);
  },
  // The native value setter plus input/change events is what frameworks see when you type.
  async fill(ws, id, [selector, ...text]) {
    const found = await evaluate(
      await pickTab(ws, id),
      `(() => {
        const el = document.querySelector(${JSON.stringify(selector)});
        if (!el) return false;
        const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, "value").set.call(el, ${JSON.stringify(text.join(" "))});
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
        return true;
      })()`,
    );
    if (!found) fail(`nothing matches ${selector}`);
  },
  async shot(ws, id, [file]) {
    if (!file) fail("usage: iso browser shot <file.png>");
    const { data } = await onTab(await pickTab(ws, id), (cdp) => cdp.send("Page.captureScreenshot", { format: "png" }));
    writeFileSync(file, Buffer.from(data, "base64"));
    console.log(file);
  },
  async close(ws, id) {
    const tab = await pickTab(ws, id);
    await fetch(`${BASE}/json/close/${tab.id}`);
    writeTabs(
      ws,
      readTabs(ws).filter((t) => t !== tab.id),
    );
  },
};

const args = process.argv.slice(2);
const ws = option(args, "--ws") || process.env.ISOVIM_WS;
const tab = option(args, "--tab");
const command = args.shift();
if (!commands[command]) {
  console.log(USAGE);
  process.exit(command === "help" || command === "--help" || !command ? 0 : 1);
}
if (command !== "start" && !ws) fail("no workspace: pass --ws <id> or run inside an isovim agent ($ISOVIM_WS)");
if (command !== "start" && command !== "open" && !(await version())) fail("the isovim Chrome isn't running; iso browser start");
await commands[command](ws, tab, args);
