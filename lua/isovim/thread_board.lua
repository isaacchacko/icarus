-- A project's board, as Linear's: one view, one buffer drawn in four columns, no splits. Cards are tasks
-- (isovim.board_tasks), which only the user makes or changes, each with its threads under it as rows and
-- a view of its own (isovim.task_view), whose keys work on a card too. A thread is on one task at most, and there are no subthreads: a thread made from a thread on a
-- task lands on the same task, as a sibling.
--
-- Motion is the user's: a card's column changes only when they move it with H or L. No post, state
-- change or agent moves one, so a task whose threads have all resolved stays put, and says so. L into Done
-- resolves its open threads, prompting nobody; H out opens again the ones that move resolved, and no
-- others. On the Backburner its threads leave the Inbox and stop nagging, but for a question waiting,
-- as its asker is blocked (isovim.surfaces). As columns say nothing of state, marks do, in any column:
-- unread, the user's turn, a question, an agent working, resolved; a card rolls its threads' up.
--
-- A thread on no task, as all are at first, as one a router opens by itself or an issue's: open, a slim row
-- under a No task group at the top of Working, which H and L don't move. C on one makes a task of its title
-- and A attaches it to a task. Resolved, it isn't on the board.
--
-- Narrow, the columns shrink to MIN_WIDTH, then the board shows as many as fit, moving as the focus
-- does, so its layout never wraps. Column heads are the window's winbar, so they stay as it scrolls.
local surfaces = require("isovim.surfaces")
local threads = require("isovim.threads")
local tasks = require("isovim.board_tasks")
local boxes = require("isovim.boxes")

local M = {}

M.COLUMNS = {
  { key = "backburner", name = "Backburner", glyph = "\u{f1978}", hl = "Comment" }, -- md-dots_circle
  { key = "working", name = "Working", glyph = "\u{f0aa1}", hl = "DiagnosticWarn" }, -- md-circle_slice_4
  { key = "checking", name = "Checking", glyph = "\u{f0208}", hl = "DiagnosticInfo" }, -- md-eye
  { key = "done", name = "Done", glyph = "\u{f05e0}", hl = "DiagnosticOk" }, -- md-check_circle
}

local INDEX = {}
for i, column in ipairs(M.COLUMNS) do
  INDEX[column.key] = i
end

-- Priority as Linear has it: 0 none, 1 urgent, 2 high, 3 medium, 4 low.
local BADGES = {
  { " ! ", "IsovimBoardUrgent", "urgent" },
  { "▂▄▆", "DiagnosticWarn", "high" },
  { "▂▄ ", "DiagnosticInfo", "medium" },
  { "▂  ", "Comment", "low" },
}

M.BADGES = BADGES

local MIN_WIDTH, GAP = 28, 1

local function highlights()
  boxes.highlights()
  local function bg(name)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    return ok and hl.bg or nil
  end
  -- Not bold: a bold face may have no box-drawing glyphs, and this is a card's border.
  vim.api.nvim_set_hl(0, "IsovimBoardFocus", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "IsovimBoardFocusRow", { default = true, link = "Visual" })
  vim.api.nvim_set_hl(0, "IsovimBoardUrgent", { default = true, fg = "#000000", bg = "#E8833A", bold = true })
  vim.api.nvim_set_hl(0, "IsovimBoardKey", { default = true, bg = bg("CursorLine"), bold = true })
end

local function rank(task)
  return (task.priority or 0) > 0 and task.priority or 5
end

local function number_of(id)
  return tonumber(id:sub(2)) or 0
end

-- What needs the user, whatever column it's in.
local function needs_them(entry)
  return entry.needs_you or (entry.pending or 0) > 0
end

local function unread_of(entry)
  return entry.new_reply or entry.parked_unread or entry.marked_unread or (entry.resolved and entry.needs_you)
end

