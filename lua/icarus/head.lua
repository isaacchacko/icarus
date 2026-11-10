-- task.md shows only what you write: its YAML header's lines are hidden, its cursor and its top line
-- are kept below them, so you can't scroll or move onto them, and an edit that reaches them
-- (backspacing into them, dk, dgg) is put back.
-- The header is edited in a buffer of its own (icarus://head/<slug>), which the outline opens in main,
-- drawn with the keys dim and the values bright. :w there writes it into task.md, and so task.json
-- (icarus.tasks); a header changed another way (cancelling it, the list's s) shows there.
local M = {}

local NS = vim.api.nvim_create_namespace("icarus_head")
local HIDE = vim.api.nvim_create_namespace("icarus_head_hide")

local function highlights()
  vim.api.nvim_set_hl(0, "IcarusHeadKey", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "IcarusHeadValue", { link = "Normal", default = true })
  vim.api.nvim_set_hl(0, "IcarusHeadTitle", { bold = true, default = true })
  vim.api.nvim_set_hl(0, "IcarusHeadStatus", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "IcarusHeadDone", { link = "Comment", default = true })
end
highlights()

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

local function head_name(file)
  return "icarus://head/" .. vim.fs.basename(vim.fs.dirname(vim.api.nvim_buf_get_name(file)))
end

-- The header buffer of file, shown as the file has it unless you've unsaved edits there.
local function pull(file)
  local head = vim.fn.bufnr("^" .. head_name(file) .. "$")
  if head ~= -1 and not vim.bo[head].modified then
    vim.api.nvim_buf_set_lines(head, 0, -1, false, vim.list_slice(headers[file], 2, #headers[file] - 1))
    vim.bo[head].modified = false
    paint(head)
  end
end

-- The header's lines hidden in file's windows, and taken as how it should be.
local function take(file)
  vim.api.nvim_buf_clear_namespace(file, HIDE, 0, -1)
  local close = bounds(file)
  headers[file] = close and vim.api.nvim_buf_get_lines(file, 0, close + 1, false) or {}
  pull(file)
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

-- The header buffer of the task, for main to show.
---@return integer buf
function M.buffer(task)
  local file = vim.fn.bufadd(task.file)
  vim.fn.bufload(file)
  guard(file)
  local name = head_name(file)
  local head = vim.fn.bufnr("^" .. name .. "$")
  if head == -1 then
    head = vim.api.nvim_create_buf(false, true)
    vim.bo[head].buftype = "acwrite"
    vim.bo[head].bufhidden = "hide"
    vim.bo[head].swapfile = false
    vim.bo[head].filetype = "yaml"
    vim.api.nvim_buf_set_name(head, name)
  end
  -- Each time, so a header buffer from before a hot reload has only this code's.
  vim.api.nvim_clear_autocmds({ buffer = head, event = { "TextChanged", "TextChangedI", "BufWriteCmd" } })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = head, callback = function()
    paint(head)
  end })
  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = head, callback = function()
    local lines = vim.list_extend({ "---" }, vim.api.nvim_buf_get_lines(head, 0, -1, false))
    lines[#lines + 1] = "---"
    local close = bounds(file)
    vim.api.nvim_buf_set_lines(file, 0, close and close + 1 or 0, false, lines)
    vim.bo[head].modified = false
    require("icarus.tasks").save(file)
  end })
  pull(file)
  return head
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
vim.api.nvim_create_autocmd("ColorScheme", { group = "icarus_head", callback = highlights })

-- A hot reload drops what the old code put on its buffers, whatever those groups were keyed by: left
-- on a hidden task.md, they'd call functions this code doesn't have.
for _, autocmd in ipairs(vim.api.nvim_get_autocmds({})) do
  if autocmd.group_name and autocmd.group_name:match("^icarus_head_%d+$") then
    pcall(vim.api.nvim_del_augroup_by_name, autocmd.group_name)
  end
end

-- After a hot reload, a task.md showing gets this code's autocmds.
vim.schedule(function()
  require("icarus.head").sync()
end)

return M
