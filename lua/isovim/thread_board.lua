-- A project's threads as a kanban board, as all threads otherwise read as equal weight when some are
-- subthreads of others: one view (one buffer drawn in four columns, no splits), as Linear's board is.
--
-- Motion is the user's: a card's column changes only when they move it with H or L, as a column entry
-- in the thread. No post, state change or agent moves one, and no agent can. A new thread lands in
-- Working, a new subthread in its parent's column, and a thread older than the board is placed once,
-- resolved in Done and the rest in Working. L into Done resolves it, H out of Done opens it again,
-- prompting nobody; a thread an agent resolves stays where it is. Backburner leaves the Inbox and stops
-- nagging, a new post only marking its card (isovim.surfaces). So columns say nothing of state: a card's
-- marks do, in any column: unread, the user's turn, an agent working, resolved. A top-level thread is a
-- full card; a subthread is a slim dim row, under its parent's card in the same column, else with its
-- parent's id. Within a column: priority first, then most recent.
--
-- Narrow, the columns shrink to MIN_WIDTH, then the board shows as many as fit, moving as the focus
-- does, so its layout never wraps. Column heads are the window's winbar, so they stay as it scrolls.
local surfaces = require("isovim.surfaces")
local threads = require("isovim.threads")
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

-- The column a thread's in: where it was put.
function M.column_of(entry)
  return entry.column or (entry.resolved and "done" or "working")
end

local function rank(entry)
  return (entry.priority or 0) > 0 and entry.priority or 5
end

local function before(a, b)
  if rank(a) ~= rank(b) then
    return rank(a) < rank(b)
  elseif (a.last_at or 0) ~= (b.last_at or 0) then
    return (a.last_at or 0) > (b.last_at or 0)
  end
  return (tonumber(a.name:sub(2)) or 0) > (tonumber(b.name:sub(2)) or 0)
end

