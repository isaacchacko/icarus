-- Threads: one idea's conversation between the user and a repo's router, read on its own. The router
-- stays one agent with one session, its context warm; a thread is a view of the exchanges about one
-- thing, so its chat doesn't drown in every small idea, and no new agent pays a cold start for each.
-- They live only in a repo with a router on this host: General and Terminals have none.
--
-- A thread is iso/threads/<id>.jsonl in the repo's iso/ (ids t1, t2...), appended to, never
-- rewritten, a JSON object a line:
--   {kind = "thread", id, title, created_by, at, status = "open", stand_in?}    its header, first; stand_in:
--                                                   its title is only cut from the first post, for the agent to replace
--   {kind = "task", on = <task id>|"none", by, at}  the task it's on (isovim.board_tasks), one at most;
--                                                   a thread made in a turn on it takes it (M.new's callers)
--   {kind = "post", by = "user"|<agent address>, text, at, images?, no_reply?, keeps_wait?}
--                                                   no_reply: it needs nothing from the user (below);
--                                                   keeps_wait: the turn that made it also marked a worker
--   {kind = "resolved", by, outcome?, tell?, at}, {kind = "reopened", by, at}   tell: an agent resolved
--                                                   it, so it's marked unread, without needing them,
--                                                   until they open it; not on a root's answer, which
--                                                   the decision log takes
--   {kind = "renamed", by, title, from?, at}        its title from then on, and what it was (posts keep
--                                                   their tags); the header keeps the first, which stays shown
--   {kind = "ask", qid, question, options, multi, other, by, at}   a question the router asks in it
--   {kind = "answered", qid, labels, other?, by, at}, {kind = "raised", qid, by, why?, at}
-- A question asked in a thread lives there, not in the repo: isovim.surfaces lists each one still
-- waiting as a question surface (named <id>-<qid>, its file the thread's), so the Inbox, root mode
-- and iso answer take it as any question; its answer is appended here, where the asker's thread
-- ask waits for it.
--   {kind = "bypass", on = <worker address>|"none", by, why?, at}   who the user's posts go to, in the
--                                                   router's place (below); {kind = "bypass_told", upto, at}
--   {kind = "working", state = "start"|"end", by?, died?, at}   the router's turn on one of its posts;
--                                                   died: it stopped mid-turn (M.end_dead_turns)
--   {kind = "waiting", on = "user"|<agent address>|"none", by, why?, at}   whose turn it is
-- A post of the user's goes to the router as a prompt tagged "[thread <repo>#<id> "<title>"]";
-- the supervisor (isovim.acp.host) marks that turn working in the thread and posts the turn's last
-- message there when it ends, so the router just answers. Posts on one thread that wait in its queue
-- go together, as one prompt and one turn. It posts more with iso router thread
-- post. What the user has read (the last line seen, per thread) is run/<repo>/threads.json: a
-- router post past it marks the thread unread (new_reply) until they open it.
--
-- Whose turn it is is apart from what's been read. After an agent's post it's the user's turn, opened
-- or not, so they never miss one: the thread is in the Inbox until they post, it's resolved or they
-- dismiss it (D). The agent opts out when a post needs nothing from them: iso router thread post
-- --no-reply, or iso router thread waiting <id> none|<worker> in a turn whose last message posts
-- itself, the mark standing for that post. Posts during a turn on the thread count when it ends.
-- Waiting on a worker clears on the router's next post, unless that turn marked it too, or once that
-- worker has finished or gone, and the router is told, when it's free to hear it; M.listen,
-- in the router's supervisor, sees to that.
--
-- The user starts a thread with its first message, which goes to the router as any post, under a stand-in title
-- cut from it (stand_in on the header) till someone renames it, the prompt saying to.
--
-- A bypass lets a thread go back and forth with one worker at less cost, the router staying its owner.
-- Only a router makes, replaces or deletes one, and a worker holds one at most. While it stands the
-- user's posts go straight to the worker, tagged as always, so its supervisor treats the turn as a
-- router's does, and the router hears nothing of them. The worker asks to end it with thread release. It
-- ends on its own when the thread is resolved or the worker is removed or stays down; a restart keeps it.
-- Who has to hear of an end is worked out from the file, so they're told once, by the router's
-- supervisor (M.sweep), whoever ended it and whatever restarted since.
--
-- A dedicated router (iso router spawn --dedicated) takes threads in the main router's place, any
-- number of them, which a worker's one bypass doesn't describe: it's who the thread is with (M.router_of),
-- beneath any bypass. It has its task's threads, old and new, as nothing but its record says so, and those
-- bypassed to it, an {kind = "owner", on, by} entry. A worker's bypass from it ends back at it. Once it's
-- removed they're the main router's again, with nothing to undo. The main router's supervisor still does the
-- sweep for all of them, telling each what's about its own threads.
local store = require("isovim.store")

local M = {}

function M.dir(repo)
  return store.path(repo) .. "/threads"
end

function M.file(repo, id)
  return M.dir(repo) .. "/" .. id .. ".jsonl"
end

-- Why repo can't have threads, or nil when it can: a repo (not General) with a router here.
function M.refusal(repo)
  if not repo or store.is_pseudo(repo) or not store.valid_key(repo) then
    return "threads live in a repo with a router; General and Terminals have none"
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
  local info = { id = head.id, title = head.title or head.id or "?", first_title = not head.stand_in and head.title or nil, stand_in = head.stand_in, created_by = head.created_by, at = head.at,
    status = head.status or "open", posts = 0, last_reply = 0, working = false, root_posts = 0 }
  local function waits(on, at)
    info.waiting_on, info.waiting_at = on, at
  end
  -- Bypasses that have ended, for those who haven't been told.
  info.ended_bypasses = {}
  local function bypass_ended(entry, why)
    info.ended_bypasses[#info.ended_bypasses + 1] = { worker = info.bypass, why = why, by = entry.by, outcome = entry.outcome, seq = entry.seq }
  end
  -- The router's turn on the thread, while it runs: whether it posted for the user, and its mark.
  local turn
  for _, entry in ipairs(entries) do
    if entry.kind == "post" or entry.kind == "resolved" or entry.kind == "reopened" or entry.kind == "thread" then
      info.last_at = entry.at or info.last_at
    end
    if entry.kind == "post" then
      info.posts = info.posts + 1
      info.last_by = entry.by
      info.root_answer = entry.root and entry or nil
      -- After it's resolved, and not a turn's closing word on it: something new that may need the user.
      if info.status == "resolved" and entry.by ~= "user" and not entry.no_reply and not info.working then
        info.late_post = entry.seq
      end
      if entry.by == "user" then
        info.root_posts, info.handed = 0, nil
      end
      if entry.root then
        -- The root answered in the user's place: it no longer waits on them, and nothing new to read.
        info.root_posts, info.handed = info.root_posts + 1, nil
        waits(nil)
      elseif entry.by ~= "user" then
        info.last_reply = entry.seq
        if turn then
          turn.posted, turn.spoke = turn.posted or not entry.no_reply, true
        elseif entry.keeps_wait then
          -- It marked a worker in the same turn: that's what it waits on.
        elseif not entry.no_reply then
          waits("user", entry.at)
        elseif info.waiting_on ~= "user" then
          waits(nil)
        end
      elseif info.waiting_on == "user" then
        waits(nil)
      end
    elseif entry.kind == "resolved" then
      info.status, info.outcome, info.resolved_at = "resolved", entry.outcome, entry.at
      info.resolved_seq = entry.tell and entry.seq or nil
      waits(nil)
      if info.bypass then
        bypass_ended(entry, "resolved")
        info.bypass = nil
      end
    elseif entry.kind == "reopened" then
      info.status, info.outcome, info.resolved_seq, info.root_answer, info.late_post = "open", nil, nil, nil, nil
    elseif entry.kind == "ask" or entry.kind == "answered" or entry.kind == "raised" then
      info.root_answer = nil
    elseif entry.kind == "renamed" and type(entry.title) == "string" then
      info.title, info.stand_in = entry.title, nil
    elseif entry.kind == "task" then
      info.task = entry.on ~= "none" and entry.on or nil
    elseif entry.kind == "bypass" then
      local on = entry.on ~= "none" and entry.on or nil
      if info.bypass and info.bypass ~= on then
        bypass_ended(entry, entry.why or (on and "replaced" or "deleted"))
      end
      info.bypass = on
    elseif entry.kind == "owner" then
      info.owner = entry.on ~= "none" and entry.on or nil
    elseif entry.kind == "handed" then
      info.handed = entry.seq
    elseif entry.kind == "bypass_told" then
      info.ended_bypasses = vim.tbl_filter(function(each)
        return each.seq > (entry.upto or 0)
      end, info.ended_bypasses)
    elseif entry.kind == "working" then
      info.working = entry.state == "start"
      info.working_at = entry.at
      info.working_by = info.working and entry.by or nil
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
        elseif turn.spoke and info.waiting_on ~= "user" then
          waits(nil)
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
  info.last_seq = entries[#entries] and entries[#entries].seq or 0
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

-- A thread's title until it's given one: the first line of what started it, cut short.
function M.stand_in(text)
  local line = vim.trim((text or ""):gsub("%[Image #%d+%]", ""):match("[^\n]*%S[^\n]*") or ""):gsub("%s+", " ")
  if line == "" then
    return "An image"
  end
  return vim.fn.strchars(line) > 60 and (vim.fn.strcharpart(line, 0, 59) .. "…") or line
end

-- A new thread in repo, titled title, by (user or an agent's address), on task if given, its title only a
-- stand-in if stand_in; its id, or nil and why.
---@return string? id, string? err
function M.new(repo, title, by, task, stand_in)
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
  append(repo, id, { kind = "thread", id = id, title = title, created_by = by, status = "open", stand_in = stand_in or nil })
  if task then
    append(repo, id, { kind = "task", on = task, by = by })
    require("isovim.board_tasks").note_thread(repo, task, id, true, by)
  end
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

-- Whether by marked a worker during the turn it's in now, outside a turn on this thread (that keeps
-- track itself): its state file was last written as the turn started.
local function marked_this_turn(info, by)
  if info.working or not info.waiting_on or info.waiting_on == "user" or by == "user" then
    return false
  end
  local ws, agent = by:match("^(.*)/([^/]+)$")
  local stat = ws and vim.uv.fs_stat(store.state_file(ws, agent))
  return stat ~= nil and (info.waiting_at or 0) >= stat.mtime.sec
end

-- A post in the thread; no_reply: it needs nothing from the user, so it doesn't make it their turn.
-- Says so if that left the thread on the user's turn, for a root with no grace (isovim.rootmode).
local function publish_users_turn(repo, id)
  local info = M.summary(M.read(repo, id) or {})
  if info.waiting_on == "user" and not info.working then
    local events = require("isovim.events")
    events.publish(events.topic("thread", repo, id, "users_turn"), { repo = repo, id = id })
  end
end

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
  local post = append(repo, id, { kind = "post", by = by, text = text, images = images and images[1] and images or nil,
    no_reply = no_reply or nil, keeps_wait = marked_this_turn(M.summary(entries), by) or nil })
  publish_users_turn(repo, id)
  return post
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
  publish_users_turn(repo, id)
  return true
end

-- Resolves the thread with an outcome, or (resolved already) opens it again.
---@return string? status, string? err
function M.resolve(repo, id, by, outcome, reopen)
  local entries, err = exists(repo, id)
  if not entries then
    return nil, err
  end
  local info = M.summary(entries)
  if reopen then
    if info.status == "open" then
      return nil, id .. " is open"
    end
    append(repo, id, { kind = "reopened", by = by })
    return "open"
  elseif info.status == "resolved" then
    return nil, id .. " is resolved already"
  end
  outcome = outcome and vim.trim(outcome) ~= "" and vim.trim(outcome) or nil
  -- An agent resolving on a root's answer: nothing is left for the user, and the Root log holds it.
  local decided = by ~= "user" and info.root_answer
  if decided then
    require("isovim.surfaces").log_thread_decision(repo, id, info.title, decided, outcome)
  end
  append(repo, id, { kind = "resolved", by = by, outcome = outcome, tell = by ~= "user" and not decided or nil })
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
  append(repo, id, { kind = "renamed", by = by, title = title, from = M.summary(entries).title })
  return title
end

-- Puts the thread on a task, or on none ("none"): the board's, so the user's.
---@return boolean? set, string? err
function M.set_task(repo, id, task, by)
  local entries, err = exists(repo, id)
  if not entries then
    return nil, err
  end
  local tasks = require("isovim.board_tasks")
  tasks.note_thread(repo, M.summary(entries).task, id, false, by)
  append(repo, id, { kind = "task", on = task, by = by })
  if task ~= "none" then
    tasks.note_thread(repo, task, id, true, by)
  end
  return true
end

-- The thread's task, if any, and the other threads on it, oldest first, resolved ones too, who it's
-- bypassed to, and the title it started with if it has been renamed since, as the user's question is
-- often all of it.
---@return string? task, string[] siblings, string? bypass, string? first_title
function M.related(repo, id)
  local all = M.list(repo, true)
  local task, siblings, bypass, first_title = nil, {}, nil, nil
  for _, info in ipairs(all) do
    if info.id == id then
      task, bypass = info.task, info.bypass
      first_title = info.first_title ~= info.title and info.first_title or nil
    end
  end
  for _, info in ipairs(all) do
    if task and info.task == task and info.id ~= id then
      table.insert(siblings, 1, info.id)
    end
  end
  return task, siblings, bypass, first_title
end

-- The thread by's running turn is on, if there's just the one: a thread by makes during it lands on
-- that one's task. No command needs telling, as a turn is marked in its thread.
function M.turn_thread(repo, by)
  local working = vim.tbl_filter(function(info)
    return info.working and (info.working_by == by or (not info.working_by and not info.bypass))
  end, M.list(repo))
  return #working == 1 and working[1].id or nil
end

-- The turn of by (a router or a bypassed worker) on the thread started or ended (the supervisor's);
-- died: it stopped mid-turn.
function M.working(repo, id, state, died, by)
  if vim.uv.fs_stat(M.file(repo, id)) then
    append(repo, id, { kind = "working", state = state, died = died or nil, by = by })
    if state == "end" then
      publish_users_turn(repo, id)
    end
  end
end

-- The open thread a worker holds a bypass to, if any.
function M.holder(repo, worker)
  local info = vim.iter(M.list(repo)):find(function(each)
    return each.bypass == worker
  end)
  return info and info.id
end

-- Why the thread can't go to on (a worker's address, or "none"), or nil.
function M.bypass_refusal(repo, id, on)
  local entries, err = exists(repo, id)
  if not entries then
    return err
  end
  local info = M.summary(entries)
  if info.status ~= "open" then
    return id .. " is resolved"
  elseif on == "none" then
    return not (info.bypass or info.owner) and (id .. " has no bypass: it goes to its router") or nil
  elseif info.bypass == on or info.owner == on then
    return ("%s goes to %s already"):format(id, on)
  end
  local ws, agent = on:match("^(.*)/([^/]+)$")
  local record = ws and store.agent(ws, agent)
  if not record or ws ~= repo then
    return ("%s isn't an agent of %s on this host"):format(on, repo)
  elseif record.dedicated then
    return nil
  elseif store.role(record) ~= "worker" then
    return ("%s is a %s: a bypass goes to a worker or a dedicated router"):format(on, store.role(record))
  elseif record.of or not require("isovim.panes").reports(record.kind) then
    return ("%s is a terminal or a script's pane: a bypass goes to a worker"):format(on)
  end
  local holds = M.holder(repo, on)
  if holds then
    return ("%s holds %s's bypass already, and a worker holds one: end that first"):format(on, holds)
  end
end

-- The thread goes to on from now, or back with "none": from a worker to its router, else from a
-- dedicated router to the main one (why: isovim's reason). A wait on that worker it replaces, as it's
-- now who the thread goes to. Any open thread can have one, whatever it holds already: nothing here
-- needs more than its entries.
function M.set_bypass(repo, id, on, by, why)
  local info = M.summary(M.read(repo, id) or {})
  local ws, agent = on:match("^(.*)/([^/]+)$")
  local record = ws and store.agent(ws, agent)
  if (record and record.dedicated) or (on == "none" and not info.bypass) then
    append(repo, id, { kind = "owner", on = on, by = by })
    return
  end
  if info.waiting_on == on then
    append(repo, id, { kind = "waiting", on = "none", by = "isovim", why = "bypass" })
  end
  append(repo, id, { kind = "bypass", on = on, by = by, why = why })
end

-- The repo's main router, and each task's dedicated one, for one look over its threads.
---@return {main?: string, tasks: table<string, string>}
function M.routers(repo)
  local routers = { main = store.router(repo), tasks = {} }
  for _, agent in ipairs(store.agents(repo)) do
    local task = agent.dedicated and agent.dedicated.task
    if task then
      routers.tasks[task] = repo .. "/" .. agent.id
    end
  end
  return routers
end

local function exists_agent(address)
  local ws, agent = address:match("^(.*)/([^/]+)$")
  return ws ~= nil and store.agent(ws, agent) ~= nil
end

-- The router a thread is with: the dedicated router it was bypassed to, else its task's, else the main one.
---@param routers? table M.routers, for a caller going through many threads
function M.router_of(repo, info, routers)
  if info.owner and exists_agent(info.owner) then
    return info.owner
  end
  routers = routers or M.routers(repo)
  return routers.tasks[info.task or ""] or routers.main
end

-- Who the user's posts on the thread go to: its bypass, while that worker exists, else its router.
---@return string? address, boolean? bypassed
function M.recipient(repo, id)
  local info = M.summary(M.read(repo, id) or {})
  if info.bypass and exists_agent(info.bypass) then
    return info.bypass, true
  end
  return M.router_of(repo, info), false
end

-- Who has the thread in the main router's place, if anyone does.
---@param routers? table M.routers
---@return string? address
function M.goes_to(repo, info, routers)
  routers = routers or M.routers(repo)
  local router = info.bypass or M.router_of(repo, info, routers)
  return router ~= routers.main and router or nil
end

-- What a bypassed worker is told with each post, as a role's prompt doesn't say it.
M.BYPASS_NOTE = "\n\n(This thread's bypass is yours: this turn's last message is posted to it for you and is its only output, as "
  .. "is that of the turn a background job started here wakes when it ends. No other turn of yours posts: use iso worker thread "
  .. "post. iso worker thread release <reason> asks the router to end the bypass.)"

-- What a worker is told as a thread is bypassed to it.
function M.bypass_prompt(repo, id, title, router)
  return ("You now hold a bypass to thread %s %q of %s, from %s: the user's posts there come straight to you as prompts "
    .. "tagged with the thread, and the router doesn't see them. Read it so far with `iso worker thread show %s`.\n\n"
    .. "Answer within its topic. On a turn from one of those prompts, your last message, only what you say after your last tool "
    .. "call, is posted to the thread for you and is that turn's only output: don't post it again, and make it whole, as nobody reads "
    .. "your chat for it. The same goes for the turn a background job you started in such a turn wakes when it ends. No other turn "
    .. "posts, so a parent's message, other work or a Monitor's event stays in your chat: for those use `iso worker thread post %s "
    .. "\"...\"` if the user should see it. After "
    .. "any post of yours it's the user's turn, in their Inbox until they post, so when one needs nothing from them, run `iso "
    .. "worker thread waiting %s none` before you end the turn, or use `iso worker thread post %s --no-reply \"...\"`.\n\n"
    .. "You can't move the bypass or resolve the thread; the router stays its owner, and can still post there. `iso worker thread "
    .. "release <reason>` asks it to end this, and can carry the outcome you'd propose. Your other work and your parent stay as "
    .. "they were."):format(id, title, repo, router or "the router", id, id, id, id)
end

-- What a dedicated router is told as a thread is bypassed to it.
function M.owner_prompt(repo, id, title, by)
  return ("Thread %s %q of %s is yours now, from %s: the user's posts there come straight to you as prompts tagged with the "
    .. "thread. Read it so far with `iso router thread show %s`."):format(id, title, repo, by, id)
end

-- Sends an agent a prompt, from a process that stays up (the TUI or a supervisor).
local function send_to(address, text, images)
  local cmd = { require("isovim.panes").bin, "send", address }
  for _, image in ipairs(images or {}) do
    vim.list_extend(cmd, { "--image", image.path })
  end
  cmd[#cmd + 1] = text
  return vim.system(cmd, { text = true })
end

-- A post that is only one of these asks for the last agent post on the thread again, this way.
local SHORTCUTS = {
  qqq = "with fewer characters and no fluff, losing no fact or decision",
  www = "as /kin would (the kin skill), for a reader with no context on what's going on",
}

-- What the agent is told for a shortcut; nil for any other post, and with no agent post yet to
-- rewrite, when it's an ordinary post. Posts merged with it (isovim.acp.host) go in order around it.
local function shortcut(repo, id, text)
  local how = SHORTCUTS[vim.trim(text)]
  local last
  for _, entry in ipairs(how and M.read(repo, id) or {}) do
    if entry.kind == "post" and entry.by ~= "user" then
      last = entry
    end
  end
  return last and ("[isovim: the user posted only \"%s\", which asks you to rewrite the last agent post on this thread %s. "
    .. "It's %s's, starting \"%s\"; iso <your role> thread show %s has it if it's been compacted away. Unless other posts "
    .. "came with this one, the rewrite is this turn's reply, and needs no work beyond that.]")
    :format(vim.trim(text), how, last.by, (last.text or ""):gsub("%s+", " "):sub(1, 60), id) or nil
end

-- What the router is sent for a post of the user's. The tag names its task, if it's on one; the
-- supervisor's batching needs it to end in `"]`. A stand-in title is said to be one till it's replaced.
function M.prompt(repo, id, title, text)
  local info = M.summary(M.read(repo, id) or {})
  local on = info.task and require("isovim.board_tasks").read(repo)[info.task]
  local name = info.stand_in and ("\n\n(This thread's title is only a stand-in cut from the user's first words. Name it as you "
    .. "answer: `iso <your role> thread rename %s \"<title>\"`.)"):format(id) or ""
  return ("[thread %s#%s %q%s] %s%s"):format(repo, id, title, on and (" · task %s %q"):format(on.id, on.title) or "",
    shortcut(repo, id, text) or text, name)
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
  local info = M.summary(M.read(repo, id) or {})
  return info.last_reply > was or (info.resolved_seq or 0) > was
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

-- How long a worker that's a thread's wait gets to start: it's marked as it's messaged, often before
-- it's working. And how long a router's turn on a thread gets to show as its state: it's written just before.
local WORKER_START, TURN_START = 30, 15

local function draft_file(repo, id)
  return store.run_dir(repo) .. "/thread-draft-" .. id
end

-- There's text in the thread's composer as of now, from a key the user pressed, or there isn't any more.
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

-- Ends the turns nothing will end: a router's supervisor that dies mid-turn never writes the end, and
-- until it's written the thread says working… and stays out of the Inbox. Run by that supervisor
-- once it's back and by the TUI, which sees it whether or not it comes back. True if it ended one.
---@return boolean
function M.end_dead_turns(repo)
  local status = require("isovim.status")
  local ended, alive = false, {}
  for _, info in ipairs(M.list(repo)) do
    if info.working and os.time() - (info.working_at or 0) >= TURN_START then
      -- A worker on older code doesn't say the turn is its, so its bypass does.
      local owner = info.working_by or info.bypass or store.router(repo) or ""
      if alive[owner] == nil then
        alive[owner] = owner ~= "" and status.owner_state(owner) == "working"
      end
      if not alive[owner] then
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

-- How a worker something waits on has finished, in words, or nil if it hasn't: gone, or between turns
-- with nothing going, WORKER_START after the mark. told_at: the router was told of it then, and marked
-- it again, so it waits quietly until that worker has done something since.
local function finished(worker, marked_at, told_at)
  local state = require("isovim.status").owner_state(worker)
  if state == "gone" then
    return "is gone"
  elseif state ~= "idle" or os.time() - (marked_at or 0) < WORKER_START or has_background(worker) then
    return nil
  end
  local ws, id = worker:match("^(.*)/([^/]+)$")
  local stat = told_at and vim.uv.fs_stat(store.state_file(ws, id))
  if stat and stat.mtime.sec <= told_at then
    return nil
  end
  return "has finished its turn"
end

-- How long a bypassed worker may stay down before its bypass ends: a restart comes back within it.
local WORKER_DOWN = 30
local down_since = {}

-- Ends the bypass of a worker that's been removed or has stayed down.
local function end_gone_bypasses(repo)
  for _, info in ipairs(M.list(repo)) do
    local worker = info.bypass
    if worker then
      local ws, agent = worker:match("^(.*)/([^/]+)$")
      if not store.agent(ws, agent) then
        down_since[worker] = nil
        M.set_bypass(repo, info.id, "none", "isovim", "removed")
      elseif require("isovim.panes").running(ws, agent) then
        down_since[worker] = nil
      else
        down_since[worker] = down_since[worker] or os.time()
        if os.time() - down_since[worker] >= WORKER_DOWN then
          down_since[worker] = nil
          M.set_bypass(repo, info.id, "none", "isovim", "exited")
        end
      end
    end
  end
end

-- Tells those who have to hear that a bypass ended, once: the worker if it's still there, the router
-- unless it did it.
local function tell_ended_bypasses(repo, tell)
  for _, info in ipairs(M.list(repo, true)) do
    local upto = 0
    for _, ended in ipairs(info.ended_bypasses) do
      upto = math.max(upto, ended.seq)
      local where = ("thread %s %q"):format(info.id, info.title)
      if ended.why ~= "removed" and ended.why ~= "exited" then
        send_to(ended.worker, ("[isovim] Your bypass to %s has ended: %s. Its posts don't come to you any more."):format(where,
          ended.why == "resolved" and "the thread was resolved" or ended.why == "replaced" and "it went to another worker"
            or "the router ended it"))
      end
      if ended.by ~= M.router_of(repo, info) then
        tell(info, ("[isovim] The bypass of %s to %s has ended: %s. The user's next post comes to you."):format(where, ended.worker,
          ended.why == "resolved" and ("the thread was resolved by " .. tostring(ended.by)) or ended.why == "removed"
            and "that worker was removed" or ended.why == "exited" and "that worker stopped" or tostring(ended.why)))
      end
    end
    if upto > 0 then
      append(repo, info.id, { kind = "bypass_told", upto = upto })
    end
  end
end

-- Says which dedicated routers are gone since the last look, once each, as their threads come back
-- to the main router however they went. Forgets across a restart of its supervisor, which only
-- loses that one line: the threads have already gone back.
local known_dedicated = {}
local function tell_gone_dedicated(repo, say)
  local now = {}
  for _, agent in ipairs(store.agents(repo)) do
    if agent.dedicated then
      now[repo .. "/" .. agent.id] = agent.dedicated
    end
  end
  for address, dedicated in pairs(known_dedicated[repo] or {}) do
    if not now[address] then
      local back = vim.tbl_map(function(info)
        return info.id
      end, vim.tbl_filter(function(info)
        return info.owner == address or (dedicated.task and info.task == dedicated.task)
      end, M.list(repo)))
      say(("[isovim] Dedicated router %s (%s) is gone. %s"):format(address, dedicated.task and ("task " .. dedicated.task) or dedicated.component,
        #back > 0 and ("Its threads come to you again: " .. table.concat(back, ", ") .. ".") or "It had no open threads."))
    end
  end
  known_dedicated[repo] = now
end

-- One look over the repo's open threads: say(text) sends the main router a message, and what's about
-- a thread goes to the router it's with. Telling it of a worker
-- waits till busy() says it's free, as queued it could arrive after the router has settled the thread
-- anyway; what's still so then is looked at afresh.
function M.sweep(repo, say, busy)
  M.end_dead_turns(repo)
  end_gone_bypasses(repo)
  local main = store.router(repo)
  local function tell(info, text)
    local to = M.router_of(repo, info)
    if to == main then
      say(text)
    else
      send_to(to, text)
    end
  end
  tell_ended_bypasses(repo, tell)
  tell_gone_dedicated(repo, say)
  require("isovim.pages").sweep(repo, say, busy, finished)
  for _, info in ipairs(M.list(repo)) do
    local worker = info.waiting_on ~= "user" and info.waiting_on or nil
    local how = worker and not busy() and finished(worker, info.waiting_at, info.told_of == worker and info.told_at or nil)
    if how then
      append(repo, info.id, { kind = "waiting", on = "none", by = "isovim", why = how == "is gone" and "gone" or "idle" })
      tell(info, ("[isovim] Thread %s %q was waiting on %s, which %s. Post where it stands with `iso router thread "
        .. "post %s \"...\"`, mark who it waits on now, or resolve it if it's settled. Marking the same worker "
        .. "again waits quietly until it does more."):format(info.id, info.title,
        worker, how, info.id))
    end
  end
end

-- Keeps the repo's threads moving, from its router's supervisor, so it runs whether or not the TUI
-- is open: every 10s, and soon after one of the repo's agents changes state or goes.
---@param repo string
---@param say fun(text: string)
---@param busy fun(): boolean
function M.listen(repo, say, busy)
  local safe = require("isovim.safe")
  local sweep = safe.wrap("threads.sweep", function()
    M.sweep(repo, say, busy)
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

-- Root mode (isovim.rootmode) has a root on top of its repo's threads, as of its Inbox's questions.
-- When an agent's post has sat on the user's turn for a while, the root is told once, and answers in
-- the user's place or leaves it, which leaves it in their Inbox. A root doesn't go back and forth with
-- a router for long: past ROOT_ANSWERS answers with no word from the user, the thread stays theirs.
local ROOT_ANSWERS, VIEW_FRESH = 3, 30

local function root_told_file(repo)
  return store.run_dir(repo) .. "/root-threads.json"
end

-- The thread is on screen in front of the user (the TUI's, every few seconds while it is), and when
-- they last pressed a key in it.
function M.viewing(repo, id, last_key)
  vim.fn.mkdir(store.run_dir(repo), "p")
  vim.fn.writefile({ tostring(last_key) }, store.run_dir(repo) .. "/thread-view-" .. id)
end

-- What holds the root back from a thread the user may be at stops, in case they've walked away, once
-- it's sat for thread_root_grace with no key pressed since the post landed.
local function not_walked_away(last_key, info)
  return os.time() - math.max(last_key, info.waiting_at or 0) < require("isovim.config").thread_root_grace() * 60
end

local function drafted(repo, info)
  local stat = vim.uv.fs_stat(draft_file(repo, info.id))
  return stat ~= nil and not_walked_away(stat.mtime.sec, info)
end

local function viewed(repo, info)
  local file = store.run_dir(repo) .. "/thread-view-" .. info.id
  local stat = vim.uv.fs_stat(file)
  if not stat or os.time() - stat.mtime.sec >= VIEW_FRESH then
    return false
  end
  local ok, lines = pcall(vim.fn.readfile, file)
  return not_walked_away(ok and tonumber(lines[1]) or 0, info)
end

local function by_a_root(address)
  local ws, agent = (address or ""):match("^(.*)/([^/]+)$")
  local record = ws and store.agent(ws, agent)
  return record ~= nil and store.role(record) == "root"
end

-- The user hands the thread to the root at once (gr on it), past the wait and whatever it says.
function M.hand_to_root(repo, id)
  local entries, err = exists(repo, id)
  if not entries then
    return nil, err
  end
  append(repo, id, { kind = "handed", by = "user" })
  local events = require("isovim.events")
  events.publish(events.topic("thread", repo, id, "handed"), { repo = repo, id = id })
  return true
end

-- Whether the root may answer now: the user has spoken since, or it's moved on, and it may not.
function M.root_may_answer(info)
  return info.status == "open" and (info.handed ~= nil or (info.waiting_on == "user" and info.last_by ~= "user"))
end

-- What a router or a bypass holder is told with the root's answer: their reply is a turn on the
-- thread as any other, and would land on the user's turn.
M.ROOT_NOTE = "\n\n(That's the root, answering in the user's place. If your reply needs nothing from the user, "
  .. "iso <your role> thread waiting %s none with it keeps it out of their Inbox.)"

---@return table? post, string? err
function M.root_post(repo, id, by, text)
  local entries, err = exists(repo, id)
  if not entries then
    return nil, err
  end
  return append(repo, id, { kind = "post", by = by, text = vim.trim(text), root = true })
end

-- The threads the root should hear of now, each marked told so it's told once: up to limit, what the
-- user handed it first, then the longest waiting. handed_only is for between its regular looks. The
-- first look at a repo tells nothing and starts from there: threads already waiting stay the user's,
-- and gr hands one over.
---@param grace integer seconds on the user's turn before the root hears of it
---@return {id: string, title: string, handed: boolean, by?: string, at?: integer, text?: string}[]
function M.for_root(repo, grace, limit, handed_only)
  local infos = M.list(repo)
  local file = root_told_file(repo)
  local ok, lines = pcall(vim.fn.readfile, file)
  local decoded, told = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  local first_look = not (decoded and type(told) == "table")
  told = not first_look and told or {}
  local tasks = require("isovim.board_tasks").read(repo)
  local now, due = os.time(), {}
  for _, info in ipairs(infos) do
    local seen = told[info.id] or 0
    local task = info.task and tasks[info.task]
    if first_look then
      told[info.id] = info.last_seq
    elseif info.status == "open" and (info.handed or 0) > seen then
      due[#due + 1] = { info = info, handed = true }
    elseif not handed_only and M.root_may_answer(info) and not info.handed and info.last_reply > seen
      and now - (info.waiting_at or now) >= grace and info.root_posts < ROOT_ANSWERS and info.pending == 0
      and not info.working and not by_a_root(info.last_by) and not (task and task.column == "backburner")
      and not drafted(repo, info) and not viewed(repo, info) then
      due[#due + 1] = { info = info }
    end
  end
  table.sort(due, function(a, b)
    if (a.handed or false) ~= (b.handed or false) then
      return a.handed == true
    end
    return (a.info.waiting_at or 0) < (b.info.waiting_at or 0)
  end)
  local taken = {}
  for i = 1, math.min(limit, #due) do
    local each = due[i]
    told[each.info.id] = each.info.last_seq
    local post
    for _, entry in ipairs(M.read(repo, each.info.id) or {}) do
      if entry.kind == "post" and entry.by ~= "user" then
        post = entry
      end
    end
    taken[#taken + 1] = { id = each.info.id, title = each.info.title, handed = each.handed == true,
      by = post and post.by, at = post and post.at, text = post and post.text }
  end
  if first_look or #taken > 0 then
    vim.fn.mkdir(store.run_dir(repo), "p")
    vim.fn.writefile({ vim.json.encode(next(told) and told or vim.empty_dict()) }, file)
  end
  return taken
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
