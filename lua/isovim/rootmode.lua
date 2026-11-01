-- Root mode: a root is in charge of clearing the Inbox, which it shares with you. iso rootmode
-- on|off <repo|host> (isovim.cli.rootmode) turns it on for one repo (its repo root) or the whole
-- host (the host root); this module keeps which is on, in ~/.isovim/rootmode.json (this host's
-- alone: it isn't synced), and says which roots may answer a question and which one is told of it.
-- A question isn't routed anywhere: it stays in its repo's Inbox, and the first answer wins,
-- yours or a root's. A root's ACP supervisor subscribes to the Inbox (M.listen) and tells the root
-- of each new question it's in charge of, whoever asked it and whatever code they run.
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

local function label(scope)
  return scope == "host" and "this host" or scope
end
M.label = label

-- The questions as their root gets them: intro, each with its options, then how to answer.
function M.questions_text(intro, entries, scope)
  local role = M.role(scope)
  local lines = { intro }
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = ("[question %s/%s, from %s] %s%s"):format(entry.repo, entry.name, entry.asker or "a shell",
      entry.question, entry.multi and " (pick any)" or "")
    for i, opt in ipairs(entry.options) do
      lines[#lines + 1] = ("  %d. %s%s"):format(i, opt.label, opt.description and (" · " .. opt.description) or "")
    end
    if entry.other then
      lines[#lines + 1] = "  (or your own words)"
    end
  end
  lines[#lines + 1] = ("Answer what you can stand behind with `iso %s answer <repo>/<name> <answer...>`; leave "
    .. "the rest to the user with `iso %s answer <repo>/<name> --raise`. The user may answer first: the first "
    .. "answer wins."):format(role, role)
  local mode = M.entry(scope)
  if mode and mode.task then
    lines[#lines + 1] = "Your task (raise what's outside it): " .. mode.task
  end
  return table.concat(lines, "\n")
end

-- The questions in repos that address is the root in charge of and wasn't told of yet, marked
-- told; all takes those told before too. Nil while root mode is on for it nowhere.
---@return isovim.Surface[]? entries, string? scope "host" or its repo
function M.take(address, repos, all)
  local scope = M.active("host") == address and "host" or nil
  for repo in pairs(scope and {} or M.read().repos) do
    scope = scope or (M.active(repo) == address and repo or nil)
  end
  if not scope then
    return nil
  end
  local surfaces = require("isovim.surfaces")
  local list = {}
  for _, repo in ipairs(repos) do
    surfaces.scan(repo)
    vim.list_extend(list, surfaces.take_untold(repo, function(entry)
      return M.root_for(entry) == address
    end, all))
  end
  return list, scope
end

-- Subscribes a root to the Inbox, from its supervisor: say(text) gets one message per batch of
-- new questions it's in charge of, a few seconds after the last surface event, and on start one
-- for those asked while it was down. It goes by the event bus, so it doesn't matter who wrote or
-- scanned the surface, or what code they run; take_untold's marks keep any question from being
-- told twice. It listens whether root mode is on or not, and tells only while it is.
---@param address string the root, <ws>/<agent>
---@param say fun(text: string)
function M.listen(address, say)
  local surfaces = require("isovim.surfaces")
  local pending, everywhere = {}, true
  local timer = assert(vim.uv.new_timer())
  local flush = require("isovim.safe").wrap("rootmode.listen", function()
    local repos = everywhere and surfaces.repos() or vim.tbl_keys(pending)
    pending, everywhere = {}, false
    local list, scope = M.take(address, repos)
    if list and #list > 0 then
      say(M.questions_text(("%s in %s, which root mode has you clear with the user:"):format(
        #list == 1 and "A new question" or (#list .. " new questions"),
        scope == "host" and "this host's Inboxes" or (scope .. "'s Inbox")), list, scope))
    end
  end)
  local function soon(delay)
    timer:start(delay, 0, vim.schedule_wrap(flush))
  end
  require("isovim.events").watch(function(_, event)
    if event.type == "question" and type(event.repo) == "string" and event.topic:match("^surface%.")
      and (event.topic:match("%.created$") or event.topic:match("%.changed$")) then
      pending[event.repo] = true
      soon(3000)
    end
  end)
  soon(5000)
end

return M
