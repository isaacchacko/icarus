-- Tables in a chat or its thread, drawn to fit the window showing them (icarus.acp.look draws one).
-- Each keeps the rows the agent wrote, so it's drawn again when the window's width changes, or when
-- a chat that was out of sight shows. Both of a chat's buffers fit the same width, whichever shows.
local look = require("icarus.acp.look")

local M = {}

local MARK = vim.api.nvim_create_namespace("icarus_table_marks")
local HL = vim.api.nvim_create_namespace("icarus_table_hl")
-- How wide a table is drawn before a window has ever shown its chat.
local UNSEEN = 100

-- The narrowest window showing the chat, so none wraps; nil if none does.
local function window_width(chat)
  local width
  for _, buf in ipairs({ chat.buf, chat.thread }) do
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      width = math.min(width or math.huge, vim.api.nvim_win_get_width(win))
    end
  end
  return width
end

local function width_for(chat)
  chat.table_room = window_width(chat) or chat.table_room or UNSEEN
  return chat.table_room - 2
end

-- Replaces height lines at row with the table drawn to width.
local function put(buf, row, height, table_, width)
  local drawn, spans = look.table(table_.rows, width)
  local lines = {}
  for i, line in ipairs(drawn) do
    lines[i] = (i == 1 and table_.first or table_.rest) .. line
  end
  vim.api.nvim_buf_clear_namespace(buf, HL, row, row + height)
  vim.api.nvim_buf_set_lines(buf, row, row + height, false, lines)
  table_.mark = vim.api.nvim_buf_set_extmark(buf, MARK, row, 0, { id = table_.mark })
  table_.height, table_.width = #lines, width
  if vim.trim(table_.first) ~= "" then
    vim.api.nvim_buf_set_extmark(buf, HL, row, 0, { end_col = #vim.trim(table_.first), hl_group = "IcarusAcpMessage", priority = 120 })
  end
  for _, s in ipairs(spans) do
    local lead = #(s[1] == 0 and table_.first or table_.rest)
    vim.api.nvim_buf_set_extmark(buf, HL, row + s[1], lead + s[2], { end_col = lead + s[3], hl_group = s[4], priority = 120 })
  end
end

-- Draws the tables between rows row and last of buf whose lines have all come: a table is whole once
-- a line that isn't one of its rows follows it, or the text ends (whole). prefix(line) is what a
-- line starts with, rest what a drawn line after the first does, and before(row, n) runs on the rows
-- of each table about to be drawn. Runs while buf is modifiable; returns where the next may start.
function M.scan(chat, buf, row, last, whole, prefix, rest, before)
  while row <= last do
    local lines = vim.api.nvim_buf_get_lines(buf, row, last + 1, false)
    local function text(i)
      local line = lines[i]
      return line and line:sub(#prefix(line) + 1)
    end
    if not look.table_row(text(1)) then
      row = row + 1
    elseif not text(2) then
      break
    elseif not look.table_alignments(text(2)) then
      row = row + 1
    else
      local n = 3
      while text(n) and look.table_row(text(n)) do
        n = n + 1
      end
      if not text(n) and not whole then
        break
      end
      local rows = {}
      for i = 1, n - 1 do
        rows[i] = text(i)
      end
      if before then
        before(row, n - 1)
      end
      local table_ = { rows = rows, first = prefix(lines[1]), rest = rest }
      put(buf, row, n - 1, table_, width_for(chat))
      chat.tables = chat.tables or {}
      chat.tables[buf] = chat.tables[buf] or {}
      table.insert(chat.tables[buf], table_)
      last = last + table_.height - (n - 1)
      row = row + table_.height
    end
  end
  return row
end

-- Draws the chat's tables again if the width to fit has changed.
function M.fit(chat)
  if not window_width(chat) then
    return
  end
  local width = width_for(chat)
  for buf, tables in pairs(chat.tables or {}) do
    if not vim.api.nvim_buf_is_valid(buf) then
      chat.tables[buf] = nil
    else
      local count = vim.api.nvim_buf_line_count(buf)
      local follow = vim.tbl_filter(function(win)
        return vim.api.nvim_win_get_cursor(win)[1] == count
      end, vim.fn.win_findbuf(buf))
      local modifiable = vim.bo[buf].modifiable
      vim.bo[buf].modifiable = true
      for _, table_ in ipairs(tables) do
        if table_.width ~= width then
          local row = vim.api.nvim_buf_get_extmark_by_id(buf, MARK, table_.mark, {})[1]
          local height = table_.height
          put(buf, row, height, table_, width)
          -- What counts rows in a message still streaming, below the table.
          local grew = table_.height - height
          if buf == chat.buf then
            chat.block_row = chat.block_row and chat.block_row > row and chat.block_row + grew or chat.block_row
            chat.table_scan = chat.table_scan and chat.table_scan > row and chat.table_scan + grew or chat.table_scan
          elseif chat.thread_scan and chat.thread_scan > row then
            chat.thread_scan = chat.thread_scan + grew
          end
        end
      end
      vim.bo[buf].modifiable = modifiable
      for _, win in ipairs(follow) do
        vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
      end
    end
  end
end

vim.api.nvim_create_autocmd("WinResized", {
  group = vim.api.nvim_create_augroup("icarus_tables", { clear = true }),
  callback = function()
    for _, chat in pairs(_G.icarus_open_chats or {}) do
      pcall(M.fit, chat)
    end
  end,
})

return M
