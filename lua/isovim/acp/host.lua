-- The supervisor of one ACP agent, run in its tmux pane by agent_host.lua (nvim -l), so tmux owns
-- its lifetime as it owns a TUI agent's and it outlives the isovim TUI. It starts the adapter
-- (isovim.acp.adapter), opens or resumes the session with the agent's role prompt, the files its
-- CLAUDE.md files @import (isovim.acp.imports, which the adapter doesn't expand) and isovim's
-- hooks, writes everything the session does to the agent's journal (isovim.acp.journal), and
-- serves an nvim RPC socket where prompts come in. Every journal entry also goes at once to the
-- chats that subscribed over the socket (the TUI's, iso attach's), so text streams token by token.
-- One prompt is with the agent at a time: one that arrives while it works is queued and sent when
-- the turn ends; the queue can be listed, edited, reordered, cleared, and one of its prompts sent
-- now, which cancels the running turn. It writes the agent's state file (ready, working, idle),
-- which publishes agent.<scope>.<id>.status, and publishes msg.<scope>.<id> for each message it
-- takes. Its pane shows a plain-text tail.
--
-- A prompt that fails on something that passes (claude not logged in, a usage limit, the adapter
-- going away) isn't used up: it goes back to the front of the queue, which is held (state held,
-- with why, and a held-aN notice in the repo's Inbox) until the login is back or a retry works.
-- A supervisor that starts while claude isn't logged in holds its queue the same way. Claude Code
-- restores the system prompt a session started with, so a resumed, reloaded or forked session
-- whose role prompt changed gets it as its first message, "[isovim: your role is now X]".
-- Stopping, it stops everything it started, the background shells Claude runs in process groups
-- of their own too.
--
-- Restarts: iso <role> restart asks it to start again on its session (CALLS.restart), once the
-- running turn ends; its queue is kept on disk, and its first message says who restarted it and why.
-- It also restarts itself when isovim's code it runs changes on disk (a pull, isovim's
-- self-update), at its next idle moment, with no message, as nothing was cut off. Either way the
-- restart is iso restart's, what R in the sidebar does, run by the tmux server.
--
-- iso handover: the adapter is stopped (which closes the ACP session), your own claude runs in the
-- pane on the same session (claude --resume), and when it exits what happened there goes into the
-- journal from Claude's transcript and the session is opened again. One writer at a time: prompts
-- that come in meanwhile wait in the queue.
--
-- Permissions: the session runs in its adapter's no-prompts mode (claude's bypassPermissions, as TUI
-- agents run with --permission-mode bypassPermissions; codex's agent-full-access, or read-only for a
-- read-only agent). A permission the agent asks for anyway, and every question
-- it asks (AskUserQuestion, as a form elicitation), becomes a question surface in its repo's Inbox,
-- and the answer goes back to the agent (isovim.acp.asks).
--
-- Sessions (isovim.acp.sessions): a restart resumes the recorded session; an agent made by iso fork
-- (fork_of in its record, with fork_at and fork_seq for a fork at a message) forks it on its first
-- start, its journal starting with its parent's up to there. /new and /clear start a new session,
-- /resume goes back to one the agent had, and a rewind forks the session before one of your
-- prompts, puts the files back as they were before that prompt's turn (from the turn's git
-- snapshot) and sends the edited prompt; each keeps the journal it leaves as that session's.
local store = require("isovim.store")
local events = require("isovim.events")
local status = require("isovim.status")
local journal = require("isovim.acp.journal")
local adapter = require("isovim.acp.adapter")
local imports = require("isovim.acp.imports")
local log = require("isovim.acp.log")
local sessions = require("isovim.acp.sessions")
local asks_mod = require("isovim.acp.asks")
local images = require("isovim.acp.images")
local threads = require("isovim.threads")
local Client = require("isovim.acp.client")
local auth = require("isovim.auth")

local M = {}

