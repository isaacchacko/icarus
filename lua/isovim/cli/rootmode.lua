-- Root mode on the command line (isovim.rootmode keeps the state). iso rootmode on <repo|host>
-- makes a root answer in your place: a worker spawned over ACP and promoted (repo-root for a repo,
-- root for the host), or the agent that holds that role already, with --task "<description>" as
-- its first message (guidance only: the root decides what's outside it and raises that to you).
-- iso rootmode off hands its waiting questions on, to the host root or to you.
--
-- A router's question goes to the most specific active root: the question surface stays in the
-- router's repo, marked as routed to that root (so it waits on the root, not on you), and the root
-- gets it as a message, stamped as from the router. The root answers with iso <role> answer
-- <question> <answer>, which unblocks the router's iso router surface question, or gives it to
-- you with iso <role> answer <question> --raise.
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

local function label(scope)
  return scope == "host" and "this host" or scope
end

-- The --task text, as the root's first message.
local function task_text(scope, task)
  return ("Root mode is on for %s, and you are its %s. Your task, as guidance (you decide what falls "
    .. "outside it, and raise that to the user with iso %s answer <question> --raise):\n\n%s")
    :format(label(scope), scope == "host" and "host root" or "repo root", rootmode.role(scope), task)
end

-- The question as its root gets it.
local function question_text(entry, scope, mode, from)
  local role = rootmode.role(scope)
  local id = entry.repo .. "/" .. entry.name
  local lines = { ("[question %s, from %s] %s%s"):format(id, from and ("the router " .. from) or "a shell",
    entry.question, entry.multi and " (pick any)" or "") }
  for i, opt in ipairs(entry.options) do
    lines[#lines + 1] = ("  %d. %s%s"):format(i, opt.label, opt.description and (" · " .. opt.description) or "")
  end
  if entry.other then
    lines[#lines + 1] = "  (or your own words)"
  end
  lines[#lines + 1] = ("Root mode gives it to you, the %s of %s, and the router waits on it. Answer with "
    .. "`iso %s answer %s <answer>`, or give it to the user with `iso %s answer %s --raise`.")
    :format(scope == "host" and "host root" or "repo root", label(scope), role, id, role, id)
  if mode and mode.task then
    lines[#lines + 1] = "Your task (raise what's outside it): " .. mode.task
  end
  return table.concat(lines, "\n")
end

-- Sends a pending question to the most specific active root, or back to the user when there's
-- none; one a root raised stays with the user. from is the asking router (<ws>/<agent>), if any.
---@return string? to the root it went to
function M.route_question(entry, from)
  -- The root pseudo-repo's questions are the host root's own, to you.
  if entry.answer or entry.raised or entry.repo == "root" then
    return entry.routed
  end
  local to, mode, scope = rootmode.route(entry.repo)
  -- A root never gets its own question: a repo root's goes on to the host root.
  if to and to == from then
    local was = scope
    to, mode, scope = nil, nil, nil
    if was ~= "host" and rootmode.active("host") ~= from then
      to, mode = rootmode.active("host")
      scope = to and "host" or nil
    end
  end
  if to == entry.routed then
    return to
  end
  local routed = surfaces.route(entry, to)
  if to and routed then
    send(to, question_text(routed, scope, mode, from), from)
  end
  return to
end

-- Hands on every pending question routed to address (a root whose root mode went off).
local function reroute(address)
  local moved = {}
  for _, repo in ipairs(surfaces.repos()) do
    for _, entry in ipairs(surfaces.scan(repo)) do
      if entry.type == "question" and not entry.answer and entry.routed == address then
        moved[#moved + 1] = { entry = entry, to = M.route_question(entry) }
      end
    end
  end
  return moved
end

-- A scope from what was typed: host, owner/repo, or a dir in a repo.
local function scope_of(text)
  if text == "host" then
    return "host"
  end
  local dir = vim.fs.normalize(text)
  if vim.fn.isdirectory(dir) == 1 then
    return require("isovim.repos").of(vim.uv.fs_realpath(dir) or dir) or fail(text .. " isn't in a repo with an origin")
  elseif text ~= "_" and store.valid_key(text) then
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

local function on(scope, task)
  local role = rootmode.role(scope)
  local address, mode = rootmode.active(scope)
  if address then
    if task then
      mode.task = task
      rootmode.set(scope, mode)
      send(address, task_text(scope, task))
    end
    out(("root mode is already on for %s: %s%s"):format(label(scope), address, task and "; it has the task now" or ""))
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
    out(("root mode is on for %s: %s, its %s already, answers its routers now"):format(label(scope), address, role))
  else
    -- A worker, promoted before its first session opens, so that session has the role's prompt.
    local key = scope == "host" and "_" or scope
    local dir = scope ~= "host" and known_clone(scope) or nil
    local agent, err = store.add_agent(key, { kind = "claude", acp = true, name = role, role = "worker", checkout = dir,
      prompt = first })
    if not agent then
      fail(err or "could not add the agent")
    end
    store.set_role(key, agent.id, role)
    address = key .. "/" .. agent.id
    rootmode.set(scope, { agent = address, task = task, since = os.time() })
    c.ensure_running(c.resolve(key), store.agent(key, agent.id))
    out(("root mode is on for %s: %s, a new %s, answers its routers"):format(label(scope), address, role))
  end
  c.tui("require('isovim').refresh()")
end

local function off(scope)
  local mode = rootmode.entry(scope)
  if not mode then
    out("root mode is already off for " .. label(scope))
    return
  end
  rootmode.set(scope, nil)
  local moved = reroute(mode.agent)
  local next_root = rootmode.route(scope ~= "host" and scope or "_")
  local ws, id = mode.agent:match("^(.*)/([^/]+)$")
  if ws and store.agent(ws, id) then
    send(mode.agent, ("Root mode is off for %s: its routers' questions go to %s now. You keep your role.")
      :format(label(scope), next_root or "the user"))
  end
  for _, m in ipairs(moved) do
    out(("%s/%s goes to %s"):format(m.entry.repo, m.entry.name, m.to or "the user"))
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
