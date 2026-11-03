-- Threads: one idea's conversation between the user and a repo's router, read on its own. The router
-- stays one agent with one session, its context warm; a thread is a view of the exchanges about one
-- thing, so its chat doesn't drown in every small idea, and no new agent pays a cold start for each.
-- They live only in a repo with a router on this host: General, Root and Terminals have none.
--
-- A thread is iso/threads/<id>.jsonl in the repo's iso/ (ids t1, t2...), appended to, never
-- rewritten, a JSON object a line:
--   {kind = "thread", id, title, created_by, at, status = "open", parent?}    its header, first
--   {kind = "parent", on = <id>|"none", by, at}     its parent thread from then on (children aren't
--                                                   stored: M.related finds them by scanning)
--   {kind = "post", by = "user"|<agent address>, text, at, images?, no_reply?}   no_reply: it needs
--                                                   nothing from the user (below)
--   {kind = "resolved", by, outcome?, at}, {kind = "reopened", by, at}
--   {kind = "renamed", by, title, at}               its title from then on (posts keep their tags)
--   {kind = "ask", qid, question, options, multi, other, by, at}   a question the router asks in it
--   {kind = "answered", qid, labels, other?, by, at}, {kind = "raised", qid, by, why?, at}
-- A question asked in a thread lives there, not in the repo: isovim.surfaces lists each one still
-- waiting as a question surface (named <id>-<qid>, its file the thread's), so the Inbox, root mode
-- and iso answer take it as any question; its answer is appended here, where the asker's thread
-- ask waits for it.
--   {kind = "working", state = "start"|"end", died?, at}   the router's turn on one of its posts;
--                                                   died: it stopped mid-turn (M.end_dead_turns)
--   {kind = "waiting", on = "user"|<agent address>|"none", by, why?, at}   whose turn it is
-- A post of the user's goes to the router as a prompt tagged "[thread <repo>#<id> "<title>"]";
-- the supervisor (isovim.acp.host) marks that turn working in the thread and posts the turn's last
-- message there when it ends, so the router just answers. It posts more with iso router thread
-- post. What the user has read (the last line seen, per thread) is run/<repo>/threads.json: a
-- router post past it makes the thread wait on them (needs_you) until they open it.
--
-- Whose turn it is is apart from what's been read. After an agent's post it's the user's turn, opened
-- or not, so they never miss one: the thread is in the Inbox until they post, it's resolved or they
-- dismiss it (D). The agent opts out when a post needs nothing from them: iso router thread post
-- --no-reply, or iso router thread waiting <id> none|<worker> in a turn whose last message posts
-- itself, the mark standing for that post. Posts during a turn on the thread count when it ends.
-- Waiting on a worker clears once that worker has finished or gone, and the router is told; M.listen,
-- in the router's supervisor, sees to that, and gives the router a thread the user stopped at the
-- title of, the title as their first post.
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
    status = head.status or "open", posts = 0, last_reply = 0, working = false, parent = head.parent }
  local function waits(on, at)
    info.waiting_on, info.waiting_at = on, at
  end
  -- The router's turn on the thread, while it runs: whether it posted for the user, and its mark.
  local turn
  for _, entry in ipairs(entries) do
    if entry.kind == "post" then
      info.posts = info.posts + 1
      if entry.by ~= "user" then
        info.last_reply = entry.seq
        if turn then
          turn.posted = turn.posted or not entry.no_reply
        elseif not entry.no_reply then
          waits("user", entry.at)
        end
      elseif info.waiting_on == "user" then
        waits(nil)
      end
    elseif entry.kind == "resolved" then
      info.status, info.outcome, info.resolved_at = "resolved", entry.outcome, entry.at
      waits(nil)
    elseif entry.kind == "reopened" then
      info.status, info.outcome = "open", nil
    elseif entry.kind == "renamed" and type(entry.title) == "string" then
      info.title = entry.title
    elseif entry.kind == "parent" then
      info.parent = entry.on ~= "none" and entry.on or nil
    elseif entry.kind == "working" then
      info.working = entry.state == "start"
      info.working_at = entry.at
      -- A turn on their post is the answer to whatever waited on them.
      if info.working and info.waiting_on == "user" then
        waits(nil)
      end
      if not info.working and turn then
        -- Its supervisor died: whatever it marked or posted, the user has to hear of it.
        if entry.died then
          waits("user", entry.at)
        elseif turn.mark then
          waits(turn.mark ~= "none" and turn.mark or nil, turn.at)
        elseif turn.posted then
          waits("user", entry.at)
        end
      end
      turn = info.working and {} or nil
    elseif entry.kind == "waiting" then
      -- isovim telling the router a worker finished: told once, till that worker does more.
      if entry.by == "isovim" then
        info.told_of, info.told_at = info.waiting_on, entry.at
      end
      waits(entry.on ~= "none" and entry.on or nil, entry.at)
      -- The router's own mark stands for its turn's post; the user's D or a worker clearing doesn't,
      -- but a worker clearing ends a mark on it.
      if turn and entry.by == "isovim" then
        turn.mark = turn.mark and "none"
      elseif turn and entry.by ~= "user" then
        turn.mark, turn.at = entry.on, entry.at
      end
    end
  end
  info.questions = M.questions(entries)
  info.pending = #vim.tbl_filter(function(q)
    return not q.answer
  end, info.questions)
  return info
