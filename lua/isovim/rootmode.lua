-- Root mode: a repo's root decides its Inbox's questions before they reach you, and is on top of its
-- threads. iso rootmode on|off <repo> (isovim.cli.rootmode) turns it on for one repo, for its root;
-- this module keeps which is on, in ~/.isovim/rootmode.json (this host's alone: it isn't synced), and
-- says which root decides a question.
-- A question isn't routed anywhere: it stays in its repo's Inbox, tagged root deciding (the
-- surface's deciding, so it doesn't count as needing you) until the root answers it or raises it to
-- you with a one-line why; with root mode off, or no root, it's yours at once. You may answer
-- any of them, and the first answer wins. A root's ACP supervisor subscribes to the Inbox
-- (M.listen) and tells the root of each new question it decides, whoever asked it and whatever
-- code they run, and of threads that have sat on your turn (isovim.threads.for_root), which it
-- answers in your place or leaves with you.
--   { "repos": { "<owner/repo>": {agent, task?, since} } }
-- An entry is active while its agent's record still holds the root role; one whose agent went
-- away is off.
local store = require("isovim.store")

local M = {}

M.file = store.root .. "/rootmode.json"

---@alias isovim.RootMode {agent: string, task?: string, since: number}

---@return {repos: table<string, isovim.RootMode>}
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
  vim.fn.writefile({ vim.json.encode({ repos = next(state.repos) and state.repos or vim.empty_dict() }) }, tmp)
  assert(vim.uv.fs_rename(tmp, M.file))
end

---@return isovim.RootMode?
function M.entry(repo)
  return M.read().repos[repo]
end

---@param entry? isovim.RootMode nil turns it off
function M.set(repo, entry)
  local state = M.read()
  state.repos[repo] = entry
  write(state)
end

-- The repo's root while root mode is on there: its address (<ws>/<agent>) and entry.
---@return string? address, isovim.RootMode? entry
function M.route(repo)
  local entry = M.entry(repo)
  local ws, id
  if entry and type(entry.agent) == "string" then
    ws, id = entry.agent:match("^(.*)/([^/]+)$")
  end
  local record = ws and store.agent(ws, id)
  if record and store.role(record) == "root" then
    return entry.agent, entry
  end
end

-- Whether a root may answer a question still open to roots: pending, not the user's (raised), and
-- one not asked by the root itself.
local function open(entry)
  return entry.type == "question" and not entry.answer and not entry.raised
end

