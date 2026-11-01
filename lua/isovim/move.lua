-- Moving a workspace to another host: its agents stop here and pick their conversations back up
-- there. One tar goes over ssh into `iso receive`: the workspace dir, Claude's transcripts for it,
-- each Codex agent's rollout, the agents' session ids and a manifest of which agents were running.
-- Claude keys transcripts by the workspace's path, which differs between hosts, so the receiver
-- files them under its own path's key. A worktree workspace also brings its branch and uncommitted
-- work as a git bundle, and gets a new worktree of the same repo on the other host.
--
-- A new-layout agent (<key>/aN) moves on its own (M.send_agent): its record, its journal (with its
-- queue file and the sessions it kept), its plain-text transcript and its session's transcript
-- (Claude's, filed on the other host under the key of the path it will run in there; Codex's
-- rollout). Its worktree goes as its branch: pushed to origin here and made again there, as aN/w
-- from that host's base clone, so a dirty worktree is refused (commit first). It keeps its aN when
-- the other host never gave that number out, else takes the next one there. It's refused mid-turn,
-- and roots stay on their host. Once the other host has it, it's removed here (its children go on
-- as when it's removed: to its parent, else the repo's router).
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
-- Why a running agent of this kind can't restart on host (its claude or codex isn't logged in
-- there, as that host's iso __auth says), or nil. A host that can't say (an older isovim) is let
-- through, as before.
local function remote_blocked(host, agent)
  local kind = require("isovim.auth").kind_of(agent)
  if not kind then
    return nil
  end
  local cmd = ("%s %s %s"):format(M.ssh, vim.fn.shellescape(host), vim.fn.shellescape(M.remote_bin .. " __auth " .. kind))
  local result = vim.system({ "bash", "-c", cmd }, { text = true, timeout = 30000 }):wait()
  local ok, answer = pcall(vim.json.decode, vim.trim(result.stdout or ""))
  if result.code == 0 and ok and type(answer) == "table" and answer.logged_in == false then
    return ("%s needs login on %s (%s)"):format(kind, host, tostring(answer.detail))
  end
end

function M.send(ws, host)
  if store.v2(ws.id) then
    return false, "a repo's agents move one at a time: iso move <owner>/<repo>/aN <host>"
  end
  local dir = store.dir(ws.id)
  local manifest = { id = ws.id, running = {} }
  local agents = store.agents(ws.id)
  for _, agent in ipairs(agents) do
    if panes.running(ws.id, agent.id) then
      table.insert(manifest.running, agent.id)
    end
  end
  -- The running ones restart there: not while their kind isn't logged in there.
  for _, agent in ipairs(agents) do
    local blocked = vim.tbl_contains(manifest.running, agent.id) and remote_blocked(host, agent)
    if blocked then
      return false, blocked .. "; its agents stay running here"
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
  if manifest.agent then
    return M.receive_agent(stage, manifest)
  end
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

-- A new-layout agent

local function run_git(dir, args, timeout)
  local result = vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true, timeout = timeout }):wait()
  return result.code == 0, vim.trim(result.stdout or ""), vim.trim(result.stderr or "")
end

-- Claude's transcript of a session (<session>.jsonl, under whichever project it's in) and the dir
-- of its subagents' beside it, when there is one.
---@return string? transcript, string? dir
local function claude_transcript(session)
  local projects = vim.fs.dirname(panes.claude_project("/"))
  local file = vim.fn.glob(projects .. "/*/" .. session .. ".jsonl", false, true)[1]
  if not file then
    return nil
  end
  local dir = file:sub(1, -7)
  return file, is_dir(dir) and dir or nil
end

