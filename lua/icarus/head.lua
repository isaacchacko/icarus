-- task.md shows only what you write: its YAML header's lines are hidden, its cursor and its top line
-- are kept below them, so you can't scroll or move onto them, and an edit that reaches them
-- (backspacing into them, dk, dgg) is put back.
local M = {}

local HIDE = vim.api.nvim_create_namespace("icarus_head_hide")

-- Per task.md buffer with this code's autocmds, the header as it should be, between its ---.
local headers = {}

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

-- The header's lines hidden in file's windows, and taken as how it should be.
local function take(file)
  vim.api.nvim_buf_clear_namespace(file, HIDE, 0, -1)
  local close = bounds(file)
  headers[file] = close and vim.api.nvim_buf_get_lines(file, 0, close + 1, false) or {}
  if close then
    for row = 0, close do
      vim.api.nvim_buf_set_extmark(file, HIDE, row, 0, { conceal_lines = "" })
    end
  end
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

local function guard(file)
  for _, win in ipairs(vim.fn.win_findbuf(file)) do
    vim.wo[win][0].conceallevel = 2
    clamp(win, file)
  end
  if headers[file] then
    return
  end
  take(file)
  local group = vim.api.nvim_create_augroup("icarus_head_" .. file, { clear = true })
  vim.api.nvim_create_autocmd({ "BufWritePost", "BufReadPost" }, { group = group, buffer = file, callback = function()
    take(file)
  end })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { group = group, buffer = file, callback = function(ev)
    local want = headers[file]
    if ev.event == "TextChanged" and vim.api.nvim_get_current_buf() == file
      and not vim.deep_equal(vim.api.nvim_buf_get_lines(file, 0, #want, false), want) then
      vim.cmd("silent undo")
      vim.notify("That would change task.md's header", vim.log.levels.WARN)
      return
    end
    take(file)
  end })
  -- Backspacing at the start of what you write would join it to the header's ---.
  for _, key in ipairs({ "<BS>", "<C-h>", "<C-w>", "<C-u>" }) do
    vim.keymap.set("i", key, function()
      local close = bounds(file)
      local cursor = vim.api.nvim_win_get_cursor(0)
      if close and cursor[1] == close + 2 and cursor[2] == 0 then
        return ""
      end
      return key
    end, { buffer = file, expr = true, desc = "Delete, but not into the header" })
  end
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, { group = group, buffer = file, callback = function()
    clamp(vim.api.nvim_get_current_win(), file)
  end })
  vim.api.nvim_create_autocmd("WinScrolled", { group = group, callback = function()
    for _, win in ipairs(vim.fn.win_findbuf(file)) do
      clamp(win, file)
    end
  end })
end

function M.sync()
  local buf = vim.api.nvim_win_get_buf(require("icarus").main())
  if is_task_md(buf) then
    guard(buf)
  end
end

vim.api.nvim_create_autocmd("BufWinEnter", {
  group = vim.api.nvim_create_augroup("icarus_head", { clear = true }),
  callback = function()
    vim.schedule(function()
      require("icarus.head").sync()
    end)
  end,
})

-- After a hot reload, a task.md showing gets this code's autocmds.
vim.schedule(function()
  require("icarus.head").sync()
end)

return M
