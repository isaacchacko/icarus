-- A task's screen: its agent on the left, as icarus shows any chat, and on the right a column of the
-- task's folder (icarus.explorer, <leader>l) beside the file you last had open there, task.md at first. The agent is
-- the task's newest chat, or a new one in a new agents/<n> folder (on "(no task)", in icarus's dir).
local chats = require("icarus.chats")
local explorer = require("icarus.explorer")
local tasks = require("icarus.tasks")

local M = {}

-- A new chat on task: in a folder of its own under the task, or for the sentinel where icarus runs.
---@param task icarus.Task
---@return icarus.ChatRecord
function M.new_agent(task)
  if task.sentinel then
    return chats.create(vim.fn.getcwd(), task.slug)
  end
  local _, dir = tasks.new_agent(task.slug)
  local record = chats.create(dir, task.slug)
  -- Its file in the agent sidebar, before it starts.
  require("icarus.org").ensure(task)
  return record
end

-- How you left a task's screen, kept in its .file: the file the right column shows and its cursor,
-- as you move around, and whether the explorer is open, as <leader>l changes it. Opening the task
-- again shows it that way.
---@return {path?: string, cursor?: integer[], explorer?: boolean}
local function kept(slug)
  local file = tasks.dir(slug) .. "/.file"
  local ok, value = pcall(vim.json.decode, vim.fn.filereadable(file) == 1 and table.concat(vim.fn.readfile(file), "") or "")
  return ok and type(value) == "table" and value or {}
end

-- Changes what's kept for the task with slug.
function M.keep(slug, fields)
  if vim.fn.isdirectory(tasks.dir(slug)) == 1 then
    vim.fn.writefile({ vim.json.encode(vim.tbl_extend("force", kept(slug), fields)) }, tasks.dir(slug) .. "/.file")
  end
end

local function remember()
  local view = require("icarus").view()
  local side = explorer.win()
  -- Not while a task opens: its file shows before its cursor is put back.
  if M.opening or not (view and view.kind == "task" and side and vim.api.nvim_get_current_win() == side) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(side)
  local path = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype == "" and path ~= "" then
    M.keep(view.task, { path = path, cursor = vim.api.nvim_win_get_cursor(side) })
  end
end

vim.api.nvim_create_autocmd({ "BufEnter", "WinLeave", "VimLeavePre" }, {
  group = vim.api.nvim_create_augroup("icarus_task_page_file", { clear = true }),
  callback = function()
    require("icarus.task_page").remember()
  end,
})
M.remember = remember

-- Escape in normal mode on a task's screen goes to the list, and Escape there comes back. It's bound
-- on the task's own buffers, so nothing else there takes the key.
local function escape_to_list(buf)
  vim.keymap.set("n", "<Esc>", function()
    require("icarus.list").open()
  end, { buffer = buf, nowait = true, desc = "To the list" })
end

---@param task icarus.Task
---@param record? icarus.ChatRecord the agent to show; the task's newest by default
function M.open(task, record)
  tasks.touch(task.slug)
  record = record or chats.on_task(task.slug)[1] or M.new_agent(task)
  require("icarus").open(record)
  local chat = require("icarus.acp.chat").get(record)
  for _, buf in ipairs({ chat.buf, require("icarus.acp.thread").buf(chat), chat.input }) do
    escape_to_list(buf)
  end
  require("icarus").set_view({ kind = "task", task = task.slug, chat = record.id })
  local left = kept(task.slug)
  local path = type(left.path) == "string" and vim.fn.filereadable(left.path) == 1 and left.path or task.file
  local cursor = path == left.path and left.cursor
  M.opening = true
  local ok, file = pcall(explorer.open_file, path)
  M.opening = false
  file = assert(ok and file, file)
  escape_to_list(vim.api.nvim_win_get_buf(file))
  if left.explorer == false then
    explorer.hide()
  else
    explorer.show(task.dir, path)
  end
  if cursor then
    pcall(vim.api.nvim_win_set_cursor, file, cursor)
  end
  if path ~= task.file then
    vim.cmd.stopinsert()
    return
  end
  -- A task with nothing written under its header is where you start, at its end; else the agent's
  -- composer, where show left you. Either way in normal mode: switching tasks isn't typing.
  local written = vim.iter(tasks.body(task)):any(function(line)
    return vim.trim(line) ~= ""
  end)
  if not task.sentinel and not written then
    vim.api.nvim_set_current_win(file)
    vim.api.nvim_win_set_cursor(file, { vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(file)), 0 })
  end
  vim.cmd.stopinsert()
end

-- The header edited by hand goes into task.json (redrawn if it lost what it can't); the header
-- window over it (icarus.head) shows it.
vim.api.nvim_create_autocmd("BufWritePost", {
  group = vim.api.nvim_create_augroup("icarus_task_page", { clear = true }),
  pattern = "*/tasks/*/task.md",
  callback = function(ev)
    tasks.read(vim.fs.basename(vim.fs.dirname(ev.match)))
  end,
})

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
