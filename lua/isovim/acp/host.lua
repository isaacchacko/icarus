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
-- iso handover: the adapter is stopped (which closes the ACP session), your own claude runs in the
-- pane on the same session (claude --resume), and when it exits what happened there goes into the
-- journal from Claude's transcript and the session is opened again. One writer at a time: prompts
-- that come in meanwhile wait in the queue.
--
-- Permissions: the session runs in bypassPermissions mode, as TUI agents run with
-- --permission-mode bypassPermissions. A permission the agent asks for anyway is denied (approvals
-- aren't built yet) and the denial is journaled, so the chat shows it.
local store = require("isovim.store")
local events = require("isovim.events")
local status = require("isovim.status")
local journal = require("isovim.acp.journal")
local adapter = require("isovim.acp.adapter")
local imports = require("isovim.acp.imports")
local log = require("isovim.acp.log")
local Client = require("isovim.acp.client")

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

-- Journals an entry and sends it to every subscribed chat; one whose channel is gone is dropped.
local function append(kind, fields)
  local entry = S.writer.append(kind, fields)
  for chan in pairs(S.subscribers) do
    local ok = pcall(vim.rpcnotify, chan, "nvim_exec_lua", "require('isovim.acp.chat').push(...)",
      { S.ws, S.agent, entry })
    if not ok then
      S.subscribers[chan] = nil
    end
  end
  return entry
end

local function notice(text)
  append("notice", { text = text })
  out("\n[" .. text .. "]\n")
end

local function set_state(state)
  status.set_state(S.ws, S.agent, state)
end

local function queue_items()
  return vim.tbl_map(function(prompt)
    return { id = prompt.id, text = prompt.text, from = prompt.from, via = prompt.via }
  end, S.queue)
end

-- The queue as it is now, after anything but a push (which journals a queued entry).
local function queue_changed()
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

local deliver

-- The next queued prompt goes, unless the session isn't up (a handover, a restart).
local function next_prompt()
  if S.busy or not S.ready then
    return
  end
  local prompt = table.remove(S.queue, 1)
  if prompt then
    deliver(prompt)
  else
    set_state("idle")
  end
end

-- The turn ended: say so, and send the next queued prompt.
local function turn_ended(prompt, result, err)
  S.busy = false
  local reason = result and result.stopReason or nil
  append("turn", { state = "end", id = prompt.id, stopReason = reason, error = err and err.message or nil })
  if err then
    notice("the prompt failed: " .. tostring(err.message or vim.inspect(err)))
  end
  out("\n")
  next_prompt()
end

---@param prompt isovim.acp.Prompt
deliver = function(prompt)
  S.busy = true
  append("prompt", { id = prompt.id, text = prompt.text, from = prompt.from, message = prompt.kind, stamp = prompt.stamp,
    via = prompt.via })
  append("turn", { state = "start", id = prompt.id })
  set_state("working")
  out(("\n❯ %s%s\n"):format(prompt.from and ("(" .. prompt.from .. ") ") or "", prompt.text))
  S.client:request("session/prompt", { sessionId = S.session, prompt = { { type = "text", text = prompt.text } } },
    function(result, err)
      turn_ended(prompt, result, err)
    end)
end

-- Takes a prompt: sends it now, or queues it while a turn runs (or before the session is up).
---@param prompt isovim.acp.Prompt
local function submit(prompt)
  prompt.id = next_id()
  local queued = S.busy or not S.ready
  if prompt.publish then
    events.publish_msg(S.ws, S.agent, { from = prompt.from, kind = prompt.kind, id = prompt.stamp,
      text = prompt.message or prompt.text, queued = queued })
  end
  if queued then
    S.queue[#S.queue + 1] = prompt
    append("queued", { id = prompt.id, text = prompt.text, from = prompt.from, via = prompt.via, position = #S.queue })
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

-- What the socket answers: iso's CLI and the TUI call these (isovim.acp.call).
local CALLS = {}

---@param payload {text: string, from?: string, kind?: string, stamp?: string, message?: string, publish?: boolean}
function CALLS.prompt(payload)
  if type(payload.text) ~= "string" or vim.trim(payload.text) == "" then
    error("a prompt needs text")
  end
  return submit({ text = payload.text, from = payload.from, kind = payload.kind, stamp = payload.stamp,
    message = payload.message, publish = payload.publish, via = payload.publish and "iso" or "composer" })
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
-- sender and takes the new text; one without an id is a new prompt of yours. A queued prompt left
-- out is dropped. Ids no longer queued (sent meanwhile) are left out and reported as gone.
---@param payload {items: {id?: string, text: string}[]}
function CALLS.queue_set(payload)
  local by_id = {}
  for _, prompt in ipairs(S.queue) do
    by_id[prompt.id] = prompt
  end
  local queue, gone = {}, {}
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
        end
      else
        prompt = { id = next_id(), text = text, via = "composer" }
      end
      queue[#queue + 1] = prompt
    end
  end
  S.queue = queue
  queue_changed()
  next_prompt()
  return { items = queue_items(), gone = gone }
end

function CALLS.queue_clear()
  local cleared = #S.queue
  S.queue = {}
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

-- A permission the agent asks for: denied, with the reject option it offered (or a cancel).
local function deny(params, answer)
  local reject
  for _, option in ipairs(params.options or {}) do
    if option.kind == "reject_once" or (option.kind == "reject_always" and not reject) then
      reject = option.optionId
    end
  end
  answer({ outcome = reject and { outcome = "selected", optionId = reject } or { outcome = "cancelled" } })
  local call = params.toolCall or {}
  local tool = call.title or (call.rawInput and vim.inspect(call.rawInput)) or call.toolCallId or "a tool"
  append("permission", { tool = tool, toolCallId = call.toolCallId, decision = "denied",
    reason = "approvals not built yet" })
  out(("\ndenied: %s (approvals not built yet)\n"):format(tool))
end

local handlers = {
  on_notification = function(method, params)
    if method == "session/update" and type(params.update) == "table" then
      -- A load replays history that the journal already holds.
      if S.replaying then
        return
      end
      append("update", { update = params.update })
      show_update(params.update)
    end
  end,
  on_request = function(method, params, answer)
    if method == "session/request_permission" then
      deny(params, answer)
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

-- The settings and prompt every session is opened with: the instructions appended to Claude
-- Code's own, and isovim's hooks (the same --settings TUI agents get).
local function meta()
  local append_text, found = instructions()
  S.imported = vim.tbl_map(function(import)
    return import.path
  end, found)
  return {
    systemPrompt = { append = append_text },
    claudeCode = { options = { settings = require("isovim.panes").hook_settings() } },
  }
end

local function remember_session(id)
  S.session = id
  vim.fn.mkdir(store.run_dir(S.ws), "p")
  vim.fn.writefile({ id }, store.run_dir(S.ws) .. "/" .. S.agent .. ".session")
  store.update_agent(S.ws, S.agent, { session = id })
end

-- The session is up: bypass mode, then ready, then what was waiting.
local function session_ready(how, fresh)
  append("session", { how = how, sessionId = S.session, imports = S.imported })
  S.client:request("session/set_mode", { sessionId = S.session, modeId = "bypassPermissions" }, function(_, err)
    if err then
      notice("could not set bypassPermissions mode: " .. tostring(err.message))
    else
      append("mode", { modeId = "bypassPermissions" })
    end
    S.ready = true
    set_state("ready")
    out(("[session %s: %s]\n"):format(how, S.session))
    -- The spawn's prompt goes once, to the agent's first session.
    if fresh and S.spec.prompt and S.spec.prompt ~= "" and not S.prompted then
      table.insert(S.queue, 1, { id = next_id(), text = S.spec.prompt, via = "spawn" })
    end
    local first = table.remove(S.queue, 1)
    if first then
      deliver(first)
    end
  end)
end

local function new_session()
  S.client:request("session/new", { cwd = S.cwd, mcpServers = {}, _meta = meta() }, function(result, err)
    if err or not result or not result.sessionId then
      notice("could not open a session: " .. tostring(err and err.message or "no session id"))
      return M.shutdown(1)
    end
    remember_session(result.sessionId)
    session_ready("new", true)
  end)
end

-- Resumes the recorded session: session/resume when the agent has it (no replay), else
-- session/load with its replay left out of the journal; a new one when neither works.
local function open_session(init)
  local id = store.session_id(S.ws, S.agent)
  if not id then
    return new_session()
  end
  local caps = init.agentCapabilities or {}
  local resume = type(caps.sessionCapabilities) == "table" and caps.sessionCapabilities.resume ~= nil
  local method = resume and "session/resume" or (caps.loadSession and "session/load") or nil
  if not method then
    return new_session()
  end
  S.replaying = method == "session/load"
  S.client:request(method, { sessionId = id, cwd = S.cwd, mcpServers = {}, _meta = meta() }, function(_, err)
    S.replaying = false
    if err then
      notice(("could not resume session %s (%s); starting a new one"):format(id, tostring(err.message)))
      return new_session()
    end
    S.session = id
    session_ready(resume and "resume" or "load", false)
  end)
end

-- Starts the adapter and opens the session. Live Bash output comes as terminal output deltas
-- (claude-agent-acp's _meta extension), which the chat draws under the tool call.
local function start_adapter()
  local client
  S.client = Client.new(adapter.command(S.cwd), vim.tbl_extend("force", handlers, {
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
    clientCapabilities = { fs = { readTextFile = false, writeTextFile = false }, terminal = false,
      _meta = { terminal_output = true, terminal_output_delta = true } },
  }, function(init, init_err)
    if init_err or not init then
      notice("the agent did not initialize: " .. tostring(init_err and init_err.message))
      return M.shutdown(1)
    end
    open_session(init)
  end)
end

-- Claude exited: what it did goes into the journal, any client attached for the handover is
-- detached, and the session is opened again, which sends what was queued meanwhile.
local function handed_back(code)
  local handover = S.handover
  local path = handover.transcript or require("isovim.acp.handover").transcript(S.session)
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
  if S.handover then
    error("it's already handed over")
  elseif S.busy then
    error("it's working; cancel its turn (C-c in the chat) or wait for it to end")
  elseif not S.session or not S.ready then
    error("its session isn't up yet")
  end
  local handover_mod = require("isovim.acp.handover")
  local transcript = handover_mod.transcript(S.session)
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

function M.shutdown(code)
  if S.handover and S.handover.pid then
    vim.uv.kill(S.handover.pid, "sighup")
  end
  if S.client then
    pcall(S.client.stop, S.client)
  end
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
  vim.fn.mkdir(store.run_dir(ws), "p")
  log.file = store.run_dir(ws) .. "/" .. agent .. ".acp.log"
  S.writer = journal.writer(ws, agent)
  S.prompted = vim.iter(journal.read(ws, agent)):any(function(entry)
    return entry.kind == "prompt"
  end)
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

  if not adapter.installed() and not vim.env.ISOVIM_ACP_CMD then
    out(("installing %s@%s ...\n"):format(adapter.package, adapter.version))
  end
  local installed, err = adapter.ensure()
  if not installed then
    notice("could not install " .. adapter.package .. ": " .. tostring(err))
    return M.shutdown(1)
  end
  start_adapter()

  while true do
    vim.wait(2 ^ 31 - 1, function()
      return false
    end, 2 ^ 31 - 1)
  end
end

return M
