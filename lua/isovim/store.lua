local M = {}

M.root = vim.env.ISOVIM_HOME or vim.fs.normalize("~/.isovim")
M.workspaces = M.root .. "/workspaces"
M.archive = M.root .. "/archive"
M.run = M.root .. "/run"
M.session_file = M.root .. "/session.json"
M.lock_file = M.root .. "/isovim.lock"
-- Unix sockets cap paths near 104 bytes, so tests with a deep ISOVIM_HOME set ISOVIM_SOCK.
M.socket = vim.env.ISOVIM_SOCK or M.root .. "/nvim.sock"
-- Where agents' work lives (~/iso/<owner>/<repo>/...); pilots point it into their tmp dir.
M.work = vim.env.ISOVIM_WORK or vim.fs.normalize("~/iso")

local META = ".isovim.json"

-- The new layout (opt-in for now: iso agent --v2) keeps agents per repo under the work root instead
-- of per workspace:
--   <key>/aN/                  the agent's own dir, where it starts
--   <key>/iso/agents/aN.json   its record, outside aN/ so a dir left without one can be told apart
--   <key>/iso/next             the next N, taken under a lock: a number is never given out twice
--   <key>/iso/                 also the repo's transcripts/, layout.json and the .isovim.json
--                              holding its PRs and pins, as a workspace's own dir holds them
-- <key> is the repo as isovim.repos names it ("owner/repo"), or "_" for agents in no repo. A key
-- stands wherever a workspace id does (store.list, run dirs, tmux names), so an agent's address is
-- <key>/aN. A workspace id never holds a "/" and is never "_", so the two can't be confused.
function M.v2(id)
  return id == "_" or (type(id) == "string" and id:find("/", 1, true) ~= nil)
end

-- A key safe as a path under the work root: "_", or two or more names as repos.normalize makes them.
function M.valid_key(key)
  if key == "_" then
    return true
  end
  local parts = vim.split(key or "", "/", { plain = true })
  return #parts >= 2 and vim.iter(parts):all(function(part)
    return part:match("^[%w._-]+$") ~= nil and not part:match("^%.+$")
  end)
end

local function records(key)
  return M.work .. "/" .. key .. "/iso/agents"
end

-- Where a new-layout agent's record is; also its ISOVIM_META.
function M.record_file(key, agent)
  return records(key) .. "/" .. agent .. ".json"
end

