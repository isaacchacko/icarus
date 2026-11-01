-- The JSON-RPC side of an ACP connection: request ids and their callbacks, sorting what arrives
-- into requests, notifications and responses, answering an unknown request with -32601 (the agent
-- waits on every id it sends), answering each request exactly once, and failing every pending
-- callback when the agent goes away. What ACP methods mean is the supervisor's (isovim.acp.host).
--
-- Vendored from agentic.nvim (the JSON-RPC half of lua/agentic/acp/acp_client.lua at f0bef08), MIT:
--   Copyright (c) 2025 Carlos Gomes
--   Permission is hereby granted, free of charge, to any person obtaining a copy of this software
--   and associated documentation files (the "Software"), to deal in the Software without
--   restriction, subject to the conditions in LICENSE.agentic beside this file: the above copyright
--   notice and this permission notice shall be included in all copies or substantial portions of
--   the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
-- isovim's changes: its own log, isovim's code style, one handler for notifications and one for
-- requests instead of per-session subscribers (a supervisor holds one session), and no UI types.
local log = require("isovim.acp.log")
local transport_module = require("isovim.acp.transport")

-- JSON-RPC "Method not found", which the spec requires for a request naming an unknown method.
local METHOD_NOT_FOUND = -32601
local TRANSPORT_ERROR = -32000

---@class isovim.acp.Handlers
---@field on_notification fun(method: string, params: table)
---@field on_request? fun(method: string, params: table, answer: fun(result?: table, err?: {code: integer, message: string})): boolean
---  true when it took the request (and will answer it); false leaves it to -32601
---@field on_state? fun(state: string)
---@field on_exit? fun(code: integer, signal: integer, stderr: string[])

local Client = {}
Client.__index = Client

---@param config isovim.acp.TransportConfig
---@param handlers isovim.acp.Handlers
function Client.new(config, handlers)
  local client = setmetatable({ id_counter = 0, callbacks = {}, state = "disconnected", handlers = handlers }, Client)
  client.transport = transport_module.create_stdio_transport(config, {
    on_state_change = function(state)
      client:_set_state(state)
    end,
    -- From a libuv callback: everything after framing runs on the main loop, in order.
    on_message = function(message)
      vim.schedule(function()
        client:_handle_message(message)
      end)
    end,
    on_exit = function(code, signal, stderr)
      if handlers.on_exit then
        vim.schedule(function()
          handlers.on_exit(code, signal, stderr)
        end)
      end
    end,
  })
  return client
end

function Client:start()
  self.transport:start()
end

function Client:stop()
  self.transport:stop()
end

function Client:_set_state(state)
  self.state = state
  if state == "disconnected" or state == "error" then
    local pending = self.callbacks
    self.callbacks = {}
    for _, callback in pairs(pending) do
      vim.schedule(function()
        pcall(callback, nil, { code = TRANSPORT_ERROR, message = state })
      end)
    end
  end
  if self.handlers.on_state then
    vim.schedule(function()
      self.handlers.on_state(state)
    end)
  end
end

---@param callback fun(result: table?, err: table?)
function Client:request(method, params, callback)
  self.id_counter = self.id_counter + 1
  local id = self.id_counter
  self.callbacks[id] = callback
  local message = { jsonrpc = "2.0", id = id, method = method, params = params or vim.empty_dict() }
  log.debug("request:", method, id)
  if not self.transport:send(vim.json.encode(message)) then
    self.callbacks[id] = nil
    vim.schedule(function()
      callback(nil, { code = TRANSPORT_ERROR, message = "not connected" })
    end)
  end
end

function Client:notify(method, params)
  log.debug("notification:", method)
  self.transport:send(vim.json.encode({ jsonrpc = "2.0", method = method, params = params or vim.empty_dict() }))
end

function Client:_result(id, result)
  self.transport:send(vim.json.encode({ jsonrpc = "2.0", id = id, result = result == nil and vim.NIL or result }))
end

function Client:_error(id, code, message)
  self.transport:send(vim.json.encode({ jsonrpc = "2.0", id = id, error = { code = code, message = message } }))
end

function Client:_handle_message(message)
  if message.method and message.result == nil and message.error == nil then
    if message.id ~= nil then
      self:_handle_request(message.id, message.method, message.params or {})
    else
      local ok, err = pcall(self.handlers.on_notification, message.method, message.params or {})
      if not ok then
        log.warn("notification handler failed:", message.method, err)
      end
    end
  elseif message.id ~= nil then
    local callback = self.callbacks[message.id]
    if callback then
      self.callbacks[message.id] = nil
      callback(message.result, message.error)
    else
      log.warn("no callback for response id " .. tostring(message.id))
    end
  else
    log.warn("unknown message type:", message)
  end
end

-- A request is owed exactly one answer, even when its handler throws.
function Client:_handle_request(id, method, params)
  local answered = false
  local function answer(result, err)
    if answered then
      return
    end
    answered = true
    if err then
      self:_error(id, err.code, err.message)
    else
      self:_result(id, result)
    end
  end
  local ok, taken = true, false
  if self.handlers.on_request then
    ok, taken = pcall(self.handlers.on_request, method, params, answer)
  end
  if not ok then
    log.warn("request handler failed:", method, taken)
    answer(nil, { code = -32603, message = "Internal error" })
  elseif not taken then
    -- "_"-prefixed methods are vendor extensions; either way an unknown request gets -32601.
    if type(method) == "string" and method:sub(1, 1) ~= "_" then
      log.warn("unknown request method: " .. tostring(method))
    end
    answer(nil, { code = METHOD_NOT_FOUND, message = "Method not found" })
  end
end

return Client
