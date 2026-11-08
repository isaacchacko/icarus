-- One chat's ACP connection, run inside icarus: it starts the adapter (icarus.acp.adapter) in the
-- chat's dir, opens a new session or loads the chat's last one (the adapter replays its history as
-- updates), and sets bypassPermissions, as isovim's agents always ran. One prompt is with the agent
-- at a time; what's sent while it works waits in the queue, and all of it goes as one prompt when the
-- turn ends. The adapter stops with icarus, the chat's session kept for the next load.
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
local images = require("icarus.acp.images")

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

-- What every agent is told, on top of its imports (CLAUDE.md and the rest): who it is on its task, its
-- place there by the task's orchestration (icarus.orchestration), and how to work; not how icarus's
-- tools work, which `ica help` says when it needs them.
local RENAME_EVERY = 10
-- And a task's lead, to keep its task's status saying where the task stands.
local STATUS_EVERY = 8

local WORK = "Get the work done. Decide what's yours to decide; bring what isn't (to your parent, or to the"
  .. " user if you have none) with the evidence and your recommendation. Check your own work before you"
  .. " call it done: run it, test it, look at it. Report short: what changed, what's left, what you need."
  .. " Name yourself in a few words for what you're doing (`ica name <name>`) once you know, and again"
  .. " when it changes: the user tells agents apart by it."
  .. "\n\nLink what you mention (file paths, URLs, icarus://agent/<id>, icarus://task/<slug>); the user"
  .. " opens links with <Tab>. `ica help` lists what icarus gives you when you need it: comments and"
  .. " proposed edits in files the user watches with you, messages to the other agents on your task,"
  .. " forks, visuals. When icarus itself gets in your way, `ica bug <what happened>` and carry on."

