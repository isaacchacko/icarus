-- The board: every task at a glance, the whole screen, in a column per status (spec, building,
-- review, merged, cancelled). A task is a card: its title, how many of its agents are working,
-- need you or are idle, and how many links it has. It redraws every second while it shows.
--
-- h and l go from column to column, j and k from card to card; <CR> opens the task, <Tab> shows its
-- task.md and its PRs over the board (<Tab>, q or <Esc> closes it, <CR> opens the task, gx a link
-- under the cursor); s moves it on
-- to the next status and S back; gx opens its first link; t makes a task; <C-x> cancels it (or puts
-- it back), <C-d> deletes it; q goes back to the view before.
local chats = require("icarus.chats")
local tasks = require("icarus.tasks")

local M = {}

local NAME = "icarus://board"
local NS = vim.api.nvim_create_namespace("icarus_board")
local REFRESH_MS = 1000
local CARD_LINES = 5
local GAP = 2

-- In _G, so a hot reload keeps them: the card picked, and the columns as last drawn.
_G.icarus_board = _G.icarus_board or { col = 1, row = 1 }
local state = _G.icarus_board

local function highlights()
  vim.api.nvim_set_hl(0, "IcarusBoardHeader", { bold = true, default = true })
  vim.api.nvim_set_hl(0, "IcarusBoardCount", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "IcarusBoardCard", { link = "FloatBorder", default = true })
  vim.api.nvim_set_hl(0, "IcarusBoardSelected", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "IcarusBoardDone", { link = "Comment", default = true })
end
highlights()

local function fit(text, cols)
  local width = vim.fn.strdisplaywidth(text)
  if width <= cols then
    return text .. (" "):rep(cols - width)
  end
  return vim.fn.strcharpart(text, 0, cols - 1) .. "…"
end

-- The tasks, a list per status, the last opened first.
local function columns()
  local by = {}
  for _, status in ipairs(tasks.STATUSES) do
    by[status] = {}
  end
  for _, task in ipairs(tasks.recent()) do
    if not task.sentinel and by[task.status] then
      table.insert(by[task.status], task)
    end
  end
  return by
end

