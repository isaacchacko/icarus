-- Commands that look without changing anything: agents, their status and screens, search, and
-- what isovim runs on.
local store = require("isovim.store")
local panes = require("isovim.panes")
local status = require("isovim.status")
local c = require("isovim.cli.common")

local out = c.out
local fail = c.fail
local resolve_agent = c.resolve_agent
local split_host = c.split_host
local word = c.word
local await = c.await
local option = c.option
local flag = c.flag
local forward = c.forward

local commands = {}

function commands.ls(args)
  local sessions = panes.sessions()
  local titles = panes.titles()
  local rows = {}
  for _, ws in ipairs(store.list()) do
    -- Its git origin ("owner/repo") and how this host draws it: {name, glyph, color}.
    local repos = require("isovim.repos")
    local repo = ws.repo and repos.style(ws.repo) or not store.v2(ws.id) and repos.for_dir(ws.dir) or nil
    for _, agent in ipairs(store.agents(ws.id)) do
      local running = sessions[ws.id] and sessions[ws.id][agent.id]
      rows[#rows + 1] = {
        id = ws.id .. "/" .. agent.id,
        workspace = ws.name,
        agent = agent.name,
        kind = agent.kind,
        -- Set on a repo script's pane (setup, run), which the sidebar lists under Terminals.
        script = require("isovim.scripts").of(agent),
        role = store.role(agent),
        hidden = agent.hidden or false,
        status = running and (status.get(ws.id, agent.id) or "idle") or "stopped",
        doing = running and panes.subtitle(agent.kind, titles[ws.id .. "/" .. agent.id]) or nil,
        -- When anything last happened in it (epoch seconds), for scripts that wait for quiet.
        active = running or nil,
        dir = store.agent_dir(ws.id, agent.id),
        repo = repo,
        read_only = agent.read_only or nil,
        parent = agent.parent,
        tasks = agent.tasks,
      }
    end
  end
  table.sort(rows, function(a, b)
    return a.workspace .. a.id < b.workspace .. b.id
  end)
  if args[1] == "--json" then
    out(vim.json.encode(rows))
    return
  end
  for _, row in ipairs(rows) do
    local label = ("%s · %s%s%s"):format(row.workspace, row.agent, row.hidden and " (hidden)" or "",
      row.parent and (" (parent " .. row.parent .. ")") or "")
    out(("%-18s %-9s %-6s %s%s"):format(row.id, row.status, row.role, label, row.doing and ("  — " .. row.doing) or ""))
  end
end

local function repo_commit()
  local result = vim.system({ "git", "-C", vim.fs.dirname(panes.bin), "rev-parse", "--short", "HEAD" }, { text = true }):wait()
  return result.code == 0 and vim.trim(result.stdout) or "unknown"
end

function commands.version()
  out(repo_commit())
end

-- What isovim needs, each with ok or what to do about it; peers must run the same isovim for moves.
function commands.doctor()
  local problems = 0
  local function check(ok, what, fix)
    out(("%s %s%s"):format(ok and "ok  " or "FAIL", what, ok and "" or ("  -> " .. fix)))
    problems = problems + (ok and 0 or 1)
  end
  local function version(cmd)
    local result = vim.system(cmd, { text = true }):wait()
    return result.code == 0 and vim.trim(result.stdout):match("[%d.]+") or nil
  end
  local tmux = version({ "tmux", "-V" })
  check(tmux and vim.version.ge(vim.version.parse(tmux, { strict = false }), "3.0"), "tmux " .. (tmux or "missing"), "install tmux 3.0 or newer")
  check(vim.fn.has("nvim-0.11") == 1, "nvim " .. tostring(vim.version()), "nvim 0.11 or newer")
  check(vim.fn.executable("jq") == 1, "jq", "install jq")
  check(vim.system({ "gh", "auth", "status" }):wait().code == 0, "gh signed in", "gh auth login")
  check(vim.fn.executable("node") == 1, "node", "put node on PATH (the language servers for files you open run on it)")
  check(vim.fn.executable("lsof") == 1, "lsof", "install lsof (the sidebar's dev server ports)")
  check(vim.fn.executable("rg") == 1, "rg", "install ripgrep (iso find searches conversations with it)")
  for _, name in ipairs({ "claude", "codex" }) do
    local path = panes.exe(name)
    check(vim.fn.executable(path) == 1, name .. " " .. path, "install " .. name .. " (agents of that kind can't start)")
  end
  local link = vim.fn.resolve(vim.fn.exepath("iso"))
  check(link == panes.bin, "iso on PATH is this repo's", "ln -s " .. panes.bin .. " ~/.local/bin/iso")
  -- A prompt file that can't be read is left out of what its role is told, silently.
  local config = require("isovim.config")
  for _, role in ipairs(store.roles) do
    local path = config.prompt_file(role)
    if path then
      check(vim.fn.filereadable(path) == 1, ("%s prompt %s"):format(role, path), "create it, or fix prompts." .. role .. " in " .. config.path)
    end
  end
  local prompts = config.get().prompts
  for role in pairs(type(prompts) == "table" and prompts or {}) do
    if not vim.tbl_contains(store.roles, role) then
      check(false, "prompts." .. role .. " is a role", "roles are " .. table.concat(store.roles, ", "))
    end
  end
  local here = repo_commit()
  out("     this isovim: " .. here)
  local remote = require("isovim.remote")
  for name, host in pairs(remote.peers()) do
    local cmd = ("%s %s %s"):format(remote.ssh, vim.fn.shellescape(host), vim.fn.shellescape(remote.remote_bin .. " version"))
    local result = vim.system({ "bash", "-c", cmd }, { text = true, timeout = 6000 }):wait()
    local theirs = result.code == 0 and vim.trim(result.stdout) or nil
    if result.code == 255 or result.signal ~= 0 then
      check(false, name .. " reachable", "it may be asleep; moves and its sidebar rows wait for it")
    elseif not theirs then
      check(false, name .. " runs an isovim with `iso version`", "update its isovim to this one's commit")
    else
      check(theirs == here, ("%s runs isovim %s"):format(name, theirs), "update one side so both run the same commit")
    end
  end
  if problems > 0 then
    os.exit(1)
  end
