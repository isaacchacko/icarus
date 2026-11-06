-- The outline: the column left of main on a task's screen, every buffer on the task in one dim list.
-- <CR> opens a row in main. ◆ marks what's waiting on you (icarus.inbox). The list keeps its order
-- whatever waits, and it follows the task on screen, drawn again every second.
--
-- Main is TEXT columns at most, and it sits centred: the outline takes the left margin and a blank
-- window the right one, so a wider screen only adds margin. <leader>z blanks the outline in place,
-- so main doesn't move. Neither blank window can be entered.
local chats = require("icarus.chats")
local tasks = require("icarus.tasks")

local T = require("icarus.theme")

local M = {}

local REFRESH_MS = 1000
local TEXT = 90
local MIN_WIDTH = 24
local NAME = "icarus://outline"
local NS = vim.api.nvim_create_namespace("icarus_outline")

vim.api.nvim_set_hl(0, "IcarusOutlineRow", { link = "Comment", default = true })
vim.api.nvim_set_hl(0, "IcarusOutlineHere", { link = "Normal", default = true })
vim.api.nvim_set_hl(0, "IcarusOutlineWaiting", { fg = T.sun })

-- In _G, so a hot reload keeps one timer.
_G.icarus_outline = _G.icarus_outline or {}
local state = _G.icarus_outline

-- Names in a task's folder that aren't yours to open: icarus's own.
local NOT_FILES = { agents = true, org = true, ["task.json"] = true, ["claims.json"] = true, ["graph.json"] = true }

local function win_with(flag)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[win][flag] then
      return win
    end
  end
end

local function scratch(name)
  local buf = vim.fn.bufnr("^" .. name .. "$")
  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, name)
    vim.bo[buf].modifiable = false
  end
  return buf
end

-- A row of the list: what it says, which buffer it opens, whether that's waiting on you.
---@class icarus.OutlineRow
---@field key string
---@field text string
---@field lead? string what goes before the text: an agent's tree
---@field glyph? string
---@field glyph_hl? string
---@field waiting? boolean
---@field line? integer the line that's waiting
---@field open fun()

---@type table<string, fun(task: icarus.Task, waiting: table): icarus.OutlineRow[]>
local ROWS = {}

function ROWS.task(task, waiting)
  if vim.fn.filereadable(task.file) == 0 then
    return {}
  end
  return { { key = "file:" .. task.file, text = "task.md", line = waiting.files[task.file], open = function()
    require("icarus.task_page").show(task, { file = task.file, line = waiting.files[task.file] })
  end } }
end

-- The files in dir, then its folders, each a row that opens and closes in place: a task's folder can
-- hold hundreds of an agent's screenshots.
function ROWS.files(task, waiting, dir, lead)
  dir, lead = dir or task.dir, lead or ""
  local names, folders = {}, {}
  for name, kind in vim.fs.dir(dir) do
    if not name:match("^%.") and not NOT_FILES[name] then
      table.insert(kind == "directory" and folders or names, name)
    end
  end
  table.sort(names)
  table.sort(folders)
  local out = {}
  for _, name in ipairs(names) do
    local path = dir .. "/" .. name
    if path ~= task.file then
      out[#out + 1] = { key = "file:" .. path, text = name, lead = lead, line = waiting.files[path], open = function()
        require("icarus.task_page").show(task, { file = path, line = waiting.files[path] })
      end }
    end
  end
  for _, name in ipairs(folders) do
    local path = dir .. "/" .. name
    state.open = state.open or {}
    out[#out + 1] = { key = "folder:" .. path, text = name .. "/", lead = lead, open = function()
      state.open[path] = not state.open[path] or nil
      M.redraw()
    end }
    if state.open[path] then
      vim.list_extend(out, ROWS.files(task, waiting, path, lead .. "  "))
    end
  end
  return out
end

function ROWS.agents(task, waiting)
  local out = {}
  for _, row in ipairs(require("icarus.org").rows(task)) do
    local id = row.target.chat
    local asks = id and waiting.chats[id]
    out[#out + 1] = { key = id and "chat:" .. id or "subagent:" .. row.target.subagent, lead = row.tree,
      glyph = asks and "◆" or row.glyph, glyph_hl = row.hl,
      text = row.note and (row.name .. "  " .. row.note) or row.name, waiting = asks or row.status == "needs you", open = function()
        if id then
          require("icarus.task_page").show(task, { chat = id })
        else
          require("icarus.subagents").open(row.target.subagent)
        end
      end }
  end
  return out
