-- Your config follows you to the other hosts: every write isovim makes to ~/.isovim/config.json or
-- ~/.isovim/repos/** calls M.changed, which starts `iso __sync` in the background; `iso sync` runs
-- one in the foreground. A sync copies to each host in config.json's hosts:
--   repos/       with rsync --update over ssh, never a base-clone/ (each host clones its own) nor a
--                temp file; nothing is deleted on the other side, and a file that's newer there
--                stays, so a host that slept through an edit never sends its stale copy back
--   prompts/     the role prompts, the same way, in the same rsync
--   config.json  merged into theirs key by key, the newer of each winning: config.keys.json beside
--                it records when each key last changed (refreshed at each sync from the file's
--                mtime); a key with no record on a side counts as as old as that side's file. self,
--                hosts, reaper and enforce say who a host is, who its peers are and whether it's
--                cut over, so stay that host's own
-- events/, run/ and the rest of ~/.isovim stay on their host. A host that's down is logged to
-- ~/.isovim/sync.log and simply tried again on the next write, since each sync sends everything.
-- One sync runs at a time; a write during one makes it go round again.
local store = require("isovim.store")

local M = {}

M.log_file = store.root .. "/sync.log"
-- Where isovim's home is on the other hosts: relative to their home dir, as ssh starts there.
M.remote_root = vim.env.ISOVIM_SYNC_ROOT or ".isovim"
-- Keys of config.json that belong to one host; enforce is on once that host is cut over.
M.local_keys = { self = true, hosts = true, reaper = true, enforce = true }
local MAX_LOG = 256 * 1024

local function peers()
  return require("isovim.remote").peers()
end

local function log(line)
  vim.fn.mkdir(store.root, "p")
  local stat = vim.uv.fs_stat(M.log_file)
  if stat and stat.size > MAX_LOG then
    vim.uv.fs_rename(M.log_file, M.log_file .. ".1")
  end
  local file = io.open(M.log_file, "a")
  if file then
    file:write(os.date("!%Y-%m-%dT%H:%M:%SZ "), line, "\n")
    file:close()
  end
end

-- After a write: a sync in the background, when there's a host to sync to. It outlives an iso
-- command that exits right after.
function M.changed()
  if vim.env.ISOVIM_NO_SYNC or next(peers()) == nil then
    return
  end
  local bin = require("isovim.panes").bin
  vim.system({ "sh", "-c", ("nohup %s __sync </dev/null >/dev/null 2>&1 &"):format(vim.fn.shellescape(bin)) }):wait()
end

local function ssh_cmd(host, remote)
  local cmd = vim.split(require("isovim.remote").ssh, " ", { trimempty = true })
  return vim.list_extend(cmd, { host, remote })
end

local function decode(text)
  local ok, value = pcall(vim.json.decode, text or "")
  return ok and type(value) == "table" and not vim.islist(value) and value or nil
end

-- JSON with sorted keys, so the same value hashes the same on every host.
local function canonical(value)
  if type(value) ~= "table" then
    return vim.json.encode(value)
  elseif vim.islist(value) then
    return "[" .. table.concat(vim.tbl_map(canonical, value), ",") .. "]"
  end
  local keys = vim.tbl_keys(value)
  table.sort(keys)
  return "{" .. table.concat(vim.tbl_map(function(key)
    return vim.json.encode(key) .. ":" .. canonical(value[key])
  end, keys), ",") .. "}"
end

local function hash(value)
  return value == nil and "" or vim.fn.sha256(canonical(value))
end

M.stamps_file = store.root .. "/config.keys.json"

-- This host's config.keys.json, brought up to date with config.json: a key whose value changed
-- (or that went, as hash "") since the last refresh is stamped with the file's mtime.
---@return table<string, {h: string, t: integer}>
function M.stamps(config, mtime)
  local ok, lines = pcall(vim.fn.readfile, M.stamps_file)
  local stamps = ok and decode(table.concat(lines, "\n")) or {}
  local changed = false
  for key in pairs(vim.tbl_extend("force", {}, stamps, config)) do
    if not M.local_keys[key] then
      local h = hash(config[key])
      if type(stamps[key]) ~= "table" or stamps[key].h ~= h then
        stamps[key], changed = { h = h, t = mtime }, true
      end
    end
  end
  if changed then
    vim.fn.writefile({ vim.json.encode(stamps) }, M.stamps_file)
  end
  return stamps
end

-- config.json for the peer, and its stamps: per key the newer side's value (ours on a tie), with
-- its own self, hosts and reaper kept (its name as self when it has none).
local function merged(ours, our_stamps, our_mtime, theirs, their_stamps, their_mtime, name)
  local result, stamps = {}, {}
  -- A stamp counts only while it's of the value that side has: a key edited since that side's
  -- last sync (a hand edit, a sync from an older isovim) is as new as its file.
  local function when(side, side_stamps, key, fallback)
    local stamp = side_stamps[key]
    return type(stamp) == "table" and stamp.h == hash(side[key]) and tonumber(stamp.t) or fallback
  end
  for key in pairs(vim.tbl_extend("force", {}, ours, theirs, our_stamps, their_stamps)) do
    if not M.local_keys[key] then
      local ours_at, theirs_at = when(ours, our_stamps, key, our_mtime), when(theirs, their_stamps, key, their_mtime)
      local mine = ours_at >= theirs_at
      if mine then
        result[key] = ours[key]
      else
        result[key] = theirs[key]
      end
      stamps[key] = { h = hash(result[key]), t = mine and ours_at or theirs_at }
    end
  end
  for key in pairs(M.local_keys) do
    result[key] = theirs[key]
  end
  result.self = result.self or name
  return result, stamps
end

-- One peer: config.json, then repos/. nil, why when it failed.
---@return boolean? ok, string? why
local function push(name, host)
  local root = M.remote_root
  local q = vim.fn.shellescape
  local config_path = store.root .. "/config.json"
  local stat = vim.uv.fs_stat(config_path)
  if stat then
    local ok, lines = pcall(vim.fn.readfile, config_path)
    local ours = ok and decode(table.concat(lines, "\n"))
    if ours then
      local our_stamps = M.stamps(ours, stat.mtime.sec)
      -- Theirs, a separator, their stamps, a separator, their config.json's mtime.
      local sep = "\n--isovim-sync--\n"
      local read = vim.system(ssh_cmd(host, ("cat %s/config.json 2>/dev/null; printf %s; cat %s/config.keys.json 2>/dev/null; printf %s; date -r %s/config.json +%%s 2>/dev/null; true")
        :format(q(root), q(sep), q(root), q(sep), q(root))), { text = true, timeout = 30000 }):wait()
      if read.code ~= 0 then
        return nil, ("could not reach it (exit %s): %s"):format(tostring(read.code), vim.trim(read.stderr or ""))
      end
      local parts = vim.split(read.stdout, sep, { plain = true })
      local theirs = vim.trim(parts[1] or "") == "" and {} or decode(parts[1])
      if not theirs then
        return nil, "its config.json isn't a JSON object, so it's left alone"
      end
      local their_stamps = decode(parts[2]) or {}
      local their_mtime = tonumber(vim.trim(parts[3] or "")) or 0
      local want, stamps = merged(ours, our_stamps, stat.mtime.sec, theirs, their_stamps, their_mtime, name)
      if not vim.deep_equal(want, theirs) or not vim.deep_equal(stamps, their_stamps) then
        for key in pairs(want) do
          if not M.local_keys[key] and not vim.deep_equal(want[key], ours[key]) then
            log(("%s keeps its newer %s"):format(name, key))
          end
        end
        -- Stamps first: a config.json without them would only make its keys look older.
        for _, file in ipairs({ { "config.keys.json", vim.json.encode(stamps) }, { "config.json", vim.json.encode(want, { indent = "  " }) } }) do
          local path = root .. "/" .. file[1]
          local write = ("mkdir -p %s && cat > %s && mv %s %s"):format(q(root), q(path .. ".sync.tmp"), q(path .. ".sync.tmp"), q(path))
          local wrote = vim.system(ssh_cmd(host, write), { stdin = file[2] .. "\n", text = true, timeout = 30000 }):wait()
          if wrote.code ~= 0 then
            return nil, ("could not write its %s: %s"):format(file[1], vim.trim(wrote.stderr or ""))
          end
        end
      end
    end
  end
  -- repos/ and the role prompts (isovim.prompts) in one rsync, with --update: a file newer on the
  -- peer stays.
  local dirs = vim.tbl_filter(function(dir)
    return vim.fn.isdirectory(dir) == 1
  end, { store.root .. "/repos", store.root .. "/prompts" })
  if #dirs > 0 then
    if vim.fn.executable("rsync") == 0 then
      return nil, "rsync is missing here, so repos/ and prompts/ weren't sent"
    end
    local cmd = { "rsync", "-a", "--update", "--exclude=base-clone/", "--exclude=*.tmp", "--exclude=*.lock",
      "-e", require("isovim.remote").ssh, "--rsync-path=mkdir -p " .. q(root) .. " && rsync" }
    local result = vim.system(vim.list_extend(vim.list_extend(cmd, dirs), { host .. ":" .. root .. "/" }),
      { text = true, timeout = 120000 }):wait()
    if result.code ~= 0 then
      return nil, ("rsync failed (exit %s): %s"):format(tostring(result.code), vim.trim(result.stderr or ""))
    end
  end
  return true
end

-- Every peer once. Returns name -> true or the reason it failed.
---@return table<string, true|string>
local function push_all()
  local results = {}
  for name, host in pairs(peers()) do
    local ok, why = push(name, host)
    results[name] = ok or why
    log(ok and ("synced to %s (%s)"):format(name, host) or ("FAILED %s (%s): %s; tried again on the next write"):format(name, host, why))
  end
  return results
end

-- A sync, unless one is running, which is then told to go round again. Returns each peer's result,
-- or nil when it left the work to the running one. With wait (iso sync), it waits for the running
-- one to end, up to wait seconds, and then runs its own: asking that one to go round again instead
-- would keep it going for as long as the asking went on.
---@param opts? {wait?: number}
---@return table<string, true|string>?
function M.run(opts)
  vim.fn.mkdir(store.run, "p")
  local lock, again = store.run .. "/sync.lock", store.run .. "/sync.again"
  local deadline = os.time() + (opts and opts.wait or 0)
  while not vim.uv.fs_mkdir(lock, 448) do
    local stat = vim.uv.fs_stat(lock)
    if stat and os.time() - stat.mtime.sec > 600 then
      vim.uv.fs_rmdir(lock)
    elseif os.time() < deadline then
      vim.uv.sleep(100)
    else
      vim.fn.writefile({}, again)
      return nil
    end
  end
  local ok, results = pcall(function()
    local results
    repeat
      os.remove(again)
      results = push_all()
    until not vim.uv.fs_stat(again)
    return results
  end)
  vim.uv.fs_rmdir(lock)
  if not ok then
    log("FAILED: " .. tostring(results))
    error(results)
  end
  return results
end

-- The last line of the log, for checkhealth.
function M.last()
  local ok, lines = pcall(vim.fn.readfile, M.log_file)
  return ok and lines[#lines] or nil
end

return M