-- The board's rows by column, in order: a task {task, threads, done, folded}, a thread {entry, task?}, or
-- the No task group {group, count}. query keeps what has it in its id or title, a task's threads with it.
function M.columns(repo, query, folded)
  local all_tasks = tasks.read(repo)
  local rows = surfaces.thread_rows(repo)
  local on_task, taskless = {}, {}
  for _, entry in pairs(rows) do
    if entry.task then
      on_task[entry.task] = on_task[entry.task] or {}
      table.insert(on_task[entry.task], entry)
    elseif not entry.resolved then
      taskless[#taskless + 1] = entry
    end
  end
  query = query and query ~= "" and query:lower() or nil
  local function has(id, title, extra)
    if not query then
      return true
    end
    for _, text in ipairs({ id, title or "", extra or "" }) do
      if text:lower():find(query, 1, true) then
        return true
      end
    end
    return false
  end
  -- A task's search covers its labels and assignee too.
  local function traits(task)
    return table.concat(task.labels, " ") .. " " .. (task.assignee and ((tasks.assignee_name(task.assignee) or "") .. " " .. task.assignee) or "")
  end
  local columns = {}
  for i in ipairs(M.COLUMNS) do
    columns[i] = {}
  end
  -- Priority first, then most recent.
  local ordered = vim.tbl_values(all_tasks)
  for _, task in ipairs(ordered) do
    for _, entry in ipairs(on_task[task.id] or {}) do
      task.last_at = math.max(task.last_at or 0, entry.last_at or 0)
    end
  end
  table.sort(ordered, function(a, b)
    if rank(a) ~= rank(b) then
      return rank(a) < rank(b)
    elseif (a.last_at or 0) ~= (b.last_at or 0) then
      return (a.last_at or 0) > (b.last_at or 0)
    end
    return number_of(a.id) > number_of(b.id)
  end)
  local function by_recent(a, b)
    if (a.last_at or 0) ~= (b.last_at or 0) then
      return (a.last_at or 0) > (b.last_at or 0)
    end
    return number_of(a.name) > number_of(b.name)
  end
  table.sort(taskless, by_recent)
  local shown_taskless = vim.tbl_filter(function(entry)
    return has(entry.name, entry.title)
  end, taskless)
  if #shown_taskless > 0 then
    local list = columns[INDEX.working]
    list[#list + 1] = { group = true, count = #shown_taskless }
    for _, entry in ipairs(shown_taskless) do
      list[#list + 1] = { entry = entry, key = entry.name }
    end
  end
  for _, task in ipairs(ordered) do
    local own = on_task[task.id] or {}
    -- Open first, each in the order it was made, so a task's threads read as they went.
    table.sort(own, function(a, b)
      if (a.resolved or false) ~= (b.resolved or false) then
        return not a.resolved
      end
      return number_of(a.name) < number_of(b.name)
    end)
    local whole = has(task.id, task.title, traits(task))
    local kept = vim.tbl_filter(function(entry)
      return whole or has(entry.name, entry.title)
    end, own)
    if whole or #kept > 0 then
      local done = 0
      for _, entry in ipairs(own) do
        done = done + (entry.resolved and 1 or 0)
      end
      local list = columns[INDEX[task.column] or INDEX.working]
      local is_folded = folded and folded[task.id] and not query
      list[#list + 1] = { task = task, threads = own, done = done, folded = is_folded, key = task.id }
      for _, entry in ipairs(is_folded and {} or kept) do
        list[#list + 1] = { entry = entry, on = task, key = entry.name }
      end
    end
  end
  return columns
end

-- A thread's marks, at a glance: unread, the user's turn, a question, an agent working, resolved.
local function marks_of(entry)
  local parts = {}
  if unread_of(entry) then
    parts[#parts + 1] = boxes.seg("●", "DiagnosticWarn")
  end
  if (entry.pending or 0) > 0 then
    parts[#parts + 1] = boxes.seg("?", "DiagnosticWarn")
  elseif entry.waiting_on == "user" then
    parts[#parts + 1] = boxes.seg("\u{f0a4}", "DiagnosticWarn") -- fa-hand_o_right: over to you
  end
  if entry.working then
    parts[#parts + 1] = boxes.seg(require("isovim.status").icon("working"), "DiagnosticInfo")
  end
  if entry.resolved then
    parts[#parts + 1] = boxes.seg("✓", "DiagnosticOk")
  end
  return parts
end

M.thread_marks = marks_of

local function joined(parts)
  local out = boxes.seg("")
  for _, part in ipairs(parts) do
    out = boxes.cat(out, boxes.seg(" "), part)
  end
  return out
end

-- A card's marks: its threads', once each.
local function rolled_up(row)
  local parts, seen = {}, {}
  for _, entry in ipairs(row.threads) do
    for _, part in ipairs(marks_of(entry)) do
      -- Resolved is said under the title, in numbers.
      if part.text ~= "✓" and not seen[part.text] then
        seen[part.text] = true
        parts[#parts + 1] = part
      end
    end
  end
  return parts
end

local function badge(task)
  local b = BADGES[task.priority or 0]
  return b and boxes.seg(b[1], b[2]) or nil
end

-- What's under a card's progress: assignee, due date, estimate, how many PRs and tickets.
local function card_meta(task)
  local parts = {}
  if task.assignee then
    parts[#parts + 1] = boxes.seg("@" .. (tasks.assignee_name(task.assignee) or "?"), "Comment")
  end
  if task.due then
    local overdue = task.due < os.date("%Y-%m-%d") and task.column ~= "done"
    parts[#parts + 1] = boxes.seg("\u{f073} " .. task.due:sub(6), overdue and "DiagnosticError" or "Comment")
  end
  if task.estimate then
    parts[#parts + 1] = boxes.seg("◆" .. task.estimate, "Comment")
  end
  local counts = { pr = 0, linear = 0 }
  for _, link in ipairs(task.links) do
    counts[link.type] = (counts[link.type] or 0) + 1
  end
  if counts.pr > 0 then
    parts[#parts + 1] = boxes.seg("\u{f407} " .. counts.pr, "Comment")
  end
  if counts.linear > 0 then
    parts[#parts + 1] = boxes.seg("\u{f0ac} " .. counts.linear, "Comment")
  end
  local out = boxes.seg("")
  for i, part in ipairs(parts) do
    out = boxes.cat(out, i > 1 and boxes.seg("  ") or boxes.seg(""), part)
  end
  return #parts > 0 and out or nil
end

-- A task's card: lines width cells wide.
local function card(row, column, width, focused, labels)
  local task = row.task
  local any_need = vim.iter(row.threads):any(needs_them)
  local border = focused and "IsovimBoardFocus" or any_need and "DiagnosticWarn" or "IsovimPrBorder"
  local inner = width - 4
  local head = boxes.cat(boxes.seg(column.glyph, column.hl), boxes.seg(" "), boxes.seg(task.id, "IsovimPrDim"), joined(rolled_up(row)))
  local tag = badge(task)
  if tag then
    head = boxes.cat(boxes.fit(head, inner - 3), tag)
  end
  local lines = { boxes.seg("╭" .. ("─"):rep(width - 2) .. "╮", border), boxes.side(width, head, border) }
  local pieces = require("isovim.acp.look").wrap(task.title, inner)
  for i, piece in ipairs(pieces) do
    if i > 3 then
      break
    end
    local text = task.title:sub(piece[1] + 1, piece[2])
    if i == 3 and #pieces > 3 then
      text = vim.fn.strcharpart(text, 0, math.max(0, vim.fn.strchars(text) - 1)) .. "…"
    end
    lines[#lines + 1] = boxes.side(width, boxes.seg(text, focused and "Bold" or nil), border)
  end
  local total = #row.threads
  local under
  if total == 0 then
    under = boxes.seg("no threads: n starts one", "Comment")
  elseif row.done == total then
    under = boxes.seg(("✓ all %d resolved"):format(total), "DiagnosticOk")
  else
    under = boxes.seg(("%d/%d done"):format(row.done, total), "Comment")
  end
  if row.folded and total > 0 then
    under = boxes.cat(under, boxes.seg("  ▸ folded: z", "Comment"))
  end
  lines[#lines + 1] = boxes.side(width, boxes.fit(under, inner), border)
  local extra = card_meta(task)
  if extra then
    lines[#lines + 1] = boxes.side(width, boxes.fit(extra, inner), border)
  end
  if #task.labels > 0 then
    local line = boxes.seg("")
    for i, name in ipairs(task.labels) do
      line = boxes.cat(line, i > 1 and boxes.seg(" ") or boxes.seg(""), boxes.seg("● ", require("isovim.task_view").label_hl(labels, name)), boxes.seg(name, "Comment"))
    end
    lines[#lines + 1] = boxes.side(width, boxes.fit(line, inner), border)
  end
  lines[#lines + 1] = boxes.seg("╰" .. ("─"):rep(width - 2) .. "╯", border)
  return lines
end

-- A thread's slim row: dim unless it needs the user, which reads in any column.
local function slim(row, width, focused)
  local entry = row.entry
  local glyph = entry.last_glyph and boxes.cat(boxes.seg(entry.last_glyph[1], entry.last_glyph[2]), boxes.seg(" ")) or boxes.seg("")
  local line = boxes.cat(boxes.seg(row.on and "  " or " ", "NonText"), boxes.seg(entry.name .. " ", "Comment"), glyph,
    boxes.seg(entry.title or "", needs_them(entry) and "Normal" or "Comment"))
  local tail = joined(marks_of(entry))
  if entry.bypass_name then
    tail = boxes.cat(tail, boxes.seg(" → " .. entry.bypass_name, "Comment"))
  elseif entry.waiting_on and entry.waiting_on ~= "user" then
    tail = boxes.cat(tail, boxes.seg(" ⧗ " .. (entry.waiting_name or entry.waiting_on), "Comment"))
  end
  local out = boxes.cat(boxes.fit(line, width - boxes.cells(tail)), tail)
  if focused then
    out.marks[#out.marks + 1] = { 0, #out.text, "IsovimBoardFocusRow" }
  end
  return { out }
end

local function hints(view, width)
  local line = boxes.cat(boxes.seg("\u{f0db} ", "Special"), boxes.seg("Board", "Title"), boxes.seg("  "))
  if view.board_searching or (view.board_query or "") ~= "" then
    line = boxes.cat(line, boxes.seg("/", "IsovimBoardKey"), boxes.seg(" " .. (view.board_query or "") .. (view.board_searching and "▏" or "") .. "  "))
  end
  for _, hint in ipairs({ { "hjkl", "move" }, { "H L", "status" }, { "0-4", "priority" }, { "C", "task" }, { "n", "thread" }, { "⏎", "open" }, { "/", "search" }, { "?", "keys" } }) do
    local piece = boxes.cat(boxes.seg(" " .. hint[1] .. " ", "IsovimBoardKey"), boxes.seg(" " .. hint[2] .. "  ", "Comment"))
    if boxes.cells(line) + boxes.cells(piece) > width then
      break
    end
    line = boxes.cat(line, piece)
  end
  return line
end

-- How many columns fit in width, how wide each is, and which show: the focused one always.
local function fit_columns(view, width)
  local count = math.max(1, math.min(#M.COLUMNS, math.floor((width + GAP) / (MIN_WIDTH + GAP))))
  local each = math.max(10, math.floor((width - (count - 1) * GAP) / count))
  local first = view.board_first or 1
  local at = view.board_col or 2
  if at < first then
    first = at
  elseif at > first + count - 1 then
    first = at - count + 1
  end
  first = math.max(1, math.min(first, #M.COLUMNS - count + 1))
  view.board_first = first
  return first, count, each
end

-- The rows the focus can be on, in a column: all but a group's heading.
local function focusable(list)
  return vim.tbl_filter(function(row)
    return not row.group
  end, list or {})
end

-- Where the focus is, in what's listed: its row if that's still there, else what's nearest it.
local function settle_focus(view, columns)
  for i, list in ipairs(columns) do
    for j, row in ipairs(focusable(list)) do
      if row.key == view.board_focus then
        view.board_col, view.board_index = i, j
        return
      end
    end
  end
  local col = view.board_col or 2
  local list = focusable(columns[col])
  if #list == 0 and not view.board_focus then
    for i, each in ipairs(columns) do
      if #focusable(each) > 0 then
        col, list = i, focusable(each)
        break
      end
    end
  end
  local index = math.max(1, math.min(view.board_index or 1, #list))
  view.board_col, view.board_index = col, index
  view.board_focus = list[index] and list[index].key or nil
end

-- The board's lines and highlights for width, and where its focus is. Pure but for the view's focus.
function M.layout(view, width)
  highlights()
  view.board_columns = view.board_columns or M.columns(view.repo, view.board_query, view.board_folded)
  local columns = view.board_columns
  local _, labels = tasks.read(view.repo)
  settle_focus(view, columns)
  local first, count, each = fit_columns(view, width)
  local cells, firsts = {}, {}
  for c = first, first + count - 1 do
    local out = {}
    firsts[c] = {}
    for _, row in ipairs(columns[c]) do
      local focused = row.key ~= nil and row.key == view.board_focus
      local from = #out + 1
      local lines
      if row.group then
        lines = { boxes.fit(boxes.cat(boxes.seg("No task", "Comment"), boxes.seg("  " .. row.count, "Comment")), each) }
      elseif row.task then
        lines = card(row, M.COLUMNS[c], each, focused, labels)
      else
        lines = slim(row, each, focused)
      end
      for _, line in ipairs(lines) do
        out[#out + 1] = line
      end
      if row.key then
        firsts[c][row.key] = { from = from, to = #out }
      end
    end
    cells[c] = out
  end
  local lines, marks = { hints(view, width), boxes.seg("") }, {}
  local height = 0
  for c = first, first + count - 1 do
    height = math.max(height, #cells[c])
  end
  local focus_at
  local top = #lines
  for r = 1, height do
    local line = boxes.seg("")
    for c = first, first + count - 1 do
      if c > first then
        line = boxes.cat(line, boxes.seg((" "):rep(GAP)))
      end
      local where = c == view.board_col and view.board_focus and firsts[c][view.board_focus]
      if where and where.from == r then
        focus_at = { top + r, #line.text, top + where.to }
      end
      line = boxes.cat(line, cells[c][r] or boxes.seg((" "):rep(each)))
    end
    lines[#lines + 1] = line
  end
  local texts = {}
  for i, line in ipairs(lines) do
    texts[i] = line.text
    for _, mark in ipairs(line.marks) do
      if mark[3] then
        marks[#marks + 1] = { i - 1, mark[1], mark[2], mark[3] }
      end
    end
  end
  return texts, marks, focus_at, { first = first, count = count, each = each }
end

-- The column heads, as a winbar: they stay as the board scrolls, lined up with the columns. A column
-- counts its tasks.
local function winbar(view, fit, columns)
  local parts = {}
  for c = fit.first, fit.first + fit.count - 1 do
    local column = M.COLUMNS[c]
    local n = #vim.tbl_filter(function(row)
      return row.task ~= nil
    end, columns[c])
    local left = c == fit.first and fit.first > 1 and "‹ " or ""
    local right = c == fit.first + fit.count - 1 and c < #M.COLUMNS and " ›" or ""
    local shown = left .. column.glyph .. (" %s %d"):format(column.name, n) .. right
    local pad = math.max(0, fit.each - vim.fn.strdisplaywidth(shown))
    local on = c == view.board_col and "Title" or "Comment"
    parts[#parts + 1] = ("%%#%s#%s%%#%s#%s%s"):format(column.hl, left .. column.glyph, on, (" %s %d%s"):format(column.name, n, right), (" "):rep(pad))
  end
  return table.concat(parts, (" "):rep(GAP)) .. "%#Normal#"
end

-- Draws the board in the view's buffer, the cursor on its focus.
function M.draw(view)
  local sv = require("isovim.surface_view")
  local win = vim.fn.bufwinid(view.buf)
  local width = win ~= -1 and vim.api.nvim_win_get_width(win) or 120
  view.width = win ~= -1 and width or view.width
  local lines, marks, focus_at, fit = M.layout(view, width)
  view.board_drawn = vim.json.encode({ lines, marks, width })
  sv.set_lines(view.buf, lines, marks)
  if win ~= -1 then
    vim.wo[win][0].winbar = winbar(view, fit, view.board_columns)
    if focus_at then
      -- The whole of its card in sight, its first line under the cursor.
      pcall(vim.api.nvim_win_set_cursor, win, { focus_at[3], 0 })
      pcall(vim.api.nvim_win_set_cursor, win, { focus_at[1], focus_at[2] })
    end
  end
end

-- Threads or tasks changed under it: read them again, and draw if it reads differently.
function M.refresh(view)
  view.board_columns = nil
  local win = vim.fn.bufwinid(view.buf)
  local width = win ~= -1 and vim.api.nvim_win_get_width(win) or view.width or 120
  local lines, marks = M.layout(view, width)
  if vim.json.encode({ lines, marks, width }) ~= view.board_drawn then
    M.draw(view)
  end
end

local function focused(view)
  for _, row in ipairs(focusable((view.board_columns or {})[view.board_col or 0])) do
    if row.key == view.board_focus then
      return row
    end
  end
end

-- The task the focus is on or under.
local function focused_task(view)
  local row = focused(view)
  return row and (row.task or row.on), row
end

local function changed(view)
  surfaces.scan(view.repo)
  surfaces.recheck()
  view.board_columns = nil
  M.draw(view)
end

local function toast(text)
  vim.notify("isovim: " .. text, vim.log.levels.INFO)
end

-- H and L: the task a column left or right, the only thing that moves one. L into Done resolves its open
-- threads, prompting nobody; H out opens again the ones that move resolved, and no others.
local function move_status(view, direction)
  local task = focused_task(view)
  if not task then
    return toast("a thread on no task isn't moved: C makes it a task, a attaches it to one")
  end
  local to = M.COLUMNS[INDEX[task.column] + direction]
  if not to then
    return toast(direction > 0 and "it's done: H opens it again" or "it's on the backburner already")
  end
  tasks.move(view.repo, task.id, to.key)
  changed(view)
end

local function set_priority(view, value)
  local task = focused_task(view)
  if not task then
    return toast("priority is a task's: this thread is on none")
  end
  tasks.set_priority(view.repo, task.id, value)
  changed(view)
end

local function move_focus(view, column_step, row_step)
  local columns = view.board_columns or {}
  if column_step ~= 0 then
    local to = (view.board_col or 2) + column_step
    if not columns[to] then
      return
    end
    local list = focusable(columns[to])
    local index = math.max(1, math.min(view.board_index or 1, #list))
    view.board_col, view.board_index = to, index
    view.board_focus = list[index] and list[index].key or nil
  else
    local list = focusable(columns[view.board_col or 0])
    local index = (view.board_index or 1) + row_step
    if list[index] then
      view.board_index, view.board_focus = index, list[index].key
    end
  end
  M.draw(view)
end

local function jump(view, last)
  local list = focusable((view.board_columns or {})[view.board_col or 0])
  local index = last and #list or 1
  if list[index] then
    view.board_index, view.board_focus = index, list[index].key
    M.draw(view)
  end
end

-- /: the cards filtered as it's typed. <CR> keeps it, <Esc> clears it.
local function search(view)
  view.board_searching = true
  view.board_query = view.board_query or ""
  local function redraw()
    view.board_columns = nil
    M.draw(view)
    vim.cmd.redraw()
  end
  redraw()
  while true do
    local ok, key = pcall(vim.fn.getcharstr)
    if not ok or key == vim.keycode("<Esc>") or key == vim.keycode("<C-c>") then
      view.board_query = ""
      break
    elseif key == vim.keycode("<CR>") then
      break
    elseif key == vim.keycode("<BS>") or key == "\127" or key == vim.keycode("<C-h>") then
      view.board_query = vim.fn.strcharpart(view.board_query, 0, math.max(0, vim.fn.strchars(view.board_query) - 1))
    elseif key:byte(1) ~= 128 and vim.fn.strdisplaywidth(key) > 0 then
      view.board_query = view.board_query .. key
    end
    redraw()
  end
  view.board_searching = nil
  redraw()
end

-- C: a new task; on a thread with none, a task made of its title, with it attached.
local function create(view)
  local row = focused(view)
  if row and row.entry and not row.on then
    local id = tasks.new(view.repo, row.entry.title)
    if id then
      threads.set_task(view.repo, row.entry.name, id, "user")
      view.board_focus = id
      changed(view)
    end
    return
  end
  vim.ui.input({ prompt = "New task: " }, function(title)
    local id = title and tasks.new(view.repo, title)
    if id then
      view.board_focus = id
      changed(view)
    end
  end)
end

-- A: the thread on a task, picked.
local function attach(view)
  local row = focused(view)
  if not (row and row.entry) then
    return toast("A attaches a thread to a task: go to a thread's row")
  end
  local choices = vim.tbl_filter(function(task)
    return not (row.on and row.on.id == task.id)
  end, vim.tbl_values(tasks.read(view.repo)))
  table.sort(choices, function(x, y)
    return number_of(x.id) > number_of(y.id)
  end)
  if #choices == 0 then
    return toast("there's no task to attach it to: C makes one of it")
  end
  vim.ui.select(choices, {
    prompt = ("Attach %s to:"):format(row.entry.name),
    format_item = function(task)
      return ("%s  %s"):format(task.id, task.title)
    end,
  }, function(task)
    if task then
      threads.set_task(view.repo, row.entry.name, task.id, "user")
      changed(view)
    end
  end)
end

-- The board's keys, for the help (`?` in the sidebar, and here).
M.help_keys = {
  { "h j k l", "the column to the left or right, the row below or above" },
  { "H / L", "move the task a column left / right, the only thing that moves one. L into Done resolves its open threads, H out opens those again, prompting nobody; on the Backburner they leave the Inbox and stop nagging" },
  { "0-4", "the task's priority: none, urgent, high, medium, low" },
  { "C", "a new task; on a thread with none, a task of its title" },
  { "n", "a new thread on the task: its title, then your first post" },
  { "s p a t", "the task's status, priority, assignee (a label, it tells nobody), labels (l is the column to the right)" },
  { "D e", "the task's due date, estimate" },
  { "r", "rename the task" },
  { "R K", "add or remove a relation to another task; link or unlink a PR or Linear ticket" },
  { "A", "attach the thread to a task, picked" },
  { "d", "delete the task, its threads kept, on no task" },
  { "<CR>", "open the task's own view, or the thread" },
  { "z", "fold the task's threads" },
  { "/ / <Esc>", "search ids, titles, labels and assignees, filtering as you type (<CR> keeps it) / clear it" },
  { "gg / G", "the top / bottom of the column" },
  { "?", "these keys" },
}

function M.bind(view)
  local function on(lhs, fn, desc)
    vim.keymap.set("n", lhs, function()
      require("isovim.safe").wrap("the board", fn)()
    end, { buffer = view.buf, nowait = true, desc = "isovim: " .. desc })
  end
  on("h", function() move_focus(view, -1, 0) end, "the column to the left")
  on("l", function() move_focus(view, 1, 0) end, "the column to the right")
  on("j", function() move_focus(view, 0, 1) end, "the row below")
  on("k", function() move_focus(view, 0, -1) end, "the row above")
  on("H", function() move_status(view, -1) end, "the task a column left")
  on("L", function() move_status(view, 1) end, "the task a column right")
  for value = 0, 4 do
    on(tostring(value), function() set_priority(view, value) end, "the task's priority")
  end
  on("C", function() create(view) end, "a new task")
  on("A", function() attach(view) end, "attach the thread to a task")
  local actions = require("isovim.task_view").actions
  for _, key in ipairs(require("isovim.task_view").KEYS) do
    on(key[1], function()
      local task = focused_task(view)
      if not task then
        return toast("that's a task's: this thread is on none (C makes it one, A attaches it)")
      end
      actions[key[2]](view.repo, task)
    end, key[3])
  end
  on("d", function()
    local task = focused_task(view)
    if task then
      vim.ui.select({ "Delete it, keeping its threads", "Keep it" }, { prompt = ("Delete task %s, %q?"):format(task.id, task.title) }, function(_, index)
        if index == 1 then
          for _, entry in pairs(surfaces.thread_rows(view.repo)) do
            if entry.task == task.id then
              threads.set_task(view.repo, entry.name, "none", "user")
            end
          end
          tasks.delete(view.repo, task.id)
          require("isovim.surface_view").close(view.repo, task.id)
          changed(view)
        end
      end)
    end
  end, "delete the task")
  on("/", function() search(view) end, "search")
  on("<Esc>", function()
    if (view.board_query or "") ~= "" then
      view.board_query = ""
      view.board_columns = nil
      M.draw(view)
    end
  end, "clear the search")
  on("gg", function() jump(view, false) end, "the top of the column")
  on("G", function() jump(view, true) end, "the bottom of the column")
  on("?", function()
    local text = vim.tbl_map(function(key)
      return ("%-12s %s"):format(key[1], key[2])
    end, M.help_keys)
    vim.notify(table.concat(text, "\n"), vim.log.levels.INFO, { title = "The board" })
  end, "the board's keys")
  on("<CR>", function()
    local row = focused(view)
    if row and row.task then
      surfaces.open(surfaces.task_entry(view.repo, row.task.id))
    elseif row and row.entry then
      surfaces.open(row.entry)
    end
  end, "open the task's view, or the thread")
  on("z", function()
    local task = focused_task(view)
    if task then
      view.board_folded = view.board_folded or {}
      view.board_folded[task.id] = not view.board_folded[task.id] or nil
      view.board_focus = task.id
      view.board_columns = nil
      M.draw(view)
    end
  end, "fold the task's threads")
end

-- A window showing the board: its lines cut, not wrapped.
function M.dress(win)
  local wo = vim.wo[win][0]
  wo.wrap, wo.cursorline, wo.number, wo.relativenumber, wo.signcolumn = false, false, false, false, "no"
  wo.conceallevel, wo.list = 0, false
end

-- The board as text, by column, for agents.
function M.text(repo)
  local out = {}
  for i, list in ipairs(M.columns(repo)) do
    local column = M.COLUMNS[i]
    local n = #vim.tbl_filter(function(row)
      return row.task ~= nil
    end, list)
    out[#out + 1] = ("%s (%d)"):format(column.name, n)
    for _, row in ipairs(list) do
      if row.group then
        out[#out + 1] = ("  No task (%d)"):format(row.count)
      elseif row.task then
        out[#out + 1] = ("  %s  %d/%d done"):format(tasks.summary_line(repo, row.task), row.done, #row.threads)
      else
        local entry = row.entry
        local tail = {}
        if unread_of(entry) then
          tail[#tail + 1] = "unread"
        end
        if entry.resolved then
          tail[#tail + 1] = "resolved"
        end
        if (entry.pending or 0) > 0 then
          tail[#tail + 1] = "question waiting"
        end
        if entry.working then
          tail[#tail + 1] = "working"
        end
        if entry.waiting_on then
          tail[#tail + 1] = "waiting on " .. (entry.waiting_on == "user" and "user" or (entry.waiting_name or entry.waiting_on))
        end
        if entry.bypass_name then
          tail[#tail + 1] = "goes to " .. entry.bypass_name
        end
        out[#out + 1] = ("    %s  %s%s"):format(entry.name, entry.title or "", #tail > 0 and ("  [" .. table.concat(tail, ", ") .. "]") or "")
      end
    end
  end
  return out
end

return M
