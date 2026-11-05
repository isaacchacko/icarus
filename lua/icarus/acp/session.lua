-- One chat's ACP connection, run inside icarus: it starts the adapter (icarus.acp.adapter) in the
-- chat's dir, opens a new session or loads the chat's last one (the adapter replays its history as
-- updates), and sets bypassPermissions, as isovim's agents always ran. One prompt is with the agent
-- at a time; one sent while it works waits in the queue and goes when the turn ends. The adapter
-- stops with icarus, the chat's session kept for the next load.
--
-- What it hears goes to its handlers:
--   on_session(id)                 the session is open (new or loaded)
--   on_update(update, loading)     a session/update; loading while a load replays history
--   on_prompt(text)                a prompt went to the agent
--   on_turn("start"|"end", result) result: {stopReason?, error?}
--   on_permission(params, answer)  session/request_permission; answer(optionId) or answer() to cancel
--   on_notice(text)                icarus's own words: errors, the adapter exiting
local Client = require("icarus.acp.client")
local adapter = require("icarus.acp.adapter")
local imports = require("icarus.acp.imports")

local M = {}

---@class icarus.acp.Session
---@field client? table
---@field id? string
---@field ready boolean
---@field busy boolean
---@field loading boolean
---@field queue string[]
---@field handlers table
local Session = {}
Session.__index = Session

local function with_instructions(params, cwd)
  local imported = imports.prompt(imports.collect(cwd))
  if imported ~= "" then
    params._meta = { systemPrompt = { append = imported } }
  end
  return params
end

function Session:deliver(text)
  self.busy = true
  self.handlers.on_prompt(text)
  self.handlers.on_turn("start")
  self.client:request("session/prompt", { sessionId = self.id, prompt = { { type = "text", text = text } } },
    function(result, err)
      self.busy = false
      self.handlers.on_turn("end", { stopReason = result and result.stopReason, error = err and err.message })
      local next_text = table.remove(self.queue, 1)
      if next_text then
        self:deliver(next_text)
      end
    end)
end

function Session:prompt(text)
  if self.busy or not self.ready then
    self.queue[#self.queue + 1] = text
  else
    self:deliver(text)
  end
end

function Session:cancel()
  if self.busy then
    self.client:notify("session/cancel", { sessionId = self.id })
  end
end

function Session:stop()
  if self.client then
    self.client:stop()
  end
end

function Session:opened(id)
  self.id = id
  self.handlers.on_session(id)
  self.client:request("session/set_mode", { sessionId = id, modeId = adapter.mode }, function(_, err)
    if err then
      self.handlers.on_notice(("could not set %s: %s"):format(adapter.mode, tostring(err.message)))
    end
    self.ready = true
    local first = table.remove(self.queue, 1)
    if first then
      self:deliver(first)
    end
  end)
end

function Session:new_session(cwd)
  self.client:request("session/new", with_instructions({ cwd = cwd, mcpServers = {} }, cwd), function(result, err)
    if err or not (result and result.sessionId) then
      return self.handlers.on_notice("could not open a session: " .. tostring(err and err.message or "no session id"))
    end
    self:opened(result.sessionId)
  end)
end

function Session:open(cwd, id, caps)
  if not (id and caps.loadSession) then
    return self:new_session(cwd)
  end
  self.loading = true
  self.client:request("session/load", with_instructions({ sessionId = id, cwd = cwd, mcpServers = {} }, cwd),
    function(_, err)
      self.loading = false
      if err then
        self.handlers.on_notice(("could not load session %s (%s); starting a new one"):format(id, tostring(err.message)))
        return self:new_session(cwd)
      end
      self:opened(id)
    end)
end

function Session:connect(cwd, id)
  local handlers = self.handlers
  self.client = Client.new(adapter.command(cwd), {
    on_notification = function(method, params)
      if method == "session/update" and type(params.update) == "table" then
        handlers.on_update(params.update, self.loading)
      end
    end,
    on_request = function(method, params, answer)
      if method ~= "session/request_permission" then
        return false
      end
      handlers.on_permission(params, function(option)
        answer({ outcome = option and { outcome = "selected", optionId = option } or { outcome = "cancelled" } })
      end)
      return true
    end,
    on_exit = function(code, signal, stderr)
      self.ready, self.busy = false, false
      handlers.on_notice(("the agent exited (code %s, signal %s)%s"):format(code, signal,
        #stderr > 0 and (": " .. stderr[#stderr]) or ""))
    end,
  })
  local ok, err = pcall(self.client.start, self.client)
  if not ok then
    return handlers.on_notice("could not start the agent: " .. tostring(err))
  end
  self.client:request("initialize", {
    protocolVersion = 1,
    clientInfo = { name = "icarus", version = "1" },
    clientCapabilities = { fs = { readTextFile = false, writeTextFile = false }, terminal = false,
      _meta = { terminal_output = true, terminal_output_delta = true } },
  }, function(init, init_err)
    if init_err or not init then
      return handlers.on_notice("the agent did not initialize: " .. tostring(init_err and init_err.message))
    end
    self:open(cwd, id, init.agentCapabilities or {})
  end)
end

-- A session the code before a hot reload started, given this code's methods.
function M.adopt(session)
  setmetatable(session, Session)
end

-- Starts a chat's session in cwd: id's, loaded, or a new one when id is nil.
---@return icarus.acp.Session
function M.start(cwd, id, handlers)
  local self = setmetatable({ ready = false, busy = false, loading = false, queue = {}, handlers = handlers }, Session)
  adapter.ensure(function(err)
    if err then
      return handlers.on_notice(err)
    end
    self:connect(cwd, id)
  end)
  return self
end

return M
