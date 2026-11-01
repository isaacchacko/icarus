-- Root mode: a root is in charge of clearing the Inbox, which it shares with you. iso rootmode
-- on|off <repo|host> (isovim.cli.rootmode) turns it on for one repo (its repo root) or the whole
-- host (the host root); this module keeps which is on, in ~/.isovim/rootmode.json (this host's
-- alone: it isn't synced), and says which roots may answer a question and which one is told of it.
-- A question isn't routed anywhere: it stays in its repo's Inbox, and the first answer wins,
-- yours or a root's.
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

-- The root in charge of repo's Inbox: the repo's root, else the host root, else nil (only you).
---@return string? address, isovim.RootMode? entry, string? scope "host" or the repo
function M.route(repo)
  for _, scope in ipairs({ repo, "host" }) do
    local address, entry = M.active(scope)
    if address then
      return address, entry, scope
    end
  end
end

-- Whether a root may answer a question still open to roots: pending, not the user's (raised), and
-- one not asked by the root itself.
local function open(entry)
  return entry.type == "question" and not entry.answer and not entry.raised
end

-- Whether address may answer the question: it's the root of the question's repo or the host's,
-- while root mode is on there. You may answer any question; a root never answers its own, nor one
-- that's yours (raised: a root's --raise, or a permission request).
function M.may_answer(address, entry)
  return open(entry) and address ~= entry.asker
    and (M.active(entry.repo) == address or M.active("host") == address)
end

-- The root told of a question, the one in charge of its repo's Inbox: the repo's root, else the
-- host root, passing over the one that asked it (a repo root's own question goes to the host root).
---@return string? address, string? scope
function M.root_for(entry)
  if not open(entry) then
    return nil
  end
  for _, scope in ipairs({ entry.repo, "host" }) do
    local address = M.active(scope)
    if address and address ~= entry.asker then
      return address, scope
    end
  end
end

-- Whether root mode is on for a repo (its own root) or, with "host", for the host.
function M.on(scope)
  return M.active(scope) ~= nil
end

return M
