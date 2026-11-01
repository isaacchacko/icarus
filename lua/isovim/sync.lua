-- Your config follows you to the other hosts: every write isovim makes to ~/.isovim/config.json or
-- ~/.isovim/repos/** calls M.changed, which starts `iso __sync` in the background; `iso sync` runs
-- one in the foreground. A sync copies to each host in config.json's hosts:
--   repos/       with rsync over ssh, never a base-clone/ (each host clones its own) nor a temp file;
--                nothing is deleted on the other side
--   config.json  merged into theirs: everything but self and hosts, which say who a host is and who
--                its peers are, so stay that host's own
-- events/, run/ and the rest of ~/.isovim stay on their host. A host that's down is logged to
-- ~/.isovim/sync.log and simply tried again on the next write, since each sync sends everything.
-- One sync runs at a time; a write during one makes it go round again.
local store = require("isovim.store")

local M = {}

M.log_file = store.root .. "/sync.log"
-- Where isovim's home is on the other hosts: relative to their home dir, as ssh starts there.
M.remote_root = vim.env.ISOVIM_SYNC_ROOT or ".isovim"
-- Keys of config.json that belong to one host.
M.local_keys = { self = true, hosts = true }
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

-- config.json for the peer: ours, with its own self and hosts kept (its name as self when it has none).
local function merged(ours, theirs, name)
  local result = {}
  for key, value in pairs(ours) do
    if not M.local_keys[key] then
      result[key] = value
    end
  end
  for key in pairs(M.local_keys) do
    result[key] = theirs[key]
  end
  result.self = result.self or name
  return result
end

-- One peer: config.json, then repos/. nil, why when it failed.
---@return boolean? ok, string? why
local function push(name, host)
  local root = M.remote_root
  local q = vim.fn.shellescape
  local config_path = store.root .. "/config.json"
  if vim.uv.fs_stat(config_path) then
    local ok, lines = pcall(vim.fn.readfile, config_path)
    local ours = ok and decode(table.concat(lines, "\n"))
    if ours then
      local read = vim.system(ssh_cmd(host, ("cat %s/config.json 2>/dev/null || true"):format(q(root))), { text = true, timeout = 30000 }):wait()
      if read.code ~= 0 then
        return nil, ("could not reach it (exit %s): %s"):format(tostring(read.code), vim.trim(read.stderr or ""))
      end
      local theirs = vim.trim(read.stdout) == "" and {} or decode(read.stdout)
      if not theirs then
        return nil, "its config.json isn't a JSON object, so it's left alone"
      end
      local want = merged(ours, theirs, name)
      if not vim.deep_equal(want, theirs) then
        local text = vim.json.encode(want, { indent = "  " })
        local write = ("mkdir -p %s && cat > %s/config.json.sync.tmp && mv %s/config.json.sync.tmp %s/config.json")
          :format(q(root), q(root), q(root), q(root))
        local wrote = vim.system(ssh_cmd(host, write), { stdin = text .. "\n", text = true, timeout = 30000 }):wait()
        if wrote.code ~= 0 then
          return nil, "could not write its config.json: " .. vim.trim(wrote.stderr or "")
        end
      end
    end
  end
  local repos = store.root .. "/repos"
  if vim.fn.isdirectory(repos) == 1 then
    if vim.fn.executable("rsync") == 0 then
      return nil, "rsync is missing here, so repos/ wasn't sent"
    end
    local result = vim.system({ "rsync", "-a", "--exclude=base-clone/", "--exclude=*.tmp", "--exclude=*.lock",
      "-e", require("isovim.remote").ssh, "--rsync-path=mkdir -p " .. q(root .. "/repos") .. " && rsync",
      repos .. "/", host .. ":" .. root .. "/repos/" }, { text = true, timeout = 120000 }):wait()
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
-- or nil when it left the work to the running one.
---@return table<string, true|string>?
function M.run()
  vim.fn.mkdir(store.run, "p")
  local lock, again = store.run .. "/sync.lock", store.run .. "/sync.again"
  if not vim.uv.fs_mkdir(lock, 448) then
    local stat = vim.uv.fs_stat(lock)
    if stat and os.time() - stat.mtime.sec > 600 then
      vim.uv.fs_rmdir(lock)
      return M.run()
    end
    vim.fn.writefile({}, again)
    return nil
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
