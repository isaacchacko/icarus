-- Root mode on the command line (isovim.rootmode keeps the state). iso rootmode on <repo|host>
-- puts a root in charge of clearing the Inbox: an agent spawned over ACP with the role (repo-root
-- for a repo, root for the host), or the agent that holds that role already, with --task
-- "<description>" as its first message (guidance only: the root decides what's outside it and
-- leaves that to you). iso rootmode off just stops telling it of questions. iso rootmode on host
-- takes the place of a root the iso root file names, and tells it so.
--
-- The root and you share the Inbox. The root is told of each new question open to roots by its
-- own supervisor's subscription (isovim.rootmode.listen, one message per batch), and of those
-- already waiting when root mode turns on (one message listing them, from here). It answers with iso <role>
-- answer <question> <answer>, which reaches the asker as yours does (a router blocked in iso router
-- surface question, an ACP agent's supervisor), or leaves it to you with --raise.
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

local label = rootmode.label

-- The --task text, as the root's first message.
local function task_text(scope, task)
  return ("Root mode is on for %s, and you are its %s. Your task, as guidance (you decide what falls "
    .. "outside it, and leave that to the user with iso %s answer <question> --raise):\n\n%s")
    :format(label(scope), scope == "host" and "host root" or "repo root", rootmode.role(scope), task)
end

-- A scope from what was typed: host (or root), owner/repo, or a dir in a repo.
local function scope_of(text)
  -- root, the host root's pseudo-repo, is the host's too.
  if text == "host" or text == store.ROOT then
    return "host"
  end
  local dir = vim.fs.normalize(text)
  if vim.fn.isdirectory(dir) == 1 then
    return require("isovim.repos").of(vim.uv.fs_realpath(dir) or dir) or fail(text .. " isn't in a repo with an origin")
  elseif not store.is_pseudo(text) and store.valid_key(text) then
    return text:lower()
  end
  fail(("%s is neither host, a repo (owner/repo) nor a dir in one"):format(text))
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

local USAGE = 'usage: iso rootmode on|off <repo|host> [--task "<description>"]'

-- The iso root file's root, when root mode on the host took its place, is told so.
local function tell_replaced(before, scope, address)
  local root = require("isovim.root")
  local now = root.address(address:match("^(.*)/([^/]+)$"))
  local local_address = before and before:match("^" .. vim.pesc(require("isovim.remote").self()) .. ":(.+)$")
  if not local_address or before == now then
    return
  end
  local ok, err = c.try(send, local_address, ("The user turned root mode on for %s: %s holds the root role now, and "
    .. "the user's authority goes with it, so your messages aren't stamped as the root's. iso root still names you, "
    .. "and you are the root again if %s goes."):format(label(scope), now, now))
  if not ok then
    io.stderr:write(("iso: could not tell %s it isn't the root now: %s\n"):format(before, err))
  end
end

-- Tells the scope's root of every question waiting in its Inbox (every repo's, for the host), in
-- one message, marking them told so its subscription (rootmode.listen) doesn't tell them again.
local function tell_waiting(scope, address)
  local list = rootmode.take(address, scope == "host" and surfaces.repos() or { scope }, true)
  if list and #list > 0 then
    local ok, err = c.try(send, address, rootmode.questions_text(("Root mode is on for %s: you clear its Inbox with "
      .. "the user. %s waiting there now:"):format(label(scope), #list == 1 and "One question is"
      or (#list .. " questions are")), list, scope))
    if not ok then
      io.stderr:write(("iso: root mode: could not tell %s of the %d waiting question(s): %s\n"):format(address, #list, err))
    end
  end
end

local function on(scope, task)
  local before = scope == "host" and require("isovim.root").get() or nil
  local role = rootmode.role(scope)
  local address, mode = rootmode.active(scope)
  if address then
    if task then
      mode.task = task
      rootmode.set(scope, mode)
      send(address, task_text(scope, task))
    end
    out(("root mode is already on for %s: %s%s"):format(label(scope), address, task and "; it has the task now" or ""))
    tell_waiting(scope, address)
    return
  end
  local roles = require("isovim.cli.roles")
  address = roles.holders(role, scope ~= "host" and scope or nil)[1]
  local first = task and task_text(scope, task) or nil
  if address then
    rootmode.set(scope, { agent = address, task = task, since = os.time() })
    if first then
      send(address, first)
    end
    out(("root mode is on for %s: %s, its %s already, clears its Inbox with you now"):format(label(scope), address, role))
  else
    -- A new agent spawned with the role, never promoted: its first session opens (session/new) with
    -- the role's prompt, which a resumed or reloaded session couldn't take as its system prompt.
    -- Not while claude isn't logged in here: a root that can't work would be on in your place.
    local blocked = require("isovim.auth").why("claude")
    if blocked then
      fail(("root mode stays off for %s: %s"):format(label(scope), blocked))
    end
    -- The host root lives in root/, the pseudo-repo of its own.
    local key = scope == "host" and store.ROOT or scope
    local dir = scope ~= "host" and known_clone(scope) or nil
    local agent, err = store.add_agent(key, { kind = "claude", acp = true, name = role, role = role, checkout = dir,
      prompt = first })
    if not agent then
      fail(err or "could not add the agent")
    end
    address = key .. "/" .. agent.id
    rootmode.set(scope, { agent = address, task = task, since = os.time() })
    c.ensure_running(c.resolve(key), store.agent(key, agent.id))
    out(("root mode is on for %s: %s, a new %s, clears its Inbox with you"):format(label(scope), address, role))
  end
  tell_replaced(before, scope, address)
  tell_waiting(scope, address)
  c.tui("require('isovim').refresh()")
end

local function off(scope)
  local mode = rootmode.entry(scope)
  if not mode then
    out("root mode is already off for " .. label(scope))
    return
  end
  rootmode.set(scope, nil)
  local ws, id = mode.agent:match("^(.*)/([^/]+)$")
  if ws and store.agent(ws, id) then
    c.try(send, mode.agent, ("Root mode is off for %s: you aren't told of its questions now, and they're the "
      .. "user's to answer. You keep your role."):format(label(scope)))
  end
  out(("root mode is off for %s; %s keeps its role"):format(label(scope), mode.agent))
  c.tui("require('isovim').refresh()")
end

-- iso rootmode on|off <repo|host> [--task "<description>"]
function M.rootmode(args)
  local task = option(args, "--task")
  local mode, target = args[1], args[2]
  if (mode ~= "on" and mode ~= "off") or not target or args[3] then
    fail(USAGE)
  elseif task and mode == "off" then
    fail("--task is for iso rootmode on")
  end
  local scope = scope_of(target)
  if mode == "on" then
    on(scope, task and vim.trim(task) ~= "" and vim.trim(task) or nil)
  else
    off(scope)
  end
end

return M
