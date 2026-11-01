-- The supervisor of one ACP agent, run in its tmux pane by agent_host.lua (nvim -l), so tmux owns
-- its lifetime as it owns a TUI agent's and it outlives the isovim TUI. It starts the adapter
-- (isovim.acp.adapter), opens or resumes the session with the agent's role prompt and isovim's
-- hooks, writes everything the session does to the agent's journal (isovim.acp.journal), and
-- serves an nvim RPC socket (isovim.acp.socket) where prompts come in. One prompt is with the agent
-- at a time: one that arrives while it works is queued and sent when the turn ends. It writes the
-- agent's state file (ready, working, idle), which publishes agent.<scope>.<id>.status, and
-- publishes msg.<scope>.<id> for each message it takes. Its pane shows a plain-text tail.
--
-- Permissions: the session runs in bypassPermissions mode, as TUI agents run with
-- --permission-mode bypassPermissions. A permission the agent asks for anyway is denied (approvals
-- aren't built yet) and the denial is journaled, so the chat shows it.
local store = require("isovim.store")
local events = require("isovim.events")
local status = require("isovim.status")
local journal = require("isovim.acp.journal")
local adapter = require("isovim.acp.adapter")
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

local S = {
  ws = nil, ---@type string
  agent = nil, ---@type string
  writer = nil, ---@type isovim.acp.Writer
  client = nil, ---@type table
  session = nil, ---@type string?
  ready = false,
  busy = false,
  queue = {}, ---@type isovim.acp.Prompt[]
  replaying = false,
  prompts = 0,
  prompted = false, -- whether the journal has a prompt yet, so the spawn's goes only once
}

-- Prompt ids, unique in the journal across restarts.
local function next_id()
  S.prompts = S.prompts + 1
  return ("p%d.%d"):format(os.time(), S.prompts)
end

local function out(text)
  io.stdout:write(text)
  io.stdout:flush()
end

local function notice(text)
  S.writer.append("notice", { text = text })
  out("\n[" .. text .. "]\n")
end

local function set_state(state)
  status.set_state(S.ws, S.agent, state)
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

-- The turn ended: say so, and send the next queued prompt.
local function turn_ended(prompt, result, err)
  S.busy = false
  local reason = result and result.stopReason or nil
  S.writer.append("turn", { state = "end", id = prompt.id, stopReason = reason, error = err and err.message or nil })
  if err then
    notice("the prompt failed: " .. tostring(err.message or vim.inspect(err)))
  end
  out("\n")
  local next_prompt = table.remove(S.queue, 1)
  if next_prompt then
    deliver(next_prompt)
  else
    set_state("idle")
  end
end

---@param prompt isovim.acp.Prompt
deliver = function(prompt)
  S.busy = true
  S.writer.append("prompt", { id = prompt.id, text = prompt.text, from = prompt.from, kind = prompt.kind, stamp = prompt.stamp })
  S.writer.append("turn", { state = "start", id = prompt.id })
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
    S.writer.append("queued", { id = prompt.id, text = prompt.text, from = prompt.from, position = #S.queue })
    out(("\n(queued %d) %s\n"):format(#S.queue, prompt.text))
    return { id = prompt.id, queued = true, position = #S.queue }
  end
  deliver(prompt)
  return { id = prompt.id, queued = false }
end

-- What the socket answers: iso's CLI and the TUI call these (isovim.acp.call).
local CALLS = {}

---@param payload {text: string, from?: string, kind?: string, stamp?: string, message?: string, publish?: boolean}
function CALLS.prompt(payload)
  if type(payload.text) ~= "string" or vim.trim(payload.text) == "" then
    error("a prompt needs text")
  end
  return submit({ text = payload.text, from = payload.from, kind = payload.kind, stamp = payload.stamp,
    message = payload.message, publish = payload.publish })
end

function CALLS.status()
  return { state = status.state(S.ws, S.agent), ready = S.ready, busy = S.busy, queue = #S.queue, session = S.session,
    journal = S.writer.path }
end

function CALLS.cancel()
  if S.busy and S.session then
    S.client:notify("session/cancel", { sessionId = S.session })
  end
  return { cancelled = S.busy }
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
  S.writer.append("permission", { tool = tool, toolCallId = call.toolCallId, decision = "denied",
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
      S.writer.append("update", { update = params.update })
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
  on_exit = function(code, signal, stderr)
    notice(("the agent exited (code %s, signal %s)%s"):format(code, signal,
      #stderr > 0 and (": " .. stderr[#stderr]) or ""))
    if S.ready then
      set_state("idle")
    end
    M.shutdown(1)
  end,
}

-- The settings and prompt every session is opened with: the role prompt appended to Claude Code's
-- own, and isovim's hooks (the same --settings TUI agents get).
local function meta(spec)
  local panes = require("isovim.panes")
  return {
    systemPrompt = { append = panes.instructions(spec) },
    claudeCode = { options = { settings = panes.hook_settings() } },
  }
end

local function remember_session(id)
  S.session = id
  vim.fn.mkdir(store.run_dir(S.ws), "p")
  vim.fn.writefile({ id }, store.run_dir(S.ws) .. "/" .. S.agent .. ".session")
  store.update_agent(S.ws, S.agent, { session = id })
end

-- The session is up: bypass mode, then ready, then what was waiting.
local function session_ready(how, spec, fresh)
  S.writer.append("session", { how = how, sessionId = S.session })
  S.client:request("session/set_mode", { sessionId = S.session, modeId = "bypassPermissions" }, function(_, err)
    if err then
      notice("could not set bypassPermissions mode: " .. tostring(err.message))
    else
      S.writer.append("mode", { modeId = "bypassPermissions" })
    end
    S.ready = true
    set_state("ready")
    out(("[session %s: %s]\n"):format(how, S.session))
    -- The spawn's prompt goes once, to the agent's first session.
    if fresh and spec.prompt and spec.prompt ~= "" and not S.prompted then
      table.insert(S.queue, 1, { id = next_id(), text = spec.prompt })
    end
    local first = table.remove(S.queue, 1)
    if first then
      deliver(first)
    end
  end)
end

local function new_session(spec, cwd)
  S.client:request("session/new", { cwd = cwd, mcpServers = {}, _meta = meta(spec) }, function(result, err)
    if err or not result or not result.sessionId then
      notice("could not open a session: " .. tostring(err and err.message or "no session id"))
      return M.shutdown(1)
    end
    remember_session(result.sessionId)
    session_ready("new", spec, true)
  end)
end

-- Resumes the recorded session: session/resume when the agent has it (no replay), else
-- session/load with its replay left out of the journal; a new one when neither works.
local function open_session(spec, cwd, init)
  local id = store.session_id(S.ws, S.agent)
  if not id then
    return new_session(spec, cwd)
  end
  local caps = init.agentCapabilities or {}
  local resume = type(caps.sessionCapabilities) == "table" and caps.sessionCapabilities.resume ~= nil
  local method = resume and "session/resume" or (caps.loadSession and "session/load") or nil
  if not method then
    return new_session(spec, cwd)
  end
  S.replaying = method == "session/load"
  S.client:request(method, { sessionId = id, cwd = cwd, mcpServers = {}, _meta = meta(spec) }, function(_, err)
    S.replaying = false
    if err then
      notice(("could not resume session %s (%s); starting a new one"):format(id, tostring(err.message)))
      return new_session(spec, cwd)
    end
    S.session = id
    session_ready(resume and "resume" or "load", spec, false)
  end)
end

function M.shutdown(code)
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
  S.ws, S.agent = ws, agent
  vim.fn.mkdir(store.run_dir(ws), "p")
  log.file = store.run_dir(ws) .. "/" .. agent .. ".acp.log"
  S.writer = journal.writer(ws, agent)
  S.prompted = vim.iter(journal.read(ws, agent)):any(function(entry)
    return entry.kind == "prompt"
  end)
  local cwd = vim.uv.cwd()
  out(("isovim ACP supervisor for %s in %s\n"):format(addr, cwd))

  for _, name in ipairs({ "sigterm", "sigint", "sighup" }) do
    vim.uv.new_signal():start(name, function()
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

  S.client = Client.new(adapter.command(cwd), handlers)
  local started, start_err = pcall(S.client.start, S.client)
  if not started then
    notice("could not start the agent: " .. tostring(start_err))
    return M.shutdown(1)
  end
  S.client:request("initialize", {
    protocolVersion = 1,
    clientInfo = { name = "isovim", version = "1" },
    clientCapabilities = { fs = { readTextFile = false, writeTextFile = false }, terminal = false },
  }, function(init, init_err)
    if init_err or not init then
      notice("the agent did not initialize: " .. tostring(init_err and init_err.message))
      return M.shutdown(1)
    end
    open_session(spec, cwd, init)
  end)

  while true do
    vim.wait(2 ^ 31 - 1, function()
      return false
    end, 2 ^ 31 - 1)
  end
end

return M
