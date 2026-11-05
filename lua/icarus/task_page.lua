-- A task's screen: its agent on the left, as icarus shows any chat, and on the right a column of the
-- task's folder (icarus.explorer) over its spec.md, which opens there and only there. The agent is
-- the task's newest chat, or a new one in a new agents/<n> folder (on "(no task)", in icarus's dir).
local chats = require("icarus.chats")
local explorer = require("icarus.explorer")
local tasks = require("icarus.tasks")

local M = {}

local SIDE_WIDTH = 0.5

-- A new chat on task: in a folder of its own under the task, or for the sentinel where icarus runs.
---@param task icarus.Task
---@return icarus.ChatRecord
function M.new_agent(task)
  if task.sentinel then
    return chats.create(vim.fn.getcwd(), task.slug)
  end
  local _, dir = tasks.new_agent(task.slug)
  return chats.create(dir, task.slug)
end

---@param task icarus.Task
---@param record? icarus.ChatRecord the agent to show; the task's newest by default
function M.open(task, record)
  tasks.touch(task.slug)
  record = record or chats.on_task(task.slug)[1] or M.new_agent(task)
  require("icarus").open(record)
  local side = explorer.win()
  if not side then
    side = vim.api.nvim_open_win(0, false, { split = "right", win = -1,
      width = math.floor(vim.o.columns * SIDE_WIDTH) })
  end
  explorer.show(task.dir, side, task.spec)
  local spec = explorer.open_file(task.spec, side)
  vim.wo[spec][0].winbar = (" %s%s"):format(task.title:gsub("%%", "%%%%"), task.status and ("  ·  " .. task.status) or "")
  -- A task's spec still to write is where you start; else the agent's composer, where show left you.
  if not task.sentinel and vim.fn.getfsize(task.spec) <= 0 then
    vim.api.nvim_set_current_win(spec)
    vim.cmd.startinsert()
  end
end

-- Asks for the task's name, makes it and opens it.
function M.new()
  vim.ui.input({ prompt = "New task: " }, function(title)
    title = title and vim.trim(title) or ""
    if title ~= "" then
      M.open(tasks.create(title))
    end
  end)
end

return M