local function read_json(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  local decoded, value = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  return decoded and type(value) == "table" and value or nil
end

-- Written to a temp file and renamed over the old one, so no reader ever sees half of it.
local function write_json(path, value)
  local tmp = ("%s.%d.tmp"):format(path, vim.uv.os_getpid())
  vim.fn.writefile({ vim.json.encode(value) }, tmp)
  assert(vim.uv.fs_rename(tmp, path))
end

function M.read_session()
  local ok, lines = pcall(vim.fn.readfile, M.session_file)
  local decoded, session = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  return decoded and type(session) == "table" and session or {}
end

function M.write_session(session)
  vim.fn.writefile({ vim.json.encode(session) }, M.session_file)
end

-- Only remove the lock if it is ours; a takeover may already have replaced it.
-- bin/iso records the TUI process, which is this Lua server's parent.
function M.release_lock()
  local ok, lines = pcall(vim.fn.readfile, M.lock_file)
  if ok and tonumber(lines[1]) == vim.uv.os_getppid() then
    vim.fn.delete(M.lock_file)
  end
end

-- Host-only runtime state for a workspace's agents: <agent>.state and <agent>.session from its hooks, <agent>.seen.
-- A repo key's "/" becomes "+" (never in a key), so every run dir sits right under run/, where the
-- sidebar watches.
function M.run_dir(id)
  return M.run .. "/" .. id:gsub("/", "+")
end

function M.state_file(ws, agent)
  return M.run_dir(ws) .. "/" .. agent .. ".state"
end

function M.seen_file(ws, agent)
  return M.run_dir(ws) .. "/" .. agent .. ".seen"
end

-- The id of the agent's conversation, so a restart resumes that one and not another agent's.
-- A new-layout agent's record keeps it too, for when the run dir is gone.
function M.session_id(ws, agent)
  local file = io.open(M.run_dir(ws) .. "/" .. agent .. ".session")
  local id = file and vim.trim(file:read("*a")) or ""
  if file then
    file:close()
  end
  if id == "" and M.v2(ws) then
    return (M.agent(ws, agent) or {}).session
  end
  return id ~= "" and id or nil
end

-- A workspace's own dir, or a repo key's iso/: where its .isovim.json, layout.json and transcripts are.
function M.path(id)
  if M.v2(id) then
    return M.work .. "/" .. id .. "/iso"
  end
  return M.workspaces .. "/" .. id
end

local function read_meta(dir)
  local ok, lines = pcall(vim.fn.readfile, dir .. "/" .. META)
  if not ok then
    return nil
  end
  local decoded, meta = pcall(vim.json.decode, table.concat(lines, "\n"))
  return decoded and meta or nil
end

local function write_meta(dir, meta)
  vim.fn.writefile({ vim.json.encode(meta) }, dir .. "/" .. META)
end

local function new_id()
  repeat
    local id = vim.uv.random(3):gsub(".", function(c)
      return string.format("%02x", c:byte())
    end)
    if not vim.uv.fs_stat(M.path(id)) then
      return id
    end
  until false
end

-- Linux filesystems may not record birthtime; fall back to the creation time we stored.
local function created_at(dir, meta)
  local stat = vim.uv.fs_stat(dir)
  local birth = stat and stat.birthtime.sec or 0
  return birth > 0 and birth or meta.created
end

-- Where a workspace's agents run and its files are: the project dir it was given (kept relative to
-- ~ so it holds on every host), or else its own dir. A project dir missing on this host falls back.
local function project_dir(id, meta)
  local dir = meta and meta.dir and vim.fs.normalize(meta.dir)
  if dir and vim.fn.isdirectory(dir) == 1 then
    return dir
  end
  return M.path(id)
end

-- A repo key's dir holds its agents' own dirs (M.agent_dir).
function M.dir(id)
  if M.v2(id) then
    return M.work .. "/" .. id
  end
  return project_dir(id, read_meta(M.path(id)))
end

