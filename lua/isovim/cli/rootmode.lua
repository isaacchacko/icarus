-- Root mode on the command line (isovim.rootmode keeps the state). iso rootmode on <repo|host>
-- makes a root answer in your place: an agent spawned over ACP with the role (repo-root for a repo,
-- root for the host), or the agent that holds that role already, with --task "<description>" as
-- its first message (guidance only: the root decides what's outside it and raises that to you).
-- iso rootmode off hands its waiting questions on, to the host root or to you, as iso rm of a root
-- does. iso rootmode on host takes the place of a root the iso root file names, and tells it so.
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

-- The roots a question asked in repo goes to, most specific first: the repo's root, then the
-- host root, while root mode is on for each. A root never gets its own question (from, the asker):
-- a repo root's goes on to the host root.
local function roots_for(repo, from)
  local found = {}
  for _, scope in ipairs({ repo, "host" }) do
    local to, mode = rootmode.active(scope)
    if to and to ~= from and not vim.iter(found):any(function(r)
      return r.to == to
    end) then
      found[#found + 1] = { to = to, mode = mode, scope = scope }
    end
  end
  return found
end

-- Sends a pending question to the most specific active root, or back to the user when there's
-- none; one a root raised stays with the user. from is the asking router (<ws>/<agent>), if any
-- (else the one that asked it first). It's marked routed to a root only once the root has it: a
-- root the send fails for is passed over, for the next root or the user. resend gives it to a
-- root that has it already (it was reworded).
---@return string? to the root it went to
function M.route_question(entry, from, resend)
  -- The root pseudo-repo's questions are the host root's own, to you.
  if entry.answer or entry.raised or entry.repo == "root" then
    return entry.routed
  end
  from = from or entry.asker
  for _, root in ipairs(roots_for(entry.repo, from)) do
    if root.to == entry.routed and not resend then
      return root.to
    end
    local ok, err = c.try(send, root.to, question_text(entry, root.scope, root.mode, from), from)
    if ok then
      surfaces.route(entry, root.to, nil, from)
      return root.to
    end
    io.stderr:write(("iso: root mode: %s/%s could not go to the root %s (%s); passing it on\n")
      :format(entry.repo, entry.name, root.to, err))
  end
  if entry.routed then
    surfaces.route(entry, nil, nil, from)
  end
end

-- Hands on every pending question routed to address, a root whose root mode went off or that was
-- removed: to the next root, or to the user.
---@return {entry: isovim.Surface, to?: string}[] moved
function M.reroute(address)
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
local reroute = M.reroute

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
    out(("root mode is on for %s: %s, a new %s, answers its routers"):format(label(scope), address, role))
  end
  tell_replaced(before, scope, address)
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
  local next_root = rootmode.route(scope ~= "host" and scope or store.GENERAL)
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
