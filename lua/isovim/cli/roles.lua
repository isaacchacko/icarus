-- Roles on the command line: iso <role> <action> runs the action under the role the agent states,
-- and bare iso <command> is the user's. isovim checks both against who is calling, proven by
-- ancestry (root.caller) and that agent's record; for now it only warns, so agents can switch
-- before anything is refused. Also iso spawn and iso <role> promote, whose rules are enforced.
local store = require("isovim.store")
local commands = require("isovim.cli.commands")
local c = require("isovim.cli.common")

local out = c.out
local fail = c.fail
local option = c.option
local flag = c.flag

local M = {}

local RANK = commands.rank
-- Roots have no parent.
local ROOTS = { ["repo-root"] = true, root = true }

local function warn(message)
  io.stderr:write("iso: warning: " .. message .. "\n")
end

-- The agent running this and its recorded role; nil from a plain shell, another host's ssh, or a
-- terminal agent, which is the user typing.
---@return string? address, string? role, string? ws, string? agent
local function caller()
  local ws, agent = require("isovim.root").caller()
  local record = ws and store.agent(ws, agent) or { kind = "claude" }
  if ws and require("isovim.panes").reports(record.kind) then
    return ws .. "/" .. agent, store.role(record), ws, agent
  end
end

-- iso root <address>|--clear (or nothing) is still the old iso root; any other role word, and
-- root followed by one of its actions, is a namespace.
function M.namespace(command, args)
  if not RANK[command] then
    return false
  end
  return command ~= "root" or args[1] == "help" or commands.action("root", args[1]) ~= nil
end

-- Warns when the caller isn't who iso <role> <name> is for.
local function check_role(role, name)
  local address, mine = caller()
  if not address then
    local bare = commands.find(name) and (": the user runs iso " .. name) or ""
    warn(("iso %s ... is for agents, and this isn't one%s (this will be refused later)"):format(role, bare))
  elseif mine ~= role and commands.action(mine, name) then
    warn(("you are a %s, not a %s: run iso %s %s (this will be refused later)"):format(mine, role, mine, name))
  elseif mine ~= role then
    warn(("you are a %s, not a %s, and %s isn't a %s action (this will be refused later)"):format(mine, role, name, mine))
  end
end

-- Warns an agent off a bare command, which is the user's, pointing at its role form if it has one.
-- Commands agents still run until their replacement lands (no audience) are left alone.
function M.warn_bare(entry)
  local form = entry.role_form or entry.name
  local has_form = vim.iter(commands.roles):any(function(role)
    return commands.action(role, form) ~= nil
  end)
  if entry.audience == "plumbing" or not (has_form or entry.audience == "user") then
    return
  end
  local address, role = caller()
  if not address then
    return
  elseif commands.action(role, form) then
    local instead = form ~= entry.name and (", not iso " .. entry.name) or ""
    warn(("agents run iso %s %s%s; bare iso commands are the user's and will be refused to agents later"):format(role, form, instead))
  elseif entry.audience == "user" then
    warn(("iso %s is the user's; it will be refused to agents later"):format(entry.name))
  end
end

local function browser(args)
  local node = { "node", vim.fs.dirname(require("isovim.panes").bin) .. "/iso-browser.mjs" }
  local ok, _, code = os.execute(table.concat(vim.tbl_map(vim.fn.shellescape, vim.list_extend(node, args)), " "))
  os.exit(ok and 0 or code or 1)
end

-- iso <role> <action> ...: the action's own command, after the role check.
function M.run(role, args)
  local name = table.remove(args, 1)
  if not name or name == "help" then
    out(commands.role_usage(role))
    os.exit(name and 0 or 1)
  end
  local entry = commands.action(role, name)
  if not entry then
    fail(("%s isn't a %s action; iso %s help lists them"):format(name, role, role))
  end
  check_role(role, name)
  if not entry.module then
    browser(args)
  end
  require("isovim.cli." .. entry.module)[entry.name](args)
end

