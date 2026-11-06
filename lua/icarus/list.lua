-- The list: every open task, the whole screen, grouped by status with each status's glyph, in the order
-- the loop goes (Backlog, Todo, In Progress, Review, Blocked, Done). A task shows its high priority
-- (p) and today (T) flags, whether an agent on it needs you, and how many links it has. f shows only
-- today's tasks. Cancelled tasks are soft deleted, so they aren't listed; the pinned task lives
-- outside the list.
--
-- j and k go between tasks, <CR> opens one, n makes a task, d deletes one (its folder goes to trash),
-- s changes its status, u undoes the last change, and q goes back to the view before. Tab shows the
-- overview on the right: links, status, agents, history.
local tasks = require("icarus.tasks")

local M = {}

local NAME = "icarus://list"
local OVERVIEW = "icarus://overview"
local NS = vim.api.nvim_create_namespace("icarus_list")
local UNDO_MAX = 50

-- In _G, so a hot reload keeps the task picked and the undo history.
_G.icarus_list = _G.icarus_list or { row = 1, undo = {} }
local state = _G.icarus_list

-- The rows as last drawn, so the cursor can move without reading the tasks again.
local cached

local function highlights()
  vim.api.nvim_set_hl(0, "IcarusListHeader", { bold = true, default = true })
  vim.api.nvim_set_hl(0, "IcarusListDone", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "IcarusListSelected", { link = "CursorLine", default = true })
end
highlights()

-- The statuses the list shows, in the loop's order.
local function shown()
  return vim.tbl_filter(function(status)
    return status ~= "cancelled"
  end, tasks.STATUSES)
end

-- The tasks in each status, last opened first.
---@return table<string, icarus.Task[]>
local function by_status()
  local by = {}
  for _, status in ipairs(tasks.STATUSES) do
    by[status] = {}
  end
  for _, task in ipairs(tasks.recent()) do
    if not task.sentinel and not task.pinned and by[task.status] and (task.today or not state.today_only) then
      table.insert(by[task.status], task)
    end
  end
  return by
end