-- The files of the agent's that go along, as {from, to under the stage}.
local function agent_files(key, id)
  local journal = require("isovim.acp.journal")
  local files = {}
  for _, name in ipairs({ id .. ".jsonl", id .. ".queue.json", id .. ".sessions" }) do
    local path = journal.dir(key) .. "/" .. name
    if vim.uv.fs_stat(path) then
      files[#files + 1] = { path, "journal/" .. name }
    end
  end
  local text = store.path(key) .. "/transcripts/" .. id .. ".txt"
  if vim.uv.fs_stat(text) then
    files[#files + 1] = { text, "transcripts/" .. id .. ".txt" }
  end
  return files
end

-- Moves the new-layout agent key/agent to host (an ssh name): see the top of this file.
---@param agent isovim.Agent
---@return boolean ok, string message the address it has there, or why not
function M.send_agent(key, agent, host)
  local id = agent.id
  local address = key .. "/" .. id
  local role = store.role(agent)
  if agent.of or not (agent.kind == "claude" or agent.kind == "codex") then
    return false, address .. " isn't an agent that moves (a terminal or script pane stays with its host)"
  elseif role == "root" or role == "repo-root" then
    return false, ("%s is a %s, and a root belongs to its host: turn root mode off, or move a worker"):format(address, role)
  end
  local running = panes.running(key, id)
  if running and agent.acp then
    local up, state = require("isovim.acp").call(key, id, "status")
    if up and type(state) == "table" and state.handover then
      return false, address .. " is handed over to Claude's screen; quit claude there first"
    elseif up and type(state) == "table" and state.busy then
      return false, address .. " is mid-turn; wait for its turn to end, or cancel it (C-c in its chat)"
    end
  elseif running and require("isovim.status").get(key, id) == "working" then
    return false, address .. " is mid-turn; wait for its turn to end, or cancel it"
  end
  local blocked = running and remote_blocked(host, agent)
  if blocked then
    return false, blocked .. "; it stays running here"
  end
  -- Its worktree goes as its branch, pushed to origin.
  local w = store.dir(key) .. "/" .. id .. "/w"
  local branch
  if is_dir(w) then
    local _, dirty = run_git(w, { "status", "--porcelain" })
    if dirty ~= "" then
      return false, ("%s's worktree (%s) has uncommitted changes; commit them first, since the move takes its branch")
        :format(address, store.home_relative(w))
    end
    local _, current = run_git(w, { "branch", "--show-current" })
    if current == "" then
      return false, ("%s's worktree is on a detached HEAD; put it on a branch first"):format(address)
    end
    branch = current
    local pushed, _, err = run_git(w, { "push", "--quiet", "origin", "HEAD:refs/heads/" .. branch }, 120000)
    if not pushed then
      return false, ("could not push %s to origin: %s"):format(branch, err)
    end
  end
  local manifest = { agent = true, key = key, record = vim.deepcopy(agent), running = running, branch = branch,
    from = require("isovim.remote").self() }
  local repo_dir = agent.repo and require("isovim.repos").dir(agent.repo) .. "/base-clone"
  if repo_dir and is_dir(repo_dir) then
    local _, url = run_git(repo_dir, { "remote", "get-url", "origin" })
    manifest.origin = url ~= "" and url or nil
  elseif branch then
    local _, url = run_git(w, { "remote", "get-url", "origin" })
    manifest.origin = url ~= "" and url or nil
  end
  -- Its parent here is named with this host from there.
  local parent = manifest.record.parent
  if parent and not parent:find(":", 1, true) then
    manifest.record.parent = manifest.from .. ":" .. parent
  end
  manifest.record.branch = nil

  if running then
    panes.stop(key, id)
    -- The supervisor writes its queue on every change and removes its socket as it exits.
    local sock = require("isovim.acp").socket(key, id)
    vim.wait(5000, function()
      return not vim.uv.fs_stat(sock)
    end, 50)
  end
  local function abort(err)
    if running then
      panes.start(key, store.agent(key, id) or agent, store.agent_dir(key, id))
    end
    return false, err
  end

  local stage = vim.fn.tempname()
  vim.fn.mkdir(stage .. "/journal", "p")
  for _, file in ipairs(agent_files(key, id)) do
    copy(file[1], stage .. "/" .. file[2])
  end
  local session = store.session_id(key, id)
  manifest.record.session = session or manifest.record.session
  if session and agent.kind == "codex" then
    local rollout = panes.codex_rollout(session)
    if rollout then
      copy(rollout, stage .. "/codex/" .. rollout:sub(#panes.codex_sessions + 2))
    end
  elseif session then
    local transcript, subagents = claude_transcript(session)
    if transcript then
      copy(transcript, stage .. "/claude/" .. session .. ".jsonl")
    end
    if subagents then
      copy(subagents, stage .. "/claude/" .. session)
    end
  end
  vim.fn.writefile({ vim.json.encode(manifest) }, stage .. "/manifest.json")

  local tar = { "tar", "-cf", "-", "-C", stage, "." }
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
  local there = vim.trim(result.stdout or ""):match("([^%s]+/a%d+) is here") or address
  -- It's there now: gone from here, as iso rm removes one, its journal too.
  store.remove_agent(key, id)
  for _, file in ipairs(agent_files(key, id)) do
    vim.fn.delete(file[1], "rf")
  end
  return true, there
end

-- This host's base clone of repo, made from origin's url when there's no checkout here to make it
-- from (isovim.repoconf.base); fetched when it's there.
---@return string? path, string? err
local function base_clone(repo, url)
  local repoconf = require("isovim.repoconf")
  local path, err = repoconf.base(repo)
  if path or not url or is_dir(require("isovim.repos").dir(repo) .. "/base-clone/.git") then
    return path, err
  end
  path = require("isovim.repos").dir(repo) .. "/base-clone"
  local tmp = ("%s.%d.tmp"):format(path, vim.uv.os_getpid())
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local cloned = vim.system({ "git", "clone", "--quiet", url, tmp }, { text = true }):wait()
  if cloned.code ~= 0 then
    vim.fn.delete(tmp, "rf")
    return nil, vim.trim(cloned.stderr)
  end
  local _, branch = run_git(tmp, { "symbolic-ref", "--quiet", "--short", "HEAD" })
  run_git(tmp, { "checkout", "--quiet", "--detach" })
  if branch ~= "" then
    run_git(tmp, { "branch", "--quiet", "-D", branch })
  end
  if not vim.uv.fs_rename(tmp, path) then
    vim.fn.delete(tmp, "rf")
  end
  return is_dir(path .. "/.git") and path or nil, "could not clone " .. url
end

-- The other end of send_agent: files what it packed, makes its worktree from its branch, and
-- starts it if it was running there.
---@return boolean ok, string message
function M.receive_agent(stage, manifest)
  local key, record = manifest.key, manifest.record
  if not (type(key) == "string" and store.valid_key(key) and type(record) == "table" and record.id) then
    return false, "the move's manifest names no agent"
  end
  local role = store.role(record)
  if role == "router" and store.router(key) then
    return false, ("%s has a router here already (%s); one router per repo per host"):format(key, store.router(key))
  end
  local repo = record.repo
  if record.read_only or manifest.branch then
    if not repo then
      return false, "a read-only agent or one with a worktree belongs to a repo, and this one names none"
    end
    local base, err = base_clone(repo, manifest.origin)
    if not base then
      return false, ("no base clone of %s here: %s"):format(repo, tostring(err))
    end
    if manifest.branch then
      -- A branch of that name left here from before is moved to what was pushed, unless it's in use.
      run_git(base, { "fetch", "--quiet", "origin", manifest.branch }, 60000)
      local has_local = run_git(base, { "rev-parse", "--verify", "--quiet", "refs/heads/" .. manifest.branch })
      if has_local then
        local moved, _, err2 = run_git(base, { "branch", "-f", manifest.branch, "origin/" .. manifest.branch })
        if not moved then
          return false, ("%s here has its own %s, in use: %s"):format(repo, manifest.branch, err2)
        end
      end
    end
  end
  if record.checkout and not is_dir(record.checkout) then
    record.checkout = nil
  end
  local was = record.id
  local adopted, err = store.adopt_record(key, record)
  if not adopted then
    return false, err
  end
  local id = adopted.id
  local address = key .. "/" .. id
  local function undo(why)
    os.remove(store.record_file(key, id))
    vim.fn.delete(store.dir(key) .. "/" .. id, "rf")
    return false, why
  end
  if manifest.branch then
    local log = store.run_dir(key) .. "/" .. id .. ".worktree_setup.log"
    vim.fn.mkdir(store.run_dir(key), "p")
    local path, branch_or_err = require("isovim.cli.work").ensure_worktree(key, adopted, manifest.branch, log)
    if not path then
      return undo("could not make its worktree here: " .. tostring(branch_or_err))
    end
  end
  -- Its journal and transcript, under its id here.
  local journal = require("isovim.acp.journal")
  vim.fn.mkdir(journal.dir(key), "p")
  for _, suffix in ipairs({ ".jsonl", ".queue.json", ".sessions" }) do
    local from = stage .. "/journal/" .. was .. suffix
    if vim.uv.fs_stat(from) then
      vim.fn.delete(journal.dir(key) .. "/" .. id .. suffix, "rf")
      copy(from, journal.dir(key) .. "/" .. id .. suffix)
    end
  end
  local text = stage .. "/transcripts/" .. was .. ".txt"
  if vim.uv.fs_stat(text) then
    copy(text, store.path(key) .. "/transcripts/" .. id .. ".txt")
  end
  -- Its session: Claude finds a session by the path it runs in, so the transcript goes under that
  -- path's project here.
  local session = adopted.session
  if session then
    vim.fn.mkdir(store.run_dir(key), "p")
    vim.fn.writefile({ session }, store.run_dir(key) .. "/" .. id .. ".session")
  end
  if is_dir(stage .. "/claude") then
    local cwd = store.agent_dir(key, id)
    vim.fn.mkdir(cwd, "p")
    local project = panes.claude_project(cwd)
    vim.fn.mkdir(project, "p")
    vim.system({ "cp", "-R", stage .. "/claude/.", project }):wait()
  end
  for _, file in ipairs(vim.fn.glob(stage .. "/codex/**/*.jsonl", false, true)) do
    local target = panes.codex_sessions .. "/" .. file:sub(#stage + #"/codex/" + 1)
    if not vim.uv.fs_stat(target) then
      copy(file, target)
    end
  end
  vim.fn.delete(stage, "rf")
  local renamed = id ~= was and (" (%s was taken here)"):format(was) or ""
  if manifest.running then
    local started = panes.start(key, adopted, store.agent_dir(key, id))
    if started.code ~= 0 then
      return true, ("%s is here%s; it didn't start: %s"):format(address, renamed, vim.trim(started.stderr or ""))
    end
    return true, ("%s is here%s; resumed"):format(address, renamed)
  end
  return true, ("%s is here%s"):format(address, renamed)
end

return M
