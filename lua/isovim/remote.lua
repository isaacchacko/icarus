-- The other hosts' agents: each host's `ivim ls --json`
-- over ssh, fetched in the background and cached; a peer that doesn't answer (asleep) drops out
-- until it does. Opening one attaches a terminal to it over ssh (ivim attach).
local config = require("isovim.config").get

local M = {}

M.ssh = vim.env.ISOVIM_SSH or "ssh -o BatchMode=yes -o ConnectTimeout=3"
M.remote_bin = vim.env.ISOVIM_REMOTE_BIN or "~/.local/bin/ivim"

local TTL = 10
local cache = {} ---@type table<string, {rows?: table[], at: integer, busy?: boolean}>

-- name -> ssh host, from the config's hosts (ISOVIM_PEERS="name=host,..." for pilots; "-" for none).
---@return table<string, string>
function M.peers()
  if vim.env.ISOVIM_PEERS then
    local peers = {}
    for name, host in vim.env.ISOVIM_PEERS:gmatch("([^,=]+)=([^,]+)") do
      peers[name] = host
    end
    return peers
  end
  return config().hosts or {}
end

-- This host's name, as others address its agents (<host>:<ws>/<agent>).
function M.self()
  return vim.env.ISOVIM_SELF or config().self or vim.fn.hostname()
end

-- The ssh host for a peer's name or alias; nil for this host or an unknown name.
function M.host_of(name)
  local peers = M.peers()
  name = (config().aliases or {})[name] or name
  return peers[name], name
end

-- Runs `ivim <args>` on a peer and waits: the remote's own output, exit code and errors.
---@param args string[]
function M.run(host, args, timeout)
  local cmd = vim.split(M.ssh, " ", { trimempty = true })
  local remote = M.remote_bin .. " " .. table.concat(vim.tbl_map(vim.fn.shellescape, args), " ")
  vim.list_extend(cmd, { host, remote })
  return vim.system(cmd, { text = true, timeout = timeout }):wait()
end

local function command(host, args)
  return ("%s %s %s"):format(M.ssh, vim.fn.shellescape(host), vim.fn.shellescape(M.remote_bin .. " " .. args))
end

-- The peer's agents ({id, workspace, agent, kind, status, hidden}), or nil while unknown or down.
---@return table[]?
function M.list(name, host, on_update)
  local entry = cache[name]
  if not entry then
    entry = { at = 0 }
    cache[name] = entry
  end
  if not entry.busy and os.time() - entry.at >= TTL then
    entry.busy = true
    vim.system({ "bash", "-c", command(host, "ls --json") }, { text = true }, function(result)
      local decoded, rows = pcall(vim.json.decode, result.code == 0 and result.stdout or "")
      local new = decoded and type(rows) == "table" and rows or nil
      local changed = vim.json.encode(new or false) ~= vim.json.encode(entry.rows or false)
      entry.rows, entry.at, entry.busy, entry.down = new, os.time(), nil, new == nil
      if changed then
        vim.schedule(on_update)
      end
    end)
  end
  return entry.rows
end

-- Whether the peer's last listing failed (asleep, off the network).
function M.down(name)
  return cache[name] ~= nil and cache[name].down == true
end

-- After something changed on that host (a move), so the next listing asks again.
function M.invalidate(name)
  if cache[name] then
    cache[name].at = 0
  end
end

-- Every peer's agents now, asked in parallel; a peer that doesn't answer in time is left out.
---@return table<string, table[]> name -> rows
function M.list_all_now(timeout)
  local jobs = {}
  for name, host in pairs(M.peers()) do
    jobs[name] = vim.system({ "bash", "-c", command(host, "ls --json") }, { text = true, timeout = timeout })
  end
  local all = {}
  for name, job in pairs(jobs) do
    local result = job:wait()
    local decoded, rows = pcall(vim.json.decode, result.code == 0 and result.stdout or "")
    if decoded and type(rows) == "table" then
      all[name] = rows
    end
  end
  return all
end

-- A shell command that attaches this terminal to the peer's agent.
function M.attach_cmd(host, id)
  return ("%s -t %s %s"):format(M.ssh, vim.fn.shellescape(host), vim.fn.shellescape(M.remote_bin .. " attach " .. id))
end

return M