function M.home_relative(path)
  local home = vim.fs.normalize("~")
  return vim.startswith(path, home .. "/") and "~" .. path:sub(#home + 1) or path
end

---@param dir? string nil or "" goes back to the workspace's own dir
function M.set_dir(id, dir)
  local path = M.path(id)
  local meta = read_meta(path) or {}
  if dir and dir ~= "" then
    meta.dir = M.home_relative((vim.fn.fnamemodify(vim.fs.normalize(dir), ":p"):gsub("/$", "")))
  else
    meta.dir = nil
  end
  write_meta(path, meta)
end

-- The repo keys under the work root that have agents. A key is a dir whose iso/agents/ holds a
-- record; nothing below one is looked in, and keys from hosts other than GitHub can be up to four
-- names long (host/group/sub/repo).
---@return string[]
local function keys()
  local found = {}
  local function walk(dir, key, depth)
    if key and vim.uv.fs_stat(dir .. "/iso/agents") then
      if M.valid_key(key) and #vim.fn.glob(records(key) .. "/a*.json", false, true) > 0 then
        found[#found + 1] = key
      end
      return
    end
    if depth == 4 then
      return
    end
    for name, kind in vim.fs.dir(dir) do
      if kind == "directory" and not vim.startswith(name, ".") then
        walk(dir .. "/" .. name, key and key .. "/" .. name or name, depth + 1)
      end
    end
  end
  walk(M.work, nil, 0)
  return found
end

---@return {id:string, name:string, dir:string, created:integer, modified:integer, repo?:string}[]
function M.list()
  local workspaces = {}
  for _, key in ipairs(keys()) do
    local stat = vim.uv.fs_stat(records(key))
    workspaces[#workspaces + 1] = {
      id = key,
      name = (read_meta(M.path(key)) or {}).name or key,
      dir = M.dir(key),
      created = created_at(M.path(key), {}) or 0,
      modified = stat and stat.mtime.sec or 0,
      repo = key ~= "_" and key or nil,
    }
  end
  for id, kind in vim.fs.dir(M.workspaces) do
    local dir = M.path(id)
    local meta = kind == "directory" and read_meta(dir)
    if meta then
      local stat = vim.uv.fs_stat(dir)
      workspaces[#workspaces + 1] = {
        id = id,
        name = meta.name,
        dir = project_dir(id, meta),
        created = created_at(dir, meta),
        modified = stat and stat.mtime.sec or 0,
      }
    end
  end
  return workspaces
end

---@param project? string the workspace's project dir (M.set_dir)
---@param worktree? boolean work in a new worktree of project (a repo) instead of project itself
---@return string? id, string? err
---@param worktree? boolean|string a worktree on a new branch, or (a string) of that branch or PR
function M.create(name, project, worktree)
  local branch, repo
  if worktree then
    local trees = require("isovim.worktree")
    local path, result
    if type(worktree) == "string" then
      path, result = trees.create_from(project, worktree)
    else
      path, result = trees.create(project, name)
    end
    if not path then
      return nil, result
    end
    repo = M.home_relative(vim.uv.fs_realpath(project) or project)
    project, branch = path, result
  end
  local id = new_id()
  local dir = M.path(id)
  vim.fn.mkdir(dir, "p")
  write_meta(dir, { name = name, created = os.time(), branch = branch, repo = repo })
  if project and project ~= "" then
    M.set_dir(id, project)
  end
  return id
end

-- Where the agent's work is, which its repo's scripts run in: a new-layout agent's worktree, <key>/aN/w
-- (iso <role> wt), else its own dir <key>/aN; any other agent's workspace's dir.
function M.work_dir(ws, agent)
  if not M.v2(ws) then
    return M.dir(ws)
  end
  local own = M.dir(ws) .. "/" .. agent
  return vim.fn.isdirectory(own .. "/w") == 1 and own .. "/w" or own
end

-- Where the agent starts: a new-layout agent in its own dir, <key>/aN, a read-only one in its repo's
-- base clone when there is one, and a script pane in the work dir of the agent it runs for (`of`);
-- any other agent in its workspace's dir.
function M.agent_dir(ws, agent)
  if not M.v2(ws) then
    return M.dir(ws)
  end
  local spec = M.agent(ws, agent) or {}
  if spec.of then
    return M.work_dir(ws, spec.of)
  end
  local base = spec.read_only and spec.repo and require("isovim.repos").dir(spec.repo) .. "/base-clone"
  if base and vim.fn.isdirectory(base) == 1 then
    return base
  end
  return M.dir(ws) .. "/" .. agent
end

function M.update_meta(id, fields)
  local meta = read_meta(M.path(id)) or {}
  for key, value in pairs(fields) do
    meta[key] = value
  end
  write_meta(M.path(id), meta)
end

-- The projects workspaces have worked in (a worktree's repo, else the project dir), most recently
-- made first, archived ones included: what a new workspace is likely to want.
---@return string[] home-relative dirs that exist here
function M.projects()
  local seen, list = {}, {}
  local metas = {}
  for _, root in ipairs({ M.workspaces, M.archive }) do
    for id, kind in vim.fs.dir(root) do
      local meta = kind == "directory" and read_meta(root .. "/" .. id)
      if meta then
        metas[#metas + 1] = meta
      end
    end
  end
  table.sort(metas, function(a, b)
    return (a.created or 0) > (b.created or 0)
  end)
  local origins = {}
  local function origin(dir)
    local ok, lines = pcall(vim.fn.readfile, vim.fs.normalize(dir) .. "/.git/config")
    local in_origin = false
    for _, line in ipairs(ok and lines or {}) do
      if line:match("^%[") then
        in_origin = line == '[remote "origin"]'
      elseif in_origin and line:match("^%s*url%s*=") then
        return vim.trim(line:match("=(.*)$"))
      end
    end
  end
  for _, meta in ipairs(metas) do
    local project = meta.repo or (not meta.branch and meta.dir) or nil
    if project and not seen[project] and vim.fn.isdirectory(vim.fs.normalize(project)) == 1 then
      seen[project] = true
      list[#list + 1] = project
      local url = origin(project)
      if url then
        origins[url] = true
      end
    end
  end
  -- Then the repos not yet used, one clone per origin, the most recently touched first, since any
  -- clone can hold new worktrees. They're looked for in ~, the usual code folders, the folders
  -- holding the projects above, and the config's repo_dirs.
  local configured = require("isovim.config").get().repo_dirs or {}
  local roots = vim.list_extend({ "~", "~/code", "~/Code", "~/src", "~/dev", "~/Developer", "~/projects", "~/Projects", "~/Programs", "~/repos", "~/git", "~/work" }, configured)
  for _, project in ipairs(list) do
    roots[#roots + 1] = vim.fs.dirname(vim.fs.normalize(project))
  end
  local clones, scanned = {}, {}
  for _, root in ipairs(roots) do
    root = vim.fs.normalize(root)
    if not scanned[root] then
      scanned[root] = true
      for name, kind in vim.fs.dir(root) do
        local dir = root .. "/" .. name
        if kind == "directory" and not vim.startswith(name, ".") and vim.fn.isdirectory(dir .. "/.git") == 1 then
          -- Touched: checked out (HEAD) or committed to and staged in (index).
          local at = 0
          for _, file in ipairs({ "HEAD", "index" }) do
            local stat = vim.uv.fs_stat(dir .. "/.git/" .. file)
            at = math.max(at, stat and stat.mtime.sec or 0)
          end
          clones[#clones + 1] = { dir = M.home_relative(dir), at = at }
        end
      end
    end
  end
  table.sort(clones, function(a, b)
    return a.at > b.at
  end)
  for _, clone in ipairs(clones) do
    local url = origin(clone.dir)
    if not seen[clone.dir] and not (url and origins[url]) then
      seen[clone.dir] = true
      if url then
        origins[url] = true
      end
      list[#list + 1] = clone.dir
    end
  end
  return list
end

-- Archived workspaces, newest first.
---@return {id: string, name: string, archived: integer}[]
function M.archived()
  local list = {}
  for id, kind in vim.fs.dir(M.archive) do
    local meta = kind == "directory" and read_meta(M.archive .. "/" .. id)
    if meta then
      local stat = vim.uv.fs_stat(M.archive .. "/" .. id)
      list[#list + 1] = { id = id, name = meta.name or id, archived = stat and stat.ctime.sec or 0 }
    end
  end
  table.sort(list, function(a, b)
    return a.archived > b.archived
  end)
  return list
end

-- Brings an archived workspace back; one made with a worktree gets one again on its branch.
---@return boolean? ok, string? err
function M.unarchive(id)
  if vim.uv.fs_stat(M.path(id)) then
    return nil, "workspace " .. id .. " is already here"
  end
  local ok, err = vim.uv.fs_rename(M.archive .. "/" .. id, M.path(id))
  if not ok then
    return nil, err
  end
  for _, file in ipairs(vim.fn.glob(M.path(id) .. "/.sessions/*.session", false, true)) do
    vim.fn.mkdir(M.run_dir(id), "p")
    vim.uv.fs_rename(file, M.run_dir(id) .. "/" .. vim.fs.basename(file))
  end
  vim.fn.delete(M.path(id) .. "/.sessions", "d")
  local meta = read_meta(M.path(id)) or {}
  if meta.branch and meta.repo and M.dir(id) == M.path(id) then
    local path, why = require("isovim.worktree").checkout(vim.fs.normalize(meta.repo), meta.branch)
    if not path then
      return true, "back, but without its worktree: " .. why
    end
    M.set_dir(id, path)
    -- A fresh checkout: the repo's setup script runs again, as for a new worktree.
    require("isovim.scripts").start(id, "setup")
  end
  return true
end

-- The branch of the worktree the workspace was made with, if any.
function M.branch(id)
  return (read_meta(M.path(id)) or {}).branch
end

function M.name(id)
  local meta = read_meta(M.path(id)) or {}
  return meta.name or id
end

function M.rename(id, name)
  local dir = M.path(id)
  local meta = read_meta(dir) or {}
  meta.name = name
  write_meta(dir, meta)
end

---@class isovim.Agent
---@field id string unique within its workspace
---@field name string
---@field kind "claude"|"codex"|"shell"|"command"
---@field cmd? string what a "command" agent runs
---@field hidden? boolean left out of the sidebar and never notifies
---@field role? "root"|"repo-root"|"router"|"worker" which role prompt it gets at launch; unset is a worker
---@field parent? string the agent that started it: <ws>/<agent> here, <host>:<ws>/<agent> on another host
---@field read_only? boolean a new-layout agent that works in its repo's base clone; on a workspace's
--- agent, iso spawn --read-only records it and nothing enforces it yet
---@field repo? string a new-layout agent's repo key; nil in "_"
---@field created? integer when a new-layout agent was made
---@field session? string a new-layout agent's conversation id, as also kept in its run dir
---@field script? string on a "command" pane isovim runs a repo script or action in: its name ("setup",
--- "run", "lint"), which lists it under Terminals with the robot
---@field of? string a new-layout script pane's agent: the aN whose work dir it runs in
---@field checkout? string the clone a new-layout agent was made from, for its repo's base clone
---@field branch? string a new-layout agent's worktree branch (iso <role> wt)

-- The root sets the north star, a repo-root holds one repo's, the router is a repo's one interface
-- to the user, workers do the work.
M.roles = { "root", "repo-root", "router", "worker" }

---@param agent isovim.Agent
function M.role(agent)
  return agent.role or "worker"
end

-- A workspace without an agent list has just its main agent.
local DEFAULT_AGENTS = { { id = "main", name = "main", kind = "claude" } }

local function number(id)
  return tonumber((id or ""):match("^a(%d+)$"))
end

-- A repo key's agents, in the order they were made.
---@return isovim.Agent[]
local function records_of(key)
  local list = {}
  for _, path in ipairs(vim.fn.glob(records(key) .. "/a*.json", false, true)) do
    local record = number(vim.fs.basename(path):sub(1, -6)) and read_json(path)
    if record and record.id then
      list[#list + 1] = record
    end
  end
  table.sort(list, function(a, b)
    return (number(a.id) or 0) < (number(b.id) or 0)
  end)
  return list
end

---@return isovim.Agent[]
function M.agents(ws)
  if M.v2(ws) then
    return records_of(ws)
  end
  local meta = read_meta(M.path(ws)) or {}
  return meta.agents or vim.deepcopy(DEFAULT_AGENTS)
end

---@return isovim.Agent?
function M.agent(ws, id)
  if M.v2(ws) then
    return number(id) and read_json(M.record_file(ws, id)) or nil
  end
  for _, agent in ipairs(M.agents(ws)) do
    if agent.id == id then
      return agent
    end
  end
end

local function has_agent(agents, id)
  return vim.iter(agents):any(function(agent)
    return agent.id == id
  end)
end

-- The next N for a repo key, under a lock (a dir, which only one process can make): one past the
-- counter, and past every aN dir and record there, so a number is never given out again even if
-- the counter file goes. aN/ is made before the lock is let go.
---@return integer? n, string? err
local function take_number(key)
  local iso = M.path(key)
  vim.fn.mkdir(records(key), "p")
  local lock = iso .. "/next.lock"
  local deadline = vim.uv.hrtime() + 5e9
  while not vim.uv.fs_mkdir(lock, 448) do
    local stat = vim.uv.fs_stat(lock)
    -- A holder that died: taking a number takes milliseconds.
    if stat and os.time() - stat.mtime.sec > 30 then
      vim.uv.fs_rmdir(lock)
    elseif vim.uv.hrtime() > deadline then
      return nil, "could not take the next agent number in " .. key .. ": " .. lock .. " is held"
    else
      vim.uv.sleep(20)
    end
  end
  local ok, lines = pcall(vim.fn.readfile, iso .. "/next")
  local n = ok and tonumber(lines[1]) or 0
  for _, dir in ipairs({ M.dir(key), records(key) }) do
    for name in vim.fs.dir(dir) do
      local taken = number((name:gsub("%.json$", "")))
      n = taken and math.max(n, taken + 1) or n
    end
  end
  vim.fn.writefile({ tostring(n + 1) }, iso .. "/next.tmp")
  vim.uv.fs_rename(iso .. "/next.tmp", iso .. "/next")
  vim.fn.mkdir(M.dir(key) .. "/a" .. n, "p")
  vim.uv.fs_rmdir(lock)
  return n
end

-- A new-layout agent: aN/ and its record. Its name is the one given, else its id.
---@return isovim.Agent? agent, string? err
local function add_record(key, spec)
  local n, err = take_number(key)
  if not n then
    return nil, err
  end
  local id = "a" .. n
  local record = { id = id, name = spec.name or id, kind = spec.kind, role = spec.role or "worker", parent = spec.parent,
    read_only = spec.read_only or false, repo = key ~= "_" and key or nil, created = os.time(), cmd = spec.cmd,
    hidden = spec.hidden or nil, prompt = spec.prompt, checkout = spec.checkout, script = spec.script, of = spec.of }
  write_json(M.record_file(key, id), record)
  return record
end

-- Ids come from the name or kind, numbered when taken: codex, codex2, ...; in a repo key, a0, a1, ...
-- A pane a repo script runs in (isovim.scripts) has its script, and in a repo key the agent it runs
-- for as `of`; checkout is the clone a new-layout agent was made from, which a base clone can be
-- made from (isovim.repoconf.base).
---@param spec {kind: string, name?: string, cmd?: string, hidden?: boolean, prompt?: string, role?: string, parent?: string, read_only?: boolean, checkout?: string, script?: string, of?: string}
---@return isovim.Agent? agent, string? err nil only for a repo key
function M.add_agent(ws, spec)
  if M.v2(ws) then
    return add_record(ws, spec)
  end
  local dir = M.path(ws)
  local meta = read_meta(dir) or {}
  local agents = meta.agents or vim.deepcopy(DEFAULT_AGENTS)
  local base = (spec.name or spec.kind):lower():gsub("[^%w]+", "-")
  local id, n = base, 1
  while has_agent(agents, id) do
    n = n + 1
    id = base .. n
  end
  local agent = { id = id, name = spec.name or id, kind = spec.kind, cmd = spec.cmd, hidden = spec.hidden or nil, prompt = spec.prompt,
    parent = spec.parent, script = spec.script }
  agent.role = spec.role ~= "worker" and spec.role or nil
  agents[#agents + 1] = agent
  meta.agents = agents
  write_meta(dir, meta)
  return agent
end

---@class isovim.Task
---@field id string
---@field title string
---@field status "todo"|"doing"|"waiting"|"blocked"|"done"
---@field parent? string id of the task it belongs under
---@field detail? string
---@field prs? integer[]
---@field linear? string[]

M.task_statuses = { todo = true, doing = true, waiting = true, blocked = true, done = true }

-- An agent's tasks, in the order it first set them; kept in its own entry, which only it writes.
---@return isovim.Task[]
function M.tasks(ws, agent)
  local spec = M.agent(ws, agent)
  return spec and spec.tasks or {}
end

-- Calls fn with the agent's entry from the workspace's agent list (written out first if the
-- workspace still has just the default agent), or with its record, then saves.
local function with_agent(ws, agent, fn)
  if M.v2(ws) then
    local record = M.agent(ws, agent)
    if record then
      fn(record)
      write_json(M.record_file(ws, agent), record)
    end
    return
  end
  local dir = M.path(ws)
  local meta = read_meta(dir) or {}
  meta.agents = meta.agents or vim.deepcopy(DEFAULT_AGENTS)
  for _, entry in ipairs(meta.agents) do
    if entry.id == agent then
      fn(entry)
    end
  end
  write_meta(dir, meta)
end

-- Adds a task or updates one; fields left nil keep their value.
---@param task isovim.Task
function M.set_task(ws, agent, task)
  with_agent(ws, agent, function(entry)
    entry.tasks = entry.tasks or {}
    for _, existing in ipairs(entry.tasks) do
      if existing.id == task.id then
        for key, value in pairs(task) do
          existing[key] = value
        end
        return
      end
    end
    table.insert(entry.tasks, task)
  end)
end

-- Removes a task and everything under it.
function M.remove_task(ws, agent, id)
  with_agent(ws, agent, function(entry)
    local gone, grew = { [id] = true }, true
    while grew do
      grew = false
      for _, task in ipairs(entry.tasks or {}) do
        if task.parent and gone[task.parent] and not gone[task.id] then
          gone[task.id], grew = true, true
        end
      end
    end
    entry.tasks = vim.tbl_filter(function(task)
      return not gone[task.id]
    end, entry.tasks or {})
    if #entry.tasks == 0 then
      entry.tasks = nil
    end
  end)
end

function M.update_agent(ws, id, fields)
  with_agent(ws, id, function(agent)
    for key, value in pairs(fields) do
      agent[key] = value
    end
  end)
end

-- The agents ws/agent started, across this host's workspaces, as <ws>/<agent>.
---@return string[]
function M.children(ws, agent)
  local found = {}
  for _, workspace in ipairs(M.list()) do
    for _, child in ipairs(M.agents(workspace.id)) do
      if child.parent == ws .. "/" .. agent then
        found[#found + 1] = workspace.id .. "/" .. child.id
      end
    end
  end
  return found
end

-- An agent going away hands its children to its own parent; with none, they become top-level.
-- With no agent, every agent of the workspace goes.
function M.reparent(ws, agent)
  local leaving = agent and { agent } or vim.tbl_map(function(entry)
    return entry.id
  end, M.agents(ws))
  for _, id in ipairs(leaving) do
    -- Read again each time: handing down the previous one may have changed this one's parent.
    local gone = M.agent(ws, id) or {}
    for _, workspace in ipairs(M.list()) do
      for _, child in ipairs(M.agents(workspace.id)) do
        if child.parent == ws .. "/" .. id then
          with_agent(workspace.id, child.id, function(entry)
            entry.parent = gone.parent
          end)
        end
      end
    end
  end
end

-- A new-layout agent loses its record; its dir stays for now (nothing tears it down yet).
function M.remove_agent(ws, id)
  M.reparent(ws, id)
  if M.v2(ws) then
    os.remove(M.record_file(ws, id))
  else
    local dir = M.path(ws)
    local meta = read_meta(dir) or {}
    meta.agents = vim.tbl_filter(function(agent)
      return agent.id ~= id
    end, meta.agents or vim.deepcopy(DEFAULT_AGENTS))
    write_meta(dir, meta)
  end
  vim.fn.delete(M.state_file(ws, id))
  vim.fn.delete(M.seen_file(ws, id))
  vim.fn.delete(M.run_dir(ws) .. "/" .. id .. ".session")
end

function M.set_hidden(ws, id, hidden)
  with_agent(ws, id, function(agent)
    agent.hidden = hidden or nil
  end)
end

function M.set_role(ws, id, role)
  local previous
  with_agent(ws, id, function(entry)
    previous = M.role(entry)
    entry.role = (role ~= "worker" or M.v2(ws)) and role or nil
  end)
  if previous and previous ~= role then
    local events = require("isovim.events")
    events.publish_agent(ws, id, "promoted", { role = role, previous = previous })
  end
end

-- nil makes it top-level: roots have no parent.
function M.set_parent(ws, id, parent)
  with_agent(ws, id, function(entry)
    entry.parent = parent
  end)
end

-- PR URLs the workspace's agents registered with `iso pr`, oldest first.
---@return string[]
function M.prs(ws)
  return (read_meta(M.path(ws)) or {}).prs or {}
end

-- Files and folders an agent pinned for you (`iso pin`), shown under the workspace.
-- Kept relative to ~, like the project dir, so they mean the same on every host.
---@return {path: string, label?: string, auto?: boolean}[]
function M.pinned(ws)
  return vim.tbl_map(function(entry)
    return { path = vim.fs.normalize(entry.path), label = entry.label, auto = entry.auto }
  end, (read_meta(M.path(ws)) or {}).pinned or {})
end

-- auto: found in an answer by autopin rather than pinned by the agent itself.
function M.pin(ws, path, label, auto)
  local dir = M.path(ws)
  local meta = read_meta(dir) or {}
  local short = vim.fn.fnamemodify(path, ":~")
  meta.pinned = vim.tbl_filter(function(entry)
    return entry.path ~= short
  end, meta.pinned or {})
  table.insert(meta.pinned, { path = short, label = label, auto = auto or nil })
  write_meta(dir, meta)
end

-- Keeps only the newest `keep` auto entries; ones agents pinned themselves always stay.
function M.trim_auto(ws, keep)
  local dir = M.path(ws)
  local meta = read_meta(dir) or {}
  local autos = 0
  for _, entry in ipairs(meta.pinned or {}) do
    autos = autos + (entry.auto and 1 or 0)
  end
  if autos <= keep then
    return
  end
  local drop = autos - keep
  meta.pinned = vim.tbl_filter(function(entry)
    if entry.auto and drop > 0 then
      drop = drop - 1
      return false
    end
    return true
  end, meta.pinned)
  write_meta(dir, meta)
end

function M.unpin(ws, path)
  local dir = M.path(ws)
  local meta = read_meta(dir) or {}
  local short = vim.fn.fnamemodify(path, ":~")
  meta.pinned = vim.tbl_filter(function(entry)
    return entry.path ~= short
  end, meta.pinned or {})
  write_meta(dir, meta)
end

---@return boolean added false when it was already there
function M.add_pr(ws, url)
  local dir = M.path(ws)
  local meta = read_meta(dir) or {}
  meta.prs = meta.prs or {}
  if vim.tbl_contains(meta.prs, url) then
    return false
  end
  meta.prs[#meta.prs + 1] = url
  write_meta(dir, meta)
  return true
end

-- Host-only content goes; what a handoff would carry stays, moved to the archive.
-- Its worktree goes too, unless it holds uncommitted work; the note says what was kept.
---@return boolean? ok, string? err, string? note
function M.archive_workspace(id)
  if M.v2(id) then
    return nil, id .. " is a repo, not a workspace: remove its agents one by one"
  end
  local dir = M.path(id)
  local note
  local project = M.dir(id)
  if M.branch(id) and project ~= M.path(id) then
    local worktree = require("isovim.worktree")
    -- The repo's teardown script first (e.g. its dev stack).
    local teardown = require("isovim.scripts").line(project, worktree.repo_of(project) or project, M.name(id), "teardown")
    if teardown then
      vim.system({ "sh", "-c", teardown }, { cwd = project }):wait(120000)
    end
    local removed, why = worktree.remove(project)
    if not removed then
      note = ("kept its worktree %s: %s"):format(M.home_relative(project), why)
    end
  end
  for name, kind in vim.fs.dir(dir) do
    if kind == "directory" and name:match("^w%d+%-") then
      vim.fn.delete(dir .. "/" .. name, "rf")
    end
  end
  -- The agents' session ids go along, so unarchived agents resume their conversations.
  for _, file in ipairs(vim.fn.glob(M.run_dir(id) .. "/*.session", false, true)) do
    vim.fn.mkdir(dir .. "/.sessions", "p")
    vim.uv.fs_rename(file, dir .. "/.sessions/" .. vim.fs.basename(file))
  end
  vim.fn.delete(M.run_dir(id), "rf")
  vim.fn.mkdir(M.archive, "p")
  local ok, err = vim.uv.fs_rename(dir, M.archive .. "/" .. id)
  return ok, err, note
end

return M
