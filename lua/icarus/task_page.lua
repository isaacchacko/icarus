-- A task's screen: one buffer at a time in main, its outline (icarus.outline) beside it to reach the
-- rest: a file, an agent's chat, or a visual. Opening a task shows the buffer you left there, task.md
-- at first. The agent you're on is the last you opened, or the task's newest, or a new one in a new
-- agents/<n> folder (on "(no task)", in icarus's dir); it isn't started until it's shown or used.
local chats = require("icarus.chats")
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
  -- Its file in the agent tree, before it starts.
  require("icarus.org").ensure(task)
  return record
end

-- How you left a task's screen, kept in its .file: what main shows ("file", "chat" or "visual"), the
-- file and its cursor, the agent and the visual it last showed.
---@return {shows?: string, path?: string, cursor?: integer[], chat?: string, visual?: integer}
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

-- The file main shows, and where its cursor is, kept; a file reached by :edit or gf is a view too.
local function remember()
  local icarus = require("icarus")
  local view = icarus.view()
  if M.opening or not (view and view.kind == "task" and view.file) then
    return
  end
  local main = icarus.main()
  local buf = vim.api.nvim_win_get_buf(main)
  local path = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype == "" and path ~= "" then
    M.keep(view.task, { shows = "file", path = path, cursor = vim.api.nvim_win_get_cursor(main) })
    if path ~= view.file then
      icarus.set_view({ kind = "task", task = view.task, file = path })
    end
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

-- main shows path, unless it already does: :edit on it would reload it, and refuse over unsaved edits.
local function show_file(main, path)
  vim.wo[main].winbar = ""
  if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(main)) ~= vim.fs.normalize(path) then
    vim.api.nvim_win_call(main, function()
      vim.cmd.edit(vim.fn.fnameescape(path))
    end)
  end
  escape_to_list(vim.api.nvim_win_get_buf(main))
end

-- What main shows next on task: a {chat = id}, a {visual = i}, or a {file = path, line?, cursor?}.
---@param task icarus.Task
---@param what {chat?: string, visual?: integer, file?: string, line?: integer, cursor?: integer[]}
function M.show(task, what)
  local icarus = require("icarus")
  local main = icarus.main()
  remember()
  M.opening = true
  local view = { kind = "task", task = task.slug }
  if what.chat then
    local record = chats.get(what.chat)
    icarus.open(record)
    local chat = require("icarus.acp.chat").get(record)
    for _, buf in ipairs({ chat.buf, require("icarus.acp.thread").buf(chat) }) do
      escape_to_list(buf)
    end
    view.chat = record.id
    M.keep(task.slug, { shows = "chat", chat = record.id })
  else
    require("icarus.acp.chat").leave(main)
    vim.api.nvim_set_current_win(main)
    if what.visual then
      local i = require("icarus.visual").show(task.slug, what.visual)
      escape_to_list(vim.api.nvim_win_get_buf(main))
      view.visual = i
      M.keep(task.slug, { shows = "visual", visual = i })
    else
      show_file(main, what.file)
      view.file = what.file
      M.keep(task.slug, { shows = "file", path = what.file })
      local at = what.line and { what.line, 0 } or what.cursor
      if at then
        pcall(vim.api.nvim_win_set_cursor, main, at)
      end
    end
  end
  M.opening = false
  icarus.set_view(view)
  require("icarus.outline").show()
  vim.cmd.stopinsert()
end

-- What arriving on task shows: the buffer you left.
local function arrival(task)
  local left = kept(task.slug)
  if left.shows == "chat" and left.chat and chats.get(left.chat) then
    return { chat = left.chat }
  end
  if left.shows == "visual" and require("icarus.visual").list(task.slug)[left.visual] then
    return { visual = left.visual }
  end
  if type(left.path) == "string" and vim.fn.filereadable(left.path) == 1 then
    return { file = left.path, cursor = left.cursor }
  end
  if task.sentinel then
    return { chat = chats.on_task(task.slug)[1].id }
  end
  -- A task with nothing written under its header is where you start, at its end.
  local written = vim.iter(tasks.body(task)):any(function(line)
    return vim.trim(line) ~= ""
  end)
  return { file = task.file, line = not written and #vim.fn.readfile(task.file) or nil }
end

-- The columns round main, for task: its agent the one you're on.
function M.enter(task, record)
  tasks.touch(task.slug)
  local left = kept(task.slug)
  record = record or (left.chat and chats.get(left.chat)) or chats.on_task(task.slug)[1] or M.new_agent(task)
  require("icarus").on_agent(record)
end

---@param task icarus.Task
---@param record? icarus.ChatRecord the agent to show; else the buffer you left
function M.open(task, record)
  M.enter(task, record)
  M.show(task, record and { chat = record.id } or arrival(task))
end

-- The header edited by hand goes into task.json (redrawn if it lost what it can't).
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
