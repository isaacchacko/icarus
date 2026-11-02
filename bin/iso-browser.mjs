#!/usr/bin/env node
// `iso browser`: one isovim Chrome per host for agents to drive over CDP. It runs with its own
// profile (your Chrome cookies copied in on first start), opens in the background and never
// takes keyboard focus; you reach it with cmd+tab. Each workspace keeps its tabs in
// ~/.isovim/run/<ws>/browser.json, each with the agent that opened it ($ISOVIM_ADDR): agents in one
// repo share a workspace, and in a signed-in session a command that lands on another's tab can do
// real harm, so an agent's commands act on its own tabs unless --tab names another. A shell (no
// $ISOVIM_ADDR) acts on the workspace's newest. No dependencies: Node's built-in fetch and WebSocket.
import { spawn } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, rmdirSync, statSync, writeFileSync } from "node:fs";
import { homedir, platform } from "node:os";
import { dirname, join } from "node:path";

const HOME = process.env.ISOVIM_HOME || join(homedir(), ".isovim");
const PORT = Number(process.env.ISOVIM_BROWSER_PORT || 9333);
const BASE = `http://127.0.0.1:${PORT}`;
const PROFILE = join(HOME, "browser", "profile");
// The agent running this; none in a shell.
const ME = process.env.ISOVIM_ADDR || null;

const USAGE = `usage: iso browser <command> [--ws <id>] [--tab <id>]
  start                 launch the isovim Chrome (in the background) if it isn't running
  tabs                  this workspace's tabs, every agent's: id, owner, url, title
  open <url>            open a tab of your own (in a background window), print its id
  go <url>              navigate the tab; with no tab of yours, opens one there
  text                  the page's visible text; with no tab of yours, opens a blank one
  eval <js>             evaluate JS in the page, print the result as JSON
  click <selector>      click the first element matching a CSS selector
  fill <selector> <text>  set an input's value the way typing would
  shot <file.png>       screenshot the tab; with no tab of yours, opens a blank one
  close                 close the tab
The workspace defaults to $ISOVIM_WS (agents have it). The tab defaults to your own newest: an agent's
commands never fall back to another agent's tab, and eval, click, fill and close fail if it has none.
--tab <id> reaches any tab in the workspace, another agent's too, on purpose. In a shell (no
$ISOVIM_ADDR) the tab defaults to the workspace's newest. Removing an agent closes its tabs.
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

// {id, owner?} each, newest last. A bare id is a tab from before tabs had owners: nobody's.
function readTabs(ws) {
  try {
    return JSON.parse(readFileSync(tabsFile(ws), "utf8")).map((tab) => (typeof tab === "string" ? { id: tab } : tab));
  } catch {
    return [];
  }
}

function writeTabs(ws, tabs) {
  const tmp = `${tabsFile(ws)}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(tabs));
  renameSync(tmp, tabsFile(ws));
}