-- bin/iso runs iso browser itself, after asking for these warnings.
M.__warn = function(args)
  local command = table.remove(args, 1)
  if M.namespace(command or "", args) and commands.action(command, args[1]) then
    check_role(command, args[1])
  elseif commands.find(command) then
    M.warn_bare(commands.find(command))
  end
end

-- What makes two dirs the same repo: its origin's name, else the git dir its worktrees share; nil
-- outside git.
local keys = {}
local function repo_key(dir)
  if keys[dir] == nil then
    local name = require("isovim.repos").of(dir)
    if not name then
      local result = vim.system({ "git", "-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir" }, { text = true }):wait()
      local common = result.code == 0 and vim.trim(result.stdout) or nil
      name = common and "local:" .. (vim.uv.fs_realpath(common) or common)
    end
    keys[dir] = name or false
  end
  return keys[dir] or nil
end

-- A workspace's repo; a new-layout unit is named for its repo (nil for "_").
local function ws_key(ws)
  if store.v2(ws.id) then
    return ws.id ~= "_" and ws.id or nil
  end
  return repo_key(ws.dir)
end

-- A repo key as a person reads it.
local function repo_name(key)
  return (key:gsub("^local:", ""):gsub("/%.git$", ""))
end

-- Who on this host already holds role (for a repo-level role, in the repo with that key), other
-- than except.
---@return string[] addresses
local function holders(role, key, except)
  local found = {}
  for _, ws in ipairs(store.list()) do
    for _, agent in ipairs(store.agents(ws.id)) do
      local address = ws.id .. "/" .. agent.id
      if store.role(agent) == role and address ~= except and (role == "root" or ws_key(ws) == key) then
        found[#found + 1] = address
      end
    end
  end
  return found
end
M.holders = holders

-- One router per repo on a host, one repo-root per repo, one root per host. A router or repo-root
-- belongs to a repo, so it needs one.
---@param address? string the agent being promoted, which doesn't count; nil for a spawn
local function check_unique(role, key, address)
  if (role == "router" or role == "repo-root") and not key then
    fail(address and ("%s isn't in a git repo, and a %s is a repo's"):format(address, role)
      or ("a %s is a repo's: spawn it with --repo and a git repo"):format(role))
  end
  local taken = role ~= "worker" and holders(role, key, address)[1]
  if taken and role == "root" then
    fail("this host already has a root: " .. taken)
  elseif taken then
    fail(("%s already has a %s%s: %s"):format(repo_name(key), role, role == "router" and " here" or "", taken))
  end
end

-- The dir --repo names: a dir, or owner/repo for a clone some workspace here already works in.
local function repo_dir(repo)
  if vim.fn.isdirectory(vim.fs.normalize(repo)) == 1 then
    return vim.uv.fs_realpath(vim.fs.normalize(repo))
  end
  local repos = require("isovim.repos")
  local want = repos.normalize(repo) or fail(("--repo %s is neither a dir nor owner/repo"):format(repo))
  local dirs = vim.tbl_map(function(ws)
    return ws.dir
  end, store.list())
  for _, dir in ipairs(vim.list_extend(dirs, store.projects())) do
    dir = vim.fs.normalize(dir)
    if vim.fn.isdirectory(dir) == 1 and repos.of(dir) == want then
      return dir
    end
  end
  fail(("no clone of %s is known here; pass its dir as --repo"):format(want))
end

-- Types a message into the agent stamped as from `from` (<ws>/<agent> on this host), as iso msg
-- from that agent would.
local function send_as(from, ws, agent, text)
  local root = require("isovim.root")
  local from_ws, from_agent = from:match("^(.-)/(.*)$")
  local sender = root.address(from_ws, from_agent)
  local stamp = root.stamp("from", sender, root.address(ws.id, agent.id), text)
  c.ensure_running(ws, agent)
  c.prompt(ws, agent, stamp .. " " .. text, { from = sender, kind = "from", id = stamp:match("(m%x+)%]$"), text = text })
end

-- iso spawn --acp: a new-layout agent (<repo key>/aN) that runs over ACP (isovim.acp), in the
-- repo dir names, else the spawner's repo, else in no repo ("_").
local function spawn_acp(key, dir, spec)
  local agent, err = store.add_agent(key, vim.tbl_extend("force", spec, { kind = "claude", acp = true, checkout = dir }))
  if not agent then
    fail(err or "could not add the agent")
  end
  c.ensure_running(c.resolve(key), agent)
  out(key .. "/" .. agent.id)
end

-- iso spawn (the user's: no parent) and iso <role> spawn (an agent's: its child, of a role no
-- higher than its own). Today each spawn is a workspace with one claude agent, in the repo's dir;
-- with --acp, a new-layout agent over ACP.
function M.spawn(args)
  local repo = option(args, "--repo")
  local role = option(args, "--role", "worker")
  local read_only = flag(args, "--read-only")
  local acp = flag(args, "--acp")
  local name = option(args, "--name")
  local prompt = vim.trim(table.concat(args, " "))
  if not RANK[role] then
    fail("--role is one of " .. table.concat(commands.roles, ", "))
  end
  local address, mine, caller_ws = caller()
  if address and RANK[role] > RANK[mine] then
    fail(("a %s spawns roles up to its own, and %s is higher"):format(mine, role))
  end
  local dir = repo and repo_dir(repo)
  if not dir and caller_ws and not store.v2(caller_ws) and store.dir(caller_ws) ~= store.path(caller_ws) then
    dir = store.dir(caller_ws)
  end
  local key = acp and (dir and require("isovim.repos").of(dir) or (caller_ws and store.v2(caller_ws) and caller_ws) or "_")
  check_unique(role, dir and repo_key(dir) or (key ~= "_" and key or nil))
  if not name then
    name = prompt ~= "" and table.concat(vim.list_slice(vim.split(prompt, "%s+"), 1, 4), " "):sub(1, 30) or role
  end
  if acp then
    spawn_acp(key, dir, { name = name, prompt = prompt ~= "" and prompt or nil, role = role,
      parent = not ROOTS[role] and address or nil, read_only = read_only or nil })
    if read_only then
      io.stderr:write("iso: --read-only is recorded on the agent; nothing enforces it yet\n")
    end
    c.tui("require('isovim').refresh()")
    return
  end
  local id = store.create(name, dir)
  store.update_agent(id, "main", {
    prompt = prompt ~= "" and prompt or nil,
    role = role ~= "worker" and role or nil,
    parent = not ROOTS[role] and address or nil,
    read_only = read_only or nil,
  })
  local ws = c.resolve(id)
  c.ensure_running(ws, store.agent(id, "main"))
  out(id .. "/main")
  if read_only then
    io.stderr:write("iso: --read-only is recorded on the agent; nothing enforces it yet\n")
  end
  c.tui("require('isovim').refresh()")
end

-- Which promotions there are: to the role, from these roles.
local PROMOTIONS = {
  router = { worker = true },
  ["repo-root"] = { worker = true, router = true },
  root = { worker = true, router = true, ["repo-root"] = true },
}

-- The environment the finisher needs: where isovim keeps things, not who the agent is.
local AGENT_ENV = { ISOVIM_WS = true, ISOVIM_STATE = true, ISOVIM_AGENT = true, ISOVIM_ROLE = true, ISOVIM_PARENT = true,
  ISOVIM_META = true, ISOVIM_HIDDEN = true }
local function finisher_env()
  local env = {}
  for key, value in pairs(vim.fn.environ()) do
    local wanted = key:match("^ISOVIM_") or key:match("^XDG_") or key:match("^FAKE_AGENT") or key == "PATH"
      or key == "HOME" or key == "CLAUDE_CONFIG_DIR" or key == "CODEX_HOME"
    if wanted and not AGENT_ENV[key] then
      env[#env + 1] = vim.fn.shellescape(key .. "=" .. value)
    end
  end
  return table.concat(env, " ")
end

-- The restart runs on the tmux server, outside the agent: a self-promotion would otherwise kill
-- its own command along with the agent.
local function finish_later(address, promoter, reason)
  local panes = require("isovim.panes")
  local log = store.run .. "/promote.log"
  local cmd = ("env %s %s __promote-finish %s %s %s >>%s 2>&1"):format(finisher_env(), vim.fn.shellescape(panes.bin),
    vim.fn.shellescape(address), vim.fn.shellescape(promoter or "-"), vim.fn.shellescape(reason), vim.fn.shellescape(log))
  vim.fn.mkdir(store.run, "p")
  local result = vim.system({ "env", "-u", "TMUX", "tmux", "-L", panes.socket, "run-shell", "-b", cmd }, { text = true }):wait()
  if result.code ~= 0 then
    fail("could not schedule the restart: " .. (result.stderr or "") .. "; iso restart " .. address .. " does it")
  end
end

local function promoted_text(role, promoter, reason, acp)
  return ("You were promoted to %s by %s%s. %s on this conversation, with that role's prompt.")
    :format(role, promoter, reason ~= "" and (": " .. reason) or "",
      acp and "Your session was reloaded" or ("You restarted as a " .. role))
end

-- A router or repo-root made root: a fork of it (iso fork) becomes the root, and it keeps its
-- role, so the repo keeps its router or repo root with the same context. An ACP agent's fork is
-- the next aN beside it, whose supervisor forks the session (session/fork).
local function fork_root(ws, agent, promoter, reason)
  local from = store.role(agent)
  local session = store.session_id(ws.id, agent.id)
  if agent.kind ~= "claude" or not session then
    fail(("%s/%s has no Claude conversation to fork into the root"):format(ws.id, agent.id))
  end
  -- As iso fork makes it: a new workspace in the same project, or a new-layout agent's next aN.
  local id = ws.id
  if not store.v2(ws.id) then
    local dir = store.dir(ws.id)
    id = store.create(ws.name .. " root", dir ~= store.path(ws.id) and dir or nil)
    store.remove_agent(id, "main")
  end
  local fork, err = store.add_agent(id, { kind = "claude", name = not store.v2(id) and agent.name or nil, role = "root",
    acp = agent.acp, checkout = agent.checkout })
  if not fork then
    fail(err)
  end
  store.update_agent(id, fork.id, { fork_of = session })
  local events = require("isovim.events")
  events.publish_agent(id, fork.id, "promoted", { role = "root", previous = from, fork_of = ws.id .. "/" .. agent.id })
  local root_ws = c.resolve(id)
  local text = ("You are a fork of the %s %s/%s, made the root by %s%s. %s/%s stays the %s; you have no parent.")
    :format(from, ws.id, agent.id, promoter, reason ~= "" and (": " .. reason) or "", ws.id, agent.id, from)
  send_as(promoter, root_ws, store.agent(id, fork.id), text)
  c.tui("require('isovim').refresh()")
  out(("%s/%s is the root, forked from the %s %s/%s, which stays the %s"):format(id, fork.id, from, ws.id, agent.id, from))
end

-- An ACP agent's promotion: its supervisor reloads the session with the new role's prompt once
-- the running turn ends, and then gives it the promoter's message, if someone else promoted it.
-- One that isn't running gets the new prompt when it next starts, and the message then.
local function reload(ws, agent, promoter, reason)
  local acp = require("isovim.acp")
  local message
  if promoter then
    local root = require("isovim.root")
    local text = promoted_text(store.role(agent), promoter, reason, true)
    local sender = root.address(promoter:match("^(.-)/(.*)$"))
    local stamp = root.stamp("from", sender, root.address(ws.id, agent.id), text)
    message = { text = stamp .. " " .. text, from = sender, kind = "from", stamp = stamp:match("(m%x+)%]$"), message = text,
      publish = true }
  end
  if require("isovim.panes").running(ws.id, agent.id) and acp.wait_up(ws.id, agent.id, 10) then
    local ok, err = acp.call(ws.id, agent.id, "reload", { then_prompt = message })
    if not ok then
      fail(("could not reach %s/%s to reload it: %s"):format(ws.id, agent.id, tostring(err)))
    end
    return
  end
  c.ensure_running(ws, agent)
  if message then
    c.prompt(ws, agent, message.text, { from = message.from, kind = "from", id = message.stamp, text = message.message })
  end
end

-- iso <role> promote [<agent>] <role> ["reason"]: only agents promote, upward only.
function M.promote(args)
  local promoter = caller()
  if not promoter then
    fail("only agents promote agents; from a shell, iso role <agent> <role> sets a role")
  end
  local target
  if not RANK[args[1] or ""] then
    target = table.remove(args, 1)
  end
  local role = table.remove(args, 1)
  local reason = vim.trim(table.concat(args, " "))
  if not role or not RANK[role] then
    fail("usage: iso <role> promote [<agent>] router|repo-root|root [\"reason\"]")
  end
  local ws, agent = c.resolve_agent(target or promoter)
  local address = ws.id .. "/" .. agent.id
  local from = store.role(agent)
  if role == from then
    fail(("%s is already a %s"):format(address, role))
  elseif RANK[role] < RANK[from] then
    fail(("%s is a %s, and there is no demotion"):format(address, from))
  elseif not (PROMOTIONS[role] or {})[from] then
    fail(("a %s isn't promoted to %s"):format(from, role))
  elseif not require("isovim.panes").reports(agent.kind) then
    fail(("%s is a %s, and only claude and codex agents have roles"):format(address, agent.kind))
  end
  check_unique(role, ws_key(ws), address)
  if role == "root" and (from == "router" or from == "repo-root") then
    fork_root(ws, agent, promoter, reason)
    return
  end
  store.set_role(ws.id, agent.id, role)
  if ROOTS[role] then
    store.set_parent(ws.id, agent.id, nil)
  end
  c.tui("require('isovim').refresh()")
  local by_other = promoter ~= address
  if agent.acp then
    reload(ws, store.agent(ws.id, agent.id), by_other and promoter or nil, reason)
    if by_other then
      out(("%s is now a %s. Once its turn ends, isovim reloads its session with that role's prompt and tells it you promoted it")
        :format(address, role))
    else
      out(("You are now a %s. When this turn ends, isovim reloads your session with that role's prompt."):format(role))
    end
    return
  end
  finish_later(address, by_other and promoter or nil, reason)
  if by_other then
    out(("%s is now a %s. Once it isn't working, isovim restarts it on its conversation as a %s and tells it you promoted it")
      :format(address, role, role))
  else
    out(("You are now a %s. End your turn now: isovim then restarts you on this conversation as a %s, with that role's prompt.")
      :format(role, role))
  end
end

-- Runs from the tmux server: waits until the agent isn't busy, restarts it so it starts on its
-- new role's prompt, and once it's ready tells it who promoted it, if that was someone else.
M["__promote-finish"] = function(args)
  local panes = require("isovim.panes")
  local status = require("isovim.status")
  local ws, agent = c.resolve_agent(args[1] or fail("usage: iso __promote-finish <ws>/<agent> <promoter|-> [reason]"))
  local promoter = args[2] ~= "-" and args[2] or nil
  local reason = table.concat(vim.list_slice(args, 3), " ")
  local busy = { working = true, checking = true, waiting = true, attention = true }
  vim.wait(12 * 3600 * 1000, function()
    return not panes.running(ws.id, agent.id) or not busy[status.state(ws.id, agent.id) or ""]
  end, 1000)
  agent = store.agent(ws.id, agent.id) or fail(args[1] .. " is gone")
  if panes.running(ws.id, agent.id) then
    panes.stop(ws.id, agent.id)
    -- The ready its start hook writes says it's back.
    os.remove(store.state_file(ws.id, agent.id))
    if not c.tui("require('isovim').restart(...)", ws.id, agent.id) then
      c.ensure_running(ws, agent)
    end
    c.await(ws.id, agent.id, 60, function(state)
      return state ~= nil
    end)
  end
  if promoter then
    send_as(promoter, ws, agent, promoted_text(store.role(agent), promoter, reason))
  end
  out(("%s %s restarted as a %s"):format(os.date("%F %T"), args[1], store.role(agent)))
end

return M
