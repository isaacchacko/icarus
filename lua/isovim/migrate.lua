-- The one-time move of the old ~/iso/_/ (general's key before it was "general") to general/ and
-- root/. Agents in no repo used to live in _/ and be addressed _/aN, the host root among them; now
-- they live in general/ (general/aN) and the host root in root/ (root/aN). The TUI's start and every
-- iso command call M.run, which costs one stat when there's nothing to move, and is safe to run any
-- number of times: it takes a lock, and once _/ is gone there's nothing left to do.
--
-- Each agent in _/ goes to root/ when it holds the root role (a script pane goes with the agent it
-- runs for), else to general/. Its number stays unless the folder it goes to has had that number
-- already (a record, an aN/ dir, or its iso/next past it), and then it takes the next free one.
-- What it moves: the record (iso/agents/aN.json, its id, name, of and parent updated), aN/ (its
-- worktree repaired, if it has one), the journal and the sessions it kept (iso/journal/aN.jsonl,
-- aN.sessions/), its transcript, and its run dir files (run/_/aN.* to run/<key>/aN.*). Then every
-- reference to an old address: other agents' parent fields, rootmode.json, ~/.isovim/root, and the
-- question surfaces routed to a moved root. Nothing in general/ or root/ is ever overwritten: a
-- file whose place is taken is kept under ~/.isovim/migrate-leftover-<time>/.
--
-- A running agent is stopped first and started again at its new address, where it resumes its
-- session (and Claude's transcript of it is copied to where Claude looks for the new dir). One that
-- is mid-turn or waiting on a question isn't cut off: the whole move waits (deferred) until none
-- is, and the next start or iso command tries again; so does one while a running agent's claude (or
-- codex) isn't logged in here (isovim.auth), as it would restart unable to work. old _/aN addresses keep working: the move's
-- map (~/.isovim/migrated.json) says where each went (store.canon_address). Every step is logged to
-- ~/.isovim/migrate.log.
local store = require("isovim.store")

local M = {}

M.log_file = store.root .. "/migrate.log"
M.lock = store.root .. "/migrate.lock"
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

-- Whether there's an old _/ to move.
function M.pending()
  return is_dir(old_dir())
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
      local repaired = vim.system({ "git", "-C", w, "worktree", "repair" }, { text = true }):wait()
      log(("repaired the worktree %s: %s"):format(w, repaired.code == 0 and "ok" or vim.trim(repaired.stderr or "")))
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

-- Moves an old _/ if there is one. opts.wait: seconds to wait for another process's move (default
-- 20); opts.force: move even with an agent mid-turn. Returns "none", "done", "deferred" or "locked",
-- and on "done" the map of old addresses to new ones.
---@param opts? {wait?: number, force?: boolean}
---@return "none"|"done"|"deferred"|"locked", table<string, string>?
function M.run(opts)
  if not M.pending() then
    return "none"
  end
  vim.fn.mkdir(store.root, "p")
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
    if not M.pending() then
      return "none"
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
