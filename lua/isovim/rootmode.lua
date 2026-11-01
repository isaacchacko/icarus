-- Root mode: a root answers the routers' questions in your place. iso rootmode on|off <repo|host>
-- (isovim.cli.rootmode) turns it on for one repo (a repo root) or the whole host (the host root);
-- this module keeps which is on, in ~/.isovim/rootmode.json (this host's alone: it isn't synced),
-- and says where a router's question goes: the most specific active root, else you.
--   { "host": {agent, task?, since}, "repos": { "<owner/repo>": {agent, task?, since} } }
-- An entry is active while its agent's record still holds the role it needs (root for the host,
-- repo-root for a repo); one whose agent went away is off.
local store = require("isovim.store")

local M = {}

M.file = store.root .. "/rootmode.json"

---@alias isovim.RootMode {agent: string, task?: string, since: number}

---@return {host?: isovim.RootMode, repos: table<string, isovim.RootMode>}
function M.read()
  local ok, lines = pcall(vim.fn.readfile, M.file)
  local decoded, state = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "", { luanil = { object = true } })
  state = decoded and type(state) == "table" and state or {}
  state.repos = type(state.repos) == "table" and state.repos or {}
  return state
end

local function write(state)
  vim.fn.mkdir(store.root, "p")
  local tmp = ("%s.%d.tmp"):format(M.file, vim.uv.os_getpid())
  vim.fn.writefile({ vim.json.encode({ host = state.host, repos = next(state.repos) and state.repos or vim.empty_dict() }) }, tmp)
  assert(vim.uv.fs_rename(tmp, M.file))
end

-- The role a scope's root holds: "host" is the host root's, a repo key a repo root's.
function M.role(scope)
  return scope == "host" and "root" or "repo-root"
end

---@return isovim.RootMode?
function M.entry(scope)
  local state = M.read()
  if scope == "host" then
    return state.host
  end
  return state.repos[scope]
end

---@param entry? isovim.RootMode nil turns it off
function M.set(scope, entry)
  local state = M.read()
  if scope == "host" then
    state.host = entry
  else
    state.repos[scope] = entry
  end
  write(state)
end

-- The scope's root while root mode is on there: its address (<ws>/<agent>) and entry.
---@return string? address, isovim.RootMode? entry
function M.active(scope)
  local entry = M.entry(scope)
  local ws, id
  if entry and type(entry.agent) == "string" then
    ws, id = entry.agent:match("^(.*)/([^/]+)$")
  end
  local record = ws and store.agent(ws, id)
  if record and store.role(record) == M.role(scope) then
    return entry.agent, entry
  end
end

-- Where a question asked in repo goes: the repo's root, else the host root, else nil (you).
---@return string? address, isovim.RootMode? entry, string? scope "host" or the repo
function M.route(repo)
  for _, scope in ipairs({ repo, "host" }) do
    local address, entry = M.active(scope)
    if address then
      return address, entry, scope
    end
  end
end

-- Whether root mode is on for a repo (its own root) or, with "host", for the host.
function M.on(scope)
  return M.active(scope) ~= nil
end

return M
