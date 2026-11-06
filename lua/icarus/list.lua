-- The list: every open task, the whole screen, grouped by status with each status's glyph, in the order
-- the loop goes (Backlog, Todo, In Progress, Review, Blocked, Done). A task has a high priority flag
-- (p) and a today flag (T). Cancelled tasks are soft deleted, so they aren't listed; the pinned task
-- lives outside the list.
--
-- j and k go between tasks, <CR> opens one, n makes a task, d deletes one (its folder goes to trash),
-- s and S move it on and back a status, u undoes the last change, and q goes back to the view before.
-- G grabs the task under the cursor: then j and k move it within its status, h and l to the status
-- before or after. Tab shows the overview on the right: links, status, agents, history. e asks the
-- task's agent to enrich it.
local tasks = require("icarus.tasks")

local M = {}

local NAME = "icarus://list"
local OVERVIEW = "icarus://overview"
local NS = vim.api.nvim_create_namespace("icarus_list")
local UNDO_MAX = 50

-- In _G, so a hot reload keeps the task picked, the grab and the undo history.
_G.icarus_list = _G.icarus_list or { row = 1, undo = {} }
local state = _G.icarus_list

local function highlights()
  vim.api.nvim_set_hl(0, "IcarusListHeader", { bold = true, default = true })
  vim.api.nvim_set_hl(0, "IcarusListFlag", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "IcarusListDone", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "IcarusListSelected", { link = "CursorLine", default = true })
  vim.api.nvim_set_hl(0, "IcarusListGrab", { link = "DiagnosticInfo", default = true })
end
highlights()

-- The statuses the list shows, in the loop's order.
local function shown()
  return vim.tbl_filter(function(status)
    return status ~= "cancelled"
  end, tasks.STATUSES)
end

-- The tasks in each status, in their order: by position where they have one, else last opened first.
---@return table<string, icarus.Task[]>
local function by_status()
  local by = {}
  for _, status in ipairs(tasks.STATUSES) do
    by[status] = {}
  end
  for _, task in ipairs(tasks.recent()) do
    if not task.sentinel and not task.pinned and by[task.status] then
      table.insert(by[task.status], task)
    end
  end
  for _, list in pairs(by) do
    local rank = {}
    for i, task in ipairs(list) do
      rank[task] = i
    end
    table.sort(list, function(a, b)
      local pa, pb = a.attrs.position, b.attrs.position
      if pa and pb and pa ~= pb then
        return pa < pb
      elseif (pa ~= nil) ~= (pb ~= nil) then
        return pa ~= nil
      end
      return rank[a] < rank[b]
    end)
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
  map("j", "move_down", "Task below, or down while grabbed")
  map("k", "move_up", "Task above, or up while grabbed")
  map("h", "move_left", "Status before, while grabbed")
  map("l", "move_right", "Status after, while grabbed")
  map("G", "grab", "Grab the task, or let it go")
  map("<CR>", "enter", "Open the task")
  map("<Tab>", "overview", "The overview on the right")
  map("e", "enrich", "Ask its agent to enrich the task")
  map("n", "new", "New task")
  map("d", "delete", "Delete it (its folder goes to trash)")
  map("p", "toggle_high", "Toggle high priority")
  map("T", "toggle_today", "Toggle today")
  map("s", "advance", "Move it to the next status")
  map("S", "retreat", "Move it back a status")
  map("u", "undo", "Undo the last change")
  map("q", "back", "Back")
  return b
end

-- Draws the list into its buffer, the picked task highlighted and the grabbed one marked.
function M.draw()
  local b = buf()
  local all = rows()
  local picking = picked(all)
  local grabbed = state.grab
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
        marks[#marks + 1] = { line = #lines - 1, group = task.slug == grabbed and "IcarusListGrab" or "IcarusListSelected" }
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

-- Changes a task's attributes or status, then draws the list again.
local function change(fn)
  local task = picked(rows())
  if task then
    fn(task)
    M.draw()
  end
end

function M.move_down()
  if state.grab then
    return M.reorder(1)
  end
  move(1)
end

function M.move_up()
  if state.grab then
    return M.reorder(-1)
  end
  move(-1)
end

function M.move_left()
  if state.grab then
    M.step_status(-1)
  end
end

function M.move_right()
  if state.grab then
    M.step_status(1)
  end
end

function M.grab()
  local task = picked(rows())
  if not task then
    return
  end
  state.grab = state.grab ~= task.slug and task.slug or nil
  M.draw()
end

-- Swaps the grabbed task with its neighbour in its status: the positions of the whole status are
-- written first, so the order is the one on screen.
function M.reorder(step)
  local task = state.grab and vim.iter(tasks.list()):find(function(each)
    return each.slug == state.grab
  end)
  if not task then
    return
  end
  local list = by_status()[task.status]
  local at = vim.fn.index(list, task) + 1
  local other = list[at + step]
  if not other then
    return
  end
  local before = {}
  for i, each in ipairs(list) do
    before[each.slug] = each.attrs.position
  end
  for i, each in ipairs(list) do
    tasks.set(each, { position = i })
  end
  tasks.set(task, { position = at + step })
  tasks.set(other, { position = at })
  remember("move " .. task.title, function()
    for slug, position in pairs(before) do
      local each = tasks.read(slug)
      if each then
        tasks.set(each, { position = position })
      end
    end
  end)
  pick(task)
  M.draw()
end

-- Moves the task to the status before or after its own, while grabbed.
function M.step_status(step)
  change(function(task)
    local order = shown()
    local at = vim.fn.index(order, task.status) + 1
    local to = order[at + step]
    if to then
      local from = task.status
      tasks.set_status(task, to)
      remember(("move %s to %s"):format(task.title, tasks.LABELS[from]), function()
        local now = tasks.read(task.slug)
        if now then
          tasks.set_status(now, from)
        end
      end)
    end
  end)
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
    local trashed = tasks.delete(task)
    remember("delete " .. task.title, function()
      vim.uv.fs_rename(trashed, task.dir)
    end)
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

function M.advance()
  M.step_status(1)
end

function M.retreat()
  M.step_status(-1)
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
  lines[#lines + 1] = ""
  lines[#lines + 1] = "e enriches it: its agent writes a summary you can accept"
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

function M.overview()
  local win = overview_win()
  if win then
    return vim.api.nvim_win_close(win, true)
  end
  local b = vim.api.nvim_create_buf(false, true)
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

-- e: asks the picked task's agent to enrich it: a summary from its links, tickets and history, which
-- it proposes into task.md for you to accept.
function M.enrich()
  local task = picked(rows())
  if not task then
    return
  end
  local record = require("icarus.chats").on_task(task.slug)[1]
  if not record then
    return vim.notify(task.title .. " has no agent yet: open it and start one", vim.log.levels.WARN)
  end
  local agent = require("icarus.acp.chat").get(record).session
  agent:prompt(table.concat({
    ("Enrich the task %s: write a short summary of it from its links, its linear and PR links, and its history."):format(task.title),
    ("Propose it into %s as a section headed `## Summary (generated)`, so the user can accept or edit it."):format(task.file),
  }, "\n"), nil, ("◉ enrich %s"):format(task.title))
end

function M.back()
  require("icarus").last_view()
end

return M