end

function ROWS.visuals(task)
  local out = {}
  for i, visual in ipairs(require("icarus.visual").list(task.slug)) do
    out[#out + 1] = { key = "visual:" .. i, text = visual.title, waiting = not visual.seen, open = function()
      require("icarus.task_page").show(task, { visual = i })
    end }
  end
  return out
end

function ROWS.prs(task)
  local prs = require("icarus.prs")
  prs.get(task.slug, function() end)
  return vim.tbl_map(function(pr)
    return { key = "pr:" .. pr.url, text = ("#%d %s"):format(pr.number, pr.title), open = function()
      require("icarus.links").open(pr.url)
    end }
  end, prs.kept(task.slug) or {})
end

function ROWS.decisions(task)
  local out = {}
  for _, row in ipairs(require("icarus.inbox").rows(task.slug)) do
    if row.decide then
      out[#out + 1] = { key = "decision:" .. row.text, text = row.text, waiting = true, open = row.decide }
    end
  end
  return out
end

-- The list's order, each a group of rows with a blank line between: the one place to change it.
local ORDER = { "task", "files", "agents", "visuals", "prs", "decisions" }

local function clip(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  return vim.fn.strcharpart(text, 0, math.max(0, width - 1)) .. "…"
end

---@return table waiting what's waiting on you on slug: {files = {[path] = line}, chats = {[id] = true}}
local function waiting_on(slug)
  local waiting = { files = {}, chats = {} }
  for _, row in ipairs(require("icarus.inbox").rows(slug)) do
    if row.path then
      local first = waiting.files[row.path]
      waiting.files[row.path] = first and row.line and math.min(first, row.line) or first or row.line or 1
    elseif row.chat then
      waiting.chats[row.chat] = true
    end
  end
  return waiting
end

-- The key of the row for what main shows.
local function here()
  local view = require("icarus").view() or {}
  return view.chat and "chat:" .. view.chat or view.file and "file:" .. view.file or view.visual and "visual:" .. view.visual
end

-- What's on each line of the list.
local rows_at = {}

local function draw()
  local win = win_with("icarus_outline")
  local view = require("icarus").view()
  local task = view and view.task and tasks.read(view.task)
  if not (win and task) or state.hidden then
    return
  end
  local waiting = waiting_on(task.slug)
  local width = vim.api.nvim_win_get_width(win)
  local lines, marks, map = {}, {}, {}
  local current = here()
  for _, group in ipairs(ORDER) do
    local rows = ROWS[group](task, waiting)
    if #rows > 0 and #lines > 0 then
      lines[#lines + 1] = ""
    end
    for _, row in ipairs(rows) do
      local asks = row.waiting or row.line ~= nil
      local mine = row.key == current
      local glyph = row.glyph or (asks and "◆") or " "
      local left = (mine and "▎" or " ") .. (row.lead or "") .. glyph .. " "
      local line = left .. clip(row.text, width - vim.fn.strdisplaywidth(left) - 1)
      lines[#lines + 1] = line
      map[#lines] = row
      marks[#marks + 1] = { #lines - 1, 0, #line, mine and "IcarusOutlineHere" or "IcarusOutlineRow" }
      if asks then
        marks[#marks + 1] = { #lines - 1, #left - #glyph - 1, #left - 1, "IcarusOutlineWaiting" }
      elseif row.glyph_hl then
        marks[#marks + 1] = { #lines - 1, #left - #glyph - 1, #left - 1, row.glyph_hl }
      end
    end
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local was = rows_at[cursor[1]]
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  rows_at = map
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, NS, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4] })
  end
  -- The cursor stays on the row it was on.
  local row = math.min(cursor[1], math.max(1, #lines))
  for i = 1, #lines do
    if was and map[i] and map[i].key == was.key then
      row = i
      break
    end
  end
  pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
end

function M.redraw()
  pcall(draw)
end

local function enter()
  local row = rows_at[vim.api.nvim_win_get_cursor(0)[1]]
  if row then
    row.open()
  end
end

local function list_buf()
  local buf = scratch(NAME)
  vim.bo[buf].filetype = "icarus_outline"
  for _, lhs in ipairs({ "<CR>", "l", "<Tab>" }) do
    vim.keymap.set("n", lhs, enter, { buffer = buf, nowait = true, desc = "Open this in main" })
  end
  vim.keymap.set("n", "q", function()
    M.focus()
  end, { buffer = buf, nowait = true, desc = "Back to main" })
  vim.keymap.set("n", "<Esc>", function()
    require("icarus.list").open()
  end, { buffer = buf, nowait = true, desc = "To the list" })
  return buf
end

local BARE = { number = false, relativenumber = false, signcolumn = "no", wrap = false, winfixwidth = true,
  statuscolumn = "", foldcolumn = "0", list = false, spell = false, winbar = "" }

local function open_win(flag, side, buf, width)
  local win = vim.api.nvim_open_win(buf, false, { split = side, win = -1, width = width })
  vim.w[win][flag] = true
  for option, value in pairs(BARE) do
    vim.wo[win][0][option] = value
  end
  return win
end

-- Main at its width and centred: the outline as the left margin, the blank window as the right.
local function fit()
  local outline = win_with("icarus_outline")
  if not outline then
    return
  end
  local width = math.max(MIN_WIDTH, math.floor((vim.o.columns - TEXT) / 2))
  local text = math.min(TEXT, vim.o.columns - width - 1)
  local margin = vim.o.columns - width - text - 2
  local right = win_with("icarus_margin")
  if margin < 1 then
    if right then
      vim.api.nvim_win_close(right, true)
    end
  else
    right = right or open_win("icarus_margin", "right", scratch("icarus://margin"), margin)
    vim.api.nvim_win_set_width(right, margin)
  end
  vim.api.nvim_win_set_width(outline, width)
end

local function stop()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

-- The columns round main, drawn for the task on screen.
function M.show()
  local win = win_with("icarus_outline")
  if not win then
    win = open_win("icarus_outline", "left", state.hidden and scratch("icarus://margin") or list_buf(), MIN_WIDTH)
    vim.wo[win][0].cursorline = false
  end
  fit()
  pcall(draw)
  if not state.timer then
    state.timer = assert(vim.uv.new_timer())
    state.timer:start(REFRESH_MS, REFRESH_MS, vim.schedule_wrap(function()
      if not win_with("icarus_outline") then
        return stop()
      end
      pcall(draw)
    end))
  end
end

-- Closes the columns, leaving main the whole screen.
function M.close()
  stop()
  local current = vim.api.nvim_get_current_win()
  for _, flag in ipairs({ "icarus_outline", "icarus_margin" }) do
    local win = win_with(flag)
    if win then
      if win == current then
        vim.api.nvim_set_current_win(require("icarus").main())
      end
      vim.api.nvim_win_close(win, true)
    end
  end
end

-- <leader>z: the list blanked where it is, or back.
function M.toggle()
  local win = win_with("icarus_outline")
  if not win then
    return
  end
  state.hidden = not state.hidden
  vim.api.nvim_win_set_buf(win, state.hidden and scratch("icarus://margin") or list_buf())
  if state.hidden and vim.api.nvim_get_current_win() == win then
    vim.api.nvim_set_current_win(require("icarus").main())
  elseif not state.hidden then
    draw()
  end
end

-- <leader>h: into the list, the row of what main shows under the cursor; from it, back to main.
function M.focus()
  local win = win_with("icarus_outline")
  if not win then
    return
  end
  if vim.api.nvim_get_current_win() == win then
    return vim.api.nvim_set_current_win(require("icarus").main())
  end
  if state.hidden then
    M.toggle()
  end
  vim.api.nvim_set_current_win(win)
  local current = here()
  for i, row in pairs(rows_at) do
    if row.key == current then
      pcall(vim.api.nvim_win_set_cursor, win, { i, 0 })
    end
  end
end

local group = vim.api.nvim_create_augroup("icarus_outline", { clear = true })
vim.api.nvim_create_autocmd("VimResized", { group = group, callback = function()
  fit()
end })
-- The blank windows are only margin: anything that lands in one (<C-l>, a click) goes back to main.
vim.api.nvim_create_autocmd("WinEnter", { group = group, callback = function()
  if vim.w.icarus_margin or vim.w.icarus_outline and state.hidden then
    vim.schedule(function()
      vim.api.nvim_set_current_win(require("icarus").main())
    end)
  end
end })

-- After a hot reload, this code's timer and keys.
stop()
vim.schedule(function()
  if win_with("icarus_outline") then
    list_buf()
    M.show()
  end
end)

return M