// fn(tabs) under the workspace's lock: what it returns is written back, whatever it's a list of,
// so no two agents' read-then-write can drop a tab. A holder that died leaves the lock behind; one
// this old is taken over, as holding it takes a moment.
async function withTabs(ws, fn) {
  const lock = `${tabsFile(ws)}.lock`;
  mkdirSync(dirname(lock), { recursive: true });
  for (;;) {
    try {
      mkdirSync(lock);
      break;
    } catch (err) {
      if (err.code !== "EEXIST") throw err;
      try {
        if (Date.now() - statSync(lock).mtimeMs > 10000) rmdirSync(lock);
      } catch {}
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
  }
  try {
    const tabs = await fn(readTabs(ws));
    if (tabs) writeTabs(ws, tabs);
    return tabs;
  } finally {
    rmdirSync(lock);
  }
}

async function targets() {
  const response = await fetch(`${BASE}/json/list`);
  return (await response.json()).filter((target) => target.type === "page");
}

// The workspace's tabs that still exist, newest last: Chrome's targets, each with its owner. Chrome
// is asked under the lock, so a tab another agent has just added is in what's compared.
async function liveTabs(ws) {
  let live;
  const tabs = await withTabs(ws, async (kept) => {
    live = new Map((await targets()).map((target) => [target.id, target]));
    return kept.filter((tab) => live.has(tab.id));
  });
  return tabs.map((tab) => ({ ...live.get(tab.id), owner: tab.owner }));
}

// A new tab of this agent's at url, loaded.
async function openTab(ws, url) {
  await start();
  const browser = await connect((await version()).webSocketDebuggerUrl);
  const { targetId } = await browser.send("Target.createTarget", { url, newWindow: true, background: true });
  browser.close();
  await withTabs(ws, (tabs) => [...tabs, ME ? { id: targetId, owner: ME } : { id: targetId }]);
  const tab = (await liveTabs(ws)).find((t) => t.id === targetId);
  await waitForLoad(tab);
  return tab;
}

function listed(tabs) {
  return tabs.map((tab) => `${tab.id.slice(0, 8)} (${tab.owner || "nobody's"})`).join(", ") || "none";
}

// The tab a command acts on: --tab's, any in the workspace; else this agent's newest; else, in a
// shell, the workspace's newest. An agent with no tab of its own gets ifNone()'s (a command that
// can open one), or an error: never another agent's tab.
async function pickTab(ws, id, ifNone) {
  const tabs = await liveTabs(ws);
  if (id) return tabs.find((t) => t.id.startsWith(id)) || fail(`no tab ${id} in workspace ${ws}; its tabs: ${listed(tabs)}`);
  if (!ME) return tabs.at(-1) || fail(`workspace ${ws} has no tab; iso browser open <url>`);
  const mine = tabs.filter((tab) => tab.owner === ME);
  if (mine.length > 0) return mine.at(-1);
  if (ifNone) return ifNone();
  fail(
    `${ME} has no tab of its own (its tabs: none), and won't act on another agent's. ` +
      `iso browser open <url> opens one, or --tab <id> reaches another on purpose; this workspace's tabs: ${listed(tabs)}`,
  );
}

// A read with no tab of the agent's to read: it gets a blank one of its own, and is told.
function blankTab(ws) {
  return async () => {
    const tab = await openTab(ws, "about:blank");
    process.stderr.write(`iso browser: ${ME} had no tab of its own, so this opened a blank one, ${tab.id.slice(0, 8)}\n`);
    return tab;
  };
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
    for (const tab of await liveTabs(ws)) {
      console.log(`${tab.id.slice(0, 8)}  ${tab.owner || "-"}${tab.owner && tab.owner === ME ? " (you)" : ""}  ${tab.url}  ${tab.title}`);
    }
  },
  async open(ws, _tab, [url]) {
    if (!url) fail("usage: iso browser open <url>");
    console.log((await openTab(ws, url)).id.slice(0, 8));
  },
  async go(ws, id, [url]) {
    if (!url) fail("usage: iso browser go <url>");
    let opened = false;
    const tab = await pickTab(ws, id, async () => {
      opened = true;
      return openTab(ws, url);
    });
    if (opened) {
      process.stderr.write(`iso browser: ${ME} had no tab of its own, so this opened one, ${tab.id.slice(0, 8)}\n`);
      return;
    }
    await onTab(tab, (cdp) => cdp.send("Page.navigate", { url }));
    await waitForLoad(tab);
  },
  async text(ws, id) {
    console.log(await evaluate(await pickTab(ws, id, blankTab(ws)), "document.body.innerText"));
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
    const { data } = await onTab(await pickTab(ws, id, blankTab(ws)), (cdp) => cdp.send("Page.captureScreenshot", { format: "png" }));
    writeFileSync(file, Buffer.from(data, "base64"));
    console.log(file);
  },
  async close(ws, id) {
    const tab = await pickTab(ws, id);
    await fetch(`${BASE}/json/close/${tab.id}`);
    await withTabs(ws, (tabs) => tabs.filter((t) => t.id !== tab.id));
  },
  // iso rm's (isovim.lifecycle): a removed agent's tabs close, in the workspace it was in.
  async "close-agent"(ws, _id, [address]) {
    let gone = [];
    await withTabs(ws, (tabs) => {
      gone = tabs.filter((tab) => tab.owner === address);
      return gone.length > 0 ? tabs.filter((tab) => tab.owner !== address) : null;
    });
    if (gone.length > 0 && (await version())) {
      for (const tab of gone) await fetch(`${BASE}/json/close/${tab.id}`);
    }
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
if (!["start", "open", "close-agent"].includes(command) && !(await version())) fail("the isovim Chrome isn't running; iso browser start");
await commands[command](ws, tab, args);
