-- The list: every open task, the whole screen, grouped by status with each status's glyph, in the order
-- the loop goes (Backlog, Todo, In Progress, Review, Blocked, Done). A task has a high priority flag
-- (p) and a today flag (T). Cancelled tasks are soft deleted, so they aren't listed; the pinned task
-- lives outside the list.
--
-- j and k go between tasks, <CR> opens one, n makes a task, d deletes one (its folder goes to trash),
-- s and S move it on and back a status, and q goes back to the view before.
local tasks = require("icarus.tasks")

local M = {}

local NAME = "icarus://list"
local NS = vim.api.nvim_create_namespace("icarus_list")

-- In _G, so a hot reload keeps the row picked.
_G.icarus_list = _G.icarus_list or { row = 1 }
local state = _G.icarus_list

local function highlights()
  vim.api.nvim_set_hl(0, "IcarusListHeader", { bold = true, default = true })
  vim.api.nvim_set_hl(0, "IcarusListFlag", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "IcarusListDone", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "IcarusListSelected", { link = "CursorLine", default = true })
end
highlights()

-- The rows: a header for each status, then its tasks, last opened first.
---@return {header?: string, task?: icarus.Task}[]
local function rows()
  local by = {}
  for _, status in ipairs(tasks.STATUSES) do
    by[status] = {}
  end
  for _, task in ipairs(tasks.recent()) do
    if not task.sentinel and not task.pinned and by[task.status] then
      table.insert(by[task.status], task)
    end
  end
  local out = {}
  for _, status in ipairs(tasks.STATUSES) do
    if status ~= "cancelled" then
      out[#out + 1] = { header = status, count = #by[status] }
      for _, task in ipairs(by[status]) do
        out[#out + 1] = { task = task }
      end
    end
  end
  return out
end

-- The row numbers that are tasks, the ones the cursor can be on.
local function task_rows(all)
  local at = {}
  for i, row in ipairs(all) do
    if row.task then
      at[#at + 1] = i
    end
  end
  return at
end

-- The task picked, keeping to the ones there are.
local function picked(all)
  local at = task_rows(all)
  if #at == 0 then
    return nil
  end
  state.row = math.max(1, math.min(#at, state.row))
  return all[at[state.row]].task
end

local function buf()
  local b
  for _, each in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(each) == NAME then
      b = each
    end
  end
  if b then
    return b
  end
  b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "icarus_list"
  vim.bo[b].modifiable = false
  vim.api.nvim_buf_set_name(b, NAME)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, function()
      require("icarus.list")[fn]()
    end, { buffer = b, nowait = true, desc = desc })
  end
  map("j", "move_down", "Task below")
  map("k", "move_up", "Task above")
  map("<CR>", "enter", "Open the task")
  map("n", "new", "New task")
  map("d", "delete", "Delete it (its folder goes to trash)")
  map("p", "toggle_high", "Toggle high priority")
  map("T", "toggle_today", "Toggle today")
  map("s", "advance", "Move it to the next status")
  map("S", "retreat", "Move it back a status")
  map("q", "back", "Back")
  return b
end

-- Draws the list into its buffer, the picked task highlighted.
function M.draw()
  local b = buf()
  local all = rows()
  local picking = picked(all)
  local lines, marks = {}, {}
  for _, row in ipairs(all) do
    if row.header then
      local glyph = tasks.GLYPHS[row.header]
      lines[#lines + 1] = ("%s %s  %d"):format(glyph, tasks.LABELS[row.header], row.count)
      marks[#marks + 1] = { line = #lines - 1, group = "IcarusListHeader" }
    else
      local task = row.task
      local glyph = tasks.GLYPHS[task.status] or ""
      local flags = (task.high and "  !" or "") .. (task.today and "  today" or "")
      lines[#lines + 1] = ("  %s %s%s"):format(glyph, task.title, flags)
      if task.status == "merged" then
        marks[#marks + 1] = { line = #lines - 1, group = "IcarusListDone" }
      end
      if task == picking then
        marks[#marks + 1] = { line = #lines - 1, group = "IcarusListSelected", whole = true }
      end
    end
  end
  if #lines == 0 then
    lines[1] = "  no tasks yet: n makes one"
  end
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
  vim.api.nvim_buf_clear_namespace(b, NS, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(b, NS, mark.line, 0, { line_hl_group = mark.group })
  end
  local win = vim.fn.win_findbuf(b)[1]
  for i, row in ipairs(all) do
    if picking and row.task == picking and win then
      pcall(vim.api.nvim_win_set_cursor, win, { i, 2 })
    end
  end
end

-- <leader>m: the list, the whole screen, in the window the chat shows in.
function M.open()
  local icarus = require("icarus")
  local win = icarus.main()
  require("icarus.explorer").close()
  require("icarus.acp.chat").hide_composer(win)
  vim.api.nvim_win_set_buf(win, buf())
  for option, value in pairs({ number = false, relativenumber = false, signcolumn = "no", wrap = false, cursorline = false }) do
    vim.wo[win][0][option] = value
  end
  vim.api.nvim_set_current_win(win)
  vim.cmd.stopinsert()
  icarus.set_view({ kind = "list" })
  M.draw()
end

local function move(step)
  local all = rows()
  local at = task_rows(all)
  state.row = math.max(1, math.min(#at, state.row + step))
  M.draw()
end

function M.move_down()
  move(1)
end

function M.move_up()
  move(-1)
end

function M.enter()
  local task = picked(rows())
  if task then
    require("icarus").open_task(tasks.read(task.slug) or task)
  end
end

function M.new()
  require("icarus").new_task()
end

function M.delete()
  local task = picked(rows())
  if not task then
    return
  end
  local answer = vim.fn.confirm(("Delete %s? Its folder goes to trash."):format(task.title), "&Delete\n&Cancel", 2)
  if answer == 1 then
    tasks.delete(task)
    M.draw()
  end
end

-- Changes a task's attributes, then draws the list again.
local function change(fn)
  local task = picked(rows())
  if task then
    fn(task)
    M.draw()
  end
end

function M.toggle_high()
  change(function(task)
    tasks.set(task, { high = not task.high })
  end)
end

function M.toggle_today()
  change(function(task)
    tasks.set(task, { today = not task.today })
  end)
end

-- Moves a task to the status next to its own in the loop; cancelled is left out, it's soft deleted.
local function step_status(step)
  change(function(task)
    local order = vim.tbl_filter(function(status)
      return status ~= "cancelled"
    end, tasks.STATUSES)
    local at = vim.fn.index(order, task.status) + 1
    local to = order[math.max(1, math.min(#order, at + step))]
    if to then
      tasks.set_status(task, to)
    end
  end)
end

function M.advance()
  step_status(1)
end

function M.retreat()
  step_status(-1)
end

function M.back()
  require("icarus").last_view()
end

return M