end

function commands.status(args)
  local host, query = split_host(args[1])
  if host then
    forward(host, { "status", query })
  end
  local ws, agent = resolve_agent(query)
  out(word(ws.id, agent.id))
end

function commands.wait(args)
  local timeout = tonumber(option(args, "--timeout", "3600"))
  local host, query = split_host(args[1])
  if host then
    forward(host, { "wait", query, "--timeout", tostring(timeout) })
  end
  local ws, agent = resolve_agent(query)
  local done = await(ws.id, agent.id, timeout, function(state)
    -- Checking and waiting agents will go on by themselves.
    return state ~= "working" and state ~= "checking" and state ~= "waiting"
  end)
  out(word(ws.id, agent.id))
  os.exit(done and 0 or 124)
end

function commands.peek(args)
  local lines = tonumber(option(args, "-n", "40"))
  local host, query = split_host(args[1])
  if host then
    forward(host, { "peek", query, "-n", tostring(lines) })
  end
  local ws, agent = resolve_agent(query)
  if not panes.running(ws.id, agent.id) then
    fail(ws.name .. " · " .. agent.name .. " is not running")
  end
  local output = vim.split(panes.capture(ws.id, agent.id, lines):gsub("%s+$", ""), "\n")
  out(table.concat(vim.list_slice(output, math.max(1, #output - lines + 1)), "\n"))
end

-- Every host's agents ranked by where the query turns up (isovim.find); --local is this host's only,
-- which is what the other hosts are asked for.
function commands.find(args)
  local json = flag(args, "--json")
  local only_here = flag(args, "--local")
  local query = table.concat(args, " ")
  if vim.trim(query) == "" then
    fail("usage: iso find <query> [--json]")
  end
  local remote = require("isovim.remote")
  local rows = {}
  local function add(host, found)
    for _, row in ipairs(found) do
      -- A peer's rows come back already addressed from there.
      if not row.host then
        row.host = host
        row.id = host .. ":" .. row.id
      end
      rows[#rows + 1] = row
    end
  end
  local jobs = {}
  if not only_here then
    for name, host in pairs(remote.peers()) do
      local cmd = vim.split(remote.ssh, " ", { trimempty = true })
      local line = remote.remote_bin .. " find --local --json " .. vim.fn.shellescape(query)
      jobs[name] = vim.system(vim.list_extend(cmd, { host, line }), { text = true, timeout = 10000 })
    end
  end
  add(remote.self(), require("isovim.find").here(query))
  for name, job in pairs(jobs) do
    local result = job:wait()
    local ok, found = pcall(vim.json.decode, result.code == 0 and result.stdout or "")
    if ok and type(found) == "table" then
      add(name, found)
    end
  end
  table.sort(rows, function(a, b)
    return a.score > b.score
  end)
  if json then
    out(vim.json.encode(rows))
    return
  end
  if #rows == 0 then
    fail("nothing found for " .. query)
  end
  for _, row in ipairs(rows) do
    local match = row.match or ""
    match = #match > 140 and (match:sub(1, 137) .. "...") or match
    local said = row.where ~= "name" and ("  — %s: %s"):format(row.where, match) or ""
    out(("%-26s %s · %s%s"):format(row.id, row.workspace, row.agent, said))
  end
end

return commands