local function instructions(record)
  local lines = {}
  local task = record and record.task and require("icarus.tasks").read(record.task)
  if task and not task.sentinel then
    lines[#lines + 1] = ("You're an agent in icarus, on the task %q (icarus://task/%s, its folder %s)."):format(
      task.title, task.slug, task.dir)
  else
    lines[#lines + 1] = "You're an agent in icarus."
  end
  lines[#lines + 1] = require("icarus.orchestration").role(record)
  local coaching = require("icarus.daedalus").coaching()
  return table.concat(lines, " ") .. "\n\n" .. WORK .. (coaching ~= "" and "\n\n" .. coaching or "")
end

local function with_instructions(params, cwd, record)
  local imported = imports.prompt(imports.collect(cwd))
  params._meta = { systemPrompt = { append = instructions(record) .. (imported ~= "" and "\n\n" .. imported or "") } }
  return params
end

-- A queued prompt is {text, images, display}; a string is one queued before images, by code before a
-- hot reload. Its text can change until it's sent.
function Session:deliver(prompt)
  if type(prompt) == "string" then
    prompt = { text = prompt }
  end
  prompt.sent = true
  -- Now and then, a reminder to keep its name saying what it does: once it's had a turn to find out,
  -- then every few turns after it last named itself (icarus.messages, ica name).
  local chat = (_G.icarus_open_chats or {})[self.chat]
  if chat and (chat.turns or 0) >= 1 and (not chat.named_at or chat.turns - chat.named_at >= RENAME_EVERY) then
    chat.named_at = chat.turns
    prompt.display = prompt.display or prompt.text
    prompt.text = prompt.text .. ("\n\n(icarus: you're named %q. If that no longer says what you're doing now,"
      .. " rename yourself in a few words: `ica name <name>`. Otherwise ignore this.)"):format(
      require("icarus.chats").get(self.chat) and require("icarus.chats").get(self.chat).title or "new chat")
  end
  -- What the user changed meanwhile in the files it watches (icarus.watch), on this turn.
  local edits = self.chat and require("icarus.watch").catch_up(self.chat)
  if edits then
    prompt.display = prompt.display or prompt.text
    prompt.text = prompt.text .. "\n\n" .. edits
  end
  local record = require("icarus.chats").get(self.chat)
  local task = chat and record and require("icarus.orchestration").leads(record) and require("icarus.tasks").read(record.task)
  if task and not task.sentinel and (chat.turns or 0) >= 2
    and (not chat.status_at or chat.turns - chat.status_at >= STATUS_EVERY) then
    chat.status_at = chat.turns
    prompt.display = prompt.display or prompt.text
    prompt.text = prompt.text .. ("\n\n(icarus: your task is at %s%s. If that's not where it stands now,"
      .. " update it: `ica status [<status>] <where it stands, in a line>`. Otherwise ignore this.)"):format(
      task.status, type(task.attrs.now) == "string" and (', "' .. task.attrs.now .. '"') or "")
  end
  self.busy = true
  self.handlers.on_prompt(prompt.display or prompt.text)
  self.handlers.on_turn("start")
  local function send()
    self.client:request("session/prompt",
      { sessionId = self.id, prompt = images.blocks(prompt.text, prompt.images, self.takes_images ~= false) },
      function(result, err)
        -- The adapter forgets a session whose Claude process died and answers every later prompt
        -- "Resource not found": load it back, once, and send again.
        if err and err.message == "Resource not found" and not prompt.reloaded then
          prompt.reloaded = true
          return self:reload(send, function()
            self.busy = false
            self.handlers.on_turn("end", { error = err.message })
          end)
        end
        self.busy = false
        self.handlers.on_turn("end", { stopReason = result and result.stopReason, error = err and err.message })
        local batch = self:take_queue()
        if batch then
          self:deliver(batch)
        end
      end)
  end
  send()
end

-- Loads this session back into the adapter, its history replayed as loading.
function Session:reload(on_loaded, on_failed)
  local record = self.chat and require("icarus.chats").get(self.chat)
  local cwd = self.cwd or (record and record.cwd)
  self.loading = true
  self.client:request("session/load", with_instructions({ sessionId = self.id, cwd = cwd, mcpServers = {} }, cwd, record),
    function(_, err)
      self.loading = false
      if err then
        self.handlers.on_notice(("could not reload session %s (%s)"):format(self.id, tostring(err.message)))
        return on_failed()
      end
      on_loaded()
    end)
end

-- Everything queued, taken out as one prompt: one turn for what piled up, not a turn each. Their texts
-- go in the order they queued, each image chip renumbered after the images before it; each part is
-- marked sent, as its text can change until it is (icarus.watch).
---@return table? prompt
function Session:take_queue()
  local parts = self.queue
  if #parts == 0 then
    return nil
  end
  self.queue = {}
  for i, part in ipairs(parts) do
    if type(part) == "string" then
      parts[i] = { text = part }
    end
  end
  if #parts == 1 then
    return parts[1]
  end
  local texts, shown, attached = {}, {}, {}
  for _, part in ipairs(parts) do
    local offset = #attached
    vim.list_extend(attached, part.images or {})
    texts[#texts + 1] = (part.text:gsub("%[Image #(%d+)%]", function(n)
      return part.images and part.images[tonumber(n)] and images.chip(tonumber(n) + offset) or nil
    end))
    shown[#shown + 1] = part.display or texts[#texts]
    part.sent = true
  end
  return { text = table.concat(texts, "\n\n---\n\n"), images = #attached > 0 and attached or nil,
    display = table.concat(shown, "\n") }
end

---@param attached? icarus.acp.Image[]
---@param display? string what the chat shows for it, if not its text
---@return table prompt
function Session:prompt(text, attached, display)
  local prompt = { text = text, images = attached, display = display }
  if self.busy or not self.ready then
    self.queue[#self.queue + 1] = prompt
  else
    self:deliver(prompt)
  end
  return prompt
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

-- The adapter's config option with this id (model, effort), if the session has it.
function Session:option(id)
  for _, option in ipairs(self.options or {}) do
    if option.id == id then
      return option
    end
  end
end

-- What the session runs at, as the status line shows it: "Opus 5.5 · Medium"; nil before it's opened.
function Session:running_at()
  local parts = {}
  for _, id in ipairs({ "model", "effort" }) do
    local option = self:option(id)
    for _, each in ipairs(option and option.options or {}) do
      if each.value == option.currentValue then
        parts[#parts + 1] = ((each.name or each.value):gsub("%s*%b()", ""))
      end
    end
  end
  return #parts > 0 and table.concat(parts, " · ") or nil
end

-- Sets one config option; done(ok) once the adapter answers with its options, which replace the old.
function Session:configure(configId, value, done)
  self.client:request("session/set_config_option", { sessionId = self.id, configId = configId, value = value }, function(result, err)
    if err then
      self.handlers.on_notice(("could not set %s to %s: %s"):format(configId, tostring(value), tostring(err.message)))
    elseif result and result.configOptions then
      self.options = result.configOptions
      vim.cmd.redrawstatus({ bang = true })
    end
    if done then
      done(err == nil)
    end
  end)
end

-- The model, then the effort, this chat was set to: effort is for the model, so it goes second.
function Session:apply_saved(done)
  local record = self.chat and require("icarus.chats").get(self.chat) or {}
  local pending = vim.tbl_filter(function(id)
    return record[id] ~= nil
  end, { "model", "effort" })
  local function step(i)
    local configId = pending[i]
    if not configId then
      return done()
    end
    self:configure(configId, record[configId], function()
      step(i + 1)
    end)
  end
  step(1)
end

function Session:opened(id, options)
  self.id = id
  self.options = options or self.options
  self.handlers.on_session(id)
  vim.cmd.redrawstatus({ bang = true })
  self.client:request("session/set_mode", { sessionId = id, modeId = adapter.mode }, function(_, err)
    if err then
      self.handlers.on_notice(("could not set %s: %s"):format(adapter.mode, tostring(err.message)))
    end
    self:apply_saved(function()
      self.ready = true
      local batch = self:take_queue()
      if batch then
        self:deliver(batch)
      end
    end)
  end)
end

function Session:new_session(cwd)
  self.client:request("session/new", with_instructions({ cwd = cwd, mcpServers = {} }, cwd, self.chat and require("icarus.chats").get(self.chat)), function(result, err)
    if err or not (result and result.sessionId) then
      return self.handlers.on_notice("could not open a session: " .. tostring(err and err.message or "no session id"))
    end
    self:opened(result.sessionId, result.configOptions)
  end)
end

function Session:open(cwd, id, caps)
  self.takes_images = (caps.promptCapabilities or {}).image == true
  if not (id and caps.loadSession) then
    return self:new_session(cwd)
  end
  self.loading = true
  self.client:request("session/load", with_instructions({ sessionId = id, cwd = cwd, mcpServers = {} }, cwd, self.chat and require("icarus.chats").get(self.chat)),
    function(result, err)
      self.loading = false
      if err then
        self.handlers.on_notice(("could not load session %s (%s); starting a new one"):format(id, tostring(err.message)))
        return self:new_session(cwd)
      end
      self:opened(id, result and result.configOptions)
    end)
end

function Session:connect(cwd, id)
  self.cwd = cwd
  local handlers = self.handlers
  self.client = Client.new(adapter.command(cwd, self.chat), {
    on_notification = function(method, params)
      if method == "session/update" and type(params.update) == "table" then
        -- A subagent's own session: not this chat's conversation (icarus.subagents).
        if self.id and params.sessionId and params.sessionId ~= self.id then
          if handlers.on_subagent then
            handlers.on_subagent(params.sessionId, params.update)
          end
          return
        end
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
    -- subagents: the adapter announces the ones an agent launches, and sends what they do on their
    -- own sessions (icarus.subagents).
    clientCapabilities = { fs = { readTextFile = false, writeTextFile = false }, terminal = false, subagents = vim.empty_dict(),
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
---@param chat? string the chat's id, for ica bug
---@return icarus.acp.Session
function M.start(cwd, id, handlers, chat)
  local self = setmetatable({ ready = false, busy = false, loading = false, queue = {}, handlers = handlers,
    chat = chat }, Session)
  adapter.ensure(function(err)
    if err then
      return handlers.on_notice(err)
    end
    self:connect(cwd, id)
  end)
  return self
end

return M
