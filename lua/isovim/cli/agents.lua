-- Commands that add, start, stop and change one agent, and an agent's own task list.
local store = require("isovim.store")
local panes = require("isovim.panes")
local status = require("isovim.status")
local c = require("isovim.cli.common")

local out = c.out
local fail = c.fail
local resolve = c.resolve
local resolve_agent = c.resolve_agent
local unit = c.unit
local spawn = c.spawn
local parent_address = c.parent_address
local caller_address = c.caller_address
local tui = c.tui
local word = c.word
local ensure_running = c.ensure_running
local option = c.option
local flag = c.flag

local commands = {}

-- An ACP agent's chat in a minimal nvim (isovim.acp.attach); any other agent's tmux pane.
local function attach(ws, agent)
  local argv = agent.acp and require("isovim.acp.attach").cmd(ws.id, agent.id) or panes.attach_cmd(ws.id, agent.id)
  local cmd = table.concat(vim.tbl_map(vim.fn.shellescape, argv), " ")
  os.execute(cmd)
  status.mark_seen(ws.id, agent.id)
end

function commands.attach(args)
  local ws, agent = resolve_agent(args[1])
  ensure_running(ws, agent)
  attach(ws, agent)
end

-- iso handover: the ACP session closes and your claude runs on it in the agent's pane (claude
-- --resume), attached to this terminal; the session reopens when Claude exits, which detaches you.
function commands.handover(args)
  local stay = flag(args, "--no-attach")
  local ws, agent = resolve_agent(args[1])
  if not agent.acp then
    fail(agent.name .. " isn't an ACP agent: attach to it (iso attach) to use Claude's screen")
  end
  ensure_running(ws, agent)
  local acp = require("isovim.acp")
  -- One just started opens its session first.
  vim.wait(30000, function()
    local up, state = acp.call(ws.id, agent.id, "status")
    return up and (state.ready or state.handover)
  end, 200)
  local ok, result = acp.call(ws.id, agent.id, "handover")
  if not ok then
    fail(("could not hand %s over: %s"):format(agent.name, tostring(result):gsub("^.-: ", "")))
  elseif not result.started then
    fail("could not run claude in " .. agent.name .. "'s pane (its chat says why)")
  end
  out(("%s: claude --resume %s runs in its pane; the ACP session comes back when it exits"):format(agent.name, result.session))
  if not stay and vim.uv.guess_handle(1) == "tty" then
    os.execute(table.concat(vim.tbl_map(vim.fn.shellescape, panes.attach_cmd(ws.id, agent.id)), " "))
  end
end

local PHONE_ORDER = { attention = 1, unread = 2, working = 3, idle = 4, stopped = 5 }
local PHONE_MARK = {
  attention = "\27[33m●\27[0m",
  unread = "\27[32m●\27[0m",
  working = "\27[34m…\27[0m",
  idle = " ",
  stopped = "\27[2m·\27[0m",
}

