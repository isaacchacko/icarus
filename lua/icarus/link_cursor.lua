-- The link under the cursor: lit whole while you're on it. In what icarus draws (chats, threads,
-- floats: buffers without a file) a link is also one step for the cursor, however it moves (l, w,
-- j down a wrapped line): moving onto it lands on its start, and moving on from its start lands on
-- the character after it. In a file you edit you can still move inside one.
local links = require("icarus.links")

local M = {}

local NS = vim.api.nvim_create_namespace("icarus_link_cursor")

vim.api.nvim_set_hl(0, "IcarusLinkHover", { link = "Visual", default = true })

-- In _G, so a hot reload keeps them: where the cursor was in each window, and the link lit.
_G.icarus_link_cursor = _G.icarus_link_cursor or { last = {} }
local state = _G.icarus_link_cursor

-- The link on line at byte col (0-based): {from, to (1-based, inclusive), target}.
local function link_at(line, col)
  if not line:find("[/%]]") then
    return nil
  end
  for _, link in ipairs(links.find(line)) do
    if col >= link[1] - 1 and col <= link[2] - 1 then
      return link
    end
  end
end

local function unlight()
  local was = state.lit
  if was and vim.api.nvim_buf_is_valid(was.buf) then
    vim.api.nvim_buf_clear_namespace(was.buf, NS, 0, -1)
    pcall(links.relabel, was.buf)
  end
  state.lit = nil
end

local function light(buf, row, link)
  unlight()
  if link then
    vim.api.nvim_buf_set_extmark(buf, NS, row, link[1] - 1, { end_col = link[2], hl_group = "IcarusLinkHover",
      priority = 200 })
    state.lit = { buf = buf, row = row, from = link[1] - 1, to = link[2] }
    pcall(links.relabel, buf)
  end
end

-- The link lit now, if one is: {buf, row, from, to} (0-based, to exclusive).
function M.lit()
  return state.lit
end

-- Where the cursor rests on a link: its first character, or a markdown link's text, as its "[" is
-- hidden and a cursor on a hidden character is drawn wrong.
local function anchor(line, link)
  local from = link[1] - 1
  return line:sub(from + 1, from + 1) == "[" and from + 1 or from
end

-- Where the cursor goes on landing at (row, col) inside link, having come from was.
local function step(buf, row, col, line, link, was)
  local from, to = anchor(line, link), link[2] - 1
  if col == from then
    return row, col
  end
  if not (was and was.row == row and was.col == from and col > from) then
    return row, from
  end
  -- On from its start: past it.
  if to + 1 <= #line - 1 then
    return row, to + 1
  elseif row + 1 < vim.api.nvim_buf_line_count(buf) then
    return row + 1, 0
  end
  return row, from
end

local function moved()
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row, col = cursor[1] - 1, cursor[2]
  local line = vim.api.nvim_get_current_line()
  local link = link_at(line, col)
  if link and vim.bo[buf].buftype ~= "" and vim.api.nvim_get_mode().mode == "n" then
    local to_row, to_col = step(buf, row, col, line, link, state.last[win])
    if to_row ~= row or to_col ~= col then
      row, col = to_row, to_col
      vim.api.nvim_win_set_cursor(win, { row + 1, col })
      line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
      link = link_at(line, col)
    end
  end
  state.last[win] = { row = row, col = col }
  light(buf, row, link)
end

local GROUP = vim.api.nvim_create_augroup("icarus_link_cursor", { clear = true })
vim.api.nvim_create_autocmd("CursorMoved", { group = GROUP, callback = function()
  pcall(moved)
end })
vim.api.nvim_create_autocmd({ "WinLeave", "InsertEnter" }, { group = GROUP, callback = unlight })
vim.api.nvim_create_autocmd("WinClosed", { group = GROUP, callback = function(ev)
  state.last[tonumber(ev.match)] = nil
end })

return M