end

-- The thread's questions, in order: each ask with its answer and raise, if any.
function M.questions(entries)
  local list, by_qid = {}, {}
  for _, entry in ipairs(entries) do
    if entry.kind == "ask" and type(entry.qid) == "string" then
      local q = { qid = entry.qid, question = entry.question, options = entry.options or {}, multi = entry.multi == true,
        other = entry.other == true, by = entry.by, at = entry.at, seq = entry.seq }
      list[#list + 1] = q
      by_qid[entry.qid] = q
    elseif entry.kind == "answered" and by_qid[entry.qid] then
      by_qid[entry.qid].answer = { labels = entry.labels or {}, other = entry.other, by = entry.by, at = entry.at }
    elseif entry.kind == "raised" and by_qid[entry.qid] then
      local q = by_qid[entry.qid]
      q.raised, q.raised_by, q.why = true, entry.by, entry.why
    end
  end
  return list
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

-- Why parent can't be a thread's parent here, or nil: it's a thread of the same repo, named by id.
local function parent_refusal(repo, parent)
  if not parent:match("^t%d+$") then
    return ("the parent is a thread of this repo, by its id (t3), not %s"):format(parent)
  elseif not M.read(repo, parent) then
    return ("%s has no thread %s"):format(repo, parent)
  end
end

-- A new thread in repo, titled title, by (user or an agent's address), under parent if given; its
-- id, or nil and why.
---@return string? id, string? err
function M.new(repo, title, by, parent)
  local why = M.refusal(repo) or (parent and parent_refusal(repo, parent))
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
  append(repo, id, { kind = "thread", id = id, title = title, created_by = by, status = "open", parent = parent })
  return id
end

local function exists(repo, id)
  local entries = M.read(repo, id)
  if not entries or not entries[1] then
    return nil, ("%s has no thread %s"):format(repo, id)
  end
  return entries
end

-- Asks a question in the thread (spec as isovim.surfaces.validate_question takes it), or finds it
-- asked there already, the same question with the same options: its qid, and how ("asked",
-- "reattached").
---@return string? qid, string how_or_err
function M.ask(repo, id, spec, by)
  local entries, err = exists(repo, id)
  if not entries then
    return nil, err
  end
  local q, why = require("isovim.surfaces").validate_question(spec)
  if not q then
    return nil, why
  end
  local n = 0
  for _, each in ipairs(M.questions(entries)) do
    if each.question == q.question and vim.deep_equal(each.options, q.options) and each.multi == q.multi and each.other == q.other then
      return each.qid, "reattached"
    end
    n = math.max(n, tonumber(each.qid:match("^q(%d+)$")) or 0)
  end
  local qid = "q" .. (n + 1)
  append(repo, id, { kind = "ask", qid = qid, question = q.question, options = q.options, multi = q.multi, other = q.other, by = by })
  return qid, "asked"
end

-- The answer to question qid ({labels, other?, by}), appended.
function M.answer(repo, id, qid, answer)
  return append(repo, id, { kind = "answered", qid = qid, labels = answer.labels, other = answer.other, by = answer.by })
end

-- Question qid given to the user by a root (root mode's raise).
function M.raise(repo, id, qid, by, why)
  return append(repo, id, { kind = "raised", qid = qid, by = by, why = why })
end

-- A post in the thread; no_reply: it needs nothing from the user, so it doesn't make it their turn.
---@param images? {path: string, mimeType: string}[]
---@return table? post, string? err
function M.post(repo, id, by, text, images, no_reply)
  local entries, err = exists(repo, id)
  if not entries then
    return nil, err
  end
  text = vim.trim(text or "")
  if text == "" and not (images and images[1]) then
    return nil, "a post needs text"
  end
  return append(repo, id, { kind = "post", by = by, text = text, images = images and images[1] and images or nil, no_reply = no_reply or nil })
end

-- Whose turn it is from now on: on is "user", an agent's address, or "none".
---@return boolean? marked, string? err
function M.wait_on(repo, id, on, by)
  local entries, err = exists(repo, id)
  if not entries then
    return nil, err
  elseif M.summary(entries).status ~= "open" then
    return nil, id .. " is resolved"
  end
  append(repo, id, { kind = "waiting", on = on, by = by })
  return true
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

-- Puts the thread under parent, or under nothing ("none"), refusing a cycle.
---@return boolean? set, string? err
function M.set_parent(repo, id, parent, by)
  local entries, err = exists(repo, id)
  if not entries then
    return nil, err
  end
  if parent ~= "none" then
    local why = parent_refusal(repo, parent)
    if why then
      return nil, why
    end
    -- Up from the new parent: reaching this thread would make a cycle.
    local at, seen = parent, {}
    while at and not seen[at] do
      if at == id then
        return nil, parent == id and (id .. " can't be its own parent")
          or ("%s is under %s already: that would be a cycle"):format(parent, id)
      end
      seen[at] = true
      local above = M.read(repo, at)
      at = above and M.summary(above).parent
    end
  end
  append(repo, id, { kind = "parent", on = parent, by = by })
  return true
end

-- The thread's parent, if any, and its children, oldest first, resolved ones too.
---@return string? parent, string[] children
function M.related(repo, id)
  local parent, children = nil, {}
  for _, info in ipairs(M.list(repo, true)) do
    if info.id == id then
      parent = info.parent
    elseif info.parent == id then
      table.insert(children, 1, info.id)
    end
  end
  return parent, children
end

-- The thread the router's running turn is on, if there's just the one: a thread a router makes
-- during it goes under it by default. No command needs telling, as a turn is marked in its thread.
function M.turn_thread(repo)
  local working = vim.tbl_filter(function(info)
    return info.working
  end, M.list(repo))
  return #working == 1 and working[1].id or nil
end

-- The router's turn on the thread started or ended (the supervisor's); died: it stopped mid-turn.
function M.working(repo, id, state, died)
  if vim.uv.fs_stat(M.file(repo, id)) then
    append(repo, id, { kind = "working", state = state, died = died or nil })
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

-- D: the user takes the thread out of the Inbox without replying or resolving it, whether it waits on
-- them, has a reply they haven't read, or both; the agent's next post brings it back.
function M.dismiss(repo, id)
  local entries, err = exists(repo, id)
  if not entries then
    return nil, err
  end
  if M.summary(entries).waiting_on == "user" then
    append(repo, id, { kind = "waiting", on = "none", by = "user" })
  end
  local now = M.read(repo, id)
  M.mark_seen(repo, id, now[#now].seq)
  return true
end

-- How long a thread with only its title waits for a first post before the router gets the title, and
-- how long a draft in its composer holds that off, from its last keystroke. And how long a worker
-- that's a thread's wait gets to start: it's marked as it's messaged, often before it's working.
-- And how long a router's turn on a thread gets to show as its state: it's written just before.
local TITLE_WAIT, DRAFT_WAIT, WORKER_START, TURN_START = 30, 300, 30, 15

local function draft_file(repo, id)
  return store.run_dir(repo) .. "/thread-draft-" .. id
end

-- The user is writing a first post in the thread's composer, or isn't any more.
function M.drafting(repo, id, typing)
  if not typing then
    os.remove(draft_file(repo, id))
    return
  end
  vim.fn.mkdir(store.run_dir(repo), "p")
  local file = io.open(draft_file(repo, id), "wb")
  if file then
    file:close()
  end
end

local function drafted(repo, id)
  local stat = vim.uv.fs_stat(draft_file(repo, id))
  return stat ~= nil and os.time() - stat.mtime.sec < DRAFT_WAIT
end

-- Ends the turns nothing will end: a router's supervisor that dies mid-turn never writes the end, and
-- until it's written the thread says working… and stays out of the Inbox. Run by that supervisor
-- once it's back and by the TUI, which sees it whether or not it comes back. True if it ended one.
---@return boolean
function M.end_dead_turns(repo)
  local status = require("isovim.status")
  local ended, alive = false, nil
  for _, info in ipairs(M.list(repo)) do
    if info.working and os.time() - (info.working_at or 0) >= TURN_START then
      if alive == nil then
        local router = store.router(repo)
        alive = router ~= nil and status.owner_state(router) == "working"
      end
      if not alive then
        M.working(repo, info.id, "end", true)
        ended = true
      end
    end
  end
  return ended
end

-- Whether an agent between turns still has work going under its supervisor (a background shell, a
-- Monitor, a turn it started itself), which it'll come back to. Bounded and in its own process, as a
-- stuck worker must not hang its router's supervisor; one that can't say counts as having none.
local function has_background(address)
  local ws, id = address:match("^(.*)/([^/]+)$")
  local sock = require("isovim.acp").socket(ws, id)
  if not vim.uv.fs_stat(sock) then
    return false
  end
  local asked = vim.system({ vim.v.progpath, "--headless", "--server", sock, "--remote-expr",
    [[luaeval("vim.json.encode(require('isovim.acp.host').call('background', vim.empty_dict()))")]] },
    { text = true, timeout = 3000 }):wait()
  local ok, answer = pcall(vim.json.decode, asked.stdout or "")
  return ok and type(answer) == "table" and type(answer.work) == "table" and #answer.work > 0
end

-- Whether the router marked a worker it's already been told of, that hasn't done anything since:
-- it knows, and asked to go on waiting.
local function told_already(info, worker)
  local ws, id = worker:match("^(.*)/([^/]+)$")
  local stat = info.told_of == worker and vim.uv.fs_stat(store.state_file(ws, id))
  return stat and stat.mtime.sec <= (info.told_at or 0)
end

-- One look over the repo's open threads: say(text) sends the router a message.
function M.sweep(repo, say)
  local status = require("isovim.status")
  M.end_dead_turns(repo)
  for _, info in ipairs(M.list(repo)) do
    local worker = info.waiting_on ~= "user" and info.waiting_on or nil
    local state = worker and status.owner_state(worker)
    if state == "gone" or (state == "idle" and os.time() - (info.waiting_at or 0) >= WORKER_START
      and not told_already(info, worker) and not has_background(worker)) then
      append(repo, info.id, { kind = "waiting", on = "none", by = "isovim", why = state })
      say(("[isovim] Thread %s %q was waiting on %s, which %s. Post where it stands with `iso router thread "
        .. "post %s \"...\"`, mark who it waits on now, or resolve it if it's settled. Marking the same worker "
        .. "again waits quietly until it does more."):format(info.id, info.title,
        worker, state == "gone" and "is gone" or "has finished its turn", info.id))
    end
    if info.posts == 0 and info.created_by == "user" and os.time() - (info.at or 0) >= TITLE_WAIT and not drafted(repo, info.id) then
      append(repo, info.id, { kind = "post", by = "user", text = info.title })
      M.drafting(repo, info.id, false)
      say(M.prompt(repo, info.id, info.title, info.title))
    end
  end
end

-- Keeps the repo's threads moving, from its router's supervisor, so it runs whether or not the TUI
-- is open: every 10s, and soon after one of the repo's agents changes state or goes.
---@param repo string
---@param say fun(text: string)
function M.listen(repo, say)
  local safe = require("isovim.safe")
  local sweep = safe.wrap("threads.sweep", function()
    M.sweep(repo, say)
  end)
  local tick, soon = assert(vim.uv.new_timer()), assert(vim.uv.new_timer())
  tick:start(5000, 10000, vim.schedule_wrap(sweep))
  require("isovim.events").watch(function(_, event)
    if event.scope == repo and event.topic:match("^agent%.") and (event.topic:match("%.status$") or event.topic:match("%.exited$"))
      and not soon:is_active() then
      soon:start(2000, 0, vim.schedule_wrap(sweep))
    end
  end)
end

-- Follows a thread file: on_entry(entry) for each line from line from+1 on, as it's appended
-- (watching its folder), on_reset() if the file shrinks or goes, on_other() when another thread's
-- file changes. Returns stop and where it's read to.
function M.follow(repo, id, on_entry, on_reset, from, on_other)
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
      elseif not err and on_other and name:match("%.jsonl$") then
        on_other()
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