-- A card's second line: its agents by status, and its links.
local function counts(task)
  local n = { working = 0, ["needs you"] = 0, idle = 0 }
  for _, record in ipairs(chats.on_task(task.slug)) do
    local status = chats.status(record.id)
    n[status] = (n[status] or 0) + 1
  end
  local parts = {}
  if n["needs you"] > 0 then
    parts[#parts + 1] = { "◆ " .. n["needs you"], "IcarusGraphNeeds" }
  end
  if n.working > 0 then
    parts[#parts + 1] = { "● " .. n.working, "IcarusGraphWorking" }
  end
  if n.idle > 0 then
    parts[#parts + 1] = { "○ " .. n.idle, "IcarusGraphIdle" }
  end
  if #task.links > 0 then
    parts[#parts + 1] = { "↗ " .. #task.links, "IcarusGraphIdle" }
  end
  if #parts == 0 then
    parts[1] = { "no agents", "IcarusGraphIdle" }
  end
  return parts
end

local function buf()
  local b
  for _, each in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(each) == NAME then
      b = each
    end
  end
  if not b then
    b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].filetype = "icarus_board"
    vim.bo[b].modifiable = false
    vim.api.nvim_buf_set_name(b, NAME)
  end
  local function map(lhs, fn, desc, arg)
    vim.keymap.set("n", lhs, function()
      require("icarus.board")[fn](arg)
    end, { buffer = b, nowait = true, desc = desc })
  end
  map("h", "move", "Column to the left", { -1, 0 })
  map("l", "move", "Column to the right", { 1, 0 })
  map("j", "move", "Card below", { 0, 1 })
  map("k", "move", "Card above", { 0, -1 })
  map("<CR>", "enter", "Open the task")
  map("<Tab>", "peek", "Show its task.md")
  map("s", "advance", "Move it to the next status", 1)
  map("S", "advance", "Move it back a status", -1)
  map("gx", "link", "Open its first link")
  map("t", "new", "New task")
  map("<C-x>", "cancel", "Cancel it, or put it back")
  map("<C-d>", "delete", "Delete it")
  map("q", "back", "Back")
  vim.api.nvim_create_autocmd("WinResized", {
    group = vim.api.nvim_create_augroup("icarus_board", { clear = true }),
    callback = function()
      if #vim.fn.win_findbuf(b) > 0 then
        require("icarus.board").draw()
      end
    end,
  })
  return b
end

local function stop()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

-- The task picked, keeping to the cards there are.
local function picked()
  local col = state.by and state.by[tasks.STATUSES[state.col]]
  if not col or #col == 0 then
    return nil
  end
  state.row = math.max(1, math.min(#col, state.row))
  return col[state.row]
end

function M.draw()
  local b = buf()
  local win = vim.fn.win_findbuf(b)[1]
  if not win then
    return stop()
  end
  local by = columns()
  state.by = by
  -- Following the picked task if it moved column.
  if state.slug then
    for c, status in ipairs(tasks.STATUSES) do
      for r, task in ipairs(by[status]) do
        if task.slug == state.slug then
          state.col, state.row = c, r
        end
      end
    end
  end
  local current = picked()
  state.slug = current and current.slug
  local ncols = #tasks.STATUSES
  local width = vim.api.nvim_win_get_width(win)
  local cell = math.max(16, math.floor((width - 2 - GAP * (ncols - 1)) / ncols))
  local inner = cell - 4
  local tallest = 0
  for _, status in ipairs(tasks.STATUSES) do
    tallest = math.max(tallest, #by[status])
  end
  -- Each screen line is a cell per column; its parts are {text, group}, put together left to right.
  local rows = {}
  local function put(r, c, parts)
    rows[r] = rows[r] or {}
    rows[r][c] = parts
  end
  for c, status in ipairs(tasks.STATUSES) do
    put(1, c, { { fit(("%s  %d"):format(status, #by[status]), cell), "IcarusBoardHeader" } })
    put(2, c, { { ("─"):rep(cell), "IcarusBoardCount" } })
    for r, task in ipairs(by[status]) do
      local top = 3 + (r - 1) * CARD_LINES
      local border = (c == state.col and r == state.row) and "IcarusBoardSelected" or "IcarusBoardCard"
      local done = status == "merged" or status == "cancelled"
      put(top, c, { { "╭" .. ("─"):rep(cell - 2) .. "╮", border } })
      put(top + 1, c, { { "│ ", border }, { fit(task.title, inner), done and "IcarusBoardDone" or "IcarusGraphTitle" }, { " │", border } })
      local line, used = { { "│ ", border } }, 0
      for i, part in ipairs(counts(task)) do
        local text = (i > 1 and "  " or "") .. part[1]
        local width = vim.fn.strdisplaywidth(text)
        -- What doesn't fit the card is left off.
        if used + width > inner then
          break
        end
        line[#line + 1] = { text, part[2] }
        used = used + width
      end
      line[#line + 1] = { (" "):rep(math.max(0, inner - used)) .. " │", border }
      put(top + 2, c, line)
      -- Where it stands, in its lead's words (ica status).
      local now = type(task.attrs.now) == "string" and task.attrs.now or ""
      put(top + 3, c, { { "│ ", border }, { fit(now, inner), "Comment" }, { " │", border } })
      put(top + 4, c, { { "╰" .. ("─"):rep(cell - 2) .. "╯", border } })
    end
  end
  local lines, marks, starts = {}, {}, {}
  for r = 1, 2 + tallest * CARD_LINES do
    local text, line_marks = " ", {}
    starts[r] = {}
    for c = 1, ncols do
      starts[r][c] = #text
      local parts = rows[r] and rows[r][c]
      local filled = 0
      for _, part in ipairs(parts or {}) do
        line_marks[#line_marks + 1] = { #text, #text + #part[1], part[2] }
        text = text .. part[1]
        filled = filled + vim.fn.strdisplaywidth(part[1])
      end
      text = text .. (" "):rep(cell - filled + (c < ncols and GAP or 0))
    end
    lines[r], marks[r] = text, line_marks
  end
  if tallest == 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  no tasks yet: t makes one"
  end
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
  vim.api.nvim_buf_clear_namespace(b, NS, 0, -1)
  for r, line_marks in pairs(marks) do
    for _, mark in ipairs(line_marks) do
      vim.api.nvim_buf_set_extmark(b, NS, r - 1, mark[1], { end_col = mark[2], hl_group = mark[3] })
    end
  end
  -- The cursor on the picked card's title, out of the way otherwise.
  if current then
    local top = 3 + (state.row - 1) * CARD_LINES
    pcall(vim.api.nvim_win_set_cursor, win, { top + 1, starts[top + 1][state.col] + #"│ " })
  end
  if not state.timer then
    state.timer = assert(vim.uv.new_timer())
    state.timer:start(REFRESH_MS, REFRESH_MS, vim.schedule_wrap(function()
      require("icarus.board").draw()
    end))
  end
end

-- h, j, k, l: dc columns over and dr cards down; across, to the nearest card there is.
function M.move(step)
  local dc, dr = step[1], step[2]
  local ncols = #tasks.STATUSES
  if dc ~= 0 then
    local col = state.col
    repeat
      col = col + dc
    until col < 1 or col > ncols or #(state.by[tasks.STATUSES[col]] or {}) > 0
    if col >= 1 and col <= ncols then
      state.col = col
    end
  end
  state.row = state.row + dr
  state.slug = nil
  picked()
  M.draw()
end

function M.enter()
  local task = picked()
  if task then
    require("icarus").open_task(tasks.read(task.slug) or task)
  end
end

-- <Tab>: the task's task.md in a float over the board, as it is on disk.
function M.peek()
  local task = picked()
  task = task and tasks.read(task.slug)
  if not task then
    return
  end
  local board = vim.api.nvim_get_current_win()
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[fbuf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, vim.fn.filereadable(task.file) == 1 and vim.fn.readfile(task.file) or {})
  vim.bo[fbuf].filetype = "markdown"
  vim.bo[fbuf].modifiable = false
  local width = math.min(100, math.floor(vim.o.columns * 0.7))
  local height = math.min(math.max(5, vim.api.nvim_buf_line_count(fbuf)), math.floor(vim.o.lines * 0.75))
  local float = vim.api.nvim_open_win(fbuf, true, { relative = "editor", width = width, height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1, col = math.floor((vim.o.columns - width) / 2),
    border = "rounded", title = " " .. task.title .. " ", title_pos = "center",
    footer = " <CR> open · <Tab> link / close · q close ", footer_pos = "right" })
  vim.wo[float].wrap, vim.wo[float].linebreak, vim.wo[float].conceallevel = true, true, 2
  local function close()
    if vim.api.nvim_win_is_valid(float) then
      vim.api.nvim_win_close(float, true)
    end
    if vim.api.nvim_win_is_valid(board) then
      vim.api.nvim_set_current_win(board)
    end
  end
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, close, { buffer = fbuf, nowait = true, desc = "Close" })
  end
  vim.keymap.set("n", "<Tab>", function()
    local target = require("icarus.links").at_cursor()
    if target then
      return require("icarus.links").open(target)
    end
    close()
  end, { buffer = fbuf, nowait = true, desc = "Open the link under the cursor, else close" })
  vim.keymap.set("n", "gx", function()
    local target = require("icarus.links").at_cursor() or vim.fn.expand("<cfile>")
    if target:match("^https?://") then
      vim.ui.open(target)
    end
  end, { buffer = fbuf, nowait = true, desc = "Open the link under the cursor" })
  -- Its PRs at the end, once they're looked up: a link each.
  local NS = vim.api.nvim_create_namespace("icarus_board_prs")
  require("icarus.prs").get(task.slug, function(prs)
    if not (vim.api.nvim_buf_is_valid(fbuf) and vim.api.nvim_win_is_valid(float)) then
      return
    end
    local pr_lines, spans = require("icarus.prs").lines(prs)
    local first = vim.api.nvim_buf_line_count(fbuf) + 2
    vim.bo[fbuf].modifiable = true
    vim.api.nvim_buf_set_lines(fbuf, -1, -1, false, vim.list_extend({ "", "# PRs" }, pr_lines))
    vim.bo[fbuf].modifiable = false
    for _, span in ipairs(spans) do
      vim.api.nvim_buf_set_extmark(fbuf, NS, first + span[1], span[2], {
        end_col = span[3] == -1 and #pr_lines[span[1] + 1] or span[3], hl_group = span[4] })
    end
    local config = vim.api.nvim_win_get_config(float)
    local tall = math.min(vim.api.nvim_buf_line_count(fbuf), math.floor(vim.o.lines * 0.75))
    if tall > config.height then
      vim.api.nvim_win_set_config(float, { relative = "editor", row = math.floor((vim.o.lines - tall) / 2) - 1,
        col = config.col, width = config.width, height = tall })
    end
  end)
  vim.keymap.set("n", "<CR>", function()
    close()
    require("icarus").open_task(task)
  end, { buffer = fbuf, nowait = true, desc = "Open the task" })
  vim.api.nvim_create_autocmd("WinLeave", { buffer = fbuf, once = true, callback = function()
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(float) then
        vim.api.nvim_win_close(float, true)
      end
    end)
  end })
end

function M.advance(step)
  local task = picked()
  if not task then
    return
  end
  local at = vim.fn.index(tasks.STATUSES, task.status) + 1
  local to = tasks.STATUSES[math.max(1, math.min(#tasks.STATUSES, at + step))]
  if to ~= task.status then
    tasks.set_status(tasks.read(task.slug) or task, to)
    state.slug = task.slug
    M.draw()
  end
end

function M.link()
  local task = picked()
  local first = task and task.links[1]
  if not first then
    return vim.notify("No links on it", vim.log.levels.WARN)
  end
  require("icarus.links").open(vim.fn.expand(first))
end

function M.new()
  require("icarus").new_task()
end

function M.cancel()
  local task = picked()
  if task then
    require("icarus").toggle_cancelled(tasks.read(task.slug) or task)
    state.slug = task.slug
    M.draw()
  end
end

function M.delete()
  local task = picked()
  if not task then
    return
  end
  vim.ui.select({ "Delete", "Keep" }, { prompt = "Delete " .. task.title .. "?" }, function(choice)
    if choice == "Delete" then
      require("icarus").delete_task(tasks.read(task.slug) or task)
      -- Deleting the task the chat showing was on goes home; the board stays.
      if (require("icarus").view() or {}).kind ~= "board" then
        M.open()
      else
        M.draw()
      end
    end
  end)
end

function M.back()
  require("icarus").last_view()
end

-- <leader>m: the board, the whole screen.
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
  -- On the task you were on, if it's on the board.
  local before = icarus.view()
  state.slug = before and before.task or state.slug
  icarus.set_view({ kind = "board" })
  M.draw()
  -- Again once the right column's explorer has gone, which takes a moment.
  vim.schedule(M.draw)
end

return M