-- Whether address may answer the question: it's the root of the question's repo, while root mode is
-- on there. You may answer any question; a root never answers its own, nor one that's yours
-- (raised: a root's raise, or a permission request).
function M.may_answer(address, entry)
  return open(entry) and address ~= entry.asker and M.route(entry.repo) == address
end

-- The root deciding a question: its repo's, unless that root asked it, which makes it yours.
---@return string? address
function M.root_for(entry)
  local address = open(entry) and M.route(entry.repo) or nil
  if address and address ~= entry.asker then
    return address
  end
end

-- Whether root mode is on for a repo.
function M.on(repo)
  return M.route(repo) ~= nil
end

-- The questions as their root gets them: intro, each with its options, then how to answer.
function M.questions_text(intro, entries, repo)
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
  lines[#lines + 1] = ("Decide what you can stand behind with `iso root answer <repo>/<name> <answer...>`; raise "
    .. "the rest to the user with `iso root raise <repo>/<name> <one line: why, and your recommendation>`. Until "
    .. "you do, it's tagged root deciding and doesn't count as needing them; they may still answer it first, "
    .. "and the first answer wins.")
  local mode = M.entry(repo)
  if mode and mode.task then
    lines[#lines + 1] = "Your task (raise what's outside it): " .. mode.task
  end
  return table.concat(lines, "\n")
end

-- The repo's questions its root hasn't been told of, marked told; all takes those told before too.
---@return isovim.Surface[]
function M.take(address, repo, all)
  local surfaces = require("isovim.surfaces")
  surfaces.scan(repo)
  return surfaces.take_untold(repo, function(entry)
    return M.root_for(entry) == address
  end, all)
end

-- How many threads one message tells of: the rest wait for its next look.
local THREADS_AT_ONCE = 8

local function ago(at)
  local minutes = math.floor((os.time() - (at or os.time())) / 60)
  return minutes < 60 and (minutes .. "m") or (math.floor(minutes / 60) .. "h")
end

-- The threads as their root gets them: the post is usually enough, so it's there, up to a point.
local function threads_text(repo, threads, grace)
  local parts = { ("[isovim: these threads have sat on the user's turn for over %d minutes with no word from them, and "
    .. "root mode has you on top of them. Answer only what's asking for a decision you can stand behind: `iso root thread "
    .. "answer <id> <your answer>` posts it as yours, sends it with your authority to whoever is working the thread "
    .. "and stops it waiting on the user. Leave the rest, with no reply at all, and it stays in their Inbox: an FYI or a "
    .. "report, an answer to a question the user asked, anything that's their own conversation. That isn't yours to answer "
    .. "for them. Their word beats yours. What's permanently off stays off: for that, and what they'd be surprised you "
    .. "decided, `iso root thread post <id> \"<one line: why, and what you'd pick>\"` raises it with them. `iso "
    .. "root thread show <id>` has the rest of a thread if the post isn't enough. If nothing needs you, end your turn.]")
    :format(math.floor(grace / 60)) }
  for _, each in ipairs(threads) do
    local text = each.text or "(no agent has posted yet)"
    parts[#parts + 1] = ("--- %s#%s \"%s\"%s%s ---\n%s"):format(repo, each.id, each.title,
      each.by and (" · " .. each.by .. ", " .. ago(each.at) .. " ago") or "",
      each.handed and " · the user handed you this one: they want you on it now" or "",
      #text > 1500 and (text:sub(1, 1500) .. "… (thread show has the rest)") or text)
  end
  return table.concat(parts, "\n\n")
end

-- Tells the root of its repo's threads. Hard batched: a root's turn is on a big context, so one
-- message at most per grace while it's free, and only what the user handed it comes sooner.
local function thread_teller(address, repo, say, busy)
  local threads = require("isovim.threads")
  local last_told = 0
  return function()
    if M.route(repo) ~= address then
      return
    end
    local grace = require("isovim.config").thread_root_grace() * 60
    local found = threads.for_root(repo, grace, THREADS_AT_ONCE, busy() or os.time() - last_told < grace)
    if #found > 0 then
      last_told = os.time()
      say(threads_text(repo, found, grace))
    end
  end
end

-- Subscribes a root to its repo's Inbox, from its supervisor: say(text) gets one message per batch of
-- new questions, a few seconds after the last surface event, and on start one for those asked while
-- it was down. It goes by the event bus, so it doesn't matter who wrote or scanned the surface, or
-- what code they run; take_untold's marks keep any question from being told twice. It listens whether
-- root mode is on or not, and tells only while it is.
---@param address string the root, <repo>/<agent>
---@param say fun(text: string)
---@param busy fun(): boolean whether a turn is running, so threads gather instead of queueing
function M.listen(address, say, busy)
  local repo = address:match("^(.*)/[^/]+$")
  local timer = assert(vim.uv.new_timer())
  local flush = require("isovim.safe").wrap("rootmode.listen", function()
    if M.route(repo) == address then
      local list = M.take(address, repo)
      if #list > 0 then
        say(M.questions_text(("%s in %s's Inbox, which root mode has you decide before the user:"):format(
          #list == 1 and "A new question" or (#list .. " new questions"), repo), list, repo))
      end
    end
  end)
  local function soon(delay)
    timer:start(delay, 0, vim.schedule_wrap(flush))
  end
  local tell_threads = require("isovim.safe").wrap("rootmode's threads", thread_teller(address, repo, say, busy))
  assert(vim.uv.new_timer()):start(60000, 60000, vim.schedule_wrap(tell_threads))
  require("isovim.events").watch(function(_, event)
    if event.repo == repo and event.topic:match("^thread%.") and event.topic:match("%.handed$") then
      vim.schedule(tell_threads)
    end
    if event.type == "question" and event.repo == repo and event.topic:match("^surface%.")
      and (event.topic:match("%.created$") or event.topic:match("%.changed$")) then
      soon(3000)
    end
  end)
  soon(5000)
end

return M
