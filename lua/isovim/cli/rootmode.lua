-- Root mode on the command line (isovim.rootmode keeps the state). iso rootmode on <repo> has the
-- repo's root decide its Inbox's questions before they reach you: an agent spawned over ACP with the
-- repo-root role, or the agent that holds it already, with --task "<description>" as its first
-- message (guidance only: the root decides what's outside it and raises that to you). iso rootmode
-- off makes what it hadn't decided yours.
--
-- The root is told of each new question by its own supervisor's subscription
-- (isovim.rootmode.listen, one message per batch), and of those already waiting when root mode
-- turns on (one message listing them, from here). It answers with iso repo-root answer <question>
-- <answer>, which reaches the asker as yours does (a router blocked in iso router surface
-- question, an ACP agent's supervisor), or raises it to you with iso repo-root raise <question>
-- <why>.
local store = require("isovim.store")
local rootmode = require("isovim.rootmode")
local surfaces = require("isovim.surfaces")
local c = require("isovim.cli.common")

local out = c.out
local fail = c.fail
local option = c.option

local M = {}

-- Gives an agent text, stamped as from `from` (<ws>/<agent> here) when an agent sent it.
local function send(address, text, from)
  local root = require("isovim.root")
  local ws, agent = c.resolve_agent(address)
  local sender, stamp
  if from then
    sender = root.address(from:match("^(.*)/([^/]+)$"))
    stamp = root.stamp("from", sender, root.address(ws.id, agent.id), text)
  end
  c.ensure_running(ws, agent)
  return c.prompt(ws, agent, stamp and (stamp .. " " .. text) or text,
    { from = sender, kind = "from", id = stamp and stamp:match("(m%x+)%]$"), text = text })
end

-- The --task text, as the root's first message.
local function task_text(repo, task)
  return ("Root mode is on for %s, and you are its repo root. Your task, as guidance (you decide what falls "
    .. "outside it, and raise that to the user with iso repo-root raise <question> <why>):\n\n%s"):format(repo, task)
end

-- A repo from what was typed: owner/repo, or a dir in a repo.
local function repo_of(text)
  local dir = vim.fs.normalize(text)
  if vim.fn.isdirectory(dir) == 1 then
    return require("isovim.repos").of(vim.uv.fs_realpath(dir) or dir) or fail(text .. " isn't in a repo with an origin")
  elseif not store.is_pseudo(text) and store.valid_key(text) then
    return text:lower()
  end
  fail(("%s is neither a repo (owner/repo) nor a dir in one"):format(text))
end

-- A clone of the repo some agent here works in, for the root's record (a base clone is made from
-- it); nil when there's none, which is fine.
local function known_clone(key)
  local repos = require("isovim.repos")
  for _, ws in ipairs(store.list()) do
    for _, agent in ipairs(store.v2(ws.id) and store.agents(ws.id) or {}) do
      if agent.checkout and vim.fn.isdirectory(agent.checkout) == 1 and ws.id == key then
        return agent.checkout
      end
    end
    if not store.v2(ws.id) and vim.fn.isdirectory(ws.dir) == 1 and repos.of(ws.dir) == key then
      return ws.dir
    end
  end
end

local USAGE = 'usage: iso rootmode on|off <repo> [--task "<description>"]'

-- Tells the repo's root of every question waiting in its Inbox, in one message, marking them told so
-- its subscription (rootmode.listen) doesn't tell them again.
local function tell_waiting(repo, address)
  local list = rootmode.take(address, repo, true)
  if #list > 0 then
    local ok, err = c.try(send, address, rootmode.questions_text(("Root mode is on for %s: you decide its Inbox's "
      .. "questions before the user. %s waiting there now:"):format(repo, #list == 1 and "One question is"
      or (#list .. " questions are")), list, repo))
    if not ok then
      io.stderr:write(("iso: root mode: could not tell %s of the %d waiting question(s): %s\n"):format(address, #list, err))
    end
  end
end

local function on(repo, task)
  local address, mode = rootmode.route(repo)
  if address then
    if task then
      mode.task = task
      rootmode.set(repo, mode)
      send(address, task_text(repo, task))
    end
    out(("root mode is already on for %s: %s%s"):format(repo, address, task and "; it has the task now" or ""))
    tell_waiting(repo, address)
    return
  end
  address = require("isovim.cli.roles").holders("repo-root", repo)[1]
  local first = task and task_text(repo, task) or nil
  if address then
    rootmode.set(repo, { agent = address, task = task, since = os.time() })
    if first then
      send(address, first)
    end
    out(("root mode is on for %s: %s, its repo-root already, decides its Inbox before you now"):format(repo, address))
  else
    -- A new agent spawned with the role, never promoted: its first session opens (session/new) with
    -- the role's prompt, which a resumed or reloaded session couldn't take as its system prompt.
    -- Not while claude isn't logged in here: a root that can't work would be on in your place.
    local blocked = require("isovim.auth").why("claude")
    if blocked then
      fail(("root mode stays off for %s: %s"):format(repo, blocked))
    end
    local agent, err = store.add_agent(repo, { kind = "claude", acp = true, name = "repo-root", role = "repo-root",
      checkout = known_clone(repo), prompt = first })
    if not agent then
      fail(err or "could not add the agent")
    end
    address = repo .. "/" .. agent.id
    rootmode.set(repo, { agent = address, task = task, since = os.time() })
    c.ensure_running(c.resolve(repo), store.agent(repo, agent.id))
    out(("root mode is on for %s: %s, a new repo-root, decides its Inbox before you"):format(repo, address))
  end
  tell_waiting(repo, address)
  c.tui("require('isovim.surfaces').recheck() require('isovim').refresh()")
end

local function off(repo)
  local mode = rootmode.entry(repo)
  if not mode then
    out("root mode is already off for " .. repo)
    return
  end
  -- What it was deciding is yours now (a question no root decides waits on you).
  local deciding = 0
  for _, entry in ipairs(surfaces.scan(repo)) do
    if entry.deciding == mode.agent then
      deciding = deciding + 1
    end
  end
  rootmode.set(repo, nil)
  local ws, id = mode.agent:match("^(.*)/([^/]+)$")
  if ws and store.agent(ws, id) then
    c.try(send, mode.agent, ("Root mode is off for %s: you aren't told of its questions or threads now, and the "
      .. "questions you hadn't decided are the user's. You keep your role."):format(repo))
  end
  out(("root mode is off for %s; %s keeps its role%s"):format(repo, mode.agent, deciding > 0
    and ("; the %d question(s) it hadn't decided are yours now"):format(deciding) or ""))
  c.tui("require('isovim.surfaces').recheck() require('isovim').refresh()")
end

-- iso rootmode on|off <repo> [--task "<description>"]
function M.rootmode(args)
  local task = option(args, "--task")
  local mode, target = args[1], args[2]
  if (mode ~= "on" and mode ~= "off") or not target or args[3] then
    fail(USAGE)
  elseif task and mode == "off" then
    fail("--task is for iso rootmode on")
  end
  local repo = repo_of(target)
  if mode == "on" then
    on(repo, task and vim.trim(task) ~= "" and vim.trim(task) or nil)
  else
    off(repo)
  end
end

return M
