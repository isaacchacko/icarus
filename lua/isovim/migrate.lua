-- The one-time moves of the old work root, ~/iso, to ~/.iso (move_work, first), and of the old _/
-- (general's key before it was "general") to general/ and root/. Agents in no repo used to live in
-- _/ and be addressed _/aN, the host root among them; now they live in general/ (general/aN) and the
-- host root in root/ (root/aN). The TUI's start and every iso command call M.run, which costs a stat
-- or two when there's nothing to move, and is safe to run any number of times: it takes a lock, and
-- once ~/iso and _/ are gone there's nothing left to do. Run inside an agent, whose stop would end
-- it partway, it starts `iso __migrate` apart from the agent's processes instead.
--
-- The work root moves whole: a rename, every agent at the same address. Its running chat agents
-- stop and start again from ~/.iso, as the agents in _/ do below (waiting the same way), and its
-- worktrees are repaired; terminals, commands and script panes keep running. Until it has moved,
-- ~/iso stays the work root (store.refresh_work).
--
-- Each agent in _/ goes to root/ when it holds the root role (a script pane goes with the agent it
-- runs for), else to general/. Its number stays unless the folder it goes to has had that number
-- already (a record, an aN/ dir, or its iso/next past it), and then it takes the next free one.
-- What it moves: the record (iso/agents/aN.json, its id, name, of and parent updated), aN/ (its
-- worktree repaired, if it has one), the journal and the sessions it kept (iso/journal/aN.jsonl,
-- aN.sessions/), its transcript, and its run dir files (run/_/aN.* to run/<key>/aN.*). Then every
-- reference to an old address: other agents' parent fields, rootmode.json, ~/.isovim/root, and the
-- question surfaces a moved agent asked. Nothing in general/ or root/ is ever overwritten: a
-- file whose place is taken is kept under ~/.isovim/migrate-leftover-<time>/.
--
-- A running agent is stopped first and started again at its new address, where it resumes its
-- session (and Claude's transcript of it is copied to where Claude looks for the new dir). One that
-- is mid-turn or waiting on a question isn't cut off: the whole move waits (deferred) until none
-- is, and the next start or iso command tries again; so does one while a running agent's claude (or
-- codex) isn't logged in here (isovim.auth), as it would restart unable to work. While it waits, _/
-- stays fully live as a key of its own (store.old_live): its agents are listed, addressed and
-- messaged at _/aN, and the root among them holds the role. Once moved, old _/aN addresses keep
-- working: the move's map (~/.isovim/migrated.json) says where each went (store.canon_address).
-- Every step is logged to ~/.isovim/migrate.log.
--
-- Then the agents' worktrees: every one was aN/w until each was named for its agent, aN/<repo>-aN
-- (store.worktree_name), so setup scripts that name a compose project, ports or hostnames after the
-- checkout's dir stop giving every agent's stack the same ones. Each old one moves to its name once
-- (M.name_worktrees), with aN/w left a symlink to it, so whatever still says w keeps working: a
-- running agent's cwd, its shells' and script panes' (the dir moves under them), records and habits.
-- One whose agent is mid-turn waits, as the moves above do, for a later command or start, and so
-- does one a script pane of its is still running in, or a compose stack runs from (docker ps): its
-- dev server's watchers and its containers' bind mounts name the old path.
local store = require("isovim.store")

local M = {}

M.log_file = store.root .. "/migrate.log"
M.lock = store.migrate_lock
local OLD = "_"
-- A lock older than this was left by a process that died.
local STALE = 300
-- States in which an agent is in the middle of something a restart would cut off.
local BUSY = { working = true, checking = true, waiting = true }

local function old_dir()
  return store.work .. "/" .. OLD
end

local function lstat(path)
  return vim.uv.fs_lstat(path)
end

local function is_dir(path)
  local stat = lstat(path)
  return stat ~= nil and stat.type == "directory"
end

-- Whether there's an old work root or an old _/ to move.
function M.pending()
  return store.old_work_live() or is_dir(old_dir())
end

-- Whether a move is going on now (the reaper waits for it).
function M.busy()
  local stat = vim.uv.fs_stat(M.lock)
  return stat ~= nil and os.time() - stat.mtime.sec < STALE
end

local function log(line)
  vim.fn.mkdir(store.root, "p")
  local file = io.open(M.log_file, "a")
  if file then
    file:write(("%s [%d] %s\n"):format(os.date("!%Y-%m-%dT%H:%M:%SZ"), vim.uv.os_getpid(), line))
    file:close()
  end
end
M.log = log

local function read_json(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  local decoded, value = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  return decoded and type(value) == "table" and value or nil
end

local function write_json(path, value)
  local tmp = ("%s.%d.tmp"):format(path, vim.uv.os_getpid())
  vim.fn.writefile({ vim.json.encode(value) }, tmp)
  assert(vim.uv.fs_rename(tmp, path))
end

local function number(name)
  return tonumber((name or ""):match("^a(%d+)$"))
end

local function names(dir)
  local list = {}
  for name in vim.fs.dir(dir) do
    list[#list + 1] = name
  end
  table.sort(list)
  return list
end

local leftover_dir
-- Where something whose place was taken is kept, under its path relative to base.
local function keep_aside(path, relative)
  leftover_dir = leftover_dir or (store.root .. "/migrate-leftover-" .. os.date("!%Y%m%dT%H%M%SZ"))
  local dest = leftover_dir .. "/" .. relative
  vim.fn.mkdir(vim.fs.dirname(dest), "p")
  local ok, err = vim.uv.fs_rename(path, dest)
  log(ok and ("kept %s aside as %s (its place was taken)"):format(path, dest) or ("could not keep %s aside: %s"):format(path, err))
end

-- Moves from to to, never over something: a dir goes in entry by entry when to is a dir already;
-- what can't go is kept aside. relative names it for the leftover dir.
local function merge(from, to, relative)
  local stat = lstat(from)
  if not stat then
    return
  end
  local there = lstat(to)
  if not there then
    vim.fn.mkdir(vim.fs.dirname(to), "p")
    local ok, err = vim.uv.fs_rename(from, to)
    if ok then
      log(("moved %s to %s"):format(from, to))
    else
      log(("could not move %s to %s: %s"):format(from, to, err))
      keep_aside(from, relative)
    end
  elseif stat.type == "directory" and there.type == "directory" then
    for _, name in ipairs(names(from)) do
      merge(from .. "/" .. name, to .. "/" .. name, relative .. "/" .. name)
    end
    vim.uv.fs_rmdir(from)
  else
    keep_aside(from, relative)
  end
end

-- _/aN, and <host>:_/aN for this host, in text, as map has them now. An address stands alone: not
-- after a letter, digit or one of "_./-", nor followed by a letter or digit.
local function rewrite(text, map, self)
  return (text:gsub("()_/a(%d+)()", function(s, digits, e)
    local before, after = text:sub(s - 1, s - 1), text:sub(e, e)
    if before:match("[%w_./%-]") or after:match("[%w]") then
      return nil
    elseif before == ":" then
      local host = text:sub(1, s - 2):match("([%w_.-]+)$")
      if host and host ~= self and host ~= vim.fn.hostname() then
        return nil
      end
    end
    return map["_/a" .. digits]
  end))
end
M.rewrite = rewrite

local function rewrite_file(path, map, self)
  local file = io.open(path, "rb")
  if not file then
    return
  end
  local text = file:read("*a")
  file:close()
  local new = rewrite(text, map, self)
  if new ~= text then
    local tmp = ("%s/.%s.%d.tmp"):format(vim.fs.dirname(path), vim.fs.basename(path), vim.uv.os_getpid())
    local out = assert(io.open(tmp, "wb"))
    out:write(new)
    out:close()
    assert(vim.uv.fs_rename(tmp, path))
    log("updated the addresses in " .. path)
  end
end

-- An address field (parent): _/aN, or this host's <host>:_/aN, as it is now.
local function remap(address, map, self)
  if type(address) ~= "string" then
    return nil
  end
  local host, rest = address:match("^([^:]+):(.*)$")
  if host and host ~= self and host ~= vim.fn.hostname() then
    return address
  end
  local moved = map[rest or address]
  return moved and ((host and host .. ":" or "") .. moved) or address
end

-- The numbers a key's folder has given out: its records, aN/ dirs and journals, and its counter.
local function taken_in(key)
  local taken, top = {}, -1
  local dir = store.key_dir(key)
  for _, sub in ipairs({ dir, dir .. "/iso/agents", dir .. "/iso/journal" }) do
    for name in vim.fs.dir(sub) do
      local n = number((name:gsub("%.json$", ""):gsub("%.jsonl$", ""):gsub("%.sessions$", "")))
      if n then
        taken[n] = true
        top = math.max(top, n)
      end
    end
  end
  local ok, lines = pcall(vim.fn.readfile, dir .. "/iso/next")
  local next_n = ok and tonumber(lines[1]) or 0
  return taken, math.max(next_n, top + 1), next_n
end

-- Copies Claude's transcripts of the agent's sessions to the project dir Claude keeps for new_dir,
-- so resuming them from there finds them (Claude files a session under the dir it ran in).
local function copy_claude_sessions(record, new_dir)
  local ids = {}
  if type(record.session) == "string" then
    ids[#ids + 1] = record.session
  end
  for _, entry in ipairs(type(record.sessions) == "table" and record.sessions or {}) do
    if type(entry) == "table" and type(entry.id) == "string" then
      ids[#ids + 1] = entry.id
    end
  end
  if #ids == 0 then
    return
  end
  local config = vim.env.CLAUDE_CONFIG_DIR or vim.fs.normalize("~/.claude")
  local projects = config .. "/projects"
  local real = vim.uv.fs_realpath(new_dir) or new_dir
  local dest = projects .. "/" .. real:gsub("[^%w]", "-")
  for _, id in ipairs(ids) do
    if id:match("^[%w-]+$") then
      for _, path in ipairs(vim.fn.glob(projects .. "/*/" .. id .. ".jsonl", false, true)) do
        local target = dest .. "/" .. id .. ".jsonl"
        if vim.fs.dirname(path) ~= dest and not lstat(target) then
          vim.fn.mkdir(dest, "p")
          local ok = vim.uv.fs_copyfile(path, target)
          log(ok and ("copied Claude's transcript of session %s to %s"):format(id, target)
            or ("could not copy Claude's transcript %s to %s"):format(path, target))
          local side = path:sub(1, -7)
          if is_dir(side) and not lstat(dest .. "/" .. id) then
            vim.system({ "cp", "-R", side, dest .. "/" .. id }):wait()
          end
        end
      end
    end
  end
end

-- A worktree moved from old_w to w, made known to its repo again. Run in the worktree, git finds the
-- repo by the worktree's .git file and fixes the repo's link back; a .git file with a relative path
-- (worktree.useRelativePaths) no longer reaches the repo from here, so then it's run from the repo,
-- found from where the worktree was.
local function repair_worktree(w, old_w)
  local repaired = vim.system({ "git", "-C", w, "worktree", "repair" }, { text = true }):wait()
  if repaired.code ~= 0 then
    local ok, lines = pcall(vim.fn.readfile, w .. "/.git")
    local gitdir = ok and (lines[1] or ""):match("^gitdir:%s*(.-)%s*$")
    if gitdir and not vim.startswith(gitdir, "/") then
      gitdir = vim.fs.normalize(old_w .. "/" .. gitdir)
    end
    local common = gitdir and gitdir:match("^(.*)/worktrees/[^/]+$")
    if common then
      repaired = vim.system({ "git", "--git-dir", common, "worktree", "repair", w }, { text = true }):wait()
    end
  end
  log(("repaired the worktree %s: %s"):format(w, repaired.code == 0 and "ok" or vim.trim(repaired.stderr or "")))
end

-- The move itself, under the lock. Returns "done" or "deferred".
local function move(opts)
  local panes = require("isovim.panes")
  local events = require("isovim.events")
  local self = require("isovim.remote").self()
  local old = old_dir()
  local old_iso = old .. "/iso"
  local old_run = store.run .. "/" .. OLD
  log(("moving %s (general's old folder) to %s and %s"):format(old, store.key_dir(store.GENERAL), store.key_dir(store.ROOT)))

  -- What's there: records, and aN/ dirs that have none.
  local agents, by_id = {}, {}
  for _, name in ipairs(names(old_iso .. "/agents")) do
    local id = name:match("^(a%d+)%.json$")
    local record = id and read_json(old_iso .. "/agents/" .. name)
    if record then
      record.id = id
      agents[#agents + 1] = { id = id, record = record }
      by_id[id] = agents[#agents]
    end
  end
  for _, name in ipairs(names(old)) do
    if number(name) and not by_id[name] and is_dir(old .. "/" .. name) then
      agents[#agents + 1] = { id = name }
      by_id[name] = agents[#agents]
    end
  end
  table.sort(agents, function(a, b)
    return number(a.id) < number(b.id)
  end)

  -- Which are running, and whether one is in the middle of something.
  for _, agent in ipairs(agents) do
    agent.session = ("iso2-%s+%s"):format(OLD, agent.id)
    agent.running = panes.raw_running(agent.session)
    local file = io.open(old_run .. "/" .. agent.id .. ".state")
    agent.state = file and file:read("*l") or nil
    if file then
      file:close()
    end
    if agent.running and BUSY[agent.state or ""] and not (opts and opts.force) then
      log(("deferred: %s/%s is %s; the move waits until no agent there is mid-turn"):format(OLD, agent.id, agent.state))
      return "deferred"
    end
  end
  -- The move restarts the running ones, and one restarted while its kind isn't logged in here
  -- comes back unable to work: they stay where they are, running, until the login is back.
  for _, agent in ipairs(agents) do
    local blocked = agent.running and agent.record and require("isovim.auth").restart_blocked(agent.record)
    if blocked then
      log(("deferred: %s/%s is running and would restart, but %s; nothing moves until it's logged in"):format(OLD,
        agent.id, blocked))
      return "deferred"
    end
  end

  -- Where each goes: root/ for a root and its script panes, general/ for the rest.
  local function target(agent)
    local record = agent.record
    if record and record.of and by_id[record.of] then
      record = by_id[record.of].record
    end
    return record and record.role == "root" and not record.of and store.ROOT or store.GENERAL
  end
  local plans = {}
  for _, key in ipairs({ store.GENERAL, store.ROOT }) do
    local taken, floor, counter = taken_in(key)
    plans[key] = { taken = taken, floor = floor, counter = counter, top = -1 }
  end
  local map = {}
  for _, agent in ipairs(agents) do
    local key = target(agent)
    local plan = plans[key]
    local n = number(agent.id)
    -- Below the counter, the number was given out there once, even if that agent is gone.
    if plan.taken[n] or n < plan.counter then
      n = nil
    end
    if not n then
      n = plan.floor
      while plan.taken[n] do
        n = n + 1
      end
      log(("%s/%s's number is taken in %s/: it becomes %s/a%d"):format(OLD, agent.id, key, key, n))
    end
    plan.taken[n] = true
    plan.top = math.max(plan.top, n)
    agent.key, agent.new = key, "a" .. n
    map[OLD .. "/" .. agent.id] = key .. "/" .. agent.new
    log(("plan: %s/%s -> %s/%s%s%s"):format(OLD, agent.id, key, agent.new, agent.record and agent.record.role and (" (" .. agent.record.role .. ")") or " (no record)",
      agent.running and (", running, " .. (agent.state or "no state") .. ": it restarts") or ""))
  end

  -- The map first: a command run meanwhile (the stopped agents' tmux hooks) reads old addresses
  -- as the new ones.
  local known = read_json(store.migrated_file) or {}
  for from, to in pairs(map) do
    known[from] = to
  end
  vim.fn.mkdir(store.root, "p")
  write_json(store.migrated_file, next(known) and known or vim.empty_dict())

  -- Running agents stop, marked as stopped by isovim at both addresses so their end isn't
  -- published as one of their own.
  for _, agent in ipairs(agents) do
    if agent.running then
      local pid = panes.raw_pid(agent.session)
      for _, dir in ipairs({ old_run, store.run_dir(agent.key) }) do
        vim.fn.mkdir(dir, "p")
      end
      vim.fn.writefile({}, old_run .. "/" .. agent.id .. ".stopped")
      vim.fn.writefile({}, store.run_dir(agent.key) .. "/" .. agent.new .. ".stopped")
      panes.raw_kill(agent.session)
      local gone = not pid or vim.wait(10000, function()
        return vim.uv.kill(pid, 0) ~= 0
      end, 100)
      if not gone then
        pcall(vim.uv.kill, pid, "sigkill")
      end
      log(("stopped %s/%s (tmux session %s, pane pid %s)"):format(OLD, agent.id, agent.session, tostring(pid)))
    end
  end

  -- Each agent: its record first (so the reaper never finds aN/ without one), then aN/, journal,
  -- transcript and run files.
  for _, agent in ipairs(agents) do
    local key, new = agent.key, agent.new
    local dir = store.key_dir(key)
    local iso = dir .. "/iso"
    if agent.record then
      local record = agent.record
      record.id = new
      if record.name == agent.id then
        record.name = new
      end
      record.repo = nil
      if record.of and by_id[record.of] then
        record.of = by_id[record.of].new
      end
      record.parent = remap(record.parent, map, self)
      vim.fn.mkdir(iso .. "/agents", "p")
      write_json(iso .. "/agents/" .. new .. ".json", record)
      os.remove(old_iso .. "/agents/" .. agent.id .. ".json")
      log(("wrote %s/iso/agents/%s.json (from %s/%s)"):format(key, new, OLD, agent.id))
    end
    merge(old .. "/" .. agent.id, dir .. "/" .. new, OLD .. "/" .. agent.id)
    local w = dir .. "/" .. new .. "/w"
    local dotgit = lstat(w .. "/.git")
    if dotgit and dotgit.type == "file" then
      repair_worktree(w, old .. "/" .. agent.id .. "/w")
    end
    for _, sub in ipairs({ "journal", "transcripts" }) do
      for _, name in ipairs(names(old_iso .. "/" .. sub)) do
        local rest = name:sub(#agent.id + 1)
        if vim.startswith(name, agent.id) and (rest == "" or rest:match("^%.")) then
          merge(old_iso .. "/" .. sub .. "/" .. name, iso .. "/" .. sub .. "/" .. new .. rest, OLD .. "/iso/" .. sub .. "/" .. name)
        end
      end
    end
    for _, name in ipairs(names(old_run)) do
      local rest = name:sub(#agent.id + 1)
      if vim.startswith(name, agent.id) and rest:match("^%.") then
        if rest == ".sock" or rest == ".stopped" then
          os.remove(old_run .. "/" .. name)
        else
          merge(old_run .. "/" .. name, store.run_dir(key) .. "/" .. new .. rest, "run/" .. OLD .. "/" .. name)
        end
      end
    end
    if agent.record and agent.record.kind == "claude" then
      copy_claude_sessions(agent.record, store.agent_dir(key, new))
    end
  end

  -- The counters: past every number given out.
  for key, plan in pairs(plans) do
    if plan.top >= 0 then
      local _, floor = taken_in(key)
      vim.fn.mkdir(store.path(key), "p")
      vim.fn.writefile({ tostring(math.max(floor, plan.top + 1)) }, store.path(key) .. "/next")
      log(("%s/iso/next is %d"):format(key, math.max(floor, plan.top + 1)))
    end
  end

  -- The rest of _/ is general's: its .isovim.json's pins and PRs join general's, everything else
  -- moves in where its place is free.
  local general = store.key_dir(store.GENERAL)
  local old_meta = read_json(old_iso .. "/.isovim.json")
  if old_meta then
    local meta_path = general .. "/iso/.isovim.json"
    local meta = read_json(meta_path) or {}
    for _, field in ipairs({ "pinned", "prs" }) do
      if type(old_meta[field]) == "table" then
        meta[field] = meta[field] or {}
        for _, item in ipairs(old_meta[field]) do
          if not vim.tbl_contains(meta[field], item) then
            table.insert(meta[field], item)
          end
        end
      end
    end
    vim.fn.mkdir(general .. "/iso", "p")
    write_json(meta_path, meta)
    os.remove(old_iso .. "/.isovim.json")
    log("merged " .. OLD .. "/iso/.isovim.json's pins and PRs into general's")
  end
  for _, name in ipairs({ "next", "next.tmp" }) do
    os.remove(old_iso .. "/" .. name)
  end
  vim.uv.fs_rmdir(old_iso .. "/next.lock")
  merge(old, general, OLD)
  if lstat(old) then
    keep_aside(old, OLD)
  end
  -- What's left in run/_ is host-only state of agents that are gone.
  if lstat(old_run) then
    merge(old_run, store.run_dir(store.GENERAL), "run/" .. OLD)
    if lstat(old_run) then
      vim.fn.delete(old_run, "rf")
    end
  end

  -- Every reference to an old address.
  for _, ws in ipairs(store.list()) do
    for _, record in ipairs(store.agents(ws.id)) do
      local parent = remap(record.parent, map, self)
      if parent ~= record.parent then
        store.update_agent(ws.id, record.id, { parent = parent })
        log(("%s/%s's parent is %s now (was %s)"):format(ws.id, record.id, parent, record.parent))
      end
    end
  end
  rewrite_file(require("isovim.rootmode").file, map, self)
  rewrite_file(require("isovim.root").file, map, self)
  local surfaces = require("isovim.surfaces")
  for _, repo in ipairs(surfaces.repos()) do
    for _, path in ipairs(vim.fn.glob(surfaces.dir(repo) .. "/*.surface", false, true)) do
      rewrite_file(path, map, self)
    end
  end

  -- The agents that were running start again where they are now, resuming their sessions.
  for _, agent in ipairs(agents) do
    if agent.running and agent.record then
      local record = store.agent(agent.key, agent.new)
      if record then
        events.publish_agent(agent.key, agent.new, "exited", { reason = "migrated", from = OLD .. "/" .. agent.id })
        local result = panes.start(agent.key, record, store.agent_dir(agent.key, agent.new))
        log(("started %s/%s again (session %s): %s"):format(agent.key, agent.new, tostring(record.session),
          result.code == 0 and "ok" or ("failed: " .. tostring(result.stderr))))
      end
    end
  end
  log("done: " .. OLD .. "/ is gone; " .. vim.inspect(map, { newline = " ", indent = "" }))
  return "done", map
end

-- The keys' folders under dir that have records (iso/agents/), as store's walk finds them.
local function key_folders(dir)
  local found = {}
  local function walk(path, folder, depth)
    if folder and is_dir(path .. "/iso/agents") then
      found[#found + 1] = folder
      return
    end
    if depth == 4 then
      return
    end
    for _, name in ipairs(names(path)) do
      if not vim.startswith(name, ".") and is_dir(path .. "/" .. name) then
        walk(path .. "/" .. name, folder and folder .. "/" .. name or name, depth + 1)
      end
    end
  end
  walk(dir, nil, 0)
  return found
end

-- value with every path under one of froms put under to instead, in its strings at any depth; and
-- whether anything changed.
local function repath(value, froms, to)
  if type(value) == "string" then
    for _, from in ipairs(froms) do
      if value == from or vim.startswith(value, from .. "/") then
        return to .. value:sub(#from + 1), true
      end
    end
    return value, false
  elseif type(value) ~= "table" then
    return value, false
  end
  local changed = false
  for k, v in pairs(value) do
    local new, did = repath(v, froms, to)
    if did then
      value[k], changed = new, true
    end
  end
  return value, changed
end

local function repath_file(path, froms, to)
  local value = lstat(path) and read_json(path)
  if not value then
    return
  end
  local new, changed = repath(value, froms, to)
  if changed then
    write_json(path, new)
    log(("updated the paths in %s"):format(path))
  end
end

-- The move of the old work root, ~/iso, to ~/.iso (store.new_work), under the lock. Agents keep
-- their addresses; only the path changes. A running chat agent is stopped first and started again
-- there, resuming its session (with Claude's transcript copied to the project dir it now runs in),
-- and waits like the move of _/ does: on one mid-turn or a login that's gone. Terminals, commands
-- and script panes keep running: a renamed folder takes their cwd with it. An old _/ goes along,
-- its agents left running for the move of _/ right after, which restarts them where they land.
-- With ~/.iso there already (or a folder left in ~/iso by a process that still had the old path)
-- the two are merged: what's in ~/.iso stays, and what can't go in is kept aside (keep_aside). An
-- agent whose record is in ~/.iso already runs from there, so it isn't stopped. Then the paths
-- kept in records (a spawn's checkout), surfaces, pins, layouts and the TUI's session say ~/.iso.
-- Returns "done" or "deferred".
local function move_work(opts)
  local panes = require("isovim.panes")
  local events = require("isovim.events")
  local from, to = store.old_work, store.new_work
  -- Merged into itself, every file would be kept aside as if its place were taken. A TUI that
  -- reloaded a store from between two versions once had both the same.
  local real = from and vim.uv.fs_realpath(from)
  if not from or from == to or (real and real == vim.uv.fs_realpath(to)) then
    log(("refused to move the work root %s onto itself (%s)"):format(tostring(from), to))
    return "done"
  end
  log(("moving the work root %s to %s"):format(from, to))

  local agents = {}
  for _, folder in ipairs(key_folders(from)) do
    for _, name in ipairs(names(from .. "/" .. folder .. "/iso/agents")) do
      local id = name:match("^(a%d+)%.json$")
      local record = id and read_json(from .. "/" .. folder .. "/iso/agents/" .. name)
      if record then
        local key = store.folder_key(folder)
        local old = key == OLD
        local agent = { folder = folder, key = key, id = id, record = record }
        local there = lstat(to .. "/" .. folder .. "/iso/agents/" .. name) ~= nil
        agent.session = old and ("iso2-%s+%s"):format(OLD, id) or panes.encode(key, id)
        agent.live = not there and record.kind ~= "terminal" and record.kind ~= "command" and not record.of
          and panes.raw_running(agent.session)
        agent.restarts = agent.live and not old
        local file = io.open((old and store.run .. "/" .. OLD or store.run_dir(key)) .. "/" .. id .. ".state")
        agent.state = file and file:read("*l") or nil
        if file then
          file:close()
        end
        agents[#agents + 1] = agent
      end
    end
  end
  -- One in _/ isn't stopped here, but the move of _/ right after restarts it, and would wait on it.
  for _, agent in ipairs(agents) do
    if agent.live and BUSY[agent.state or ""] and not (opts and opts.force) then
      log(("deferred: %s/%s is %s; the move waits until no agent there is mid-turn"):format(agent.key, agent.id, agent.state))
      return "deferred"
    end
    local blocked = agent.live and require("isovim.auth").restart_blocked(agent.record)
    if blocked then
      log(("deferred: %s/%s is running and would restart, but %s; nothing moves until it's logged in"):format(agent.key,
        agent.id, blocked))
      return "deferred"
    end
  end

  for _, agent in ipairs(agents) do
    if agent.restarts then
      local pid = panes.raw_pid(agent.session)
      vim.fn.mkdir(store.run_dir(agent.key), "p")
      vim.fn.writefile({}, panes.stopped_file(agent.key, agent.id))
      panes.raw_kill(agent.session)
      local gone = not pid or vim.wait(10000, function()
        return vim.uv.kill(pid, 0) ~= 0
      end, 100)
      if not gone then
        pcall(vim.uv.kill, pid, "sigkill")
      end
      log(("stopped %s/%s (tmux session %s, pane pid %s)"):format(agent.key, agent.id, agent.session, tostring(pid)))
    end
  end

  -- Whatever goes wrong, the agents it stopped start again, wherever they are then.
  local moved, err = pcall(function()
    -- The old root's paths as they may be kept: as given, as it resolves, and from ~.
    local froms = { from }
    local real = vim.uv.fs_realpath(from)
    if real and real ~= from then
      froms[#froms + 1] = real
    end
    local home = vim.fs.normalize("~")
    if vim.startswith(from, home .. "/") then
      froms[#froms + 1] = "~" .. from:sub(#home + 1)
    end
    -- The agents' worktrees (aN/<repo>-aN, or an old aN/w; not the w symlink), by where they are now.
    local worktrees = {}
    for _, folder in ipairs(key_folders(from)) do
      for _, name in ipairs(names(from .. "/" .. folder)) do
        local own = from .. "/" .. folder .. "/" .. name
        for _, sub in ipairs(number(name) and is_dir(own) and names(own) or {}) do
          if is_dir(own .. "/" .. sub) and lstat(own .. "/" .. sub .. "/.git") then
            worktrees[#worktrees + 1] = folder .. "/" .. name .. "/" .. sub
          end
        end
      end
    end

    if lstat(to) then
      merge(from, to, "work")
    else
      vim.fn.mkdir(vim.fs.dirname(to), "p")
      local ok, err = vim.uv.fs_rename(from, to)
      log(ok and ("moved %s to %s"):format(from, to) or ("could not move %s to %s (%s): merging it in"):format(from, to, err))
      if not ok then
        merge(from, to, "work")
      end
    end
    if lstat(from) then
      keep_aside(from, "work")
    end
    store.refresh_work()

    for _, rel in ipairs(worktrees) do
      local dotgit = lstat(to .. "/" .. rel .. "/.git")
      if dotgit and dotgit.type == "file" then
        repair_worktree(to .. "/" .. rel, from .. "/" .. rel)
      end
    end
    for _, folder in ipairs(key_folders(to)) do
      local iso = to .. "/" .. folder .. "/iso"
      for _, name in ipairs(names(iso .. "/agents")) do
        if name:match("^a%d+%.json$") then
          repath_file(iso .. "/agents/" .. name, froms, to)
        end
      end
      for _, name in ipairs(names(iso)) do
        if name:match("%.surface$") or name == ".isovim.json" or name == "layout.json" then
          repath_file(iso .. "/" .. name, froms, to)
        end
      end
      -- Merged, a folder's counter may be below a number the other side gave out.
      local key = store.folder_key(folder)
      if key ~= OLD then
        local _, floor, counter = taken_in(key)
        if floor > counter then
          vim.fn.writefile({ tostring(floor) }, iso .. "/next")
          log(("%s/iso/next is %d"):format(key, floor))
        end
      end
    end
    repath_file(store.session_file, froms, to)

    for _, agent in ipairs(agents) do
      if agent.record.kind == "claude" and agent.key ~= OLD then
        copy_claude_sessions(agent.record, store.agent_dir(agent.key, agent.id))
      end
    end
  end)
  store.refresh_work()

  for _, agent in ipairs(agents) do
    if agent.restarts then
      local record = store.agent(agent.key, agent.id)
      if record then
        events.publish_agent(agent.key, agent.id, "exited", { reason = "migrated", from = from })
        local result = panes.start(agent.key, record, store.agent_dir(agent.key, agent.id))
        log(("started %s/%s again (session %s): %s"):format(agent.key, agent.id, tostring(record.session),
          result.code == 0 and "ok" or ("failed: " .. tostring(result.stderr))))
      end
    end
  end
  if not moved then
    error(err)
  end
  log(("done: the work root is %s"):format(to))
  return "done"
end

M.named_file = store.root .. "/worktrees-named"
local naming_lock = store.root .. "/worktrees-naming.lock"
-- While one waits, a pass runs at most this often (every iso command would try).
local NAMING_EVERY = 30

-- Whether old aN/w worktrees may be left to name: until a pass finds none, which a stat says after.
function M.naming_pending()
  return vim.uv.fs_stat(M.named_file) == nil
end

-- Moves each old aN/w worktree to its name and links aN/w to it (see the top of this file); the
-- one of an agent mid-turn is left for the next pass. Returns how many moved and how many wait.
---@return integer moved, integer waiting
function M.name_worktrees()
  if not M.naming_pending() then
    return 0, 0
  end
  local last = vim.uv.fs_stat(naming_lock .. ".last")
  if last and os.time() - last.mtime.sec < NAMING_EVERY then
    return 0, 1
  end
  vim.fn.mkdir(store.root, "p")
  if not vim.uv.fs_mkdir(naming_lock, 448) then
    local stat = vim.uv.fs_stat(naming_lock)
    if not (stat and os.time() - stat.mtime.sec > STALE) then
      return 0, 1
    end
    log("took over a stale lock " .. naming_lock)
  end
  local panes, work, status = require("isovim.panes"), require("isovim.cli.work"), require("isovim.status")
  local moved, waiting = 0, 0
  local ok, err = pcall(function()
    -- The dirs running compose stacks were brought up from, asked once there's a worktree to name.
    local stacks
    -- Whether w is in use: a compose stack runs from it, a script pane of its agent is running, or
    -- its agent is mid-turn.
    local function in_use(key, id, w)
      if not stacks then
        stacks = {}
        local ps = vim.fn.executable("docker") == 1 and vim.system({ "docker", "ps", "--format",
          '{{.Label "com.docker.compose.project.working_dir"}}' }, { text = true, timeout = 3000 }):wait()
        for dir in (ps and ps.code == 0 and ps.stdout or ""):gmatch("[^\n]+") do
          stacks[#stacks + 1] = vim.uv.fs_realpath(dir) or dir
        end
      end
      local real = vim.uv.fs_realpath(w) or w
      for _, dir in ipairs(stacks) do
        if dir == real or vim.startswith(dir, real .. "/") then
          return true
        end
      end
      for _, pane in ipairs(store.agents(key)) do
        if pane.of == id and BUSY[status.state(key, pane.id) or ""] and panes.running(key, pane.id) then
          return true
        end
      end
      return BUSY[status.state(key, id) or ""] and panes.running(key, id)
    end
    for _, ws in ipairs(store.list()) do
      for _, record in ipairs(store.v2(ws.id) and store.agents(ws.id) or {}) do
        local own = store.dir(ws.id) .. "/" .. record.id
        local w = own .. "/w"
        local stat = lstat(w)
        local dotgit = stat and stat.type == "directory" and lstat(w .. "/.git")
        if dotgit and dotgit.type == "file" then
          local name = store.worktree_name(ws.id, record.id)
          local busy = not record.of and in_use(ws.id, record.id, w)
          if busy then
            waiting = waiting + 1
          elseif lstat(own .. "/" .. name) then
            log(("left %s as it is: %s/%s is there already"):format(w, own, name))
          else
            local named = own .. "/" .. name
            local common = vim.system({ "git", "-C", w, "rev-parse", "--path-format=absolute", "--git-common-dir" },
              { text = true }):wait()
            local result = common.code == 0
              and vim.system({ "git", "--git-dir", vim.trim(common.stdout), "worktree", "move", w, named }, { text = true }):wait()
              or common
            if result.code ~= 0 then
              -- git won't move one with submodules: a rename, and git told where it went.
              local renamed, rename_err = vim.uv.fs_rename(w, named)
              if renamed then
                repair_worktree(named, w)
              else
                log(("could not name the worktree %s (%s; %s)"):format(w, vim.trim(result.stderr or ""), tostring(rename_err)))
              end
            end
            if lstat(named) then
              work.link_w(own, name)
              moved = moved + 1
              log(("named the worktree %s: %s, with w linked to it"):format(w, named))
            end
          end
        end
      end
    end
  end)
  vim.fn.writefile({}, naming_lock .. ".last")
  vim.uv.fs_rmdir(naming_lock)
  if not ok then
    log("naming the worktrees failed: " .. tostring(err))
    return moved, waiting + 1
  end
  if waiting == 0 then
    vim.fn.writefile({ os.date("!%Y-%m-%dT%H:%M:%SZ") }, M.named_file)
    log("every worktree is named")
  end
  return moved, waiting
end

-- Moves an old work root and an old _/ if there are. opts.wait: seconds to wait for another
-- process's move (default 20); opts.force: move even with an agent mid-turn. Returns "none", "done",
-- "deferred" or "locked", and on "done" the map of old addresses to new ones (empty when only the
-- work root moved).
---@param opts? {wait?: number, force?: boolean}
---@return "none"|"done"|"deferred"|"locked", table<string, string>?
function M.run(opts)
  if not M.pending() then
    store.refresh_work()
    pcall(M.name_worktrees)
    return "none"
  end
  vim.fn.mkdir(store.root, "p")
  -- Inside an agent (a hook, or a command it runs) the move would stop the agent, and this process
  -- with it, partway through: it's left to one of its own, out of the agent's process tree, started
  -- at most every 10s.
  if (vim.env.ISOVIM_ADDR or "") ~= "" and not M.busy() then
    local stamp = store.run .. "/migrate.started"
    local stat = vim.uv.fs_stat(stamp)
    if not stat or os.time() - stat.mtime.sec >= 10 then
      vim.fn.mkdir(store.run, "p")
      vim.fn.writefile({}, stamp)
      log("started the move apart from " .. vim.env.ISOVIM_ADDR .. ", as it runs inside an agent")
      pcall(vim.system, { require("isovim.panes").bin, "__migrate" },
        { detach = true, stdin = false, stdout = false, stderr = false, env = { ISOVIM_ADDR = "" } })
    end
    return "deferred"
  elseif (vim.env.ISOVIM_ADDR or "") ~= "" then
    return "locked"
  end
  local deadline = vim.uv.hrtime() + (opts and opts.wait or 20) * 1e9
  while not vim.uv.fs_mkdir(M.lock, 448) do
    local stat = vim.uv.fs_stat(M.lock)
    if stat and os.time() - stat.mtime.sec > STALE then
      log("took over a stale lock " .. M.lock)
      vim.uv.fs_rmdir(M.lock)
    elseif vim.uv.hrtime() > deadline then
      return "locked"
    else
      vim.uv.sleep(100)
    end
  end
  local ok, result, map = pcall(function()
    store.refresh_work()
    local moved = "none"
    if store.old_work_live() then
      moved = move_work(opts)
      if moved == "deferred" then
        return "deferred"
      end
    end
    if not is_dir(old_dir()) then
      return moved, moved == "done" and vim.empty_dict() or nil
    end
    return move(opts)
  end)
  vim.uv.fs_rmdir(M.lock)
  if not ok then
    log("failed: " .. tostring(result))
    return "deferred"
  end
  return result, map
end

return M
