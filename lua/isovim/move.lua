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
-- rollout). Its worktree goes as its branch: pushed to origin here and made again there, as
-- aN/<repo>-aN (with aN/w linked to it) from that host's base clone, so uncommitted changes to tracked
-- files are refused (commit first). The rest of aN/ goes as files, whole: what's beside the worktree,
-- and in it what git doesn't carry (ignored and untracked files), put in the worktree there whatever
-- its name (an aN taken there changes it). Everything that goes (aN/, the record, which is in the hashed manifest, the
-- journal, queue file, kept sessions and transcripts) is listed with sizes and sha256 (streamed by
-- sha256sum, never read into memory here), and checked: as it's staged here, as it arrives there
-- and where it lands. Before the agent is stopped, every file is checked readable and the staged
-- part checked to fit. The other host says it has it only once all of that matches and, if it was
-- running, its supervisor there answers as ready; anything short of that and the other host keeps
-- nothing of it, and it starts here again as it was. It keeps its aN when the other host never
-- gave that number out, else takes the next one there. It's refused mid-turn, and
-- roots stay on their host. Once the other host has it, it's removed here (its children go on as
-- when it's removed: to its parent, else the repo's router).
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
  if is_dir(project) and not copy(project, stage .. "/claude") then
    vim.fn.delete(stage, "rf")
    return abort("could not stage its Claude transcripts from " .. project)
  end
  for _, agent in ipairs(agents) do
    local id = store.session_id(ws.id, agent.id)
    if id then
      local session = store.run_dir(ws.id) .. "/" .. agent.id .. ".session"
      local rollout = agent.kind == "codex" and panes.codex_rollout(id)
      if not copy(session, stage .. "/run/" .. agent.id .. ".session")
        or rollout and not copy(rollout, stage .. "/codex/" .. rollout:sub(#panes.codex_sessions + 2)) then
        vim.fn.delete(stage, "rf")
        return abort("could not stage " .. agent.name .. "'s session")
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
  -- An agent's manifest (its record and the lists the rest is checked against) is checked first.
  local sum = vim.uv.fs_stat(stage .. "/manifest.sha256") and vim.fn.readfile(stage .. "/manifest.sha256")[1]
  if sum then
    local hashes = M.hash({ stage .. "/manifest.json" })
    if not hashes or hashes[stage .. "/manifest.json"] ~= vim.trim(sum) then
      vim.fn.delete(stage, "rf")
      return false, "its manifest arrived different; nothing of it is kept here"
    end
  end
  local manifest = vim.json.decode(table.concat(vim.fn.readfile(stage .. "/manifest.json"), "\n"))
  if manifest.agent then
    if not sum then
      vim.fn.delete(stage, "rf")
      return false, "the move sent no manifest.sha256 (the sending isovim is older than this one: update it)"
    end
    return M.receive_agent(stage, manifest)
  end
  -- A legacy workspace never lands on a host that's cut over: its agents would be told commands
  -- retired here. The sender keeps it.
  if require("isovim.config").enforced() then
    return false, ("workspaces were retired at the cutover on %s, so workspace %s can't move here; it stays where it is")
      :format(require("isovim.remote").self(), manifest.id or "?")
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

-- Claude's transcript of a session (the current one, under dir's project when it's there) and the dir
-- of its subagents' beside it, when there is one.
---@return string? transcript, string? dir
local function claude_transcript(session, dir)
  local file = panes.claude_transcript(session, dir)
  if not file then
    return nil
  end
  local dir = file:sub(1, -7)
  return file, is_dir(dir) and dir or nil
end

-- The sha256 of each of paths, as {path = hash}: sha256sum (or shasum) reads them, so a file of any
-- size is streamed and never held here. Paths go many to a call; when the lines that come back
-- don't match them one to one (a name with a newline in it, said differently), each goes alone.
---@param paths string[]
---@return table<string, string>? hashes, string? err
function M.hash(paths)
  local cmd = vim.fn.executable("sha256sum") == 1 and { "sha256sum" }
    or vim.fn.executable("shasum") == 1 and { "shasum", "-a", "256" }
  if not cmd then
    return nil, "neither sha256sum nor shasum is installed, so its files can't be checked"
  end
  local function hex(line)
    local found = (line or ""):match("^\\?(%x+)")
    return found and #found == 64 and found:lower() or nil
  end
  local hashes = {}
  local i = 1
  while i <= #paths do
    local batch, bytes = {}, 0
    while i <= #paths and #batch < 200 and bytes < 60000 do
      batch[#batch + 1] = paths[i]
      bytes = bytes + #paths[i]
      i = i + 1
    end
    local args = vim.list_extend(vim.list_extend({}, cmd), { "--" })
    local result = vim.system(vim.list_extend(args, batch), { text = true }):wait()
    if result.code ~= 0 then
      return nil, "can't hash its files: " .. vim.trim(result.stderr or "")
    end
    local lines = vim.split(vim.trim(result.stdout or ""), "\n", { plain = true })
    local whole = #lines == #batch
    for n, path in ipairs(batch) do
      hashes[path] = whole and hex(lines[n]) or nil
      if not hashes[path] then
        local one = vim.system(vim.list_extend({ "sh", "-c", 'f=$1; shift; exec "$@" < "$f"', "sh", path }, cmd),
          { text = true }):wait()
        hashes[path] = one.code == 0 and hex(one.stdout) or nil
        if not hashes[path] then
          return nil, ("can't hash %s: %s"):format(path, vim.trim(one.stderr or ""))
        end
      end
    end
  end
  return hashes
end

-- A file's size, or why it can't be read (opened and closed, never read here).
---@return integer? size, string? err
local function readable(path, stat)
  local fd, err = vim.uv.fs_open(path, "r", 0)
  if not fd then
    return nil, ("can't read %s: %s"):format(path, tostring(err))
  end
  vim.uv.fs_close(fd)
  return stat.size
end

-- What's under root, as a sorted list of {path, type, size, sha256 | target}: every file (hashed
-- unless opts.hash is false), link and dir, but `skip` (a path relative to root) and what's in it.
-- Sockets and fifos aren't listed. A file that can't be read is an error, as it couldn't go along.
---@param opts? {hash?: boolean}
---@return table[]? entries, string? err
function M.listing(root, skip, opts)
  local entries = {}
  local full_paths = {}
  local function walk(rel)
    local dir = rel == "" and root or root .. "/" .. rel
    local handle, err = vim.uv.fs_scandir(dir)
    if not handle then
      return ("can't read %s: %s"):format(dir, tostring(err))
    end
    while true do
      local name = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local path = rel == "" and name or rel .. "/" .. name
      local full = root .. "/" .. path
      local stat = path ~= skip and vim.uv.fs_lstat(full)
      if stat and stat.type == "link" then
        entries[#entries + 1] = { path = path, type = "link", target = vim.uv.fs_readlink(full) }
      elseif stat and stat.type == "file" then
        local size, read_err = readable(full, stat)
        if not size then
          return read_err
        end
        entries[#entries + 1] = { path = path, type = "file", size = size }
        full_paths[entries[#entries]] = full
      elseif stat and stat.type == "directory" then
        entries[#entries + 1] = { path = path, type = "directory" }
        local walk_err = walk(path)
        if walk_err then
          return walk_err
        end
      end
    end
  end
  local err = walk("")
  if err then
    return nil, err
  end
  if not (opts and opts.hash == false) then
    local hashes, hash_err = M.hash(vim.tbl_values(full_paths))
    if not hashes then
      return nil, hash_err
    end
    for entry, full in pairs(full_paths) do
      entry.sha256 = hashes[full]
    end
  end
  table.sort(entries, function(a, b)
    return a.path < b.path
  end)
  return entries
end

-- The first entry of want that isn't where it should be as it was listed, said as why; nil when all
-- match. An entry's path is under root, or root is a function giving where a path is. What's there
-- besides (a setup script's output, say) doesn't count, nor is it read.
---@param root string|fun(path: string): string
---@return string? mismatch
function M.compare(want, root)
  local where = type(root) == "function" and root or function(path)
    return root .. "/" .. path
  end
  local files = {}
  for _, entry in ipairs(want) do
    local full = where(entry.path)
    local got = vim.uv.fs_lstat(full)
    local kind = got and got.type
    if not got then
      return entry.path .. " is missing"
    elseif kind ~= entry.type then
      return ("%s is a %s, not a %s"):format(entry.path, tostring(kind), entry.type)
    elseif entry.type == "file" then
      if got.size ~= entry.size then
        return ("%s arrived different (%d bytes; sent %d bytes)"):format(entry.path, got.size, entry.size)
      end
      files[#files + 1] = { entry = entry, full = full }
    elseif entry.type == "link" and vim.uv.fs_readlink(full) ~= entry.target then
      return ("%s points to %s, not %s"):format(entry.path, tostring(vim.uv.fs_readlink(full)), tostring(entry.target))
    end
  end
  local hashes, err = M.hash(vim.tbl_map(function(file)
    return file.full
  end, files))
  if not hashes then
    return err
  end
  for _, file in ipairs(files) do
    local got = hashes[file.full]
    if got ~= file.entry.sha256 then
      return ("%s arrived different (sha256 %s; sent sha256 %s)")
        :format(file.entry.path, tostring(got):sub(1, 12), tostring(file.entry.sha256):sub(1, 12))
    end
  end
end

-- What of the agent's goes besides its aN/, as {from, to under the stage, keep}: its journal, queue
-- file and kept sessions, its plain-text transcript, and its session's own transcript (Claude's,
-- with its subagents' beside it, or Codex's rollout). Those of the session are kept here (`keep`)
-- when it's gone; the rest are removed with it.
local function agent_files(key, id, kind)
  local journal = require("isovim.acp.journal")
  local files = {}
  for _, name in ipairs({ id .. ".jsonl", id .. ".queue.json", id .. ".sessions" }) do
    local path = journal.dir(key) .. "/" .. name
    if vim.uv.fs_lstat(path) then
      files[#files + 1] = { path, "journal/" .. name }
    end
  end
  local text = store.path(key) .. "/transcripts/" .. id .. ".txt"
  if vim.uv.fs_lstat(text) then
    files[#files + 1] = { text, "transcripts/" .. id .. ".txt" }
  end
  local session = store.session_id(key, id)
  if session and kind == "codex" then
    local rollout = panes.codex_rollout(session)
    if rollout then
      files[#files + 1] = { rollout, "codex/" .. rollout:sub(#panes.codex_sessions + 2), true }
    end
  elseif session then
    local transcript, subagents = claude_transcript(session, store.agent_dir(key, id))
    if transcript then
      files[#files + 1] = { transcript, "claude/" .. session .. ".jsonl", true }
    end
    if subagents then
      files[#files + 1] = { subagents, "claude/" .. session, true }
    end
  end
  return files, session
end

-- An entry like M.listing's for one path (a file, link or dir and what's in it), each path put
-- under `as`.
---@return table[]? entries, string? err
local function listed(path, as, opts)
  local stat = vim.uv.fs_lstat(path)
  if not stat then
    return {}
  elseif stat.type == "directory" then
    local entries, err = M.listing(path, nil, opts)
    if not entries then
      return nil, err
    end
    for _, entry in ipairs(entries) do
      entry.path = as .. "/" .. entry.path
    end
    table.insert(entries, 1, { path = as, type = "directory" })
    return entries
  elseif stat.type == "link" then
    return { { path = as, type = "link", target = vim.uv.fs_readlink(path) } }
  elseif stat.type == "file" then
    local size, err = readable(path, stat)
    if not size then
      return nil, err
    end
    local entry = { path = as, type = "file", size = size }
    if not (opts and opts.hash == false) then
      local hashes, hash_err = M.hash({ path })
      if not hashes then
        return nil, hash_err
      end
      entry.sha256 = hashes[path]
    end
    return { entry }
  end
  return {}
end

-- Whether what goes can, asked before the agent is stopped: every file of its aN/ and the rest
-- readable, and the rest (which is copied to a stage first) no larger than the space the stage has.
---@return string? err
local function preflight(own, skip, files, stage)
  if is_dir(own) then
    local _, err = M.listing(own, skip, { hash = false })
    if err then
      return err
    end
  end
  local total, largest = 0, nil
  for _, file in ipairs(files) do
    local entries, err = listed(file[1], file[1], { hash = false })
    if not entries then
      return err
    end
    for _, entry in ipairs(entries) do
      total = total + (entry.size or 0)
      if entry.size and (not largest or entry.size > largest.size) then
        largest = entry
      end
    end
  end
  local fs = vim.uv.fs_statfs(stage)
  local free = fs and fs.bavail * fs.bsize
  if free and total > free then
    return ("its journal and transcripts are too large to stage: %d bytes, and %s has %d free (the largest is %s, %d bytes)")
      :format(total, stage, free, largest.path, largest.size)
  end
end

-- Waits for the supervisor of the agent just started here to answer as ready (its session is up),
-- up to $ISOVIM_MOVE_START_TIMEOUT seconds (300), or for it to exit. One that isn't an ACP agent
-- has only its pane to go by: it's still there a moment later.
---@return boolean ok, string? why not
local function answers(key, spec)
  if not spec.acp then
    vim.wait(2000)
    return panes.running(key, spec.id), "it exited as it started here"
  end
  local timeout = tonumber(vim.env.ISOVIM_MOVE_START_TIMEOUT or "") or 300
  local acp = require("isovim.acp")
  local exited = false
  local ready = vim.wait(timeout * 1000, function()
    if not panes.running(key, spec.id) then
      exited = true
      return true
    end
    local up, state = acp.call(key, spec.id, "status")
    return up and type(state) == "table" and state.ready == true
  end, 200)
  if ready and not exited then
    return true
  end
  local log = store.run_dir(key) .. "/" .. spec.id .. ".acp.log"
  local tail = vim.uv.fs_stat(log) and vim.trim(vim.system({ "tail", "-n", "1", log }, { text = true }):wait().stdout or "")
  local said = tail and tail ~= "" and (" (its log: %s)"):format(tail) or ""
  if exited then
    return false, "its supervisor here exited as it started" .. said
  end
  return false, ("its supervisor here didn't answer as ready within %ds%s"):format(timeout, said)
end

-- Why the new-layout agent key/agent can't move as it is now, or nil: a terminal or script pane, a
-- root, an agent in the old _/, one mid-turn or handed over, or a worktree with uncommitted changes
-- or on a detached HEAD. Nothing here touches the other host.
---@param agent isovim.Agent
---@return string? why
function M.refusal(key, agent)
  local id = agent.id
  local address = key .. "/" .. id
  local role = store.role(agent)
  if agent.of or not (agent.kind == "claude" or agent.kind == "codex") then
    return address .. " isn't an agent that moves (a terminal or script pane stays with its host)"
  elseif role == "repo-root" then
    return ("%s is a %s, and a root belongs to its host: turn root mode off, or move a worker"):format(address, role)
  elseif store.canon(key) == store.OLD then
    return address .. " is in the old _/, whose move to general/ waits (~/.isovim/migrate.log): move it once that's done"
  end
  local running = panes.running(key, id)
  if running and agent.acp then
    local up, state = require("isovim.acp").call(key, id, "status")
    if up and type(state) == "table" and state.handover then
      return address .. " is handed over to Claude's screen; quit claude there first"
    elseif up and type(state) == "table" and state.busy then
      return address .. " is mid-turn; wait for its turn to end, or cancel it (C-c in its chat)"
    end
  elseif running and require("isovim.status").get(key, id) == "working" then
    return address .. " is mid-turn; wait for its turn to end, or cancel it"
  end
  local w = store.worktree(key, id)
  if w then
    -- Untracked and ignored files go along as files, with the rest of aN/.
    local _, dirty = run_git(w, { "status", "--porcelain", "--untracked-files=no" })
    if dirty ~= "" then
      return ("%s's worktree (%s) has uncommitted changes; commit them first, since the move takes its branch")
        :format(address, store.home_relative(w))
    end
    local _, current = run_git(w, { "branch", "--show-current" })
    if current == "" then
      return ("%s's worktree is on a detached HEAD; put it on a branch first"):format(address)
    end
  end
end

-- Moves the new-layout agent key/agent to host (an ssh name): see the top of this file.
-- opts.parent: its parent's address there, for a parent that went ahead of it (M.send_repo).
---@param agent isovim.Agent
---@param opts? {parent?: string}
---@return boolean ok, string message the address it has there, or why not
function M.send_agent(key, agent, host, opts)
  local id = agent.id
  local address = key .. "/" .. id
  local refused = M.refusal(key, agent)
  if refused then
    return false, refused
  end
  local running = panes.running(key, id)
  local blocked = running and remote_blocked(host, agent)
  if blocked then
    return false, blocked .. "; it stays running here"
  end
  -- Its worktree goes as its branch, pushed to origin.
  local w = store.worktree(key, id)
  local branch
  if w then
    local _, current = run_git(w, { "branch", "--show-current" })
    branch = current
    local pushed, _, err = run_git(w, { "push", "--quiet", "origin", "HEAD:refs/heads/" .. branch }, 120000)
    if not pushed then
      return false, ("could not push %s to origin: %s"):format(branch, err)
    end
  end
  local manifest = { agent = true, key = key, record = vim.deepcopy(agent), running = running, branch = branch,
    worktree = w and vim.fs.basename(w), from = require("isovim.remote").self() }
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
  if opts and opts.parent then
    manifest.record.parent = opts.parent
  elseif parent and not parent:find(":", 1, true) then
    manifest.record.parent = manifest.from .. ":" .. parent
  end
  manifest.record.branch = nil

  -- Before it's stopped: everything that goes can be read, and what's staged fits.
  local own = store.dir(key) .. "/" .. id
  local skip = branch and manifest.worktree .. "/.git" or nil
  local stage = vim.fn.tempname()
  local unfit = preflight(own, skip, agent_files(key, id, agent.kind), vim.fs.dirname(stage))
  if unfit then
    return false, unfit .. "; it stays running here"
  end

  if running then
    panes.stop(key, id)
    -- The supervisor writes its queue on every change and removes its socket as it exits.
    local sock = require("isovim.acp").socket(key, id)
    vim.wait(5000, function()
      return not vim.uv.fs_stat(sock)
    end, 50)
  end
  local function abort(err)
    vim.fn.delete(stage, "rf")
    if running then
      panes.start(key, store.agent(key, id) or agent, store.agent_dir(key, id))
    end
    return false, err
  end

  -- Everything that goes is listed (sizes and hashes) for the other host to check against before
  -- it says it has it: its whole aN/ (but its worktree's .git: the worktree is made again there
  -- from the branch), and its journal and transcripts, which go by way of a stage here, checked
  -- against where they came from as they're staged. Its record is in the manifest, which is hashed.
  -- An error partway (isovim's own) aborts the same way.
  local function pack()
    if is_dir(own) then
      local files, err = M.listing(own, skip)
      if not files then
        return err
      end
      manifest.files = files
    end
    vim.fn.mkdir(stage, "p")
    local sources, session = agent_files(key, id, agent.kind)
    manifest.record.session = session or manifest.record.session
    manifest.staged, manifest.units = {}, {}
    for _, file in ipairs(sources) do
      local entries, err = listed(file[1], file[2])
      if not entries then
        return err
      end
      if #entries > 0 then
        local to = stage .. "/" .. file[2]
        vim.fn.mkdir(vim.fs.dirname(to), "p")
        local copied = vim.system({ "cp", "-pR", file[1], to }, { text = true }):wait()
        if copied.code ~= 0 then
          return ("could not stage %s: %s"):format(file[1], vim.trim(copied.stderr or ""))
        end
        vim.list_extend(manifest.staged, entries)
        manifest.units[#manifest.units + 1] = file[2]
      end
    end
    local mismatch = M.compare(manifest.staged, stage)
    if mismatch then
      return "its journal and transcripts didn't stage whole: " .. mismatch
    end
    local encoded = vim.json.encode(manifest)
    if vim.fn.writefile({ encoded }, stage .. "/manifest.json") ~= 0
      or vim.fn.writefile({ vim.fn.sha256(encoded .. "\n") }, stage .. "/manifest.sha256") ~= 0 then
      return "could not write its manifest in " .. stage
    end
  end
  local packed, err = pcall(pack)
  if not packed or err then
    return abort(tostring(err))
  end

  -- aN/ goes beside the stage's files, under its id.
  local tar = { "tar", "-cf", "-", "-C", stage, "." }
  if manifest.files then
    vim.list_extend(tar, { "-C", store.dir(key), id })
  end
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
  local said = vim.trim(result.stdout or "")
  local there = said:match("([^%s]+/a%d+) is here") or address
  -- Only once the other host says it checked every file, and that its supervisor there answers,
  -- is it removed here. One that doesn't say so (an older isovim) may have it running there too.
  local checked = tonumber(said:match("(%d+) files? checked") or "")
  local count = #(manifest.files or {}) + #manifest.staged
  local resumed = said:find("; resumed", 1, true) ~= nil
  if checked ~= count or (running and not resumed) then
    return abort(("%s didn't confirm it has %s's %d files%s (it said: %s); it stays here, and may be running at %s:%s too")
      :format(host, address, count, running and " and is running it" or "", said, host, there))
  end
  -- It's there now: gone from here, as iso rm removes one, its journal too.
  store.remove_agent(key, id)
  for _, file in ipairs(agent_files(key, id, agent.kind)) do
    if not file[3] then
      vim.fn.delete(file[1], "rf")
    end
  end
  return true, there
end

-- Moves every agent of the new-layout key (a repo, or general) to host, each as M.send_agent moves
-- one; its terminals and script panes stay. Each is checked first (M.refusal), and the other host
-- asked that it answers and that a running agent's claude or codex is logged in there, so a refusal
-- leaves all of them here as they were. Parents go before their children, which keep them there.
-- A failure partway (a copy, say) stops it there: what went is said, and the rest stay here.
---@return boolean ok, string message what moved, or why not
function M.send_repo(key, host)
  local agents = vim.tbl_filter(function(agent)
    return not agent.of and (agent.kind == "claude" or agent.kind == "codex")
  end, store.agents(key))
  if #agents == 0 then
    return false, key .. " has no agents that move"
  end
  for _, agent in ipairs(agents) do
    local refused = M.refusal(key, agent)
    if refused then
      return false, refused .. "; nothing moved"
    end
  end
  local cmd = ("%s %s %s"):format(M.ssh, vim.fn.shellescape(host), vim.fn.shellescape(M.remote_bin .. " version"))
  local reached = vim.system({ "bash", "-c", cmd }, { text = true, timeout = 30000 }):wait()
  if reached.code ~= 0 then
    local why = vim.trim((reached.stderr or "") .. (reached.stdout or ""))
    return false, ("%s didn't answer (%s); nothing moved"):format(host, why ~= "" and why or ("exit " .. reached.code))
  end
  local asked = {}
  for _, agent in ipairs(agents) do
    local kind = require("isovim.auth").kind_of(agent)
    if kind and not asked[kind] and panes.running(key, agent.id) then
      asked[kind] = true
      local blocked = remote_blocked(host, agent)
      if blocked then
        return false, blocked .. "; nothing moved"
      end
    end
  end
  -- Parents first; each child's parent there is where its parent went.
  local members, order = {}, {}
  for _, agent in ipairs(agents) do
    members[key .. "/" .. agent.id] = agent
  end
  local placed = {}
  while #order < #agents do
    local before = #order
    for _, agent in ipairs(agents) do
      local parent = members[agent.parent or ""]
      if not placed[agent.id] and (not parent or placed[parent.id]) then
        placed[agent.id] = true
        order[#order + 1] = agent
      end
    end
    -- A loop of parents (never made, but a record can say anything) goes in any order.
    if #order == before then
      for _, agent in ipairs(agents) do
        if not placed[agent.id] then
          placed[agent.id] = true
          order[#order + 1] = agent
        end
      end
    end
  end
  local there, moved = {}, {}
  for _, agent in ipairs(order) do
    local ok, message = M.send_agent(key, agent, host, { parent = there[agent.parent or ""] })
    if not ok then
      local went = #moved > 0 and ("; %s moved, the rest stay here"):format(table.concat(moved, ", ")) or "; nothing moved"
      return false, message .. went
    end
    there[key .. "/" .. agent.id] = message
    moved[#moved + 1] = ("%s/%s as %s"):format(key, agent.id, message)
  end
  return true, table.concat(moved, ", ")
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
  local wrote, adopted, err = pcall(store.adopt_record, key, record)
  if not wrote or not adopted then
    return false, tostring(wrote and err or adopted)
  end
  local id = adopted.id
  local address = key .. "/" .. id
  local own = store.dir(key) .. "/" .. id
  -- What a failed move leaves here: nothing. Files it put down are removed (what was there before
  -- them put back), its worktree is unregistered, and the sender keeps the agent.
  local placed, aside = {}, {}
  local function undo(why)
    pcall(panes.stop, key, id)
    -- Its supervisor writes its journal and queue as it exits: gone first.
    local sock = require("isovim.acp").socket(key, id)
    vim.wait(5000, function()
      return not vim.uv.fs_stat(sock) and not panes.running(key, id)
    end, 50)
    os.remove(store.record_file(key, id))
    vim.fn.delete(own, "rf")
    for _, path in ipairs(placed) do
      vim.fn.delete(path, "rf")
    end
    for _, kept in ipairs(aside) do
      vim.uv.fs_rename(kept[2], kept[1])
    end
    local base = repo and require("isovim.repos").dir(repo) .. "/base-clone"
    if base and is_dir(base) then
      run_git(base, { "worktree", "prune" })
    end
    vim.fn.delete(stage, "rf")
    return false, why .. "; nothing of it is kept here"
  end
  -- Everything is checked where it lands against what the sender listed; an error partway
  -- (isovim's own) undoes it the same way.
  local function rest_unsafe(unit)
    return ("/" .. unit .. "/"):find("/%.%./") ~= nil
  end
  local function place()
    -- Its record, read back as it was written (before its worktree adds to it).
    local saved = store.agent(key, id)
    if not (saved and vim.deep_equal(saved, adopted)) then
      return undo("its record didn't save whole here")
    end
    local made
    if manifest.branch then
      local log = store.run_dir(key) .. "/" .. id .. ".worktree_setup.log"
      vim.fn.mkdir(store.run_dir(key), "p")
      placed[#placed + 1] = log
      local path, branch_or_err = require("isovim.cli.work").ensure_worktree(key, adopted, manifest.branch, log)
      if not path then
        return undo("could not make its worktree here: " .. tostring(branch_or_err))
      end
      made = vim.fs.basename(path)
    end
    -- Its aN/, over the worktree just made (whose own .git stays, as does its aN/w).
    local files = manifest.files
    if files then
      local from = stage .. "/" .. was
      if not is_dir(from) then
        return undo(("its files (%s/) didn't arrive"):format(was))
      end
      if made then
        -- Its worktree's files go in the one made here, whose name has this host's aN (and a host
        -- before named worktrees sent its old aN/w).
        local sent = manifest.worktree or "w"
        vim.fn.delete(from .. "/" .. sent .. "/.git", "rf")
        if vim.uv.fs_lstat(from .. "/w") and sent ~= "w" then
          os.remove(from .. "/w")
        end
        if sent ~= made and is_dir(from .. "/" .. sent) then
          vim.uv.fs_rename(from .. "/" .. sent, from .. "/" .. made)
        end
        files = vim.tbl_map(function(entry)
          if entry.path == "w" and entry.type == "link" then
            return vim.tbl_extend("force", entry, { target = made })
          elseif entry.path == sent or vim.startswith(entry.path, sent .. "/") then
            return vim.tbl_extend("force", entry, { path = made .. entry.path:sub(#sent + 1) })
          end
          return entry
        end, files)
      end
      vim.fn.mkdir(own, "p")
      local copied = vim.system({ "cp", "-pR", from .. "/.", own }, { text = true }):wait()
      if copied.code ~= 0 then
        return undo("could not copy its files in: " .. vim.trim(copied.stderr or ""))
      end
      local mismatch = M.compare(files, own)
      if mismatch then
        return undo("its files didn't arrive whole: " .. mismatch)
      end
    end
    -- Its journal (with its queue file and kept sessions), transcripts and session's transcript:
    -- checked as they arrived, then put in place under its id here, then checked again there.
    local staged, units = manifest.staged or {}, manifest.units or {}
    local mismatch = M.compare(staged, stage)
    if mismatch then
      return undo("its journal and transcripts didn't arrive whole: " .. mismatch)
    end
    local journal = require("isovim.acp.journal")
    local project
    local function target(unit)
      local top, rest = unit:match("^([^/]+)/(.+)$")
      if top == "journal" then
        for _, suffix in ipairs({ ".jsonl", ".queue.json", ".sessions" }) do
          if rest == was .. suffix then
            return journal.dir(key) .. "/" .. id .. suffix
          end
        end
      elseif top == "transcripts" and rest == was .. ".txt" then
        return store.path(key) .. "/transcripts/" .. id .. ".txt"
      elseif top == "claude" and not rest:find("/", 1, true) then
        -- Claude finds a session by the path it runs in, so it goes under that path's project here.
        if not project then
          local cwd = store.agent_dir(key, id)
          vim.fn.mkdir(cwd, "p")
          project = panes.claude_project(cwd)
        end
        return project .. "/" .. rest
      elseif top == "codex" then
        return panes.codex_sessions .. "/" .. rest
      end
    end
    local where = {}
    for _, unit in ipairs(units) do
      local to = target(unit)
      if not to or rest_unsafe(unit) then
        return undo("the move sent " .. unit .. ", which has no place here")
      end
      where[unit] = to
      -- What's there already (an older copy of its session, from a move here before) is put back
      -- if this fails, and replaced if it doesn't.
      if vim.uv.fs_lstat(to) then
        local kept = to .. ".before-move"
        vim.fn.delete(kept, "rf")
        local renamed, rename_err = vim.uv.fs_rename(to, kept)
        if not renamed then
          return undo(("could not set aside %s: %s"):format(to, tostring(rename_err)))
        end
        aside[#aside + 1] = { to, kept }
      end
      placed[#placed + 1] = to
      vim.fn.mkdir(vim.fs.dirname(to), "p")
      local copied = vim.system({ "cp", "-pR", stage .. "/" .. unit, to }, { text = true }):wait()
      if copied.code ~= 0 then
        return undo(("could not copy in its %s: %s"):format(unit, vim.trim(copied.stderr or "")))
      end
    end
    mismatch = M.compare(staged, function(path)
      for unit, to in pairs(where) do
        if path == unit or path:sub(1, #unit + 1) == unit .. "/" then
          return to .. path:sub(#unit + 1)
        end
      end
      return stage .. "/" .. path
    end)
    if mismatch then
      return undo("its journal and transcripts didn't copy in whole: " .. mismatch)
    end
    -- Its session id, read back.
    local session = adopted.session
    if session then
      vim.fn.mkdir(store.run_dir(key), "p")
      local to = store.run_dir(key) .. "/" .. id .. ".session"
      placed[#placed + 1] = to
      if vim.fn.writefile({ session }, to) ~= 0 or store.session_id(key, id) ~= session then
        return undo("could not save its session id here")
      end
    end
    local renamed = id ~= was and (" (%s was taken here)"):format(was) or ""
    local checked = ("; its %d files checked"):format(#(files or {}) + #staged)
    -- One that was running starts here, and its supervisor answers, or the move fails and it stays
    -- running there.
    local resumed = ""
    if manifest.running then
      local started = panes.start(key, adopted, store.agent_dir(key, id))
      if started.code ~= 0 then
        return undo("it didn't start here: " .. vim.trim((started.stderr or "") .. (started.stdout or "")))
      end
      local up, why = answers(key, adopted)
      if not up then
        return undo(why)
      end
      resumed = "; resumed"
    end
    for _, kept in ipairs(aside) do
      vim.fn.delete(kept[2], "rf")
    end
    vim.fn.delete(stage, "rf")
    return true, ("%s is here%s%s%s"):format(address, renamed, resumed, checked)
  end
  local ran, ok, message = pcall(place)
  if not ran then
    return undo("isovim failed partway here: " .. tostring(ok))
  end
  return ok, message
end


return M
