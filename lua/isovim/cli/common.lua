-- What the commands in isovim.cli.* share: output, failing, finding workspaces and agents by what
-- the user typed, reaching the open TUI, and starting an agent and waiting on its hooks.
local store = require("isovim.store")
local panes = require("isovim.panes")
local status = require("isovim.status")

local function usage()
  return require("isovim.cli.commands").usage()
end

-- print() goes to stderr under `nvim -l`.
local function out(text)
  io.stdout:write(text, "\n")
end

local function fail(message)
  io.stderr:write("iso: " .. message .. "\n")
  os.exit(1)
end

-- exact_only (for the commands that destroy or restart something) skips the prefix pass, so a
-- stale or short address is an error instead of some other agent.
local function unique(query, candidates, keys, what, exact_only)
  for _, exact in ipairs(exact_only and { true } or { true, false }) do
    local found = {}
    for _, candidate in ipairs(candidates) do
      for _, key in ipairs(keys(candidate)) do
        if (exact and key == query) or (not exact and vim.startswith(key, query)) then
          found[candidate.id] = candidate
        end
      end
    end
    local ids = vim.tbl_keys(found)
    if #ids == 1 then
      return found[ids[1]]
    elseif #ids > 1 then
      fail(("%q matches %d %s: %s"):format(query, #ids, what, table.concat(ids, ", ")))
    end
  end
  fail(("no %s matches %q"):format(what, query))
end

-- A repo key (store.v2) is matched by its start only when the query has a "/" or is a pseudo-repo's
-- (general, root, or _ for general), so a workspace id's prefix never runs into one.
local function resolve(query, exact)
  if not query then
    fail("missing workspace\n" .. usage())
  end
  query = store.canon(query)
  local by_key = store.v2(query)
  return unique(query, store.list(), function(ws)
    return (by_key or not store.v2(ws.id)) and { ws.id, ws.name } or {}
  end, "workspace", exact)
end

-- exact: a destructive command's target. It must be a whole <ws>/<agent> (ids or names, no
-- prefixes), so neither a stale aN that prefixes a live one nor a bare repo key reaches an agent.
---@return table ws, isovim.Agent agent
local function resolve_agent(query, exact)
  if not query then
    fail("missing agent\n" .. usage())
  end
  -- _/aN, from before general/ and root/, is where it is now.
  query = store.canon_address(query)
  -- The last "/" splits it, as a repo key (owner/repo/aN) has one of its own, unless the whole of
  -- it is a repo key: owner/repo means its first agent.
  local ws_query, agent_query = query:match("^(.*)/([^/]*)$")
  if ws_query and vim.iter(store.list()):any(function(ws)
    return ws.id == query
  end) then
    ws_query, agent_query = nil, nil
  end
  if exact and not (agent_query and agent_query ~= "") then
    fail(("%q isn't an agent's address: name one as <ws>/<agent>, exactly"):format(query))
  end
  local ws = resolve(ws_query or query, exact)
  local agents = store.agents(ws.id)
  if not agent_query then
    for _, agent in ipairs(agents) do
      if not agent.hidden then
        return ws, agent
      end
    end
    return ws, agents[1] or fail(ws.name .. " has no agents")
  end
  return ws, unique(agent_query, agents, function(agent)
    return { agent.id, agent.name }
  end, "agent in " .. ws.name, exact)
end

-- <host>:<ws>/<agent> names an agent on another host: the command runs there over ssh, as the
-- sidebar lists them. This host's own name, or none, means here.
---@return string? host, string query
local function split_host(query)
  local name, rest = (query or ""):match("^([%w_.-]+):(.+)$")
  if not name then
    return nil, query
  end
  local remote = require("isovim.remote")
  local host, canonical = remote.host_of(name)
  if canonical == remote.self() or name == vim.fn.hostname() then
    return nil, rest
  end
  return host or fail(("no host named %s in %s"):format(name, require("isovim.config").path)), rest
end

-- An agent as a parent field names it: <ws>/<agent> by ids here, <host>:<ws>/<agent> elsewhere.
local function parent_address(query)
  local host, rest = split_host(query)
  if host then
    return query:match("^([^:]+):") .. ":" .. rest
  end
  local ws, agent = resolve_agent(rest)
  return ws.id .. "/" .. agent.id
end

-- The agent running this, as a parent field names it; nil from a plain shell.
local function caller_address()
  local ws, agent = require("isovim.root").caller()
  return ws and ws .. "/" .. agent
end

-- Runs Lua in the open TUI; returns false when it isn't open.
local function tui(code, ...)
  if not vim.uv.fs_stat(store.socket) then
    return false
  end
  local ok, chan = pcall(vim.fn.sockconnect, "pipe", store.socket, { rpc = true })
  if not ok or chan == 0 then
    return false
  end
  local called, result = pcall(vim.rpcrequest, chan, "nvim_exec_lua", code, { ... })
  vim.fn.chanclose(chan)
  if not called then
    fail("TUI error: " .. tostring(result))
  end
  return true, result
end

local function word(ws, agent)
  if not panes.running(ws, agent) then
    return "stopped"
  end
  return status.get(ws, agent) or "idle"
end

-- Waits until the hooks write a state accepted by `done`; false on timeout.
local function await(ws, agent, timeout, done)
  return vim.wait(timeout * 1000, function()
    return done(status.state(ws, agent))
  end, 200)
end

-- Codex draws its composer once it can take a prompt; a resumed one replays its transcript first.
local function codex_ready(ws, agent, timeout)
  return vim.wait(timeout * 1000, function()
    return panes.capture(ws.id, agent.id, 0):find("for shortcuts") ~= nil
  end, 200)
end

local function ensure_running(ws, agent)
  if panes.running(ws.id, agent.id) then
    -- It may have just been started elsewhere (iso receive); a busy one takes the prompt queued.
    if agent.kind == "codex" then
      codex_ready(ws, agent, 5)
    end
    return
  end
  local result = panes.start(ws.id, agent, store.agent_dir(ws.id, agent.id))
  if result.code ~= 0 then
    fail("could not start " .. agent.name .. ": " .. (result.stderr or ""))
  end
  -- Claude says when it is ready; Codex only opens its session on the first prompt, so wait for
  -- its composer; give the rest a moment to draw a prompt.
  if agent.kind == "codex" then
    if not codex_ready(ws, agent, 30) then
      fail(agent.name .. " did not start within 30s")
    end
  elseif not panes.reports(agent.kind) then
    vim.uv.sleep(500)
  else
    -- An ACP agent's first start on a host installs its adapter first; its supervisor ends its
    -- pane when it can't start, and says why in its journal.
    local timeout = agent.acp and 120 or 30
    local gone = false
    if not await(ws.id, agent.id, timeout, function(state)
      gone = agent.acp and not panes.running(ws.id, agent.id)
      return state ~= nil or gone
    end) then
      fail(("%s did not start within %ds"):format(agent.name, timeout))
    elseif gone and status.state(ws.id, agent.id) == nil then
      local notices = vim.tbl_filter(function(entry)
        return entry.kind == "notice"
      end, require("isovim.acp.journal").read(ws.id, agent.id))
      fail(("%s did not start: %s"):format(agent.name, notices[#notices] and notices[#notices].text or "its supervisor ended"))
    end
  end
end

-- Gives the agent text as a prompt and publishes msg.<scope>.<id> with msg ({from, kind, id, text}):
-- an ACP agent's supervisor takes it over its socket, queued while the agent works, and publishes
-- the event itself; any other agent has it typed into its pane.
---@return table? result an ACP agent's answer: {id, queued, position?}
local function prompt(ws, agent, text, msg)
  if agent.acp then
    local ok, result = require("isovim.acp").call(ws.id, agent.id, "prompt",
      { text = text, from = msg.from, kind = msg.kind, stamp = msg.id, message = msg.text, publish = true })
    if not ok then
      fail("could not reach " .. agent.name .. ": " .. tostring(result))
    end
    return result
  end
  local result = panes.send(ws.id, agent.id, text)
  if result.code ~= 0 then
    fail("could not type into " .. agent.name .. ": " .. (result.stderr or ""))
  end
  require("isovim.events").publish_msg(ws.id, agent.id, msg)
end

-- Where a new-layout agent for target goes: target is a repo key ("owner/repo", or general, or _
-- for general), or a dir, which means its repo's key, or general outside one. A dir that exists
-- wins.
---@return table ws a store.list() entry for the key, made up when it has no agents yet
---@return string? checkout the dir, when it's a clone of the repo
local function unit(target)
  if not target then
    fail("missing repo or dir\n" .. usage())
  end
  local dir = vim.fs.normalize(target)
  local key, checkout
  if vim.fn.isdirectory(dir) == 1 then
    dir = vim.uv.fs_realpath(dir) or dir
    key = require("isovim.repos").of(dir) or store.GENERAL
    checkout = key ~= store.GENERAL and dir or nil
  elseif store.v2(target) and store.valid_key(target) then
    key = store.canon(target:lower())
  else
    fail(("%s is neither a dir nor a repo (owner/repo, or general for none)"):format(target))
  end
  return vim.iter(store.list()):find(function(ws)
    return ws.id == key
  end) or { id = key, name = key, dir = store.dir(key), repo = not store.is_pseudo(key) and key or nil }, checkout
end

-- Adds an agent to ws and starts it; a new-layout one (ws a repo key) gets the next aN there.
---@return string address <ws>/<agent>
local function spawn(ws, spec)
  local agent, err = store.add_agent(ws.id, spec)
  if not agent then
    fail(err or "could not add the agent")
  end
  ensure_running(ws, agent)
  tui("require('isovim').refresh()")
  return ws.id .. "/" .. agent.id
end

local function option(args, name, default)
  for i, arg in ipairs(args) do
    if arg == name then
      table.remove(args, i)
      return table.remove(args, i) or fail(name .. " needs a value")
    end
  end
  return default
end

local function flag(args, name)
  for i, arg in ipairs(args) do
    if arg == name then
      table.remove(args, i)
      return true
    end
  end
  return false
end

-- Runs the same command on the peer and ends with its output and exit code.
local function forward(host, args)
  local result = require("isovim.remote").run(host, args)
  io.stdout:write(result.stdout or "")
  io.stderr:write(result.stderr or "")
  os.exit(result.code)
end

return {
  out = out,
  fail = fail,
  usage = usage,
  unique = unique,
  resolve = resolve,
  resolve_agent = resolve_agent,
  unit = unit,
  spawn = spawn,
  split_host = split_host,
  parent_address = parent_address,
  caller_address = caller_address,
  tui = tui,
  word = word,
  await = await,
  ensure_running = ensure_running,
  prompt = prompt,
  option = option,
  flag = flag,
  forward = forward,
}
