-- Threads: one idea's conversation between the user and a repo's router, read on its own. The router
-- stays one agent with one session, its context warm; a thread is a view of the exchanges about one
-- thing, so its chat doesn't drown in every small idea, and no new agent pays a cold start for each.
-- They live only in a repo with a router on this host: General, Root and Terminals have none.
--
-- A thread is iso/threads/<id>.jsonl in the repo's iso/ (ids t1, t2...), appended to, never
-- rewritten, a JSON object a line:
--   {kind = "thread", id, title, created_by, at, status = "open"}    its header, first
--   {kind = "post", by = "user"|<agent address>, text, at, images?}
--   {kind = "resolved", by, outcome?, at}, {kind = "reopened", by, at}
--   {kind = "renamed", by, title, at}               its title from then on (posts keep their tags)
--   {kind = "working", state = "start"|"end", at}   the router's turn on one of its posts
-- A post of the user's goes to the router as a prompt tagged "[thread <repo>#<id> "<title>"]";
-- the supervisor (isovim.acp.host) marks that turn working in the thread and posts the turn's last
-- message there when it ends, so the router just answers. It posts more with iso router thread
-- post. What the user has read (the last line seen, per thread) is run/<repo>/threads.json: a
-- router post past it makes the thread wait on them (needs_you) until they open it.
local store = require("isovim.store")

local M = {}

function M.dir(repo)
  return store.path(repo) .. "/threads"
end

function M.file(repo, id)
  return M.dir(repo) .. "/" .. id .. ".jsonl"
end

-- Why repo can't have threads, or nil when it can: a repo (not General or Root) with a router here.
function M.refusal(repo)
  if not repo or store.is_pseudo(repo) or not store.valid_key(repo) then
    return "threads live in a repo with a router; General, Root and Terminals have none"
  elseif not store.router(repo) then
    return repo .. " has no router on this host to talk to (iso spawn --role router, or promote one)"
  end
end

