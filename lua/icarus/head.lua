-- A task.md in the right column shows as two windows: its YAML header in a small one on top, a
-- buffer of its own (icarus://head/<slug>) drawn with the keys dim and the values bright, and
-- under it task.md itself with the header's lines hidden, so the file window holds what you write:
-- its cursor and its top line are kept below them, so you can't scroll or move onto them, and an
-- edit made there that reaches them (backspacing into them, dk, dgg) is put back: the header is
-- edited in its own window.
-- Both are task.md: what you type in the header goes into task.md's header as you type, :w in
-- either window writes task.md (and so task.json, icarus.tasks), and a header changed another way
-- (cancelling it, the board's s) shows in the header window. <C-k> from the file goes up into it.
-- Under the header, a window of its own: the task's PRs and their Linear tickets (icarus.prs), each
-- a link (<Tab> or <CR> opens the PR on the line).
local M = {}

local NS = vim.api.nvim_create_namespace("icarus_head")
local HIDE = vim.api.nvim_create_namespace("icarus_head_hide")

-- In _G, so a hot reload keeps them: per head buffer, the task.md buffer it belongs to.
_G.icarus_head = _G.icarus_head or { of = {} }
local state = _G.icarus_head

local function highlights()
  vim.api.nvim_set_hl(0, "IcarusHeadKey", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "IcarusHeadValue", { link = "Normal", default = true })
  vim.api.nvim_set_hl(0, "IcarusHeadTitle", { bold = true, default = true })
  vim.api.nvim_set_hl(0, "IcarusHeadStatus", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "IcarusHeadDone", { link = "Comment", default = true })
end
highlights()

-- The header's closing line in file's lines (0-based row), if it has a header.
local function bounds(file)
  local lines = vim.api.nvim_buf_get_lines(file, 0, math.min(200, vim.api.nvim_buf_line_count(file)), false)
  if lines[1] ~= "---" then
    return nil
  end
  for i = 2, #lines do
    if lines[i] == "---" then
      return i - 1
    end
  end
end

local function is_task_md(buf)
  return vim.api.nvim_buf_get_name(buf):match("/tasks/[^/]+/task%.md$") ~= nil
end

local function head_win(file_win)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[win].icarus_head_of == file_win then
      return win
    end
  end
end

-- Draws the header buffer's keys and values.
local function paint(head)
  vim.api.nvim_buf_clear_namespace(head, NS, 0, -1)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(head, 0, -1, false)) do
    local key, value_at = line:match("^([%w_-]+):()")
    if key then
      vim.api.nvim_buf_set_extmark(head, NS, row - 1, 0, { end_col = #key + 1, hl_group = "IcarusHeadKey" })
      local value = line:sub(value_at):match("^%s*(.-)%s*$")
      local group = key == "title" and "IcarusHeadTitle"
        or key == "status" and ((value == "merged" or value == "cancelled") and "IcarusHeadDone" or "IcarusHeadStatus")
        or "IcarusHeadValue"
      if #line > value_at then
        vim.api.nvim_buf_set_extmark(head, NS, row - 1, value_at, { end_col = #line, hl_group = group })
      end
    elseif line:match("^%s*%-") then
      vim.api.nvim_buf_set_extmark(head, NS, row - 1, 0, { end_col = #line, hl_group = "IcarusHeadValue" })
    end
  end
end

-- Hides the header's lines in the file's windows.
local function hide(file)
  vim.api.nvim_buf_clear_namespace(file, HIDE, 0, -1)
  local close = bounds(file)
  if close then
    for row = 0, close do
      vim.api.nvim_buf_set_extmark(file, HIDE, row, 0, { conceal_lines = "" })
    end
  end
end

-- The header buffer of file, filled from file's header unless you're typing in it.
local function head_of(file)
  local name = "icarus://head/" .. vim.fs.basename(vim.fs.dirname(vim.api.nvim_buf_get_name(file)))
  local head
  for _, each in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(each) == name then
      head = each
    end
  end
  if not head then
    head = vim.api.nvim_create_buf(false, true)
    vim.bo[head].buftype = "acwrite"
    vim.bo[head].bufhidden = "hide"
    vim.bo[head].swapfile = false
    vim.bo[head].filetype = "yaml"
    vim.api.nvim_buf_set_name(head, name)
  end
  state.of[head] = file
  return head
end

-- file's header into head, as the lines between its ---.
-- The header as it should be: what the header window last wrote or read, between ---.
local function header_lines(head)
  local lines = vim.list_extend({ "---" }, vim.api.nvim_buf_get_lines(head, 0, -1, false))
  lines[#lines + 1] = "---"
  return lines
end

function M.pull(file, head)
  local close = bounds(file)
  local lines = close and vim.api.nvim_buf_get_lines(file, 1, close, false) or {}
  if not vim.deep_equal(lines, vim.api.nvim_buf_get_lines(head, 0, -1, false)) then
    state.pulling = true
    vim.api.nvim_buf_set_lines(head, 0, -1, false, lines)
    state.pulling = false
  end
  vim.bo[head].modified = false
  paint(head)
  hide(file)
end

-- head's lines into file's header, between ---.
function M.push(head)
  local file = state.of[head]
  if state.pulling or not (file and vim.api.nvim_buf_is_valid(file)) then
    return
  end
  local close = bounds(file)
  local lines = vim.list_extend({ "---" }, vim.api.nvim_buf_get_lines(head, 0, -1, false))
  lines[#lines + 1] = "---"
  vim.api.nvim_buf_set_lines(file, 0, close and close + 1 or 0, false, lines)
  paint(head)
  hide(file)
end

-- Keeps win's cursor and top line below file's header.
local function clamp(win, file)
  local close = bounds(file)
  local first = close and close + 2
  if not first or first > vim.api.nvim_buf_line_count(file) then
    return
  end
  if vim.api.nvim_win_get_cursor(win)[1] < first then
    vim.api.nvim_win_set_cursor(win, { first, 0 })
  end
  vim.api.nvim_win_call(win, function()
    if vim.fn.line("w0") < first then
      vim.fn.winrestview({ topline = first })
    end
  end)
end

local PRS = vim.api.nvim_create_namespace("icarus_head_prs")

local function prs_win(file_win)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[win].icarus_prs_of == file_win then
      return win
    end
  end
end

-- The PR window over file_win (under its header), holding prs as links.
function M.show_prs(file_win, slug, prs)
  -- None: no window, rather than one saying so.
  if #prs == 0 then
    local win = prs_win(file_win)
    if win then
      vim.api.nvim_win_close(win, true)
    end
    return
  end
  local name = "icarus://prs/" .. slug
  local buf
  for _, each in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(each) == name then
      buf = each
    end
  end
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].filetype = "icarus_prs"
    vim.api.nvim_buf_set_name(buf, name)
    for _, lhs in ipairs({ "<CR>", "<Tab>" }) do
      vim.keymap.set("n", lhs, function()
        local target = require("icarus.links").at_cursor()
        local first = require("icarus.links").find(vim.api.nvim_get_current_line())[1]
        target = target or (first and first[3])
        if target then
          require("icarus.links").open(target)
        end
      end, { buffer = buf, nowait = true, desc = "Open the PR, or the link under the cursor" })
    end
  end
  local lines, spans = require("icarus.prs").lines(prs)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, PRS, 0, -1)
  for _, span in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(buf, PRS, span[1], span[2], { end_col = span[3] == -1 and #lines[span[1] + 1] or span[3],
      hl_group = span[4] })
  end
  local win = prs_win(file_win)
  if not win then
    win = vim.api.nvim_open_win(buf, false, { split = "above", win = file_win, height = 1 })
    vim.w[win].icarus_prs_of = file_win
  end
  vim.api.nvim_win_set_buf(win, buf)
  for option, value in pairs({ number = false, relativenumber = false, signcolumn = "no", winfixheight = true, wrap = false,
    conceallevel = 2, concealcursor = "nc", cursorline = false, statuscolumn = "", foldcolumn = "0" }) do
    vim.wo[win][0][option] = value
  end
  vim.wo[win][0].winbar = "%#IcarusHeadKey# prs"
  vim.api.nvim_win_set_height(win, math.min(6, #lines) + 1)
end

local function fit(win, head)
  if vim.api.nvim_win_is_valid(win) then
    local height = math.max(1, math.min(12, vim.api.nvim_buf_line_count(head)))
    if vim.api.nvim_win_get_height(win) ~= height then
      vim.api.nvim_win_set_height(win, height)
    end
  end
end

-- Puts the header window over file_win, which shows a task.md.
function M.attach(file_win)
  local file = vim.api.nvim_win_get_buf(file_win)
  local head = head_of(file)
  M.pull(file, head)
  vim.wo[file_win][0].conceallevel = 2
  local win = head_win(file_win)
  if not win then
    win = vim.api.nvim_open_win(head, false, { split = "above", win = file_win, height = 1 })
    vim.w[win].icarus_head_of = file_win
  end
  vim.api.nvim_win_set_buf(win, head)
  for option, value in pairs({ number = false, relativenumber = false, signcolumn = "no", winfixheight = true,
    wrap = true, winbar = "", statuscolumn = "", foldcolumn = "0" }) do
    vim.wo[win][0][option] = value
  end
  fit(win, head)
  -- The task's PRs in a window under the header, once they're looked up.
  local slug = vim.fs.basename(vim.fs.dirname(vim.api.nvim_buf_get_name(file)))
  require("icarus.prs").get(slug, function(prs)
    if vim.api.nvim_win_is_valid(file_win) and vim.api.nvim_win_is_valid(win) then
      M.show_prs(file_win, slug, prs)
    end
  end)
  local group = vim.api.nvim_create_augroup("icarus_head_" .. head, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { group = group, buffer = head, callback = function()
    require("icarus.head").push(head)
    fit(win, head)
  end })
  vim.api.nvim_create_autocmd("BufWriteCmd", { group = group, buffer = head, callback = function()
    require("icarus.head").push(head)
    vim.api.nvim_buf_call(file, function()
      vim.cmd("silent write")
    end)
    vim.bo[head].modified = false
  end })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, { group = group, buffer = file, callback = function(ev)
    if vim.api.nvim_get_current_buf() == head then
      return
    end
    -- Typed in the file window and it reached the header: put back, the header's edited above.
    local here = vim.api.nvim_get_current_win()
    local want = header_lines(head)
    if ev.event == "TextChanged" and vim.api.nvim_win_get_buf(here) == file and head_win(here)
      and not vim.deep_equal(vim.api.nvim_buf_get_lines(file, 0, #want, false), want) then
      vim.cmd("silent undo")
      vim.notify("The header is edited in its window above (<C-k>)", vim.log.levels.WARN)
      return
    end
    require("icarus.head").pull(file, head)
    fit(win, head)
  end })
  -- Backspacing at the start of what you write would join it to the header's ---.
  for _, key in ipairs({ "<BS>", "<C-h>", "<C-w>", "<C-u>" }) do
    vim.keymap.set("i", key, function()
      local close = bounds(file)
      local cursor = vim.api.nvim_win_get_cursor(0)
      if close and head_win(vim.api.nvim_get_current_win()) and cursor[1] == close + 2 and cursor[2] == 0 then
        return ""
      end
      return key
    end, { buffer = file, expr = true, desc = "Delete, but not into the header" })
  end
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, { group = group, buffer = file, callback = function()
    local here = vim.api.nvim_get_current_win()
    if head_win(here) then
      clamp(here, file)
    end
  end })
  vim.api.nvim_create_autocmd("WinScrolled", { group = group, callback = function()
    if vim.api.nvim_win_is_valid(file_win) and vim.api.nvim_win_get_buf(file_win) == file and head_win(file_win) then
      clamp(file_win, file)
    end
  end })
  -- The cursor below the header, where you write.
  clamp(file_win, file)
end

-- Closes the header window over file_win, and its PR window.
function M.detach(file_win)
  for _, win in ipairs({ head_win(file_win), prs_win(file_win) }) do
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
end

-- A task.md coming into the right column gets its header window; anything else, none.
-- Every right column, as it is: one showing a task.md has its header window, one that doesn't, none.
-- Its buffer may change from another window (the visuals), so they're all looked at.
function M.sync()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[win].icarus_side then
      if is_task_md(vim.api.nvim_win_get_buf(win)) then
        if not head_win(win) or vim.api.nvim_win_get_buf(head_win(win)) ~= head_of(vim.api.nvim_win_get_buf(win)) then
          M.attach(win)
        end
      else
        M.detach(win)
      end
    end
  end
  -- One left over from a right column that closed.
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local of = vim.w[win].icarus_head_of or vim.w[win].icarus_prs_of
    if of and not (vim.api.nvim_win_is_valid(of) and vim.w[of].icarus_side) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

vim.api.nvim_create_autocmd({ "BufWinEnter", "WinClosed" }, {
  group = vim.api.nvim_create_augroup("icarus_head", { clear = true }),
  callback = function()
    vim.schedule(function()
      require("icarus.head").sync()
    end)
  end,
})
vim.api.nvim_create_autocmd("ColorScheme", { group = "icarus_head", callback = highlights })

-- After a hot reload, the right columns as they are now, each task.md's header window given this
-- code's autocmds.
vim.schedule(function()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[win].icarus_side and is_task_md(vim.api.nvim_win_get_buf(win)) then
      M.attach(win)
    end
  end
  M.sync()
end)

return M
