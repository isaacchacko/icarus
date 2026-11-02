-- The end of a new-layout agent's life. Removing one (iso rm, d in the sidebar) tears it down: its
-- script panes stop, its repo's teardown script runs in its work dir (its worktree aN/<repo>-aN, an
-- old one's aN/w, else aN), its worktree is removed from the clone it came from (`git worktree remove
-- --force`: unsaved work is discarded) and aN/ is deleted. The reaper looks every 10 minutes for aN/
-- dirs under the work root with no record (<key>/iso/agents/aN.json) and would tear those down too; until v0 is cut over it runs dry, only
-- writing what it would do to ~/.isovim/reaper.log ("reaper": "live" in config.json, or
-- `iso reap --live`, lets it act). A workspace's agents keep their own way out (store.archive_workspace).
--
-- Every removal is guarded: the dir must really be <work>/<key>/aN (its realpath, with no symlink on
-- the way), a symlink is only ever unlinked and never followed, and a repo's base clone is never
-- touched, only told to forget a worktree it no longer has.
local store = require("isovim.store")

local M = {}

M.reaper_log = store.root .. "/reaper.log"
M.interval = tonumber(vim.env.ISOVIM_REAP_INTERVAL or "") or 600
local MAX_LOG = 256 * 1024
-- An aN/ is made a moment before its record is written (store.take_number), so a young one is left be.
M.grace = tonumber(vim.env.ISOVIM_REAP_GRACE or "") or 600

local function git(dir, args)
  return vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true, timeout = 60000 }):wait()
end

local function lstat(path)
  return vim.uv.fs_lstat(path)
end

local function real(path)
  return vim.uv.fs_realpath(path)
end

local function is_agent_id(id)
  return type(id) == "string" and id:match("^a%d+$") ~= nil
end

-- <work>/<key>/aN when that's what path really is: no symlink anywhere on the way (the work root
-- itself may be one), and inside the work root. nil, why otherwise.
---@return string? path, string? why
function M.agent_path(key, id)
  key = store.canon(key)
  if not (is_agent_id(id) and store.valid_key(key)) then
    return nil, ("%s/%s is not an agent's address"):format(tostring(key), tostring(id))
  end
  local work = real(store.work)
  if not work then
    return nil, "the work root " .. store.work .. " is missing"
  end
  local folder = store.key_folder(key)
  local path = store.work .. "/" .. folder .. "/" .. id
  local stat = lstat(path)
  if not stat then
    return nil, path .. " is gone"
  elseif stat.type == "link" then
    return path, "link"
  elseif stat.type ~= "directory" then
    return nil, path .. " is not a dir"
  end
  if real(path) ~= work .. "/" .. folder .. "/" .. id then
    return nil, ("%s resolves to %s, outside %s/%s"):format(path, tostring(real(path)), work, folder)
  end
  return path
end

-- Whether path is, or is inside, any repo's base clone.
local function in_base_clone(path)
  local resolved = real(path)
  local repos = real(store.root .. "/repos")
  if not (resolved and repos and vim.startswith(resolved, repos .. "/")) then
    return false
  end
  return ("/" .. resolved:sub(#repos + 2) .. "/"):find("/base-clone/", 1, true) ~= nil
end

-- What tearing down <key>/<id> involves, without doing any of it.
---@return {path: string, link?: boolean, worktree?: string, common?: string, teardown?: string, cwd: string}? plan, string? why
function M.plan(key, id, record)
  local path, why = M.agent_path(key, id)
  if not path then
    return nil, why
  end
  if why == "link" then
    return { path = path, link = true, cwd = path }
  end
  local plan = { path = path, cwd = path }
  -- The worktree's own dir, never the aN/w symlink to it.
  local w
  for _, name in ipairs({ store.worktree_name(key, id), "w" }) do
    local stat = lstat(path .. "/" .. name)
    if not w and stat and stat.type == "directory" then
      w = path .. "/" .. name
    end
  end
  if w and not in_base_clone(w) then
    plan.cwd = w
    -- A linked worktree has a .git file naming its clone; anything else is just files.
    local dotgit = lstat(w .. "/.git")
    if dotgit and dotgit.type == "file" then
      local common = git(w, { "rev-parse", "--path-format=absolute", "--git-common-dir" })
      plan.worktree = w
      plan.common = common.code == 0 and vim.trim(common.stdout) or nil
    end
  end
  -- A script pane has nothing of its own to tear down.
  if not (record and record.of) then
    local repo = record and record.repo or (not store.is_pseudo(key) and store.valid_key(key) and key or nil)
    local name = record and record.name or id
    -- Looked up only: an agent's dir never imports its own scripts into the repo's config.
    plan.teardown = require("isovim.scripts").line(plan.cwd, require("isovim.worktree").repo_of(plan.cwd) or plan.cwd, name,
      "teardown", repo, true, repo and store.worktree_name(key, id) or nil)
  end
  return plan
end

-- Carries out a plan: the teardown script, the worktree, aN/. Returns what was done, as lines.
---@return string[] done
local function carry_out(plan)
  local done = {}
  if plan.link then
    os.remove(plan.path)
    done[#done + 1] = "unlinked " .. plan.path
    return done
  end
  if plan.teardown then
    local result = vim.system({ "sh", "-c", plan.teardown }, { cwd = plan.cwd, text = true, timeout = 120000 }):wait()
    done[#done + 1] = ("ran teardown in %s (exit %s)"):format(plan.cwd, tostring(result.code))
  end
  if plan.worktree and plan.common and not in_base_clone(plan.worktree) then
    local removed = git(plan.common, { "worktree", "remove", "--force", "--force", plan.worktree })
    done[#done + 1] = removed.code == 0 and "removed worktree " .. plan.worktree
      or ("worktree remove failed (%s); deleting it"):format(vim.trim(removed.stderr))
  end
  -- delete() removes a symlink inside, never what it points to.
  local stat = lstat(plan.path)
  if stat and stat.type == "directory" and real(plan.path) and not in_base_clone(plan.path) then
    vim.fn.delete(plan.path, "rf")
    done[#done + 1] = "deleted " .. plan.path
  end
  if plan.common then
    git(plan.common, { "worktree", "prune" })
  end
  return done
end

-- Tears a removed new-layout agent down: its script panes stop and go, then its teardown, worktree
-- and dir. Its record is already gone (store.remove_agent); `record` is what it said. An agent this
-- process didn't just stop and whose program hadn't ended is published as exited, reason removed.
---@param record isovim.Agent
---@param ended? boolean its program had already ended, and was published exited then
---@return string[] done
function M.teardown(key, record, ended)
  local panes, events = require("isovim.panes"), require("isovim.events")
  local id = record.id
  for _, pane in ipairs(store.agents(key)) do
    if pane.of == id then
      if panes.running(key, pane.id) then
        panes.stop(key, pane.id)
      end
      store.remove_agent(key, pane.id)
    end
  end
  if panes.running(key, id) then
    panes.stop(key, id)
  elseif not (ended or panes.stopped_here[key .. "/" .. id]) then
    events.publish_agent(key, id, "exited", { reason = "removed" })
  end
  pcall(require("isovim.browser").close_agent, key .. "/" .. id)
  local plan = M.plan(key, id, record)
  local done = {}
  if plan and not plan.link then
    local base = record.read_only and record.repo and require("isovim.repos").dir(record.repo) .. "/base-clone" or nil
    done = M.prune_snapshots(id, { plan.cwd, base })
  end
  return vim.list_extend(done, plan and carry_out(plan) or {})
end

-- Deletes the agent's per-turn snapshots (isovim.acp.sessions, refs/isovim/snapshots/<id>/*) from
-- the clone each dir is a checkout of: its worktree's (a clone's worktrees share its refs) or its
-- read-only base clone's. Only those refs go; nothing else in a clone is touched.
---@param dirs (string|nil)[]
---@return string[] done
function M.prune_snapshots(id, dirs)
  local done, seen = {}, {}
  if not is_agent_id(id) then
    return done
  end
  for i = 1, table.maxn(dirs) do
    local dir = dirs[i]
    local stat = dir and lstat(dir)
    local common = stat and stat.type == "directory" and git(dir, { "rev-parse", "--path-format=absolute", "--git-common-dir" })
    local git_dir = common and common.code == 0 and vim.trim(common.stdout) or nil
    if git_dir and not seen[git_dir] then
      seen[git_dir] = true
      local prefix = "refs/isovim/snapshots/" .. id .. "/"
      local refs = git(dir, { "for-each-ref", "--format=%(refname)", prefix })
      local lines = refs.code == 0 and vim.split(vim.trim(refs.stdout), "\n", { trimempty = true }) or {}
      if #lines > 0 then
        local stdin = table.concat(vim.tbl_map(function(ref)
          return "delete " .. ref
        end, lines), "\n") .. "\n"
        local deleted = vim.system({ "git", "-C", dir, "update-ref", "--stdin" }, { text = true, stdin = stdin, timeout = 60000 }):wait()
        done[#done + 1] = deleted.code == 0 and ("deleted %d snapshot ref(s) under %s in %s"):format(#lines, prefix, git_dir)
          or ("could not delete the snapshot refs in %s: %s"):format(git_dir, vim.trim(deleted.stderr or ""))
      end
    end
  end
  return done
end

local function log(lines)
  vim.fn.mkdir(store.root, "p")
  local stat = vim.uv.fs_stat(M.reaper_log)
  if stat and stat.size > MAX_LOG then
    vim.uv.fs_rename(M.reaper_log, M.reaper_log .. ".1")
  end
  local file = io.open(M.reaper_log, "a")
  if file then
    file:write(table.concat(lines, "\n"), "\n")
    file:close()
  end
end

-- The repo keys under the work root: every dir (up to four names down) with an iso/ in it. An old
-- _/ is isovim.migrate's, never reaped.
local function key_dirs()
  local found = {}
  local function walk(dir, folder, depth)
    if folder == "_" then
      return
    end
    local iso = folder and lstat(dir .. "/iso")
    if iso and iso.type == "directory" then
      found[#found + 1] = store.folder_key(folder)
      return
    end
    if depth == 4 then
      return
    end
    for name, kind in vim.fs.dir(dir) do
      -- Never follow a symlink out of the work root.
      if kind == "directory" and not vim.startswith(name, ".") then
        walk(dir .. "/" .. name, folder and folder .. "/" .. name or name, depth + 1)
      end
    end
  end
  walk(store.work, nil, 0)
  table.sort(found)
  return found
end

-- Whether <key>/<id> is still running: its tmux session, or an ACP supervisor answering on its socket.
local function alive(key, id)
  if require("isovim.panes").running(key, id) then
    return "its tmux session is running"
  end
  local sock = require("isovim.acp").socket(key, id)
  if vim.uv.fs_stat(sock) then
    local ok, chan = pcall(vim.fn.sockconnect, "pipe", sock)
    if ok and chan ~= 0 then
      vim.fn.chanclose(chan)
      return "its supervisor is up"
    end
  end
end

-- Whether the records dir holds any record.
local function has_records(records)
  for name in vim.fs.dir(records) do
    if is_agent_id(name:match("^(.*)%.json$")) then
      return true
    end
  end
  return false
end

-- One reaper pass. Dry (the default), it only logs (and writes nothing else: the teardown it
-- reports is only looked up); live, it tears each orphan down. A repo whose records dir is missing,
-- unreadable or empty while it has aN/ dirs is refused whole, and an aN/ that still runs is skipped.
---@param opts? {live?: boolean}
---@return {orphans: string[], refused: string[], reaped: string[], lines: string[]}
function M.reap(opts)
  local live = opts and opts.live
  local stamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local mode = live and "live" or "dry-run"
  local result = { orphans = {}, refused = {}, reaped = {}, lines = {} }
  local function say(line)
    result.lines[#result.lines + 1] = ("%s %s %s"):format(stamp, mode, line)
  end
  -- Agents' dirs move while the old _/ is migrated (isovim.migrate): no pass then.
  if require("isovim.migrate").busy() then
    say("skipped: the _/ migration is running")
    log(result.lines)
    return result
  end
  for _, key in ipairs(key_dirs()) do
    local dir = store.key_dir(key)
    local records = dir .. "/iso/agents"
    local rstat = lstat(records)
    local readable = rstat and rstat.type == "directory" and vim.uv.fs_access(records, "RX")
    local has_agents = false
    for name in vim.fs.dir(dir) do
      has_agents = has_agents or is_agent_id(name)
    end
    if has_agents and not readable then
      result.refused[#result.refused + 1] = key
      say(("refused %s: its records dir %s is missing or unreadable"):format(key, records))
    elseif has_agents and not has_records(records) then
      result.refused[#result.refused + 1] = key
      say(("refused %s: its records dir %s is empty, yet it has agent dirs"):format(key, records))
    elseif has_agents then
      local now = os.time()
      for name in vim.fs.dir(dir) do
        if is_agent_id(name) and not lstat(records .. "/" .. name .. ".json") then
          local addr = key .. "/" .. name
          local stat = lstat(dir .. "/" .. name)
          local running = alive(key, name)
          if stat and now - stat.mtime.sec < M.grace then
            say(("skipped %s: made %ds ago, its record may be on its way"):format(addr, now - stat.mtime.sec))
          elseif running then
            say(("skipped %s: %s"):format(addr, running))
          else
            local plan, why = M.plan(key, name, nil)
            if not plan then
              result.refused[#result.refused + 1] = addr
              say(("refused %s: %s"):format(addr, why))
            else
              result.orphans[#result.orphans + 1] = addr
              local steps = {}
              if plan.link then
                steps[#steps + 1] = "unlink the symlink " .. plan.path
              else
                if plan.teardown then
                  steps[#steps + 1] = "run teardown in " .. plan.cwd
                end
                if plan.worktree then
                  steps[#steps + 1] = ("remove worktree %s from %s"):format(plan.worktree, tostring(plan.common))
                end
                steps[#steps + 1] = "delete " .. plan.path
              end
              if live then
                result.reaped[#result.reaped + 1] = addr
                say(("tore down %s (no record): %s"):format(addr, table.concat(carry_out(plan), "; ")))
              else
                say(("would tear down %s (no record): %s"):format(addr, table.concat(steps, "; ")))
              end
            end
          end
        end
      end
    end
  end
  say(("done: %d orphan(s), %d torn down, %d refused"):format(#result.orphans, #result.reaped, #result.refused))
  log(result.lines)
  return result
end

-- The last pass's summary line from the log, for checkhealth.
---@return string?
function M.last_run()
  local ok, lines = pcall(vim.fn.readfile, M.reaper_log)
  for i = ok and #lines or 0, 1, -1 do
    if lines[i]:find(" done: ", 1, true) then
      return lines[i]
    end
  end
end

-- Live only when config.json says "reaper": "live"; dry until v0 is cut over.
function M.live()
  return require("isovim.config").get().reaper == "live"
end

-- The TUI's timer: a pass a minute after it starts, then every interval.
function M.start_timer()
  if _G.isovim_reap_timer then
    return
  end
  _G.isovim_reap_timer = vim.uv.new_timer()
  local first = math.min(60, M.interval) * 1000
  _G.isovim_reap_timer:start(first, M.interval * 1000, vim.schedule_wrap(function()
    pcall(function()
      local lifecycle = require("isovim.lifecycle")
      lifecycle.reap({ live = lifecycle.live() })
    end)
  end))
end

return M