-- The rows: a header for each status, then its tasks.
---@return {header?: string, count?: integer, task?: icarus.Task}[]
local function rows()
  local by = by_status()
  local out = {}
  for _, status in ipairs(shown()) do
    out[#out + 1] = { header = status, count = #by[status] }
    for _, task in ipairs(by[status]) do
      out[#out + 1] = { task = task }
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

-- The task picked: the one the cursor was on, wherever it has moved to, else the row's.
local function picked(all)
  local at = task_rows(all)
  if #at == 0 then
    return nil
  end
  for _, i in ipairs(at) do
    if state.slug and all[i].task.slug == state.slug then
      state.row = vim.fn.index(at, i) + 1
      return all[i].task
    end
  end
  state.row = math.max(1, math.min(#at, state.row))
  return all[at[state.row]].task
end

local function pick(task)
  state.slug = task and task.slug or nil
end

-- Records how to undo a change, so u can take it back.
local function remember(label, undo)
  table.insert(state.undo, { label = label, undo = undo })
  if #state.undo > UNDO_MAX then
    table.remove(state.undo, 1)
  end
end

-- The list's buffer, made once. Its keys and autocmds are set on every call, so a buffer made by an
-- older version of this module (a running icarus, after a hot reload) gets the current ones too.
local function buf()
  local b
  for _, each in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(each) == NAME then
      b = each
    end
  end
  if not b then
    b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].filetype = "icarus_list"
    vim.bo[b].modifiable = false
    vim.api.nvim_buf_set_name(b, NAME)
  end
  vim.api.nvim_clear_autocmds({ buffer = b, event = "CursorMoved" })
  vim.api.nvim_create_autocmd("CursorMoved", { buffer = b, callback = function()
    require("icarus.list").cursor_moved()
  end })
  -- The overview belongs to the list, so it goes when the list does.
  vim.api.nvim_clear_autocmds({ buffer = b, event = "BufWinLeave" })
  vim.api.nvim_create_autocmd("BufWinLeave", { buffer = b, callback = function()
    require("icarus.list").close_overview()
  end })
  -- An agent's state shows on its task, so the list follows it while it shows.
  vim.api.nvim_create_autocmd("User", { pattern = "IcarusChats",
    group = vim.api.nvim_create_augroup("icarus_list", { clear = true }), callback = vim.schedule_wrap(function()
      if #vim.fn.win_findbuf(b) > 0 then
        require("icarus.list").draw()
      end
    end) })
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, function()
      require("icarus.list")[fn]()
    end, { buffer = b, nowait = true, desc = desc })
  end
  map("j", "move_down", "Task below")
  map("k", "move_up", "Task above")
  map("<CR>", "enter", "Open the task")
  map("<Tab>", "overview", "The overview on the right")
  map("n", "new", "New task")
  map("d", "delete", "Delete it (its folder goes to trash)")
  map("p", "toggle_high", "Toggle high priority")
  map("T", "toggle_today", "Toggle today")
  map("f", "toggle_filter", "Show only today's tasks, or all")
  map("s", "status", "Change its status")
  map("u", "undo", "Undo the last change")
  map("q", "back", "Back")
  return b
end

-- Highlights each row: the picked task, and the done ones.
local function paint(b, all, picking)
  vim.api.nvim_buf_clear_namespace(b, NS, 0, -1)
  for i, row in ipairs(all) do
    local group
    if row.header then
      group = "IcarusListHeader"
    elseif row.task == picking then
      group = "IcarusListSelected"
    elseif row.task.status == "merged" then
      group = "IcarusListDone"
    end
    if group then
      vim.api.nvim_buf_set_extmark(b, NS, i - 1, 0, { line_hl_group = group })
    end
  end
end

-- The cursor moved, by any motion (Ctrl-D and Ctrl-U too): the task under it is the one picked, and
-- on a header the task below it. Only the highlight and the overview are drawn again, so the cursor
-- stays where it is.
function M.cursor_moved()
  local all = cached
  if not all then
    return
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local row = all[line]
  if row and row.header then
    for i = line, #all do
      if all[i].task then
        row = all[i]
        break
      end
    end
  end
  if row and row.task then
    pick(row.task)
  end
  paint(buf(), all, picked(all))
  M.draw_overview()
end

-- What a task's row shows after its title.
local function flags(task)
  local chats = require("icarus.chats")
  local needs = vim.iter(chats.on_task(task.slug)):any(function(record)
    return chats.status(record.id) == "needs you"
  end)
  return (task.high and "  !" or "") .. (needs and "  ◆ needs you" or "") .. (task.today and "  today" or "")
    .. (#task.links > 0 and ("  ↗ %d"):format(#task.links) or "")
end

-- Draws the list into its buffer, the picked task highlighted.
function M.draw()
  local b = buf()
  local all = rows()
  local picking = picked(all)
  local lines = {}
  for _, row in ipairs(all) do
    if row.header then
      lines[#lines + 1] = ("%s %s  %d"):format(tasks.GLYPHS[row.header], tasks.LABELS[row.header], row.count)
    else
      lines[#lines + 1] = ("  %s %s%s"):format(tasks.GLYPHS[row.task.status] or "", row.task.title, flags(row.task))
    end
  end
  if #lines == 0 then
    lines[1] = "  no tasks yet: n makes one"
  end
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
  cached = all
  paint(b, all, picking)
  local win = vim.fn.win_findbuf(b)[1]
  for i, row in ipairs(all) do
    if picking and row.task == picking and win then
      pcall(vim.api.nvim_win_set_cursor, win, { i, 2 })
    end
  end
  M.draw_overview()
end

-- <leader>m: the list, the whole screen, in the window the chat shows in.
function M.open()
  local icarus = require("icarus")
  local win = icarus.main()
  require("icarus.explorer").close()
  require("icarus.acp.chat").hide_composer(win)
  vim.api.nvim_win_set_buf(win, buf())
  for option, value in pairs({ number = true, relativenumber = true, signcolumn = "no", wrap = false, cursorline = false }) do
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
  pick(all[at[state.row]] and all[at[state.row]].task)
  M.draw()
end

-- Changes the picked task, then draws the list again.
local function change(fn)
  local task = picked(rows())
  if task then
    fn(task)
    M.draw()
  end
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

-- Deletes through icarus, so the task's agents stop with it. Its folder goes to trash, and u puts it back.
function M.delete()
  local task = picked(rows())
  if not task then
    return
  end
  local answer = vim.fn.confirm(("Delete %s? Its folder goes to trash."):format(task.title), "&Delete\n&Cancel", 2)
  if answer ~= 1 then
    return
  end
  local icarus = require("icarus")
  local trashed = icarus.delete_task(tasks.read(task.slug) or task)
  remember("delete " .. task.title, function()
    assert(vim.uv.fs_rename(trashed, task.dir))
  end)
  -- Deleting the task the chat showing was on goes home; the list stays.
  if (icarus.view() or {}).kind ~= "list" then
    M.open()
  else
    M.draw()
  end
end

function M.toggle_high()
  change(function(task)
    local before = task.high
    tasks.set(task, { high = not before })
    remember(("priority of %s"):format(task.title), function()
      tasks.set(tasks.read(task.slug) or task, { high = before })
    end)
  end)
end

function M.toggle_today()
  change(function(task)
    local before = task.today
    tasks.set(task, { today = not before })
    remember(("today of %s"):format(task.title), function()
      tasks.set(tasks.read(task.slug) or task, { today = before })
    end)
  end)
end

function M.toggle_filter()
  state.today_only = not state.today_only or nil
  M.draw()
end

-- s: picks the task's status from the list's statuses, the one it has marked.
function M.status()
  local task = picked(rows())
  if not task then
    return
  end
  vim.ui.select(shown(), { prompt = "Status of " .. task.title, format_item = function(status)
    return (status == task.status and "● " or "  ") .. tasks.LABELS[status]
  end }, function(to)
    if not to or to == task.status then
      return
    end
    local from = task.status
    tasks.set_status(task, to)
    remember(("status of %s"):format(task.title), function()
      local now = tasks.read(task.slug)
      if now then
        tasks.set_status(now, from)
      end
    end)
    M.draw()
  end)
end

function M.undo()
  local last = table.remove(state.undo)
  if not last then
    return vim.notify("Nothing to undo", vim.log.levels.WARN)
  end
  last.undo()
  vim.notify("Undid: " .. last.label)
  M.draw()
end

-- Tab: the overview of the picked task, on the right. Again to close it.
local function overview_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == OVERVIEW then
      return win
    end
  end
end

-- What the overview says about task: its status and orchestration, its now line, links, agents, and
-- the history of its files in ~/.icarus/edits.
local function overview_lines(task)
  local chats = require("icarus.chats")
  local lines = { "# " .. task.title, "" }
  lines[#lines + 1] = ("status: %s"):format(tasks.LABELS[task.status] or "none")
  lines[#lines + 1] = ("orchestration: %s"):format(task.attrs.orchestration or "router-worker")
  local now = type(task.attrs.now) == "string" and task.attrs.now or ""
  lines[#lines + 1] = "now: " .. (now ~= "" and now or "nothing yet")
  lines[#lines + 1] = ""
  lines[#lines + 1] = "links"
  for _, link in ipairs(task.links) do
    lines[#lines + 1] = "  " .. link
  end
  if #task.links == 0 then
    lines[#lines + 1] = "  none"
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "agents"
  for _, record in ipairs(chats.on_task(task.slug)) do
    lines[#lines + 1] = ("  %s · %s"):format(record.title or "new chat", chats.status(record.id))
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "history"
  local rel = task.dir:gsub("^/", "")
  local log = vim.system({ "git", "-C", vim.fn.expand("~/.icarus/edits"), "log", "--format=%ar  %s", "-10", "--", rel }, { text = true }):wait()
  local history = vim.split(vim.trim(log.stdout or ""), "\n", { plain = true })
  if history[1] == "" then
    history = { "  no edits logged yet" }
  end
  for _, line in ipairs(history) do
    lines[#lines + 1] = "  " .. line
  end
  return lines
end

function M.draw_overview()
  local win = overview_win()
  if not win then
    return
  end
  local task = picked(rows())
  local b = vim.api.nvim_win_get_buf(win)
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, task and overview_lines(tasks.read(task.slug) or task) or { "no task picked" })
  vim.bo[b].modifiable = false
end

function M.close_overview()
  local win = overview_win()
  if win then
    vim.api.nvim_win_close(win, true)
  end
end

function M.overview()
  if overview_win() then
    return M.close_overview()
  end
  -- Closing its window wipes the buffer, so the name is free when it opens again.
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "wipe"
  vim.bo[b].filetype = "markdown"
  vim.bo[b].modifiable = false
  vim.api.nvim_buf_set_name(b, OVERVIEW)
  vim.keymap.set("n", "q", function()
    M.overview()
  end, { buffer = b, nowait = true, desc = "Close the overview" })
  local list = vim.fn.win_findbuf(buf())[1]
  local new = vim.api.nvim_open_win(b, false, { split = "right", win = list or -1, width = 46 })
  vim.wo[new].wrap = true
  vim.wo[new].linebreak = true
  M.draw_overview()
end

function M.back()
  require("icarus").last_view()
end

return M
