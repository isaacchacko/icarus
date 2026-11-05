-- The sidebar: your chats, newest first, each with its status. <CR> opens the chat under the cursor
-- (home on the top line), n starts a new one.
local chats = require("isovim.chats")

local M = {}

local NS = vim.api.nvim_create_namespace("isovim_sidebar")
local WIDTH = 34

local STATUS = {
  working = { "●", "IsovimAcpSpinner" },
  idle = { "○", "IsovimAcpIdle" },
  ["needs you"] = { "?", "IsovimAcpAsk" },
}

local NAME = "isovim://sidebar"
local rows = {} ---@type table<integer, string> row -> chat id

local function title(record)
  return record.title or "new chat"
end

function M.refresh()
  local buf = vim.fn.bufnr("^" .. NAME .. "$")
  if buf == -1 then
    return
  end
  local current = require("isovim").current()
  local lines, marks = { " ⌂ isovim", "" }, {}
  rows = {}
  for _, record in ipairs(chats.list()) do
    local status = chats.status(record.id)
    local glyph, hl = unpack(STATUS[status])
    local text = (" %s %s"):format(glyph, title(record))
    -- Room for the status, right-aligned on the same row.
    local room = WIDTH - 2 - (status == "idle" and 0 or #status + 1)
    if vim.fn.strdisplaywidth(text) > room then
      text = vim.fn.strcharpart(text, 0, room - 1) .. "…"
    end
    lines[#lines + 1] = text
    rows[#lines] = record.id
    marks[#lines] = { hl = hl, glyph = glyph, status = status, current = record.id == current }
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, NS, 0, 0, { end_col = #lines[1], hl_group = "IsovimAcpToolTitle" })
  for row, mark in pairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, NS, row - 1, 1, { end_col = 1 + #mark.glyph, hl_group = mark.hl })
    if mark.status ~= "idle" then
      vim.api.nvim_buf_set_extmark(buf, NS, row - 1, 0, { virt_text = { { mark.status, mark.hl } }, virt_text_pos = "right_align" })
    end
    if mark.current then
      vim.api.nvim_buf_set_extmark(buf, NS, row - 1, 0, { line_hl_group = "CursorLine" })
    end
  end
end

local function enter()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local id = rows[row]
  if id then
    require("isovim").open(chats.get(id))
  elseif row == 1 then
    require("isovim").home()
  end
end

-- Its keys and its redraw, on its buffer: the new one, or after a hot reload the one already open.
function M.bind(buf)
  vim.keymap.set("n", "<CR>", enter, { buffer = buf, nowait = true })
  vim.keymap.set("n", "n", function()
    require("isovim").new_chat()
  end, { buffer = buf, nowait = true })
  vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("isovim_sidebar", { clear = true }),
    pattern = "IsovimChats",
    callback = M.refresh,
  })
  M.refresh()
end

-- Opens the sidebar as the leftmost window; returns it.
function M.open()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "isovim_sidebar"
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_set_name(buf, NAME)
  local win = vim.api.nvim_open_win(buf, false, { split = "left", win = -1, width = WIDTH })
  for name, value in pairs({ winfixwidth = true, number = false, relativenumber = false, signcolumn = "no",
    wrap = false, cursorline = false, list = false }) do
    vim.wo[win][0][name] = value
  end
  M.bind(buf)
  return win
end

-- After a hot reload: the sidebar already open, on this code.
function M.rebind()
  local buf = vim.fn.bufnr("^" .. NAME .. "$")
  if buf ~= -1 then
    M.bind(buf)
  end
end

return M
