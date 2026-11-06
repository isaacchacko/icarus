-- Subagents: the agents an agent launches itself (Claude Code's Agent tool, in the background or
-- not). icarus says it takes them (clientCapabilities.subagents), so the adapter announces each one
-- on its parent with a subagent_update (its title, its description, its state) and sends what it
-- does on a session of its own. Each chat keeps its subagents (chat.subagents), each with a log of
-- what it said and the tools it ran; the parent's chat notes when one starts and ends.
--
-- They show in the graph under their agent, and in the agent sidebar as a file beside their
-- agent's (`subagent: <its session>` on its first line), which <CR> opens: the subagent's log,
-- read only, in the window chats show in, q going back to its agent.
local M = {}

local RUNNING = { running = true, pending = true }

---@class icarus.Subagent
---@field id string its session
---@field title? string
---@field description? string
---@field state string
---@field started number
---@field last? string its last tool call's title
---@field log string[]

local function now()
  local sec, usec = vim.uv.gettimeofday()
  return sec + usec / 1e6
end

function M.running(child)
  return RUNNING[child.state] == true
end

function M.label(child)
  return child.title or child.description or "subagent"
end

local function buf_name(id)
  return "icarus://subagent/" .. id
end

local function view_buf(id)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == buf_name(id) then
      return buf
    end
  end
end

-- Puts child's log into its view, if it has one.
local function redraw(child)
  local buf = view_buf(child.id)
  if not buf then
    return
  end
  local lines = { ("↳ %s · %s"):format(M.label(child), child.state), "" }
  if child.description and child.description ~= child.title then
    vim.list_extend(lines, vim.split(child.description, "\n", { plain = true }))
    lines[#lines + 1] = ""
  end
  for _, line in ipairs(child.log) do
    vim.list_extend(lines, vim.split(line, "\n", { plain = true }))
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

-- The agent sidebar's file for child, beside its agent's.
local function sidebar_file(chat, child)
  local tasks = require("icarus.tasks")
  local task = tasks.read(chat.record.task or tasks.SENTINEL)
  if not task or task.sentinel then
    return
  end
  local org = require("icarus.org")
  org.ensure(task)
  local dir = org.dir(task.slug)
  local parent
  for name, kind in vim.fs.dir(dir, { depth = 20 }) do
    if kind == "file" and org.chat_of(dir .. "/" .. name) == chat.record.id then
      parent = dir .. "/" .. name
    end
  end
  if not parent then
    return
  end
  local slug = M.label(child):lower():gsub("[^%w]+", "-"):gsub("^-+", ""):gsub("-+$", ""):sub(1, 32)
  local path = ("%s.%s"):format(parent, slug ~= "" and slug or child.id:sub(1, 8))
  for name, kind in vim.fs.dir(vim.fs.dirname(parent)) do
    local here = vim.fs.dirname(parent) .. "/" .. name
    if kind == "file" and M.of_file(here) == child.id then
      return
    end
  end
  vim.fn.writefile({ "subagent: " .. child.id, "of: " .. chat.record.id }, path)
end

-- The subagent session a sidebar file names, if it's a subagent's.
function M.of_file(path)
  local first = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path, "", 1)[1] or ""
  return first:match("^%s*subagent:%s*(%S+)")
end

-- The open chat whose subagent id is, and the subagent.
function M.find(id)
  for _, chat in pairs(_G.icarus_open_chats or {}) do
    if chat.subagents and chat.subagents[id] then
      return chat, chat.subagents[id]
    end
  end
end

-- A subagent_update on chat's own session: a subagent announced, or its state changed.
function M.announced(chat, update, note)
  chat.subagents = chat.subagents or {}
  local id = update.sessionId
  if type(id) ~= "string" then
    return
  end
  local child = chat.subagents[id]
  local fresh = not child
  child = child or { id = id, state = "running", started = now(), log = {} }
  chat.subagents[id] = child
  child.title = update.title or child.title
  child.description = update.description or child.description
  local was = child.state
  if type(update.state) == "table" and update.state.state then
    child.state = update.state.state
  end
  if fresh then
    note(("↳ subagent: %s"):format(M.label(child)))
    sidebar_file(chat, child)
  elseif was ~= child.state and not M.running(child) then
    note(("↳ subagent %s: %s"):format(M.label(child), child.state))
  end
  redraw(child)
end

-- What a subagent does, on its own session: its messages and its tool calls, into its log.
function M.update(chat, id, update)
  chat.subagents = chat.subagents or {}
  local child = chat.subagents[id] or { id = id, state = "running", started = now(), log = {} }
  chat.subagents[id] = child
  local kind = update.sessionUpdate
  local content = type(update.content) == "table" and update.content or {}
  if kind == "agent_message_chunk" and content.type == "text" then
    if child.streaming then
      child.log[#child.log] = child.log[#child.log] .. (content.text or "")
    else
      child.log[#child.log + 1] = content.text or ""
    end
    child.streaming = true
  elseif kind == "tool_call" and update.title then
    child.streaming = false
    child.last = update.title
    child.log[#child.log + 1] = "• " .. update.title:gsub("\n.*", "")
  elseif kind == "user_message_chunk" and content.type == "text" then
    child.streaming = false
    child.log[#child.log + 1] = "❯ " .. (content.text or "")
  end
  redraw(child)
end

-- Shows the subagent with id's log in the window chats show in; q goes back to its agent.
function M.open(id)
  local chat, child = M.find(id)
  if not child then
    return vim.notify("That subagent's agent isn't open: open the agent first", vim.log.levels.WARN)
  end
  local buf = view_buf(id)
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].filetype = "markdown"
    vim.api.nvim_buf_set_name(buf, buf_name(id))
  end
  vim.keymap.set("n", "q", function()
    require("icarus").open(chat.record)
  end, { buffer = buf, nowait = true, desc = "Back to its agent" })
  redraw(child)
  local win = require("icarus").main()
  require("icarus.acp.chat").hide_composer(win)
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win][0].wrap, vim.wo[win][0].linebreak = true, true
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
end

return M
