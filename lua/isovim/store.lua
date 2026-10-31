local M = {}

M.root = vim.env.ISOVIM_HOME or vim.fs.normalize("~/.isovim")
M.workspaces = M.root .. "/workspaces"
M.archive = M.root .. "/archive"
M.run = M.root .. "/run"
M.session_file = M.root .. "/session.json"
M.lock_file = M.root .. "/isovim.lock"
-- Unix sockets cap paths near 104 bytes, so tests with a deep ISOVIM_HOME set ISOVIM_SOCK.
M.socket = vim.env.ISOVIM_SOCK or M.root .. "/nvim.sock"

local META = ".isovim.json"

function M.read_session()
  local ok, lines = pcall(vim.fn.readfile, M.session_file)
  local decoded, session = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  return decoded and type(session) == "table" and session or {}
end

function M.write_session(session)
  vim.fn.writefile({ vim.json.encode(session) }, M.session_file)
end

-- Only remove the lock if it is ours; a takeover may already have replaced it.
-- bin/ivim records the TUI process, which is this Lua server's parent.
function M.release_lock()
  local ok, lines = pcall(vim.fn.readfile, M.lock_file)
  if ok and tonumber(lines[1]) == vim.uv.os_getppid() then
    vim.fn.delete(M.lock_file)
  end
end

-- Host-only runtime state for a workspace's agents: <agent>.state and <agent>.session from its hooks, <agent>.seen.
function M.run_dir(id)
  return M.run .. "/" .. id
end

function M.state_file(ws, agent)
  return M.run_dir(ws) .. "/" .. agent .. ".state"
end

function M.seen_file(ws, agent)
  return M.run_dir(ws) .. "/" .. agent .. ".seen"
end

-- The id of the agent's conversation, so a restart resumes that one and not another agent's.
function M.session_id(ws, agent)
  local file = io.open(M.run_dir(ws) .. "/" .. agent .. ".session")
  if not file then
    return nil
  end
  local id = vim.trim(file:read("*a"))
  file:close()
  return id ~= "" and id or nil
end

function M.path(id)
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

function M.dir(id)
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

---@return {id:string, name:string, dir:string, created:integer, modified:integer}[]
function M.list()
  local workspaces = {}
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
  -- Then the repos under the config's repo_dirs not yet used: one clone per origin, the most
  -- recently touched, since any clone can hold new worktrees.
  local clones = {}
  for _, root in ipairs(require("isovim.config").get().repo_dirs or {}) do
    root = vim.fs.normalize(root)
    for name, kind in vim.fs.dir(root) do
      local dir = root .. "/" .. name
      if kind == "directory" and vim.fn.isdirectory(dir .. "/.git") == 1 then
        local stat = vim.uv.fs_stat(dir .. "/.git/HEAD")
        clones[#clones + 1] = { dir = M.home_relative(dir), at = stat and stat.mtime.sec or 0 }
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

-- A workspace without an agent list has just its main agent.
local DEFAULT_AGENTS = { { id = "main", name = "main", kind = "claude" } }

---@return isovim.Agent[]
function M.agents(ws)
  local meta = read_meta(M.path(ws)) or {}
  return meta.agents or vim.deepcopy(DEFAULT_AGENTS)
end

---@return isovim.Agent?
function M.agent(ws, id)
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

-- Ids come from the name or kind, numbered when taken: codex, codex2, ...
---@param spec {kind: string, name?: string, cmd?: string, hidden?: boolean, prompt?: string}
---@return isovim.Agent
function M.add_agent(ws, spec)
  local dir = M.path(ws)
  local meta = read_meta(dir) or {}
  local agents = meta.agents or vim.deepcopy(DEFAULT_AGENTS)
  local base = (spec.name or spec.kind):lower():gsub("[^%w]+", "-")
  local id, n = base, 1
  while has_agent(agents, id) do
    n = n + 1
    id = base .. n
  end
  local agent = { id = id, name = spec.name or id, kind = spec.kind, cmd = spec.cmd, hidden = spec.hidden or nil, prompt = spec.prompt }
  agents[#agents + 1] = agent
  meta.agents = agents
  write_meta(dir, meta)
  return agent
end

function M.update_agent(ws, id, fields)
  local dir = M.path(ws)
  local meta = read_meta(dir) or {}
  for _, agent in ipairs(meta.agents or {}) do
    if agent.id == id then
      for key, value in pairs(fields) do
        agent[key] = value
      end
    end
  end
  write_meta(dir, meta)
end

function M.remove_agent(ws, id)
  local dir = M.path(ws)
  local meta = read_meta(dir) or {}
  meta.agents = vim.tbl_filter(function(agent)
    return agent.id ~= id
  end, meta.agents or vim.deepcopy(DEFAULT_AGENTS))
  write_meta(dir, meta)
  vim.fn.delete(M.state_file(ws, id))
  vim.fn.delete(M.seen_file(ws, id))
  vim.fn.delete(M.run_dir(ws) .. "/" .. id .. ".session")
end

function M.set_hidden(ws, id, hidden)
  local dir = M.path(ws)
  local meta = read_meta(dir) or {}
  meta.agents = meta.agents or vim.deepcopy(DEFAULT_AGENTS)
  for _, agent in ipairs(meta.agents) do
    if agent.id == id then
      agent.hidden = hidden or nil
    end
  end
  write_meta(dir, meta)
end

-- PR URLs the workspace's agents registered with `ivim pr`, oldest first.
---@return string[]
function M.prs(ws)
  return (read_meta(M.path(ws)) or {}).prs or {}
end

-- Files and folders an agent pinned for you (`ivim pin`), shown under the workspace.
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