-- The repo's threads by column, each column's rows in order: {entry, depth, card (a top-level thread),
-- under (a parent shown elsewhere, for a subthread), done, total (its children's progress)}. query
-- keeps those whose id or title has it.
function M.columns(repo, query)
  threads.place_all(repo)
  local rows = surfaces.thread_rows(repo)
  local children = {}
  for _, entry in pairs(rows) do
    if entry.parent and rows[entry.parent] and entry.parent ~= entry.name then
      children[entry.parent] = children[entry.parent] or {}
      table.insert(children[entry.parent], entry)
    end
  end
  query = query and query ~= "" and query:lower() or nil
  local function matches(entry)
    return not query or entry.name:lower():find(query, 1, true) ~= nil or (entry.title or ""):lower():find(query, 1, true) ~= nil
  end
  local columns = {}
  for i, column in ipairs(M.COLUMNS) do
    local shown, placed = {}, {}
    for _, entry in pairs(rows) do
      if M.column_of(entry) == column.key and matches(entry) then
        shown[entry.name] = entry
      end
    end
    local list = {}
    local function place(entry, depth, under)
      placed[entry.name] = true
      local kids = children[entry.name] or {}
      local done = 0
      for _, kid in ipairs(kids) do
        done = done + (kid.resolved and 1 or 0)
      end
      local has_parent = entry.parent and rows[entry.parent] and entry.parent ~= entry.name
      list[#list + 1] = { entry = entry, depth = depth, card = not has_parent, under = under, done = done, total = #kids }
      local here = vim.tbl_filter(function(kid)
        return shown[kid.name] and not placed[kid.name]
      end, kids)
      table.sort(here, before)
      for _, kid in ipairs(here) do
        place(kid, depth + 1)
      end
    end
    local roots = vim.tbl_filter(function(entry)
      return not (entry.parent and shown[entry.parent] and entry.parent ~= entry.name)
    end, vim.tbl_values(shown))
    table.sort(roots, before)
    for _, entry in ipairs(roots) do
      place(entry, 0, entry.parent and rows[entry.parent] and entry.parent ~= entry.name and entry.parent or nil)
    end
    -- A cycle written by hand has no root in it.
    local rest = vim.tbl_filter(function(entry)
      return not placed[entry.name]
    end, vim.tbl_values(shown))
    table.sort(rest, before)
    for _, entry in ipairs(rest) do
      if not placed[entry.name] then
        place(entry, 0, entry.parent)
      end
    end
    columns[i] = list
  end
  return columns
end

-- What needs the user, whatever column it's in.
local function needs_them(entry)
  return entry.needs_you or (entry.pending or 0) > 0
end

local function unread_of(entry)
  return entry.new_reply or entry.parked_unread or entry.marked_unread or (entry.resolved and entry.needs_you)
end

-- A card's marks, at a glance: unread, the user's turn, an agent working, resolved.
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
  local out = boxes.seg("")
  for _, part in ipairs(parts) do
    out = boxes.cat(out, boxes.seg(" "), part)
  end
  return out
end

-- What's under a card's title: the same in words, who it waits on or goes to, and how its children
-- are getting on.
local function meta(row)
  local entry = row.entry
  local parts = {}
  local function add(text, hl)
    parts[#parts + 1] = boxes.seg(text, hl)
  end
  if entry.resolved then
    add("resolved" .. (entry.outcome and (": " .. entry.outcome:match("^[^\n]*")) or ""), "DiagnosticOk")
  elseif (entry.pending or 0) > 0 then
    add("? waiting on you", "DiagnosticWarn")
  elseif entry.working then
    add("working…", "DiagnosticInfo")
  elseif entry.waiting_on == "user" then
    add("your turn", "DiagnosticWarn")
  elseif entry.new_reply or entry.parked_unread then
    add("new reply", "DiagnosticWarn")
  elseif entry.waiting_on then
    add("waiting on " .. (entry.waiting_name or entry.waiting_on), "Comment")
  end
  if entry.bypass_name then
    add("→ " .. entry.bypass_name, "Comment")
  end
  if row.total > 0 then
    add(("%d/%d done"):format(row.done, row.total), "Comment")
  end
  local out = boxes.seg("")
  for i, part in ipairs(parts) do
    out = boxes.cat(out, i > 1 and boxes.seg(" · ", "Comment") or boxes.seg(""), part)
  end
  return out
end

local function badge(entry)
  local b = BADGES[entry.priority or 0]
  return b and boxes.seg(b[1], b[2]) or nil
end

-- A top-level thread's card: lines width cells wide.
local function card(row, column, width, focused)
  local entry = row.entry
  local border = focused and "IsovimBoardFocus" or needs_them(entry) and "DiagnosticWarn" or "IsovimPrBorder"
  local inner = width - 4
  local head = boxes.cat(boxes.seg(column.glyph, column.hl), boxes.seg(" "), boxes.seg(entry.name, "IsovimPrDim"))
  if entry.last_glyph then
    head = boxes.cat(head, boxes.seg(" "), boxes.seg(entry.last_glyph[1], entry.last_glyph[2]))
  end
  head = boxes.cat(head, marks_of(entry))
  local tag = badge(entry)
  if tag then
    head = boxes.cat(boxes.fit(head, inner - 3), tag)
  end
  local lines = { boxes.seg("╭" .. ("─"):rep(width - 2) .. "╮", border), boxes.side(width, head, border) }
  local title = entry.title or entry.name
  local pieces = require("isovim.acp.look").wrap(title, inner)
  for i, piece in ipairs(pieces) do
    if i > 3 then
      break
    end
    local text = title:sub(piece[1] + 1, piece[2])
    if i == 3 and #pieces > 3 then
      text = vim.fn.strcharpart(text, 0, math.max(0, vim.fn.strchars(text) - 1)) .. "…"
    end
    lines[#lines + 1] = boxes.side(width, boxes.seg(text, entry.resolved and "Comment" or (focused and "Bold" or nil)), border)
  end
  local under = meta(row)
  if under.text ~= "" then
    lines[#lines + 1] = boxes.side(width, under, border)
  end
  lines[#lines + 1] = boxes.seg("╰" .. ("─"):rep(width - 2) .. "╯", border)
  return lines
end

-- A subthread's slim dim row.
local function slim(row, width, focused)
  local entry = row.entry
  local lead = row.under and ("↳ " .. row.under .. " ") or ((" "):rep(math.max(0, row.depth - 1) * 2 + 1) .. "└ ")
  -- Dim unless it needs the user: that reads in any column, slim or not.
  local line = boxes.cat(boxes.seg(lead, "NonText"), boxes.seg(entry.name .. " ", "Comment"),
    boxes.seg(entry.title or "", needs_them(entry) and "Normal" or "Comment"))
  local tail = marks_of(entry)
  if row.total > 0 then
    tail = boxes.cat(tail, boxes.seg((" %d/%d"):format(row.done, row.total), "Comment"))
  end
  local tag = badge(entry)
  if tag then
    tail = boxes.cat(tail, boxes.seg(" "), tag)
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
  for _, hint in ipairs({ { "hjkl", "move" }, { "H L", "status" }, { "0-4", "priority" }, { "/", "search" }, { "C", "new" }, { "T", "tree" }, { "?", "keys" } }) do
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

-- Where the focus is, in what's listed: its card if that's still there, else what's nearest it.
local function settle_focus(view, columns)
  for i, list in ipairs(columns) do
    for j, row in ipairs(list) do
      if row.entry.name == view.board_focus then
        view.board_col, view.board_index = i, j
        return
      end
    end
  end
  local col = view.board_col or 2
  local list = columns[col] or {}
  if #list == 0 and not view.board_focus then
    for i, each in ipairs(columns) do
      if #each > 0 then
        col, list = i, each
        break
      end
    end
  end
  local index = math.max(1, math.min(view.board_index or 1, #list))
  view.board_col, view.board_index = col, index
  view.board_focus = list[index] and list[index].entry.name or nil
end

-- The board's lines and highlights for width, and where its focus is. Pure but for the view's focus.
function M.layout(view, width)
  highlights()
  view.board_columns = view.board_columns or M.columns(view.repo, view.board_query)
  local columns = view.board_columns
  settle_focus(view, columns)
  local first, count, each = fit_columns(view, width)
  local cells, firsts = {}, {}
  for c = first, first + count - 1 do
    local out = {}
    firsts[c] = {}
    for _, row in ipairs(columns[c]) do
      local focused = row.entry.name == view.board_focus
      firsts[c][row.entry.name] = { from = #out + 1 }
      for _, line in ipairs(row.card and card(row, M.COLUMNS[c], each, focused) or slim(row, each, focused)) do
        out[#out + 1] = line
      end
      firsts[c][row.entry.name].to = #out
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

-- The column heads, as a winbar: they stay as the board scrolls, lined up with the columns.
local function winbar(view, fit, columns)
  local parts = {}
  for c = fit.first, fit.first + fit.count - 1 do
    local column = M.COLUMNS[c]
    local left = c == fit.first and fit.first > 1 and "‹ " or ""
    local right = c == fit.first + fit.count - 1 and c < #M.COLUMNS and " ›" or ""
    local name = ("%s %s %d"):format(column.glyph, column.name, #columns[c])
    local shown = left .. name .. right
    local pad = math.max(0, fit.each - vim.fn.strdisplaywidth(shown))
    local on = c == view.board_col and "Title" or "Comment"
    parts[#parts + 1] = ("%%#%s#%s%%#%s#%s%s"):format(column.hl, (left .. column.glyph):gsub("%%", "%%%%"), on,
      (" %s %d%s"):format(column.name, #columns[c], right):gsub("%%", "%%%%"), (" "):rep(pad))
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

-- Threads changed under it: read them again, and draw if it reads differently.
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
  local list = (view.board_columns or {})[view.board_col or 0] or {}
  for _, row in ipairs(list) do
    if row.entry.name == view.board_focus then
      return row.entry
    end
  end
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

-- H and L: the focused card a column left or right, the only thing that moves one. L into Done resolves
-- it, marked read; H out of Done opens it again, prompting nobody.
local function move_status(view, direction)
  local entry = focused(view)
  if not entry then
    return
  end
  local repo, id = view.repo, entry.name
  local from = M.column_of(entry)
  local to = M.COLUMNS[INDEX[from] + direction]
  if not to then
    return toast(direction > 0 and "it's done: H opens it again" or "it's on the backburner already")
  end
  if to.key == "done" then
    if not entry.resolved then
      threads.resolve(repo, id, "user")
    end
    threads.dismiss(repo, id)
    surfaces.opened(repo, entry.base)
  elseif from == "done" and entry.resolved then
    threads.resolve(repo, id, "user", nil, true)
  end
  threads.set_column(repo, id, to.key, "user")
  view.board_focus = id
  changed(view)
end

local function set_priority(view, value)
  local entry = focused(view)
  if entry then
    threads.set_priority(view.repo, entry.name, value, "user")
    changed(view)
  end
end

local function move_focus(view, column_step, row_step)
  local columns = view.board_columns or {}
  if column_step ~= 0 then
    local to = (view.board_col or 2) + column_step
    if not columns[to] then
      return
    end
    local list = columns[to]
    -- The row nearest in its order.
    local index = math.max(1, math.min(view.board_index or 1, #list))
    view.board_col, view.board_index = to, index
    view.board_focus = list[index] and list[index].entry.name or nil
  else
    local list = columns[view.board_col or 0] or {}
    local index = (view.board_index or 1) + row_step
    if list[index] then
      view.board_index, view.board_focus = index, list[index].entry.name
    end
  end
  M.draw(view)
end

local function jump(view, last)
  local list = (view.board_columns or {})[view.board_col or 0] or {}
  local index = last and #list or 1
  if list[index] then
    view.board_index, view.board_focus = index, list[index].entry.name
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

-- The board's keys, for the help (`?` in the sidebar, and here).
M.help_keys = {
  { "h j k l", "the card to the left, below, above, to the right" },
  { "H / L", "move the card a column left / right, the only thing that moves one. L into Done resolves it, H out of Done opens it again, prompting nobody; on the Backburner it's out of the Inbox and stops nagging" },
  { "0-4", "its priority: none, urgent, high, medium, low" },
  { "<CR>", "open the thread" },
  { "C", "a new thread: its title, then your first post" },
  { "/ / <Esc>", "search, filtering the cards as you type (<CR> keeps it) / clear it" },
  { "gg / G", "the top / bottom of the column" },
  { "T", "the tree of what spawned what, and back" },
  { "?", "these keys" },
}

local BOARD_KEYS = { "h", "j", "k", "l", "H", "L", "0", "1", "2", "3", "4", "C", "/", "<Esc>", "gg", "G", "?", "<CR>", "T" }

function M.unbind(view)
  for _, lhs in ipairs(BOARD_KEYS) do
    pcall(vim.keymap.del, "n", lhs, { buffer = view.buf })
  end
end

function M.bind(view)
  local function on(lhs, fn, desc)
    vim.keymap.set("n", lhs, function()
      require("isovim.safe").wrap("the thread board", fn)()
    end, { buffer = view.buf, nowait = true, desc = "isovim: " .. desc })
  end
  on("h", function() move_focus(view, -1, 0) end, "the card to the left")
  on("l", function() move_focus(view, 1, 0) end, "the card to the right")
  on("j", function() move_focus(view, 0, 1) end, "the card below")
  on("k", function() move_focus(view, 0, -1) end, "the card above")
  on("H", function() move_status(view, -1) end, "its status a column left")
  on("L", function() move_status(view, 1) end, "its status a column right")
  for value = 0, 4 do
    on(tostring(value), function() set_priority(view, value) end, "its priority")
  end
  on("C", function() require("isovim.acp.chat").new_thread(view.repo) end, "a new thread")
  on("/", function() search(view) end, "search the cards")
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
    vim.notify(table.concat(text, "\n"), vim.log.levels.INFO, { title = "Thread board" })
  end, "the board's keys")
  on("<CR>", function()
    local entry = focused(view)
    if entry then
      surfaces.open(entry)
    end
  end, "open this thread")
  on("T", function() require("isovim.surface_view").flip_threads(view) end, "the tree of what spawned what")
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
    out[#out + 1] = ("%s (%d)"):format(column.name, #list)
    for _, row in ipairs(list) do
      local entry = row.entry
      local b = BADGES[entry.priority or 0]
      local tail = {}
      if b then
        tail[#tail + 1] = b[3]
      end
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
      if row.total > 0 then
        tail[#tail + 1] = ("%d/%d done"):format(row.done, row.total)
      end
      local lead = row.under and ("  ↳ " .. row.under .. " ") or row.card and "  " or ((" "):rep(row.depth * 2 + 2) .. "└ ")
      out[#out + 1] = ("%s%s  %s%s"):format(lead, entry.name, entry.title or "", #tail > 0 and ("  [" .. table.concat(tail, ", ") .. "]") or "")
    end
  end
  return out
end

return M