---@class isovim.acp.Prompt
---@field id string
---@field text string what the agent gets, stamp included
---@field from? string the sender's address, for a message
---@field kind? string "from" or "ask", for a message
---@field stamp? string the message's stamp id (m<hex>)
---@field message? string the message without its stamp, for its msg event
---@field publish? boolean whether to publish msg.<scope>.<id> (prompts from iso send/msg)
---@field via "iso"|"composer"|"spawn" where it came from: iso send/msg, the TUI's composer, iso spawn
---@field images? isovim.acp.Image[] what it attaches, [Image #n] in its text for images[n]

local S = {
  ws = nil, ---@type string
  agent = nil, ---@type string
  spec = nil, ---@type isovim.Agent
  cwd = nil, ---@type string
  writer = nil, ---@type isovim.acp.Writer
  client = nil, ---@type table
  session = nil, ---@type string?
  ready = false,
  busy = false,
  queue = {}, ---@type isovim.acp.Prompt[]
  replaying = false,
  prompts = 0,
  prompted = false, -- whether the journal has a prompt yet, so the spawn's goes only once
  subscribers = {}, ---@type table<integer, true> RPC channels of chats that get each entry
  handover = nil, ---@type {pid: integer, transcript?: string, offset: integer}?
  init = nil, ---@type table? what initialize answered: the agent's capabilities
  caps = {}, -- the adapter's agentCapabilities
  asks = nil, ---@type isovim.acp.Asks
  after_turn = nil, ---@type fun()? what waits for the running turn to end (a session switch)
  loading = false, -- a session/load whose replay goes into the journal (a /resume with no kept journal)
  held = nil, ---@type {why: string, kind: "auth"|"usage"|"transport"|"error", delay?: number}? what the queue waits on
  retry = nil, -- the timer that tries a held queue again
  backoff = nil, ---@type number? the last retry's delay, while prompts keep failing: the next one doubles it
  role_hash = nil, ---@type string? isovim.panes.role_hash of the role prompt the last session request sent
  legacy_hash = nil, ---@type string? the same prompt's hash as journals recorded it before role_hash (prompt_hash)
  restart = nil, ---@type {text?: string, why: string}? a restart that waits for the running turn to end
  code = {}, ---@type table<string, string> each isovim file it runs, as it was when it started on it (code_stat)
  code_due = false, -- a restart onto changed code waits its turn (check_code)
  broken = nil, ---@type string? the changed file that doesn't compile, said once
  inbox = false, -- subscribed to the Inbox as a root (subscribe_inbox)
}

-- Prompt ids, unique in the journal across restarts.
local function next_id()
  S.prompts = S.prompts + 1
  return ("p%d.%d"):format(os.time(), S.prompts)
end

-- The pane's tail; nothing while Claude has the pane (iso handover).
local function out(text)
  if S.handover then
    return
  end
  io.stdout:write(text)
  io.stdout:flush()
end

-- Runs code (isovim.acp.chat's) in every subscribed chat; one whose channel is gone is dropped.
local function broadcast(code, args)
  for chan in pairs(S.subscribers) do
    local ok = pcall(vim.rpcnotify, chan, "nvim_exec_lua", code, args)
    if not ok then
      S.subscribers[chan] = nil
    end
  end
end

-- Journals an entry and sends it to every subscribed chat.
local function append(kind, fields)
  local entry = S.writer.append(kind, fields)
  broadcast("require('isovim.acp.chat').push(...)", { S.ws, S.agent, entry })
  return entry
end

-- The journal becomes entries (the one it was kept as session's), and the chats read it again.
local function replace_journal(entries, session)
  sessions.replace_journal(S.ws, S.agent, entries, session)
  S.writer = journal.writer(S.ws, S.agent)
  broadcast("require('isovim.acp.chat').reload(...)", { S.ws, S.agent })
end

local function notice(text)
  append("notice", { text = text })
  out("\n[" .. text .. "]\n")
end

-- While the queue is held, the agent's state says so (held, and why) whatever else would be written.
local function set_state(state)
  if S.held and state ~= "working" then
    return status.set_state(S.ws, S.agent, "held", S.held.why)
  end
  status.set_state(S.ws, S.agent, state)
end

-- A promotion's pending reload (CALLS.reload) waits in the queue too, but isn't a prompt: the
-- queue's readers never see it, and changing or clearing the queue keeps it first.
local function reloads()
  return vim.tbl_filter(function(prompt)
    return prompt.reload
  end, S.queue)
end

local function queue_items()
  return vim.tbl_map(function(prompt)
    return { id = prompt.id, text = prompt.text, from = prompt.from, via = prompt.via, images = prompt.images }
  end, vim.tbl_filter(function(prompt)
    return not prompt.reload
  end, S.queue))
end

-- The queue is kept on disk too (iso/journal/aN.queue.json), so a supervisor that exits (a crash,
-- iso restart) starts again with it and still delivers it. A promotion's reload isn't kept: a
-- restart starts on the record's role anyway.
local function queue_file(ws, agent)
  return journal.dir(ws) .. "/" .. agent .. ".queue.json"
end

local function save_queue()
  local kept = {}
  for _, prompt in ipairs(S.queue) do
    if not prompt.reload then
      kept[#kept + 1] = { id = prompt.id, text = prompt.text, from = prompt.from, kind = prompt.kind, stamp = prompt.stamp,
        message = prompt.message, via = prompt.via, role = prompt.role, images = prompt.images }
    end
  end
  local path = queue_file(S.ws, S.agent)
  if #kept == 0 then
    os.remove(path)
    return
  end
  vim.fn.mkdir(journal.dir(S.ws), "p")
  local tmp = path .. ".tmp"
  if pcall(vim.fn.writefile, { vim.json.encode(kept) }, tmp) then
    vim.uv.fs_rename(tmp, path)
  end
end

---@return isovim.acp.Prompt[]
local function load_queue(ws, agent)
  local ok, lines = pcall(vim.fn.readfile, queue_file(ws, agent))
  local decoded, items = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "", { luanil = { object = true } })
  if not (decoded and vim.islist(items)) then
    return {}
  end
  return vim.tbl_filter(function(prompt)
    return type(prompt) == "table" and type(prompt.id) == "string" and type(prompt.text) == "string"
  end, items)
end

-- The queue as it is now, after anything but a push (which journals a queued entry).
local function queue_changed()
  save_queue()
  append("queue", { items = queue_items() })
end

-- The pane's tail: prompts, tool calls and the agent's text as it streams.
local function show_update(update)
  local kind = update.sessionUpdate
  if kind == "agent_message_chunk" and update.content and update.content.type == "text" then
    out(update.content.text or "")
  elseif kind == "tool_call" then
    out(("\n• %s\n"):format(update.title or update.toolCallId or "tool"))
  end
end

local deliver, reload, restart_now, check_code

-- The next queued prompt goes, unless the session isn't up (a handover, a restart).
local function next_prompt()
  -- A session switch that waited on the turn (or a reload) goes first; it sends what's queued.
  if not S.busy and S.after_turn then
    local after = S.after_turn
    S.after_turn = nil
    return after()
  end
  if not S.busy and S.restart then
    return restart_now()
  end
  if S.busy or not S.ready or S.held then
    return
  end
  local prompt = table.remove(S.queue, 1)
  if prompt then
    deliver(prompt)
  else
    set_state("idle")
    check_code()
  end
end

-- A held queue's notice in the agent's repo's Inbox, held-aN.md, until the queue goes again.
local function inbox_file()
  return require("isovim.surfaces").dir(store.canon(S.ws)) .. "/held-" .. S.agent .. ".md"
end

local function inbox_notice(why)
  pcall(function()
    local path = inbox_file()
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local short = why:gsub('"', "'"):gsub("%s*%(.*$", "")
    local lines = { "---", ('name: "%s/%s\'s prompts are held: %s"'):format(S.ws, S.agent, short), 'color: "#e06c75"',
      "consumable: true", "---", "", ("%s/%s's queue waits: %s."):format(S.ws, S.agent, why), "",
      ("Its %d queued prompt(s) are kept (iso/journal/%s.queue.json) and go once that's fixed; isovim tries again by itself.")
        :format(#queue_items(), S.agent) }
    local tmp = ("%s/.%s.%d.tmp"):format(vim.fs.dirname(path), vim.fs.basename(path), vim.uv.os_getpid())
    vim.fn.writefile(lines, tmp)
    vim.uv.fs_rename(tmp, path)
    require("isovim.surfaces").scan(store.canon(S.ws), true)
  end)
end

local function inbox_clear()
  pcall(function()
    if os.remove(inbox_file()) then
      require("isovim.surfaces").scan(store.canon(S.ws), true)
    end
  end)
end

-- What made a prompt fail, when it's something that passes (a login, a usage limit, the adapter
-- going away), so the prompt is kept rather than used up: "auth", "usage", "transport", or nil.
local TRANSPORT_ERROR = -32000
local function failure_kind(err)
  local text = (tostring(err.message or "") .. " " .. vim.inspect(err.data or "")):lower()
  if text:find("auth") or text:find("log ?in") or text:find("401") or text:find("credential") then
    return "auth"
  elseif text:find("usage") or text:find("rate.?limit") or text:find("limit reached") or text:find("429")
    or text:find("overloaded") or text:find("quota") or text:find("credit") or text:find("529") then
    return "usage"
  elseif err.code == TRANSPORT_ERROR or text:find("disconnected") or text:find("not connected") then
    return "transport"
  end
end

local function auth_kind()
  return auth.kind_of(S.spec) or "claude"
end

local release

-- The queue waits: nothing is sent until release, which the retry timer calls once a login is
-- back (asked every 30s) or, for anything else, after a while that doubles each time (to 30 min)
-- until a prompt goes through. The agent's state is held, with why; its repo's Inbox says so,
-- and its chat once, not at every try.
local function hold(why, kind)
  local first = not S.held and not (S.backoff and kind ~= "auth")
  local base = tonumber(vim.env.ISOVIM_RETRY_SECS or "") or (kind == "auth" and 30 or 60)
  local delay = base
  if kind ~= "auth" then
    delay = math.min(S.backoff and S.backoff * 2 or base, 1800)
    S.backoff = delay
  end
  S.held = { why = why, kind = kind, delay = delay }
  set_state("held")
  if first then
    notice("its prompts are held: " .. why .. "; they stay queued and go once that's fixed")
  end
  inbox_notice(why)
  S.retry = S.retry or vim.uv.new_timer()
  S.retry:stop()
  S.retry:start(math.floor(delay * 1000), 0, vim.schedule_wrap(function()
    if not S.held then
      return
    end
    local still = S.held.kind == "auth" and auth.why(auth_kind(), true) or nil
    if still then
      return hold(still, "auth")
    end
    release(S.held.kind == "auth" and "logged in again" or "trying again")
  end))
end

release = function(why)
  if not S.held then
    return
  end
  S.held = nil
  if S.retry then
    S.retry:stop()
  end
  inbox_clear()
  notice("its queue goes again" .. (why and (": " .. why) or ""))
  if S.ready and not S.busy then
    set_state(#S.queue > 0 and "ready" or "idle")
  end
  next_prompt()
end

-- The turn ended: say so, and send the next queued prompt. One that failed on something that
-- passes goes back to the front of the queue, which is held.
local function turn_ended(prompt, result, err)
  S.busy = false
  local reason = result and result.stopReason or nil
  append("turn", { state = "end", id = prompt.id, stopReason = reason, error = err and err.message or nil })
  -- A turn on a thread's post: its last message is the thread's reply (isovim.threads).
  local thread = S.thread_turn
  S.thread_turn = nil
  if thread then
    local text = vim.trim(thread.text)
    if text ~= "" and not err and reason ~= "cancelled" then
      pcall(threads.post, thread.repo, thread.id, S.ws .. "/" .. S.agent, text)
    end
    pcall(threads.working, thread.repo, thread.id, "end")
  end
  local kept = err and failure_kind(err)
  if not err then
    S.backoff = nil
  end
  if kept then
    -- A login that's gone is said as that, not in the adapter's words.
    local why = kept == "auth" and auth.why(auth_kind(), true) or nil
    if kept == "auth" and not why then
      -- Logged in all the same: tried again after a while, as anything else is.
      kept = "error"
    end
    why = why or ("the prompt failed (%s): %s"):format(kept, tostring(err.message))
    table.insert(S.queue, 1, prompt)
    queue_changed()
    notice("the prompt failed: " .. tostring(err.message) .. "; it's kept, first in the queue")
    hold(why, kept)
  elseif err then
    notice("the prompt failed: " .. tostring(err.message or vim.inspect(err)))
  end
  out("\n")
  -- What it asked and you didn't answer is moot now.
  if S.asks and asks_mod.waiting(S.asks) then
    asks_mod.cancel_all(S.asks, "the turn ended")
  end
  next_prompt()
end

---@param prompt isovim.acp.Prompt
deliver = function(prompt)
  -- It has left the queue.
  save_queue()
  if prompt.reload then
    return reload()
  end
  S.busy = true
  S.prompted = true
  -- The files as they were before this turn, for a rewind to put back.
  local ok, snapshot = pcall(sessions.snapshot, S.ws, S.agent, prompt.id)
  snapshot = ok and snapshot or nil
  local entry = append("prompt", { id = prompt.id, text = prompt.text, from = prompt.from, message = prompt.kind,
    stamp = prompt.stamp, via = prompt.via, role = prompt.role, images = prompt.images })
  -- The role prompt a resumed session can't get any other way: said once it's in the journal.
  if prompt.via == "role" then
    local journaled = vim.iter(journal.read(S.ws, S.agent)):find(function(e)
      return e.kind == "prompt" and e.id == prompt.id
    end)
    notice(journaled and ("gave it the %s's prompt as a message (journal seq %s): a resumed session keeps the system prompt it started with")
      :format(prompt.role or "role", tostring(journaled.seq or entry.seq))
      or ("could not find the %s's prompt in the journal after sending it"):format(prompt.role or "role"))
  end
  append("turn", { state = "start", id = prompt.id, snapshot = snapshot and snapshot.commit,
    snapshot_dir = snapshot and snapshot.dir })
  -- A thread's post (isovim.threads): the turn shows working there, and its last message goes there.
  local thread_repo, thread_id = threads.tagged(prompt.text)
  S.thread_turn = nil
  if thread_repo and vim.uv.fs_stat(threads.file(thread_repo, thread_id)) then
    S.thread_turn = { repo = thread_repo, id = thread_id, text = "" }
    pcall(threads.working, thread_repo, thread_id, "start")
  end
  -- The session's title in the history picker: its first prompt.
  pcall(sessions.note, S.ws, S.agent, S.session, { title = (prompt.message or prompt.text):sub(1, 120) })
  set_state("working")
  out(("\n❯ %s%s\n"):format(prompt.from and ("(" .. prompt.from .. ") ") or "", prompt.text))
  local takes_images = type(S.caps.promptCapabilities) == "table" and S.caps.promptCapabilities.image == true
  S.client:request("session/prompt", { sessionId = S.session, prompt = images.blocks(prompt.text, prompt.images, takes_images) },
    function(result, err)
      turn_ended(prompt, result, err)
    end)
end

-- Takes a prompt: sends it now, or queues it while a turn runs (or before the session is up).
---@param prompt isovim.acp.Prompt
local function submit(prompt)
  prompt.id = next_id()
  local queued = S.busy or not S.ready or S.held ~= nil
  if prompt.publish then
    events.publish_msg(S.ws, S.agent, { from = prompt.from, kind = prompt.kind, id = prompt.stamp,
      text = prompt.message or prompt.text, queued = queued })
  end
  if queued then
    S.queue[#S.queue + 1] = prompt
    save_queue()
    append("queued", { id = prompt.id, text = prompt.text, from = prompt.from, via = prompt.via, images = prompt.images,
      position = #S.queue })
    out(("\n(queued %d) %s\n"):format(#S.queue, prompt.text))
    return { id = prompt.id, queued = true, position = #S.queue }
  end
  deliver(prompt)
  return { id = prompt.id, queued = false }
end

local function cancel_turn()
  if S.busy and S.session then
    S.client:notify("session/cancel", { sessionId = S.session })
    return true
  end
  return false
end

-- Starts the supervisor again on its session at the same address: iso restart (what R in the
-- sidebar does) run by the tmux server, since stopping this pane ends what it runs. Prompts that
-- come in meanwhile wait in the queue, which the next supervisor loads and sends; the restart's own
-- text, when it has one, goes first.
restart_now = function()
  local restart = S.restart
  S.restart = nil
  -- It would come back unable to work.
  local blocked = auth.why(auth_kind(), true)
  if blocked then
    notice("not restarted: " .. blocked)
    return next_prompt()
  end
  local told = restart.text and { id = next_id(), text = restart.text, via = "iso" }
  if told then
    table.insert(S.queue, 1, told)
    queue_changed()
  end
  S.ready = false
  -- Still here: it carries on as it was, its restart's text taken back.
  local function stay_on(why)
    if told and S.queue[1] == told then
      table.remove(S.queue, 1)
      queue_changed()
    end
    S.ready = true
    notice("not restarted: " .. why)
    next_prompt()
  end
  local log = store.run .. "/restart.log"
  local ok, err = require("isovim.panes").later({ "restart", S.ws .. "/" .. S.agent }, log)
  if not ok then
    return stay_on(tostring(err))
  end
  notice("restarting " .. restart.why)
  vim.defer_fn(function()
    stay_on("iso restart didn't stop it within a minute (" .. log .. " says why)")
  end, 60000)
end

-- isovim's files it runs: the agent_host entry and each isovim module it has loaded, so a change
-- to one only the TUI runs (the chat, the sidebar) restarts nothing.
local ISOVIM_DIR = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
local function code_files()
  local files = { ISOVIM_DIR .. "/acp/agent_host.lua" }
  for name in pairs(package.loaded) do
    local path = (name == "isovim" or name:match("^isovim%.")) and package.searchpath(name, package.path)
    if path then
      files[#files + 1] = path
    end
  end
  return files
end

local function code_stat(path)
  local stat = vim.uv.fs_stat(path)
  return stat and ("%d.%d:%d"):format(stat.mtime.sec, stat.mtime.nsec, stat.size) or "gone"
end

-- The files changed since it started on them; a module loaded later counts from when it's first seen.
local function changed_code()
  local changed = {}
  for _, path in ipairs(code_files()) do
    local now = code_stat(path)
    S.code[path] = S.code[path] or now
    if S.code[path] ~= now then
      changed[#changed + 1] = path
    end
  end
  return changed
end

-- Nothing it would cut into: no turn, nothing queued or held, no question waiting, no handover.
local function idle()
  return S.ready and not S.busy and not S.held and not S.handover and not S.after_turn and not S.restart
    and #S.queue == 0 and not (S.asks and asks_mod.waiting(S.asks))
end

-- Restarts onto new code take turns host-wide, CODE_GAP seconds apart. Each starts a new adapter
-- whose claude resumes its session, 4-12s of CPU apiece, and every supervisor sees a self-update
-- at once: with a random 0-60s wait, ~18 restarted inside 75s on 2026-11-01 (12:46) and pinned
-- the host. ~/.isovim/run/code-restart.next holds the next free turn; this takes it, under a
-- lock, and says how long to wait for it, in ms.
local CODE_GAP = 12
local function code_turn()
  local file = store.run .. "/code-restart.next"
  local lock = file .. ".lock"
  vim.fn.mkdir(store.run, "p")
  local deadline = vim.uv.hrtime() + 2e9
  while not vim.uv.fs_mkdir(lock, 448) and vim.uv.hrtime() < deadline do
    -- A holder that died: taking a turn takes a millisecond.
    local stat = vim.uv.fs_stat(lock)
    if stat and os.time() - stat.mtime.sec > 10 then
      vim.uv.fs_rmdir(lock)
    else
      vim.uv.sleep(5)
    end
  end
  local ok, lines = pcall(vim.fn.readfile, file)
  local now = os.time()
  local at = math.max(now, ok and tonumber(lines[1] or "") or 0)
  pcall(vim.fn.writefile, { tostring(at + CODE_GAP) }, file)
  vim.uv.fs_rmdir(lock)
  return (at - now) * 1000
end

-- isovim's code it runs changed on disk (a pull, isovim's self-update): it restarts onto it at its
-- next idle moment, with no message. Checked every 30s and whenever it goes idle. It waits for its
-- turn (code_turn), so the host's supervisors restart one at a time, and goes only if it's still
-- idle then; one that isn't takes a new turn when it next is. A changed file that doesn't compile
-- keeps it on the old code, said once.
check_code = function()
  if S.code_due or not idle() then
    return
  end
  local changed = changed_code()
  if #changed == 0 then
    return
  end
  for _, path in ipairs(changed) do
    local _, err = loadfile(path)
    if err and vim.uv.fs_stat(path) then
      if S.broken ~= path .. code_stat(path) then
        S.broken = path .. code_stat(path)
        notice("isovim's new code doesn't compile, so it stays on the old: " .. err)
      end
      return
    end
  end
  S.code_due = true
  vim.defer_fn(function()
    S.code_due = false
    if idle() then
      local names = vim.tbl_map(function(path)
        return path:sub(#ISOVIM_DIR + 2)
      end, changed)
      S.restart = { why = "onto isovim's new code (" .. table.concat(names, ", ") .. ")" }
      restart_now()
    end
  end, code_turn())
end

-- What the socket answers: iso's CLI and the TUI call these (isovim.acp.call).
local CALLS = {}

-- iso <role> restart: it restarts once the running turn ends (now, with none), and text (who
-- restarted it, and why) is its first message.
---@param payload {text: string, by: string}
function CALLS.restart(payload)
  if S.handover then
    error("it's handed over to Claude's screen (iso handover)")
  elseif S.after_turn then
    error("it's switching sessions; restart it once that's done")
  end
  S.restart = { text = payload.text, why = "as " .. payload.by .. " asked" }
  if not S.busy then
    restart_now()
  end
  return { waits = S.busy }
end

-- Each image gets a chip in the text if it has none, so [Image #n] is always there for images[n].
---@param payload {text: string, from?: string, kind?: string, stamp?: string, message?: string, publish?: boolean, images?: isovim.acp.Image[]}
function CALLS.prompt(payload)
  if type(payload.text) ~= "string" or vim.trim(payload.text) == "" then
    error("a prompt needs text")
  end
  local text, attached = images.renumber(payload.text, payload.images or {}, "append")
  return submit({ text = text, from = payload.from, kind = payload.kind, stamp = payload.stamp, images = attached[1] and attached or nil,
    message = payload.message, publish = payload.publish, via = payload.publish and "iso" or "composer" })
end

-- Reloads the session with the agent's record as it is now, so a promoted agent gets its new
-- role's prompt: queued behind the running turn like a prompt, and then_prompt (a prompt's
-- payload, the promoter's message) is queued right after it, so it arrives after the reload.
---@param payload {then_prompt?: table}
function CALLS.reload(payload)
  local queued = S.busy or not S.ready or S.held ~= nil
  if queued then
    S.queue[#S.queue + 1] = { id = next_id(), reload = true, text = "(reload)", via = "iso" }
  else
    reload()
  end
  if payload.then_prompt then
    CALLS.prompt(payload.then_prompt)
  end
  return { queued = queued }
end

function CALLS.status()
  return { state = status.state(S.ws, S.agent), ready = S.ready, busy = S.busy, queue = #S.queue, session = S.session,
    journal = S.writer.path, handover = S.handover ~= nil }
end

function CALLS.cancel()
  return { cancelled = cancel_turn() }
end

-- A chat (its RPC channel here) gets every entry from now on; it reads the journal up to seq.
function CALLS.subscribe(payload)
  S.subscribers[tonumber(payload.chan)] = true
  return { seq = S.writer.seq }
end

function CALLS.queue()
  return { items = queue_items(), busy = S.busy }
end

-- Replaces the queue with items, in their order: one with the id of a queued prompt keeps its
-- sender and takes the new text, and its images whose chips the text still has; one without an id
-- is a new prompt of yours. A queued prompt left out is dropped, unless known says which prompts
-- the editor showed and it isn't one of them. Ids no longer queued (sent meanwhile) are left out
-- and reported as gone.
---@param payload {items: {id?: string, text: string}[], known?: string[]}
function CALLS.queue_set(payload)
  local by_id = {}
  for _, prompt in ipairs(S.queue) do
    by_id[prompt.id] = prompt
  end
  local queue, gone = reloads(), {}
  for _, item in ipairs(payload.items or {}) do
    local text = type(item.text) == "string" and item.text or ""
    local prompt = item.id and by_id[item.id]
    if item.id and not prompt then
      gone[#gone + 1] = item.id
    elseif vim.trim(text) ~= "" then
      if prompt then
        by_id[item.id] = nil
        if text ~= prompt.text then
          -- Edited: a message's stamp no longer matches what it says, so it's yours now.
          prompt.text, prompt.from, prompt.kind, prompt.stamp, prompt.via = text, nil, nil, nil, "composer"
          if prompt.images then
            prompt.text, prompt.images = images.renumber(text, prompt.images)
            prompt.images = prompt.images[1] and prompt.images or nil
          end
        end
      else
        prompt = { id = next_id(), text = text, via = "composer" }
      end
      queue[#queue + 1] = prompt
    end
  end
  -- What queued after the buffer was drawn (payload.known: the ids it showed) stays, behind it.
  if payload.known then
    local known = {}
    for _, id in ipairs(payload.known) do
      known[id] = true
    end
    for _, prompt in ipairs(S.queue) do
      if by_id[prompt.id] and not known[prompt.id] and not prompt.reload then
        queue[#queue + 1] = prompt
      end
    end
  end
  S.queue = queue
  queue_changed()
  next_prompt()
  return { items = queue_items(), gone = gone }
end

function CALLS.queue_clear()
  local kept = reloads()
  local cleared = #S.queue - #kept
  S.queue = kept
  queue_changed()
  return { cleared = cleared }
end

-- Sends a queued prompt now: it goes first, and the running turn is cancelled so it's next.
function CALLS.queue_send_now(payload)
  for i, prompt in ipairs(S.queue) do
    if prompt.id == payload.id then
      table.insert(S.queue, 1, table.remove(S.queue, i))
      queue_changed()
      local cancelled = cancel_turn()
      next_prompt()
      return { sent = true, cancelled = cancelled }
    end
  end
  error("no queued prompt " .. tostring(payload.id) .. " (it may have been sent)")
end

function M.call(name, payload)
  local call = CALLS[name]
  if not call then
    error("no call " .. tostring(name))
  end
  return call(payload or {})
end

-- What the agent asks you goes to its repo's Inbox; the pane's tail says so.
local function journal_ask(kind, fields)
  append(kind, fields)
  if kind == "permission" then
    out(("\n%s: %s%s\n"):format(fields.decision, fields.tool or "a tool",
      fields.decision == "asked" and (" (waiting in the Inbox: " .. tostring(fields.repo) .. "/" .. tostring(fields.name) .. ")") or ""))
  elseif kind == "question" and fields.state == "asked" then
    out(("\nasked: %s (waiting in the Inbox)\n"):format(fields.questions and fields.questions[1] and fields.questions[1].question or ""))
  elseif kind == "notice" then
    out("\n[" .. tostring(fields.text) .. "]\n")
  end
end

local handlers = {
  on_notification = function(method, params)
    if method == "session/update" and type(params.update) == "table" then
      -- A load replays history that the journal already holds.
      if S.replaying then
        return
      end
      -- One whose journal wasn't kept: what you said in it comes back as prompts.
      if S.loading and params.update.sessionUpdate == "user_message_chunk" then
        local content = type(params.update.content) == "table" and params.update.content or {}
        if content.type == "text" and vim.trim(content.text or "") ~= "" then
          append("prompt", { id = next_id(), text = content.text, via = "load" })
        end
        return
      end
      append("update", { update = params.update })
      show_update(params.update)
      -- A thread's reply is the turn's last message: what it says after its last tool call.
      local thread, kind = S.thread_turn, params.update.sessionUpdate
      if thread and kind == "agent_message_chunk" and type(params.update.content) == "table"
        and params.update.content.type == "text" then
        thread.text = thread.text .. (params.update.content.text or "")
      elseif thread and kind == "tool_call" then
        thread.text = ""
      end
    end
  end,
  on_request = function(method, params, answer)
    if method == "session/request_permission" then
      asks_mod.permission(S.asks, params, answer)
      return true
    elseif method == "elicitation/create" then
      asks_mod.elicit(S.asks, params, answer)
      return true
    end
    return false
  end,
  on_exit = function(client, code, signal, stderr)
    -- One stopped for a handover: the session comes back on another when Claude exits.
    if S.handover or client ~= S.client then
      return
    end
    notice(("the agent exited (code %s, signal %s)%s"):format(code, signal,
      #stderr > 0 and (": " .. stderr[#stderr]) or ""))
    if S.ready then
      set_state("idle")
    end
    M.shutdown(1)
  end,
}

-- What the session's prompt gets appended: the role prompt, then what the CLAUDE.md files import.
local function instructions()
  local found = imports.collect(S.cwd)
  local parts = { require("isovim.panes").instructions(S.spec), imports.prompt(found) }
  return table.concat(vim.tbl_filter(function(part)
    return part ~= ""
  end, parts), "\n\n"), found
end

-- The settings and prompt every session is opened with, onto a session request's params: the
-- instructions appended to the agent's own, and for claude isovim's hooks (the same --settings TUI
-- agents get), as its adapter takes them (isovim.acp.adapter).
local function with_meta(params)
  local append_text, found = instructions()
  S.imported = vim.tbl_map(function(import)
    return import.path
  end, found)
  local panes = require("isovim.panes")
  S.role_hash = panes.role_hash(S.spec)
  S.legacy_hash = vim.fn.sha256(panes.instructions(S.spec, nil, true))
  return adapter.session_params(S.spec.kind, params, append_text)
end

local function remember_session(id, how)
  S.session = id
  vim.fn.mkdir(store.run_dir(S.ws), "p")
  vim.fn.writefile({ id }, store.run_dir(S.ws) .. "/" .. S.agent .. ".session")
  store.update_agent(S.ws, S.agent, { session = id })
  pcall(sessions.note, S.ws, S.agent, id, { how = how })
end

-- The journal's last session entry that recorded its role prompt: role_hash, or prompt_hash (the
-- whole text's sha256) from before isovim hashed only the role and the user's files.
local function last_recorded(entries)
  entries = entries or journal.read(S.ws, S.agent)
  for i = #entries, 1, -1 do
    if entries[i].kind == "session" and (entries[i].role_hash or entries[i].prompt_hash) then
      return entries[i]
    end
  end
end

-- Whether that entry's session got the role prompt this one is opened with. An old prompt_hash
-- matches the text as it was then, so isovim's rewording since sends no one a role message.
local function same_prompt(entry)
  if entry.role_hash then
    return entry.role_hash == S.role_hash
  end
  return entry.prompt_hash == S.legacy_hash
end

-- Claude Code keeps the system prompt a session started with (a prompt_snapshot in its
-- transcript) and restores it on resume, so a resumed, reloaded or forked session never sees a
-- changed --append-system-prompt or _meta. A role or role prompt that changed since reaches it as
-- the first message instead, stamped by isovim.
local function role_prompt()
  local role = store.role(S.spec)
  local text = ("[isovim: your role is now %s]\nA resumed session keeps the system prompt it started with, so this "
    .. "is your role's prompt now; where your system prompt says otherwise about your role, this wins.\n\n%s")
    :format(role, require("isovim.panes").instructions(S.spec))
  return { id = next_id(), text = text, via = "role", role = role }
end

-- Whether the session just opened (resumed: one that keeps an earlier system prompt) needs the
-- role prompt as a message: it differs from what the journal last recorded. With nothing recorded,
-- a fork (a copy of another agent's session) does, and so does the agent's own session resumed on
-- a restart (resumed == "restart"): its journal is from before isovim recorded it, like a migrated
-- _/a0's, so its prompt is unknown. A rewind or /resume within a session keeps what it had.
local function role_changed(resumed, how, last)
  if not resumed or S.role_hash == nil then
    return false
  elseif last then
    return not same_prompt(last)
  end
  return how == "fork" or resumed == "restart"
end

-- A root (or repo-root, from its first session as one) subscribes to the Inbox: while root mode
-- has it clear one, it's told of each new question there as a message (isovim.rootmode.listen).
local function subscribe_inbox()
  local role = store.role(S.spec)
  if S.inbox or (role ~= "root" and role ~= "repo-root") then
    return
  end
  S.inbox = true
  require("isovim.rootmode").listen(S.ws .. "/" .. S.agent, function(text)
    submit({ text = text, kind = "from", message = text, publish = true, via = "iso" })
  end)
end

-- The session is up: bypass mode, then ready, then what was waiting. extra goes in its session
-- entry. resumed: it carries an earlier session's system prompt (resume, load, fork); "restart" for
-- the agent's own session reopened as its supervisor starts.
local function session_ready(how, fresh, extra, resumed)
  subscribe_inbox()
  local last = last_recorded() or (how == "fork" and S.source_entry or nil)
  local tell = role_changed(resumed, how, last)
  append("session", vim.tbl_extend("force", extra or {}, { how = how, sessionId = S.session, imports = S.imported,
    role = store.role(S.spec), role_hash = S.role_hash }))
  local mode = adapter.mode(S.spec)
  S.client:request("session/set_mode", { sessionId = S.session, modeId = mode }, function(_, err)
    if err then
      notice(("could not set %s mode: %s"):format(mode, tostring(err.message)))
    else
      append("mode", { modeId = mode })
    end
    S.ready = true
    set_state("ready")
    out(("[session %s: %s]\n"):format(how, S.session))
    -- The spawn's prompt goes once, to the agent's first session. It's kept on disk with the queue,
    -- so one held (logged out) still goes after the supervisor ends and resumes the session.
    local queued = vim.iter(S.queue):any(function(prompt)
      return prompt.via == "spawn"
    end)
    if fresh and S.spec.prompt and S.spec.prompt ~= "" and not S.prompted and not queued then
      table.insert(S.queue, 1, { id = next_id(), text = S.spec.prompt, via = "spawn" })
      save_queue()
    end
    if tell then
      table.insert(S.queue, 1, role_prompt())
      save_queue()
    end
    if S.held then
      return set_state("held")
    end
    local first = table.remove(S.queue, 1)
    if first then
      deliver(first)
    end
  end)
end

-- The session's own capabilities, from initialize.
local function session_caps()
  local caps = (S.init or {}).agentCapabilities or {}
  return caps, type(caps.sessionCapabilities) == "table" and caps.sessionCapabilities or {}
end

-- A promotion's reload: closes the session and opens it again (resume, else load) with the
-- record's role prompt in _meta, and since Claude Code restores the system prompt a session
-- started with, gives it that prompt as the first message too (role_prompt). The queue waits on it.
-- Never while claude isn't logged in: the reopened session couldn't take a prompt, so the reload
-- waits first in the queue, which is held until the login is back.
reload = function()
  local blocked = auth.why(auth_kind(), true)
  if blocked then
    table.insert(S.queue, 1, { id = next_id(), reload = true, text = "(reload)", via = "iso" })
    hold(blocked, "auth")
    return
  end
  S.busy = true
  S.spec = store.agent(S.ws, S.agent) or S.spec
  local role = store.role(S.spec)
  local caps, session = session_caps()
  local method = session.resume and "session/resume" or (caps.loadSession and "session/load") or nil
  local function done(err)
    S.busy = false
    if err then
      notice(("could not reload the session as a %s (%s); iso restart %s/%s loads it. That role's prompt goes to it as the next message")
        :format(role, err, S.ws, S.agent))
      table.insert(S.queue, 1, role_prompt())
      save_queue()
    else
      local last = last_recorded()
      append("session", { how = "reload", sessionId = S.session, role = role, imports = S.imported, role_hash = S.role_hash })
      if not (last and same_prompt(last)) then
        table.insert(S.queue, 1, role_prompt())
        save_queue()
        notice(("reloaded the session as a %s; that role's prompt goes to it as the next message, since a resumed session keeps the system prompt it started with")
          :format(role))
      else
        notice(("reloaded the session as a %s; its role prompt hasn't changed"):format(role))
      end
    end
    next_prompt()
  end
  if not (session.close and method and S.session) then
    return done("the agent can't close and reopen a session")
  end
  set_state("working")
  S.client:request("session/close", { sessionId = S.session }, function(_, close_err)
    if close_err then
      return done(tostring(close_err.message))
    end
    S.replaying = method == "session/load"
    S.client:request(method, with_meta({ sessionId = S.session, cwd = S.cwd, mcpServers = {} }),
      function(_, err)
        S.replaying = false
        if err then
          return done(tostring(err.message))
        end
        S.client:request("session/set_mode", { sessionId = S.session, modeId = adapter.mode(S.spec) }, function()
          done()
        end)
      end)
  end)
end

-- A new session. before(id) runs once it's open, before it's ready (a switch replaces the journal
-- there); on_fail when it couldn't open (default: the supervisor ends, as there's no session).
local function new_session(how, fresh, before, on_fail, extra)
  S.client:request("session/new", with_meta({ cwd = S.cwd, mcpServers = {} }), function(result, err)
    if err or not result or not result.sessionId then
      notice("could not open a session: " .. tostring(err and err.message or "no session id"))
      if on_fail then
        return on_fail()
      end
      return M.shutdown(1)
    end
    if before then
      before(result.sessionId)
    end
    remember_session(result.sessionId, how or "new")
    session_ready(how or "new", fresh ~= false, extra)
  end)
end

local function session_cap(name)
  return type(S.caps.sessionCapabilities) == "table" and S.caps.sessionCapabilities[name] ~= nil
end

-- session/fork of source, at messageId (the adapter's fork point) or whole.
local function fork_request(source, message_id, callback)
  local params = with_meta({ sessionId = source, cwd = S.cwd, mcpServers = {} })
  if message_id then
    params._meta.jetbrains = { air = { fork = { version = 1, messageId = message_id } } }
  end
  S.client:request("session/fork", params, callback)
end

-- A fork's first session: an agent iso fork made (fork_from: its journal starts with its parent's up
-- to the fork, fork_seq, all of it without one), or a router or repo-root made root (isovim.cli.roles,
-- no fork_from). Its session is a copy of spec.fork_of (at fork_at; none before the first thing the
-- agent said, which is a new session), opened with its own role prompt; a new one when the agent
-- can't fork.
local function fork_session()
  local spec = S.spec
  local from_ws, from_agent = tostring(spec.fork_from or ""):match("^(.*)/([^/]+)$")
  -- The prompt its source's session had (the carried journal keeps no session entries): a fork of
  -- the same role needs no role message.
  S.source_entry = from_ws and last_recorded(journal.read(from_ws, from_agent)) or nil
  local function carry(id)
    if from_ws then
      replace_journal(sessions.carry(journal.read(from_ws, from_agent), tonumber(spec.fork_seq)))
      -- What was queued before the session opened (a promoter's message) is still queued.
      if #S.queue > 0 then
        queue_changed()
      end
    end
    return id
  end
  local extra = { from = spec.fork_from, source = spec.fork_of, at = spec.fork_at }
  if spec.fork_seq and not spec.fork_at then
    return new_session("fork", true, carry, nil, extra)
  elseif not session_cap("fork") then
    notice("the agent can't fork sessions; this one starts new")
    return new_session("fork", true, carry, nil, extra)
  end
  fork_request(spec.fork_of, spec.fork_at, function(result, err)
    if err or not result or not result.sessionId then
      notice(("could not fork session %s (%s); starting a new one"):format(tostring(spec.fork_of),
        tostring(err and err.message or "no session id")))
      return new_session("fork", true, carry, nil, extra)
    end
    carry()
    remember_session(result.sessionId, "fork")
    session_ready("fork", true, extra, true)
  end)
end

-- Resumes the recorded session: session/resume when the agent has it (no replay), else
-- session/load with its replay left out of the journal; a new one when neither works.
local function open_session(init)
  S.caps = init.agentCapabilities or {}
  local id = store.session_id(S.ws, S.agent)
  if not id then
    if S.spec.fork_of then
      return fork_session()
    end
    return new_session()
  end
  local caps = S.caps
  local resume = type(caps.sessionCapabilities) == "table" and caps.sessionCapabilities.resume ~= nil
  local method = resume and "session/resume" or (caps.loadSession and "session/load") or nil
  if not method then
    return new_session()
  end
  S.replaying = method == "session/load"
  S.client:request(method, with_meta({ sessionId = id, cwd = S.cwd, mcpServers = {} }), function(_, err)
    S.replaying = false
    if err then
      notice(("could not resume session %s (%s); starting a new one"):format(id, tostring(err.message)))
      return new_session()
    end
    S.session = id
    session_ready(resume and "resume" or "load", false, nil, "restart")
  end)
end

-- Switching sessions (/new, /clear, /resume, a rewind): what's running stops first (its turn is
-- cancelled, and the switch goes when it ends); the session isn't ready meanwhile, so prompts that
-- come in wait in the queue and go to the new session.
local function when_idle(fn)
  if S.handover then
    error("it's handed over to Claude's screen (iso handover)")
  elseif not S.session or not S.ready and not S.busy then
    error("its session isn't up yet")
  elseif S.after_turn then
    error("it's already switching sessions")
  end
  S.ready = false
  if S.busy then
    S.after_turn = fn
    cancel_turn()
    return true
  end
  fn()
  return false
end

-- The session left behind is closed in the adapter, when it can, so it stops holding it.
local function close_old(id)
  if id and session_cap("close") then
    S.client:request("session/close", { sessionId = id }, function() end)
  end
end

-- The switch failed: the old session stays.
local function stay()
  S.ready = true
  set_state("ready")
  next_prompt()
end

-- /new and /clear: a new session, its journal empty; the old one's is kept for /resume.
function CALLS.new_session(payload)
  local old = S.session
  local waited = when_idle(function()
    new_session("new", false, function()
      replace_journal({}, old)
      close_old(old)
    end, stay, { cleared = true, command = payload.command, previous = old })
  end)
  return { switching = true, waited = waited, previous = old }
end

-- /resume <id>: back to a session the agent had, with the journal it kept (session/resume); one
-- with no kept journal is loaded (session/load), its replay going into the journal.
function CALLS.resume(payload)
  local id = payload.id
  if type(id) ~= "string" or id == "" then
    error("/resume needs a session id")
  elseif id == S.session then
    error("that's its session now")
  end
  local old = S.session
  local kept = sessions.read_archive(S.ws, S.agent, id)
  local resume = session_cap("resume") and kept ~= nil
  local method = resume and "session/resume" or (S.caps.loadSession and "session/load") or nil
  if not method then
    error("the agent can't resume sessions")
  end
  local waited = when_idle(function()
    replace_journal(kept and sessions.carry(kept) or {}, old)
    S.loading = method == "session/load" and not kept
    S.replaying = method == "session/load" and kept ~= nil
    S.client:request(method, with_meta({ sessionId = id, cwd = S.cwd, mcpServers = {} }), function(_, err)
      S.loading, S.replaying = false, false
      if err then
        -- Back to the old one, as it was.
        replace_journal(sessions.read_archive(S.ws, S.agent, old) or {})
        notice(("could not resume session %s (%s)"):format(id, tostring(err.message)))
        return stay()
      end
      close_old(old)
      remember_session(id, "resume")
      session_ready(method == "session/resume" and "resume" or "load", false, { previous = old }, true)
    end)
  end)
  return { switching = true, waited = waited, previous = old }
end

-- The sessions this agent has had, for the history picker, newest first.
function CALLS.sessions()
  local list = sessions.list(S.ws, S.agent)
  for _, item in ipairs(list) do
    item.current = item.id == S.session
    item.kept = vim.uv.fs_stat(sessions.archive(S.ws, S.agent, item.id)) ~= nil or item.current
  end
  return { sessions = list, current = S.session }
end

-- A rewind: your prompt (its id) edited to text. The session forks at the agent's message before
-- it (a new session when there's none), the files go back to the snapshot taken before its turn,
-- the journal keeps what came before it, and the edited prompt goes first.
---@param payload {id: string, text: string}
function CALLS.rewind(payload)
  if type(payload.text) ~= "string" or vim.trim(payload.text) == "" then
    error("a rewind needs the prompt's new text")
  end
  local entries = journal.read(S.ws, S.agent)
  local prompt, snapshot
  for _, entry in ipairs(entries) do
    if entry.kind == "prompt" and entry.id == payload.id then
      prompt = entry
    elseif prompt and not snapshot and entry.kind == "turn" and entry.state == "start" and entry.id == payload.id then
      snapshot = entry
    end
  end
  if not prompt then
    error("no prompt " .. tostring(payload.id) .. " in this session")
  end
  local cut = sessions.cut(entries, prompt.seq, "before")
  local old = S.session
  local function done(id)
    local restored
    local checkout = sessions.checkout(S.ws, S.agent)
    if snapshot and snapshot.snapshot and snapshot.snapshot_dir == checkout then
      local result, err = sessions.restore(snapshot.snapshot_dir, snapshot.snapshot)
      restored = result and ("files restored from the snapshot before it (%d put back, %d removed)")
        :format(result.restored, result.deleted) or ("could not restore the files: " .. tostring(err))
    elseif snapshot and snapshot.snapshot then
      -- A fork's carried turns snapshot its parent's checkout, not this one.
      restored = "its snapshot is of another checkout, so the files stay as they are"
    else
      restored = "no snapshot of its files (no checkout then), so they stay as they are"
    end
    local carried = sessions.carry(entries, cut.upto)
    replace_journal(carried, old)
    close_old(old)
    remember_session(id, "rewind")
    table.insert(S.queue, 1, { id = next_id(), text = payload.text, via = "composer" })
    session_ready("rewind", false, { previous = old, prompt = payload.id, at = cut.messageId, files = restored }, cut.messageId ~= nil)
  end
  local waited = when_idle(function()
    local function opened(result, err)
      if err or not result or not result.sessionId then
        notice(("could not fork the session before that prompt (%s)"):format(tostring(err and err.message or "no session id")))
        return stay()
      end
      done(result.sessionId)
    end
    -- Before anything the agent said: nothing to fork.
    if not cut.messageId then
      return S.client:request("session/new", with_meta({ cwd = S.cwd, mcpServers = {} }), opened)
    end
    fork_request(old, cut.messageId, opened)
  end)
  return { rewinding = true, waited = waited }
end

-- Codex runs a hook only once it's trusted: isovim's (CODEX_CONFIG, isovim.acp.adapter) are
-- trusted over codex-acp's _codex/hooks/list and /trust, which records their hashes in Codex's
-- config, as accepting them in Codex's own prompt would. An adapter without those calls (or a
-- failure) leaves them untrusted, which the journal says; the session opens either way.
local function trust_hooks(done)
  if S.spec.kind ~= "codex" then
    return done()
  end
  S.client:request("_codex/hooks/list", { cwd = S.cwd }, function(listed, err)
    local mine = {}
    for _, hook in ipairs(type(listed) == "table" and listed.hooks or {}) do
      if hook.trustStatus ~= "trusted" and tostring(hook.command or vim.json.encode(hook)):find("iso-hook", 1, true) then
        mine[#mine + 1] = { key = hook.key, currentHash = hook.currentHash }
      end
    end
    if err or #mine == 0 then
      if err then
        notice("could not list Codex's hooks, so isovim's may not run: " .. tostring(err.message))
      end
      return done()
    end
    S.client:request("_codex/hooks/trust", { cwd = S.cwd, hooks = mine }, function(result, trust_err)
      if trust_err or not (type(result) == "table" and result.trusted) then
        notice("could not trust isovim's hooks in Codex: " .. tostring(trust_err and trust_err.message or "not trusted"))
      end
      done()
    end)
  end)
end

-- Starts the adapter and opens the session. Live Bash output comes as terminal output deltas
-- (claude-agent-acp's _meta extension), which the chat draws under the tool call.
local function start_adapter()
  local client
  S.client = Client.new(adapter.command(S.cwd, S.spec), vim.tbl_extend("force", handlers, {
    on_exit = function(...)
      handlers.on_exit(client, ...)
    end,
  }))
  client = S.client
  local started, start_err = pcall(S.client.start, S.client)
  if not started then
    notice("could not start the agent: " .. tostring(start_err))
    return M.shutdown(1)
  end
  S.client:request("initialize", {
    protocolVersion = 1,
    clientInfo = { name = "isovim", version = "1" },
    -- Forms: AskUserQuestion comes as a form elicitation, which the adapter sends (and enables the
    -- tool for) only when the client offers them.
    clientCapabilities = { fs = { readTextFile = false, writeTextFile = false }, terminal = false,
      elicitation = { form = vim.empty_dict() },
      _meta = { terminal_output = true, terminal_output_delta = true } },
  }, function(init, init_err)
    if init_err or not init then
      notice("the agent did not initialize: " .. tostring(init_err and init_err.message))
      return M.shutdown(1)
    end
    S.init = init
    trust_hooks(function()
      open_session(init)
    end)
  end)
end

-- Claude exited: what it did goes into the journal, any client attached for the handover is
-- detached, and the session is opened again, which sends what was queued meanwhile.
local function handed_back(code)
  local handover = S.handover
  local path = handover.transcript or require("isovim.acp.handover").transcript(S.session, S.cwd)
  local offset = handover.transcript and handover.offset or 0
  for _, entry in ipairs(require("isovim.acp.handover").entries(path, offset)) do
    append(entry[1], vim.tbl_extend("force", entry[2], { handover = true }))
  end
  S.handover = nil
  append("handover", { state = "end", code = code })
  out(("\n[back from claude (exit %s); reopening the session]\n"):format(tostring(code)))
  if vim.env.TMUX_PANE then
    vim.system({ "tmux", "detach-client", "-s", vim.env.TMUX_PANE })
  end
  start_adapter()
end

-- iso handover: the ACP session closes (its adapter stops) and your claude takes the pane, on the
-- tty, until it exits. Refused while a turn runs.
function CALLS.handover()
  if S.spec.kind ~= "claude" then
    error("a handover gives the session to Claude's own screen; this is a " .. tostring(S.spec.kind) .. " agent")
  elseif S.handover then
    error("it's already handed over")
  elseif S.busy then
    error("it's working; cancel its turn (C-c in the chat) or wait for it to end")
  elseif not S.session or not S.ready then
    error("its session isn't up yet")
  end
  local handover_mod = require("isovim.acp.handover")
  local transcript = handover_mod.transcript(S.session, S.cwd)
  S.handover = { transcript = transcript, offset = handover_mod.size(transcript) }
  S.ready = false
  append("handover", { state = "start", sessionId = S.session })
  pcall(S.client.stop, S.client)
  local cmd = require("isovim.panes").handover_cmd(S.session, (instructions()))
  -- Its hooks report its state, as a TUI agent's do (iso-hook leaves ACP agents' alone).
  local env = {}
  for name, value in pairs(vim.fn.environ()) do
    if name ~= "ISOVIM_ACP" then
      env[#env + 1] = name .. "=" .. value
    end
  end
  io.stdout:write("\27[2J\27[H")
  io.stdout:flush()
  local handle, pid = vim.uv.spawn(cmd[1], { args = vim.list_slice(cmd, 2), cwd = S.cwd, env = env, stdio = { 0, 1, 2 } },
    function(code)
      vim.schedule(function()
        handed_back(code)
      end)
    end)
  if not handle then
    S.handover.transcript = nil
    vim.schedule(function()
      notice("could not run claude: " .. tostring(pid))
      handed_back(-1)
    end)
    return { started = false }
  end
  S.handover.pid = pid
  return { started = true, pid = pid, session = S.session, command = cmd[1] }
end

-- The supervisor stops (iso rm, iso restart, the agent's tmux session killed): everything it
-- started goes with it, the background shells Claude runs in process groups of their own too.
function M.shutdown(code)
  -- The socket first, and only while it's this one's: an iso restart starts the next supervisor
  -- on the same path while this one is still stopping.
  local sock = S.sock and vim.uv.fs_stat(S.sock)
  if sock and S.sock_ino and sock.ino == S.sock_ino then
    os.remove(S.sock)
  end
  S.sock = nil
  local transport = require("isovim.acp.transport")
  -- Asked first, while they're still below it. A signal handler runs this, in a fast context.
  local listed, below, own_pgid = pcall(transport.descendants, vim.uv.os_getpid())
  below = listed and below or {}
  if S.handover and S.handover.pid then
    vim.uv.kill(S.handover.pid, "sighup")
  end
  if S.client then
    pcall(S.client.stop, S.client)
  end
  pcall(transport.kill_descendants, below, own_pgid)
  if S.sock then
    os.remove(S.sock)
  end
  os.exit(code or 0)
end

---@param addr string <ws>/<agent>, the agent's address by ids
function M.run(addr)
  local ws, agent = (addr or ""):match("^(.*)/([^/]+)$")
  local spec = ws and store.agent(ws, agent)
  if not spec then
    io.stderr:write("isovim: no agent " .. tostring(addr) .. "\n")
    os.exit(1)
  end
  S.ws, S.agent, S.spec = ws, agent, spec
  -- LuaJIT starts every process on the same seed, which would line up the random waits (bugs.watch's).
  math.randomseed(vim.uv.hrtime() + vim.uv.os_getpid())
  changed_code()
  vim.uv.new_timer():start(30000, 30000, vim.schedule_wrap(check_code))
  vim.fn.mkdir(store.run_dir(ws), "p")
  log.file = store.run_dir(ws) .. "/" .. agent .. ".acp.log"
  S.writer = journal.writer(ws, agent)
  S.asks = asks_mod.new(ws, agent, journal_ask)
  -- Every supervisor subscribes to the bug queue; whichever claims a report first spawns its worker.
  pcall(require("isovim.bugs").watch)
  local entries = journal.read(ws, agent)
  S.prompted = vim.iter(entries):any(function(entry)
    return entry.kind == "prompt"
  end)
  -- What was queued when the last supervisor exited, delivered once the session is up; the
  -- journal says so, so a chat's queue (and its count) is this one, not what it last read.
  S.queue = load_queue(ws, agent)
  local journaled = vim.iter(entries):any(function(entry)
    return entry.kind == "queued" or entry.kind == "queue"
  end)
  if #S.queue > 0 or journaled then
    append("queue", { items = queue_items() })
    if #S.queue > 0 then
      out(("%d queued prompt(s) kept from before; they go once the session is up\n"):format(#S.queue))
    end
  end
  S.cwd = vim.uv.cwd()
  out(("isovim ACP supervisor for %s in %s\n"):format(addr, S.cwd))

  for _, name in ipairs({ "sigterm", "sigint", "sighup" }) do
    vim.uv.new_signal():start(name, function()
      -- Ctrl-C on Claude's screen is Claude's, not a reason to stop.
      if name == "sigint" and S.handover then
        return
      end
      M.shutdown(0)
    end)
  end

  -- The socket first, so a prompt sent while the adapter installs or starts waits in the queue.
  S.sock = require("isovim.acp").socket(ws, agent)
  os.remove(S.sock)
  vim.fn.serverstart(S.sock)
  S.sock_ino = (vim.uv.fs_stat(S.sock) or {}).ino

  local kind = S.spec.kind
  if not adapter.supports(kind) then
    notice(("a %s agent can't run over ACP: the launch table has %s"):format(tostring(kind),
      table.concat(vim.tbl_keys(adapter.adapters), ", ")))
    return M.shutdown(1)
  end
  local launch = adapter.get(kind)
  if not adapter.installed(kind) and not vim.env.ISOVIM_ACP_CMD then
    out(("installing %s@%s ...\n"):format(launch.package, launch.version))
  end
  local installed, err = adapter.ensure(kind)
  if not installed then
    notice("could not install " .. launch.package .. ": " .. tostring(err))
    return M.shutdown(1)
  end
  -- A claude that isn't logged in opens sessions and then fails every prompt: said once, as that,
  -- and the queue waits for the login rather than being used up.
  inbox_clear()
  local blocked = auth.why(auth_kind(), true)
  if blocked then
    hold(blocked, "auth")
  end
  start_adapter()

  while true do
    vim.wait(2 ^ 31 - 1, function()
      return false
    end, 2 ^ 31 - 1)
  end
end

return M