-- A list narrow enough for a phone: what needs you first, then the rest; a number attaches,
-- detaching (C-b d) comes back here.
function commands.phone()
  while true do
    local titles = panes.titles()
    local rows = {}
    for _, ws in ipairs(store.list()) do
      for _, agent in ipairs(store.agents(ws.id)) do
        if not agent.hidden then
          local state = word(ws.id, agent.id)
          local doing = state ~= "stopped" and panes.subtitle(agent.kind, titles[ws.id .. "/" .. agent.id])
          local label = ws.name .. " · " .. agent.name .. (doing and ("  \27[2m" .. doing .. "\27[0m") or "")
          rows[#rows + 1] = { ws = ws, agent = agent, state = state, label = label }
        end
      end
    end
    -- The other hosts' agents too: a phone usually reaches the always-on host and hops from there.
    local remote = require("isovim.remote")
    for name, list in pairs(remote.list_all_now(4000)) do
      for _, r in ipairs(list) do
        if not r.hidden then
          local label = name .. ":" .. r.workspace .. " · " .. r.agent .. (r.doing and ("  \27[2m" .. r.doing .. "\27[0m") or "")
          rows[#rows + 1] = { host = remote.peers()[name], id = r.id, state = r.status, label = label }
        end
      end
    end
    table.sort(rows, function(a, b)
      if PHONE_ORDER[a.state] ~= PHONE_ORDER[b.state] then
        return PHONE_ORDER[a.state] < PHONE_ORDER[b.state]
      end
      return a.label < b.label
    end)
    io.write("\27[2J\27[H\27[1misovim\27[0m\n")
    for i, row in ipairs(rows) do
      io.write(("%2d %s %s\n"):format(i, PHONE_MARK[row.state], row.label))
    end
    io.write("\n# attach · ⏎ refresh · q quit\n(C-b d, or :qa in a chat, comes back here)\n> ")
    io.flush()
    local line = io.read("*l")
    if not line or line == "q" then
      return
    end
    local row = rows[tonumber(line)]
    if row and row.host then
      os.execute(require("isovim.remote").attach_cmd(row.host, row.id))
    elseif row then
      ensure_running(row.ws, row.agent)
      attach(row.ws, row.agent)
    end
  end
end

-- With --v2 (or a repo key that already has agents) the agent is a new-layout one: <key>/aN in
-- ~/iso/<key>/, for the repo of a dir or a repo named as owner/repo, or in _ outside any repo.
function commands.agent(args)
  local name = option(args, "--name")
  local cmd = option(args, "--cmd")
  local prompt = option(args, "--prompt")
  local hidden = flag(args, "--hidden")
  local role = option(args, "--role")
  local parent = option(args, "--parent")
  local v2 = flag(args, "--v2")
  local read_only = flag(args, "--read-only")
  local ws, checkout
  if v2 then
    ws, checkout = unit(args[1])
  else
    ws = resolve(args[1])
  end
  local kind = args[2]
  if not vim.tbl_contains(panes.kinds, kind) then
    fail("usage: iso agent <ws> <" .. table.concat(panes.kinds, "|") .. "> [--name n] [--hidden] [--cmd c] [--prompt text] [--role r] [--parent agent] [--v2 [--read-only]]")
  end
  if read_only and not store.v2(ws.id) then
    fail("--read-only is for a new-layout agent: add --v2")
  end
  if kind == "command" and not cmd then
    fail("a command agent needs --cmd")
  end
  if role and not vim.tbl_contains(store.roles, role) then
    fail("--role is one of " .. table.concat(store.roles, ", "))
  end
  parent = parent and parent_address(parent) or caller_address()
  out(spawn(ws, { kind = kind, name = name, cmd = cmd, hidden = hidden, prompt = prompt, role = role, parent = parent,
    read_only = read_only or nil, checkout = checkout }))
end

-- The role picks the prompt an agent is told at launch, so a change reaches it only when it restarts.
function commands.role(args)
  local ws, agent = resolve_agent(args[1])
  local address = ws.id .. "/" .. agent.id
  local role = args[2]
  if not role then
    out(store.role(agent))
    return
  elseif not vim.tbl_contains(store.roles, role) then
    fail("usage: iso role <agent> [" .. table.concat(store.roles, "|") .. "]")
  elseif role == store.role(agent) then
    out(("%s is already a %s"):format(address, role))
    return
  end
  require("isovim.cli.roles").check_unique(ws, role, address)
  store.set_role(ws.id, agent.id, role)
  tui("require('isovim').refresh()")
  out(("%s is now a %s; it takes effect when it next restarts (iso restart %s)"):format(address, role, address))
end

function commands.rm(args)
  local ws, agent = resolve_agent(args[1], true)
  if not tui("require('isovim').remove_agent(...)", ws.id, agent.id) then
    panes.stop(ws.id, agent.id)
    store.remove_agent(ws.id, agent.id)
  end
  -- A root's waiting questions go on to the next root, or to you.
  for _, moved in ipairs(require("isovim.cli.rootmode").reroute(ws.id .. "/" .. agent.id)) do
    out(("%s/%s goes to %s"):format(moved.entry.repo, moved.entry.name, moved.to or "the user"))
  end
end

local function set_hidden(args, hidden)
  local ws, agent = resolve_agent(args[1])
  store.set_hidden(ws.id, agent.id, hidden)
  tui("require('isovim').refresh()")
end

function commands.hide(args)
  set_hidden(args, true)
end

function commands.unhide(args)
  set_hidden(args, false)
end

function commands.open(args)
  local ws, agent = resolve_agent(args[1])
  if not tui("require('isovim').open(...)", ws.id, agent.id) then
    ensure_running(ws, agent)
  end
end

function commands.restart(args)
  local ws, agent = resolve_agent(args[1], true)
  -- A running agent stays as it is while its kind isn't logged in: restarted, it couldn't work.
  local blocked = panes.running(ws.id, agent.id) and require("isovim.auth").restart_blocked(agent)
  if blocked then
    fail(("%s/%s keeps running, not restarted: %s"):format(ws.id, agent.id, blocked))
  end
  if not tui("require('isovim').restart(...)", ws.id, agent.id) then
    panes.stop(ws.id, agent.id)
    ensure_running(ws, agent)
  end
end

-- A tangent: a new workspace whose agent starts from a copy of <agent>'s conversation (default: the
-- agent running this), in the same project dir. It shows in the sidebar but nothing opens it, so
-- your focus stays put; it reports back with iso msg parent.
-- An ACP agent's fork is an ACP agent in the same repo whose supervisor forks the session on its
-- first start (isovim.acp.host), at the message --at names (a seq in its journal, as the chat's
-- <leader>if passes it) or whole; its chat starts with the history up to there.
local function fork_acp(ws, agent, name, prompt, at, caller)
  local session = store.session_id(ws.id, agent.id) or fail(("%s has no session to fork yet"):format(agent.name))
  local from = ws.id .. "/" .. agent.id
  local fields = { fork_of = session, fork_from = from }
  if at then
    local seq = tonumber(at) or fail("--at takes a seq in the agent's journal")
    local acp_sessions = require("isovim.acp.sessions")
    local cut = acp_sessions.cut(require("isovim.acp.journal").read(ws.id, agent.id), seq, "at")
    fields.fork_seq, fields.fork_at = cut.upto, cut.messageId
  end
  local fork, err = store.add_agent(ws.id, { kind = agent.kind, name = name, prompt = prompt, acp = true,
    parent = caller or from, read_only = agent.read_only or nil, checkout = agent.checkout })
  if not fork then
    fail(err)
  end
  store.update_agent(ws.id, fork.id, fields)
  ensure_running(ws, store.agent(ws.id, fork.id))
  out(ws.id .. "/" .. fork.id)
  tui("require('isovim').refresh()")
end

function commands.fork(args)
  local name = option(args, "--name")
  local prompt = option(args, "--prompt")
  local at = option(args, "--at")
  local caller = caller_address()
  local ws, agent = resolve_agent(args[1] or caller or fail("iso fork needs an <agent> outside an isovim agent"))
  if agent.acp then
    return fork_acp(ws, agent, name, prompt, at, caller)
  elseif at then
    fail("--at forks an ACP agent at a message; " .. agent.name .. " runs in Claude's TUI")
  elseif not store.v2(ws.id) and require("isovim.config").enforced() then
    fail("a workspace's fork was retired at the cutover: fork a new-layout agent (iso fork <owner>/<repo>/aN), its next aN")
  end
  local session = store.session_id(ws.id, agent.id)
  if agent.kind ~= "claude" or not session then
    fail(("%s · %s has no Claude conversation to fork"):format(ws.name, agent.name))
  end
  -- A new-layout agent's tangent is the next aN of its repo key.
  local tangent = ws.id
  if not store.v2(ws.id) then
    local dir = store.dir(ws.id)
    tangent = store.create(name or (ws.name .. " tangent"), dir ~= store.path(ws.id) and dir or nil)
    store.remove_agent(tangent, "main")
  end
  local fork, err = store.add_agent(tangent, { kind = "claude", name = store.v2(tangent) and name or agent.name, prompt = prompt })
  if not fork then
    fail(err)
  end
  store.update_agent(tangent, fork.id, { fork_of = session, parent = caller or (ws.id .. "/" .. agent.id) })
  fork = store.agent(tangent, fork.id)
  local result = panes.start(tangent, fork, store.agent_dir(tangent, fork.id))
  if result.code ~= 0 then
    fail("could not start the fork: " .. (result.stderr or ""))
  end
  out(tangent .. "/" .. fork.id)
  tui("require('isovim').refresh()")
end

-- An agent's own task list, shown under its row in the sidebar (T). It only ever writes the tasks
-- of the agent it runs inside, as proven by ancestry, whatever its environment says.
function commands.task(args)
  local sub = table.remove(args, 1)
  local ws, agent = require("isovim.root").caller()
  if not ws then
    fail("iso task runs inside an agent: it keeps that agent's own tasks")
  end
  local tasks = store.tasks(ws, agent)
  local function find(id)
    return vim.iter(tasks):find(function(task)
      return task.id == id
    end)
  end
  if sub == "set" then
    local status = option(args, "--status")
    local parent = option(args, "--parent")
    local detail = option(args, "--detail")
    local pr = option(args, "--pr")
    local linear = option(args, "--linear")
    local id = table.remove(args, 1) or fail("usage: iso task set <id> [<title>] [--status ...]")
    local title = #args > 0 and table.concat(args, " ") or nil
    local existing = find(id)
    if not existing and not title then
      fail("a new task needs a title: iso task set " .. id .. " \"<title>\"")
    elseif status and not store.task_statuses[status] then
      fail("status is one of todo, doing, waiting, blocked, done")
    elseif parent and (parent == id or not find(parent)) then
      fail("no task " .. tostring(parent) .. " to put it under")
    end
    local function add(list, value)
      list = vim.deepcopy(list or {})
      if value and not vim.tbl_contains(list, value) then
        list[#list + 1] = value
      end
      return #list > 0 and list or nil
    end
    store.set_task(ws, agent, {
      id = id,
      title = title,
      status = status or (existing and existing.status) or "todo",
      parent = parent,
      detail = detail,
      prs = pr and add(existing and existing.prs, tonumber(pr:match("%d+"))) or nil,
      linear = linear and add(existing and existing.linear, linear) or nil,
    })
  elseif sub == "rm" then
    local id = args[1] or fail("usage: iso task rm <id>")
    if not find(id) then
      fail("no task " .. id)
    end
    store.remove_task(ws, agent, id)
  elseif sub == "ls" then
    local function show(parent, depth)
      for _, task in ipairs(tasks) do
        if task.parent == parent then
          out(("%s%-8s %s  %s"):format(("  "):rep(depth), task.status, task.id, task.title))
          show(task.id, depth + 1)
        end
      end
    end
    show(nil, 0)
    return
  else
    fail("usage: iso task set|rm|ls")
  end
  tui("require('isovim').refresh()")
end

return commands
