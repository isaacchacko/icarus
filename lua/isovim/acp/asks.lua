-- What an ACP agent asks you, as question surfaces in its repo's Inbox (isovim.surfaces), answered
-- there (the Inbox's picker, <leader>in, iso answer) and sent back to the agent by its supervisor
-- (isovim.acp.host), which this runs in.
--
--   AskUserQuestion: claude-agent-acp asks it as a form elicitation (elicitation/create, which it
--     sends only to a client that offers forms): a field question_<n> per question (a oneOf enum,
--     or an array of an anyOf enum for a multi-select), with a free-text question_<n>_custom beside
--     it. Each question is a surface with its options, other text allowed; the elicitation is
--     answered once all of them are, accepting {question_<n> = label(s), question_<n>_custom =
--     text}. Any other form field is a question too: an enum's options, a boolean's yes/no, free text
--     for a string or a number. A url elicitation can't be shown and is declined.
--   A permission request (session/request_permission, which bypassPermissions mode still lets
--     through for some tools): a surface with Allow and Deny, answered with the request's
--     allow_once (else allow_always) or reject_once (else reject_always) option.
-- Surfaces are named <agent>-ask-<id>-<n> and <agent>-perm-<id>. One still waiting when the turn
-- ends (a cancel) is taken down, and the request answered cancelled; a supervisor that starts again
-- takes down any its last run left (the adapter that asked is gone).
local surfaces = require("isovim.surfaces")
local store = require("isovim.store")

local M = {}

---@class isovim.acp.Ask
---@field kind "elicitation"|"permission"
---@field names string[] its surfaces' names
---@field fields table[] elicitation: {key, kind, custom?} per surface
---@field answer fun(result?: table, err?: table)
---@field params table
---@field tool? string permission: what it asks to run

---@class isovim.acp.Asks
---@field ws string
---@field agent string
---@field repo string the surface key its questions go to
---@field journal fun(kind: string, fields: table)
---@field pending table<string, isovim.acp.Ask>
---@field timer? uv.uv_timer_t

local function short(text)
  return vim.fn.sha256(tostring(text) .. vim.uv.hrtime()):sub(1, 8)
end

local function remove(asks, name)
  local file = surfaces.dir(asks.repo) .. "/" .. name .. ".surface"
  if vim.uv.fs_stat(file) then
    os.remove(file)
    return true
  end
end

-- The surfaces a run of this agent's supervisor left behind.
local function sweep(asks)
  local dir = surfaces.dir(asks.repo)
  local removed = false
  for name, type in vim.fs.dir(dir) do
    local stem = type == "file" and name:match("^(.+)%.surface$")
    if stem and (vim.startswith(stem, asks.agent .. "-ask-") or vim.startswith(stem, asks.agent .. "-perm-")) then
      removed = remove(asks, stem) or removed
    end
  end
  if removed then
    surfaces.scan(asks.repo)
  end
end

---@return isovim.acp.Asks
function M.new(ws, agent, journal_fn)
  local asks = { ws = ws, agent = agent, repo = surfaces.key(ws) or "general", journal = journal_fn, pending = {} }
  pcall(sweep, asks)
  return asks
end

local function name_of(asks)
  local spec = store.agent(asks.ws, asks.agent) or {}
  return spec.name and spec.name ~= asks.agent and ("%s (%s)"):format(spec.name, asks.agent) or asks.agent
end

local check

local function watch(asks)
  if asks.timer then
    return
  end
  asks.timer = vim.uv.new_timer()
  asks.timer:start(300, 300, vim.schedule_wrap(function()
    check(asks)
  end))
end

local function unwatch(asks)
  if asks.timer and next(asks.pending) == nil then
    asks.timer:stop()
    asks.timer:close()
    asks.timer = nil
  end
end

-- Puts one question in the Inbox; nil and why when it couldn't.
local function ask_one(asks, spec, name)
  local entry, how = surfaces.ask(asks.repo, spec, name)
  if not entry then
    return nil, how
  end
  return entry
end

local function take_down(asks, ask)
  local removed = false
  for _, name in ipairs(ask.names) do
    removed = remove(asks, name) or removed
  end
  if removed then
    surfaces.scan(asks.repo)
  end
end

-- elicitations

local function enum_options(list)
  local options = {}
  for _, option in ipairs(type(list) == "table" and list or {}) do
    if type(option) == "table" and option.const ~= nil then
      options[#options + 1] = { label = tostring(option.title or option.const), description = option.description,
        value = option.const }
    elseif type(option) ~= "table" then
      options[#options + 1] = { label = tostring(option), value = option }
    end
  end
  return options
end

-- The form's fields as questions: {key, kind, custom?, spec} in the schema's order (question_0
-- before question_1), a _custom field folded into its question as other text.
local function questions_of(params)
  local schema = type(params.requestedSchema) == "table" and params.requestedSchema or {}
  local properties = type(schema.properties) == "table" and schema.properties or {}
  local keys = vim.tbl_keys(properties)
  table.sort(keys, function(a, b)
    local na, nb = tonumber(a:match("^question_(%d+)$")), tonumber(b:match("^question_(%d+)$"))
    if na and nb then
      return na < nb
    end
    return a < b
  end)
  local single = #vim.tbl_filter(function(key)
    return not key:match("_custom$")
  end, keys) == 1
  local fields = {}
  for _, key in ipairs(keys) do
    local prop = properties[key]
    if type(prop) == "table" and not (key:match("_custom$") and properties[key:gsub("_custom$", "")]) then
      local custom = properties[key .. "_custom"] and key .. "_custom" or nil
      local text = prop.description or (single and params.message) or prop.title or key
      if prop.title and prop.description and prop.title ~= prop.description then
        text = ("%s: %s"):format(prop.title, prop.description)
      elseif single and params.message and prop.title and params.message ~= prop.title then
        text = ("%s: %s"):format(prop.title, params.message)
      end
      local field = { key = key, custom = custom, question = text }
      if prop.type == "array" then
        local items = type(prop.items) == "table" and prop.items or {}
        field.kind, field.options = "multi", enum_options(items.anyOf or items.oneOf or items.enum)
      elseif prop.oneOf or prop.enum then
        field.kind, field.options = "one", enum_options(prop.oneOf or prop.enum)
      elseif prop.type == "boolean" then
        field.kind, field.options = "boolean", { { label = "Yes", value = true }, { label = "No", value = false } }
      else
        field.kind, field.options = (prop.type == "number" or prop.type == "integer") and "number" or "text", {}
      end
      fields[#fields + 1] = field
    end
  end
  return fields
end

-- The form's content from the answers, one per field.
local function content_of(fields, answers)
  local content = {}
  for i, field in ipairs(fields) do
    local answer = answers[i] or {}
    local by_label = {}
    for _, option in ipairs(field.options) do
      by_label[option.label] = option.value
    end
    local values = vim.tbl_map(function(label)
      return by_label[label] == nil and label or by_label[label]
    end, answer.labels or {})
    local other = answer.other ~= "" and answer.other or nil
    if field.kind == "multi" then
      content[field.key] = values
      if other then
        if field.custom then
          content[field.custom] = other
        else
          table.insert(values, other)
        end
      end
    elseif field.kind == "one" or field.kind == "boolean" then
      if values[1] ~= nil then
        content[field.key] = values[1]
      end
      if other then
        if field.custom then
          content[field.custom] = other
        elseif values[1] == nil then
          content[field.key] = other
        end
      end
    elseif field.kind == "number" then
      content[field.key] = tonumber(other or "")
    else
      content[field.key] = other
    end
  end
  return content
end

---@param asks isovim.acp.Asks
function M.elicit(asks, params, answer)
  if params.mode == "url" then
    asks.journal("notice", { text = ("the agent asked you to open %s; isovim can't show that, so it was declined")
      :format(tostring(params.url)) })
    return answer({ action = "decline" })
  end
  local fields = questions_of(params)
  if #fields == 0 then
    return answer({ action = "accept", content = vim.empty_dict() })
  end
  local id = short(params.toolCallId or params.message)
  local ask = { kind = "elicitation", names = {}, fields = fields, answer = answer, params = params }
  local journaled = {}
  for i, field in ipairs(fields) do
    local name = ("%s-ask-%s-%d"):format(asks.agent, id, i - 1)
    local spec = {
      question = ("%s asks: %s"):format(name_of(asks), field.question),
      options = vim.tbl_map(function(option)
        return { label = option.label, description = option.description }
      end, field.options),
      multi = field.kind == "multi",
      other = field.custom ~= nil or field.kind == "text" or field.kind == "number" or #field.options == 0,
    }
    local entry, err = ask_one(asks, spec, name)
    if not entry then
      take_down(asks, ask)
      asks.journal("notice", { text = "could not put the agent's question in the Inbox: " .. tostring(err) })
      return answer({ action = "cancel" })
    end
    ask.names[#ask.names + 1] = name
    journaled[#journaled + 1] = { question = field.question, options = spec.options, multi = spec.multi, name = name }
  end
  asks.pending[id] = ask
  asks.journal("question", { state = "asked", id = id, repo = asks.repo, toolCallId = params.toolCallId,
    message = params.message, questions = journaled })
  watch(asks)
end

-- permissions

local function option_of(params, kinds)
  for _, kind in ipairs(kinds) do
    for _, option in ipairs(params.options or {}) do
      if option.kind == kind then
        return option.optionId
      end
    end
  end
end

---@param asks isovim.acp.Asks
function M.permission(asks, params, answer)
  local call = params.toolCall or {}
  local tool = call.title or (call.rawInput and vim.inspect(call.rawInput)) or call.toolCallId or "a tool"
  local id = short(call.toolCallId or tool)
  local name = ("%s-perm-%s"):format(asks.agent, id)
  local entry, err = ask_one(asks, {
    question = ("%s asks to run: %s"):format(name_of(asks), tool),
    options = { { label = "Allow", description = "this once" }, { label = "Deny" } },
  }, name)
  if not entry then
    asks.journal("permission", { tool = tool, toolCallId = call.toolCallId, decision = "denied",
      reason = "could not ask in the Inbox: " .. tostring(err) })
    local reject = option_of(params, { "reject_once", "reject_always" })
    return answer({ outcome = reject and { outcome = "selected", optionId = reject } or { outcome = "cancelled" } })
  end
  asks.pending[id] = { kind = "permission", names = { name }, answer = answer, params = params, tool = tool }
  asks.journal("permission", { tool = tool, toolCallId = call.toolCallId, decision = "asked", repo = asks.repo,
    name = name })
  watch(asks)
end

-- Answers what's been answered in the Inbox; a question removed unanswered cancels its ask.
check = function(asks)
  for id, ask in pairs(asks.pending) do
    local answers, gone, done = {}, false, true
    for i, name in ipairs(ask.names) do
      local entry = surfaces.get(asks.repo, name)
      if not entry or entry.type ~= "question" then
        gone = true
      elseif entry.answer then
        answers[i] = entry.answer
      else
        done = false
      end
    end
    if gone or done then
      asks.pending[id] = nil
      for _, name in ipairs(ask.names) do
        surfaces.collect(asks.repo, name)
      end
      take_down(asks, ask)
      local by = answers[1] and answers[1].by or nil
      if ask.kind == "permission" then
        local allow = not gone and answers[1] and answers[1].labels[1] == "Allow"
        local option = allow and option_of(ask.params, { "allow_once", "allow_always" })
          or (not gone and option_of(ask.params, { "reject_once", "reject_always" }))
        ask.answer({ outcome = option and { outcome = "selected", optionId = option } or { outcome = "cancelled" } })
        local call = ask.params.toolCall or {}
        asks.journal("permission", { tool = ask.tool, toolCallId = call.toolCallId,
          decision = gone and "cancelled" or (allow and "allowed" or "denied"), by = by,
          reason = gone and "its question was removed" or nil })
      elseif gone then
        ask.answer({ action = "cancel" })
        asks.journal("question", { state = "cancelled", id = id, reason = "its question was removed" })
      else
        ask.answer({ action = "accept", content = content_of(ask.fields, answers) })
        asks.journal("question", { state = "answered", id = id, by = by, answers = vim.tbl_map(surfaces.answer_text, answers) })
      end
    end
  end
  unwatch(asks)
end

-- Everything still waiting is taken down and answered cancelled (the turn ended, the session went).
---@param asks isovim.acp.Asks
function M.cancel_all(asks, reason)
  for id, ask in pairs(asks.pending) do
    asks.pending[id] = nil
    take_down(asks, ask)
    if ask.kind == "permission" then
      ask.answer({ outcome = { outcome = "cancelled" } })
      local call = ask.params.toolCall or {}
      asks.journal("permission", { tool = ask.tool, toolCallId = call.toolCallId, decision = "cancelled", reason = reason })
    else
      ask.answer({ action = "cancel" })
      asks.journal("question", { state = "cancelled", id = id, reason = reason })
    end
  end
  unwatch(asks)
end

function M.waiting(asks)
  return next(asks.pending) ~= nil
end

return M