-- A thread's lines, decoded, each with its seq (its line number); nil with no such thread.
---@return table[]?
function M.read(repo, id)
  local file = io.open(M.file(repo, id), "rb")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  local entries, seq = {}, 0
  for line in text:gmatch("[^\n]+") do
    seq = seq + 1
    local ok, entry = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(entry) == "table" then
      entry.seq = seq
      entries[#entries + 1] = entry
    end
  end
  return entries
end

-- What a thread is now: its header's fields, its status and outcome as the last say, how many
-- posts, the last router post's seq, whether a turn on it runs.
function M.summary(entries)
  local head = entries[1] or {}
  local info = { id = head.id, title = head.title or head.id or "?", created_by = head.created_by, at = head.at,
    status = head.status or "open", posts = 0, last_reply = 0, working = false }
  for _, entry in ipairs(entries) do
    if entry.kind == "post" then
      info.posts = info.posts + 1
      if entry.by ~= "user" then
        info.last_reply = entry.seq
      end
    elseif entry.kind == "resolved" then
      info.status, info.outcome = "resolved", entry.outcome
    elseif entry.kind == "reopened" then
      info.status, info.outcome = "open", nil
    elseif entry.kind == "renamed" and type(entry.title) == "string" then
      info.title = entry.title
    elseif entry.kind == "working" then
      info.working = entry.state == "start"
    end
  end
  return info
end

-- The repo's threads, newest first, as M.summary says (resolved ones only with all).
function M.list(repo, all)
  local found = {}
  if vim.fn.isdirectory(M.dir(repo)) == 0 then
    return found
  end
  for base in vim.fs.dir(M.dir(repo)) do
    local id = base:match("^(t%d+)%.jsonl$")
    local entries = id and M.read(repo, id)
    if entries and entries[1] then
      local info = M.summary(entries)
      info.id = id
      if all or info.status == "open" then
        found[#found + 1] = info
      end
    end
  end
  table.sort(found, function(a, b)
    return tonumber(a.id:sub(2)) > tonumber(b.id:sub(2))
  end)
  return found
end

-- Appends an entry (its at set) to the thread, in one write (a line under PIPE_BUF is atomic).
local function append(repo, id, entry)
  entry.at = entry.at or os.time()
  local file = assert(io.open(M.file(repo, id), "ab"))
  file:write(vim.json.encode(entry) .. "\n")
  file:close()
  return entry
end

-- A new thread in repo, titled title, by (user or an agent's address); its id, or nil and why.
---@return string? id, string? err
function M.new(repo, title, by)
  local why = M.refusal(repo)
  if why then
    return nil, why
  end
  title = vim.trim((title or ""):gsub("%s+", " "))
  if title == "" then
    return nil, "a thread needs a title"
  end
  vim.fn.mkdir(M.dir(repo), "p")
  local n = 0
  for base in vim.fs.dir(M.dir(repo)) do
    n = math.max(n, tonumber(base:match("^t(%d+)%.jsonl$")) or 0)
  end
  -- The file made exclusively, so two at once never take the same id.
  local id, fd
  repeat
    n = n + 1
    id = "t" .. n
    fd = vim.uv.fs_open(M.file(repo, id), "wx", 420)
  until fd
  vim.uv.fs_close(fd)
  append(repo, id, { kind = "thread", id = id, title = title, created_by = by, status = "open" })
  return id
end

local function exists(repo, id)
  local entries = M.read(repo, id)
  if not entries or not entries[1] then
    return nil, ("%s has no thread %s"):format(repo, id)
  end
  return entries
end

-- A post in the thread.
---@param images? {path: string, mimeType: string}[]
---@return table? post, string? err
function M.post(repo, id, by, text, images)
  local entries, err = exists(repo, id)
  if not entries then
    return nil, err
  end
  text = vim.trim(text or "")
  if text == "" and not (images and images[1]) then
    return nil, "a post needs text"
  end
  return append(repo, id, { kind = "post", by = by, text = text, images = images and images[1] and images or nil })
end

-- Resolves the thread with an outcome, or (resolved already) opens it again.
---@return string? status, string? err
function M.resolve(repo, id, by, outcome, reopen)
  local entries, err = exists(repo, id)
  if not entries then
    return nil, err
  end
  local status = M.summary(entries).status
  if reopen then
    if status == "open" then
      return nil, id .. " is open"
    end
    append(repo, id, { kind = "reopened", by = by })
    return "open"
  elseif status == "resolved" then
    return nil, id .. " is resolved already"
  end
  outcome = outcome and vim.trim(outcome) ~= "" and vim.trim(outcome) or nil
  append(repo, id, { kind = "resolved", by = by, outcome = outcome })
  return "resolved"
end

-- A new title for the thread, by the user or a router.
---@return string? title, string? err
function M.rename(repo, id, by, title)
  local entries, err = exists(repo, id)
  if not entries then
    return nil, err
  end
  title = vim.trim((title or ""):gsub("%s+", " "))
  if title == "" then
    return nil, "a thread needs a title"
  elseif title == M.summary(entries).title then
    return nil, ("%s is %q already"):format(id, title)
  end
  append(repo, id, { kind = "renamed", by = by, title = title })
  return title
end

-- The router's turn on the thread started or ended (the supervisor's).
function M.working(repo, id, state)
  if vim.uv.fs_stat(M.file(repo, id)) then
    append(repo, id, { kind = "working", state = state })
  end
end

-- What the router is sent for a post of the user's.
function M.prompt(repo, id, title, text)
  return ("[thread %s#%s %q] %s"):format(repo, id, title, text)
end

-- The thread a prompt is for, from its tag (anywhere on its first line, after a stamp): repo, id.
function M.tagged(text)
  local repo, id = (text or ""):match("^[^\n]-%[thread ([^%s#]+)#(t%d+)")
  return repo, id
end

-- What the user has read: the last line seen per thread.
local function seen_file(repo)
  return store.run_dir(repo) .. "/threads.json"
end

function M.seen(repo)
  local file = io.open(seen_file(repo), "rb")
  local ok, value = pcall(vim.json.decode, file and file:read("*a") or "")
  if file then
    file:close()
  end
  return ok and type(value) == "table" and value or {}
end

-- The user has read the thread up to line seq; true when that changes whether it waits on them.
function M.mark_seen(repo, id, seq)
  local seen = M.seen(repo)
  local was = seen[id] or 0
  if seq <= was then
    return false
  end
  seen[id] = seq
  vim.fn.mkdir(store.run_dir(repo), "p")
  local path = seen_file(repo)
  local tmp = path .. "." .. vim.uv.os_getpid() .. ".tmp"
  local file = assert(io.open(tmp, "wb"))
  file:write(vim.json.encode(seen))
  file:close()
  vim.uv.fs_rename(tmp, path)
  local entries = M.read(repo, id) or {}
  return M.summary(entries).last_reply > was
end

-- Follows a thread file: on_entry(entry) for each line from line from+1 on, as it's appended
-- (watching its folder), on_reset() if the file shrinks or goes. Returns stop and where it's read to.
function M.follow(repo, id, on_entry, on_reset, from)
  local read = from or 0
  local watcher = vim.uv.new_fs_event()
  local stopped = false
  local function drain()
    if stopped then
      return
    end
    local entries = M.read(repo, id)
    if not entries or #entries < read then
      read = 0
      on_reset()
      if not entries then
        return
      end
    end
    for _, entry in ipairs(entries) do
      if entry.seq > read then
        read = entry.seq
        on_entry(entry)
      end
    end
  end
  vim.fn.mkdir(M.dir(repo), "p")
  if watcher then
    watcher:start(M.dir(repo), {}, vim.schedule_wrap(function(err, name)
      if not err and (name == nil or name == id .. ".jsonl") then
        drain()
      end
    end))
  end
  drain()
  return function()
    stopped = true
    if watcher and not watcher:is_closing() then
      watcher:stop()
      watcher:close()
    end
  end, function()
    return read
  end, drain
end

return M
