-- Moving a workspace to another host: its agents stop here and pick their conversations back up
-- there. One tar goes over ssh into `iso receive`: the workspace dir, Claude's transcripts for it,
-- each Codex agent's rollout, the agents' session ids and a manifest of which agents were running.
-- Claude keys transcripts by the workspace's path, which differs between hosts, so the receiver
-- files them under its own path's key. A worktree workspace also brings its branch and uncommitted
-- work as a git bundle, and gets a new worktree of the same repo on the other host.
local store = require("isovim.store")
local panes = require("isovim.panes")
local worktree = require("isovim.worktree")

local M = {}

-- Pilots swap ssh for a local stand-in.
M.ssh = vim.env.ISOVIM_SSH or "ssh -o BatchMode=yes -o ConnectTimeout=5"
M.remote_bin = vim.env.ISOVIM_REMOTE_BIN or "~/.local/bin/iso"

local function copy(from, to)
  vim.fn.mkdir(vim.fs.dirname(to), "p")
  return vim.system({ "cp", "-R", from, to }):wait().code == 0
end

local function is_dir(path)
  return vim.fn.isdirectory(path) == 1
end

---@return boolean ok, string? err
function M.send(ws, host)
  if store.v2(ws.id) then
    return false, "a repo's agents (the new layout) don't move between hosts yet"
  end
  local dir = store.dir(ws.id)
  local manifest = { id = ws.id, running = {} }
  local agents = store.agents(ws.id)
  for _, agent in ipairs(agents) do
    if panes.running(ws.id, agent.id) then
      table.insert(manifest.running, agent.id)
    end
  end
  panes.stop_all(ws.id)
  -- A move that fails leaves the workspace running here as it was.
  local function abort(err)
    for _, agent_id in ipairs(manifest.running) do
      panes.start(ws.id, store.agent(ws.id, agent_id), dir)
    end
    return false, err
  end

  local stage = vim.fn.tempname()
  vim.fn.mkdir(stage .. "/run", "p")
  if store.branch(ws.id) then
    if dir == store.path(ws.id) then
      return abort("its worktree is gone")
    end
    local info, err = worktree.pack(dir, stage .. "/worktree.bundle")
    if not info then
      return abort(err)
    end
    info.repo = store.home_relative(worktree.repo_of(dir))
    manifest.worktree = info
  end
  local project = panes.claude_project(dir)
  if is_dir(project) then
    copy(project, stage .. "/claude")
  end
  for _, agent in ipairs(agents) do
    local id = store.session_id(ws.id, agent.id)
    if id then
      copy(store.run_dir(ws.id) .. "/" .. agent.id .. ".session", stage .. "/run/" .. agent.id .. ".session")
      local rollout = agent.kind == "codex" and panes.codex_rollout(id)
      if rollout then
        copy(rollout, stage .. "/codex/" .. rollout:sub(#panes.codex_sessions + 2))
      end
    end
  end
  vim.fn.writefile({ vim.json.encode(manifest) }, stage .. "/manifest.json")

  local tar = { "tar", "-cf", "-", "-C", stage, ".", "-C", store.workspaces, ws.id }
  local pipeline = ("set -o pipefail; %s | %s %s %s"):format(
    table.concat(vim.tbl_map(vim.fn.shellescape, tar), " "),
    M.ssh,
    vim.fn.shellescape(host),
    vim.fn.shellescape(M.remote_bin .. " receive")
  )
  local result = vim.system({ "bash", "-c", pipeline }, { text = true }):wait()
  vim.fn.delete(stage, "rf")
  if result.code ~= 0 then
    return abort(vim.trim((result.stderr or "") .. (result.stdout or "")))
  end
  local aside
  if manifest.worktree and vim.trim(vim.fn.system({ "git", "-C", dir, "status", "--porcelain" })) ~= "" then
    aside = worktree.set_aside(dir)
  end
  local ok, err, note = store.archive_workspace(ws.id)
  if not ok then
    return false, "moved, but could not archive the copy here: " .. tostring(err)
  end
  if aside then
    note = "its old worktree, uncommitted work and all, is kept at " .. store.home_relative(aside)
  end
  return true, note
end

-- Files what `send` packed (bin/iso unpacked it into stage) and starts the agents that were running.
---@return boolean ok, string message
function M.receive(stage)
  local manifest = vim.json.decode(table.concat(vim.fn.readfile(stage .. "/manifest.json"), "\n"))
  local id = manifest.id
  local dir = store.path(id)
  if vim.uv.fs_stat(dir) then
    return false, "workspace " .. id .. " is already here"
  end
  -- First, so a repo missing here leaves nothing half moved in.
  local checkout
  if manifest.worktree then
    local err
    checkout, err = worktree.unpack(vim.fs.normalize(manifest.worktree.repo), stage .. "/worktree.bundle", manifest.worktree)
    if not checkout then
      return false, "could not recreate its worktree: " .. err
    end
  end
  local ok, err = vim.uv.fs_rename(stage .. "/" .. id, dir)
  if not ok then
    return false, "could not place workspace: " .. tostring(err)
  end
  if checkout then
    store.set_dir(id, checkout)
    store.update_meta(id, { repo = manifest.worktree.repo })
  end
  -- Its project dir, if this host has it at the same place under ~.
  dir = store.dir(id)
  if is_dir(stage .. "/claude") then
    local project = panes.claude_project(dir)
    vim.fn.mkdir(project, "p")
    vim.system({ "cp", "-R", stage .. "/claude/.", project }):wait()
  end
  for _, file in ipairs(vim.fn.glob(stage .. "/codex/**/*.jsonl", false, true)) do
    local target = panes.codex_sessions .. "/" .. file:sub(#stage + #"/codex/" + 1)
    if not vim.uv.fs_stat(target) then
      copy(file, target)
    end
  end
  vim.fn.mkdir(store.run_dir(id), "p")
  for _, file in ipairs(vim.fn.glob(stage .. "/run/*.session", false, true)) do
    copy(file, store.run_dir(id) .. "/" .. vim.fs.basename(file))
  end
  local started = {}
  -- Script terminals are rebuilt for this host's paths; a new worktree gets set up here too.
  local scripts = require("isovim.scripts")
  local script = { setup = true, run = true }
  for _, agent_id in ipairs(manifest.running) do
    local agent = store.agent(id, agent_id)
    if agent and script[agent_id] and agent.kind == "command" then
      if scripts.start(id, agent_id) then
        table.insert(started, agent.name)
      end
    elseif agent and panes.start(id, agent, dir).code == 0 then
      table.insert(started, agent.name)
    end
  end
  if checkout and not vim.tbl_contains(manifest.running, "setup") and scripts.start(id, "setup") then
    table.insert(started, "setup")
  end
  vim.fn.delete(stage, "rf")
  local name = store.name(id)
  if #started == 0 then
    return true, name .. " is here"
  end
  return true, ("%s is here; resumed %s"):format(name, table.concat(started, ", "))
end

return M
