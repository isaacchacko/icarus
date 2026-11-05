-- A task's file explorer: its folder as a tree at the top of the right column, over the window the
-- files it opens show in. <CR> on a folder opens or closes it; on a file, opens it in the window
-- under the explorer, never in the agent's. Dotfiles aren't listed. Both windows are side windows
-- (vim.w.icarus_side), which icarus never shows a chat in, and a task's spec.md that lands anywhere
-- else in the tab goes to the side instead.
local M = {}

local NS = vim.api.nvim_create_namespace("icarus_explorer")

---@class icarus.Explorer
---@field root string
---@field open table<string, boolean> the folders opened
---@field rows table<integer, {path: string, dir: boolean}>

_G.icarus_explorers = _G.icarus_explorers or {} ---@type table<integer, icarus.Explorer> by buffer
local explorers = _G.icarus_explorers

local function entries(dir)
  local list = {}
  for name, kind in vim.fs.dir(dir) do
    if not vim.startswith(name, ".") then
      list[#list + 1] = { name = name, dir = kind == "directory" }
    end
  end
  table.sort(list, function(a, b)
    if a.dir ~= b.dir then
      return a.dir
    end
    return a.name < b.name
  end)
  return list
end

local function draw(buf)
  local explorer = explorers[buf]
  local lines, marks = { vim.fn.fnamemodify(explorer.root, ":~") }, {}
  explorer.rows = {}
  local function walk(dir, depth)
    for _, entry in ipairs(entries(dir)) do
      local path = dir .. "/" .. entry.name
      local glyph = entry.dir and (explorer.open[path] and "▾ " or "▸ ") or "  "
      lines[#lines + 1] = ("  "):rep(depth) .. glyph .. entry.name .. (entry.dir and "/" or "")
      explorer.rows[#lines] = { path = path, dir = entry.dir }
      if entry.dir then
        marks[#marks + 1] = #lines
      end
      if entry.dir and explorer.open[path] then
        walk(path, depth + 1)
      end
    end
  end
  walk(explorer.root, 0)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, NS, 0, 0, { end_col = #lines[1], hl_group = "IcarusAcpToolTitle" })
  for _, row in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, NS, row - 1, 0, { end_col = #lines[row], hl_group = "Directory" })
  end
end

-- The window under explorer_win that its files show in, made if it's gone.
local function file_win(explorer_win)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[win].icarus_file_of == explorer_win then
      return win
    end
  end
  local win = vim.api.nvim_open_win(0, false, { split = "below", win = explorer_win,
    height = math.floor(vim.api.nvim_win_get_height(explorer_win) * 0.75) })
  vim.w[win].icarus_side, vim.w[win].icarus_file_of = true, explorer_win
  vim.wo[win][0].wrap, vim.wo[win][0].linebreak = true, true
  return win
end

-- Opens path in the window under the explorer in explorer_win; returns that window.
function M.open_file(path, explorer_win)
  local win = file_win(explorer_win)
  vim.api.nvim_win_call(win, function()
    vim.cmd.edit(vim.fn.fnameescape(path))
  end)
  return win
end

local function enter()
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local explorer = explorers[buf]
  local row = explorer and explorer.rows[vim.api.nvim_win_get_cursor(0)[1]]
  if not row then
    return
  elseif row.dir then
    explorer.open[row.path] = not explorer.open[row.path] or nil
    draw(buf)
  else
    vim.api.nvim_set_current_win(M.open_file(row.path, win))
  end
end

-- Shows root's tree in win, the cursor on select's row.
function M.show(root, win, select)
  local name = "icarus://explorer" .. root
  local buf = vim.fn.bufnr("^" .. vim.pesc(name) .. "$")
  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "icarus_explorer"
    vim.api.nvim_buf_set_name(buf, name)
    explorers[buf] = { root = root, open = {}, rows = {} }
  end
  vim.keymap.set("n", "<CR>", enter, { buffer = buf, nowait = true, desc = "Open the file, or open or close the folder" })
  vim.keymap.set("n", "R", function()
    draw(buf)
  end, { buffer = buf, nowait = true, desc = "Read the folder again" })
  draw(buf)
  vim.api.nvim_win_set_buf(win, buf)
  vim.w[win].icarus_side = true
  for option, value in pairs({ number = false, relativenumber = false, signcolumn = "no", wrap = false, winfixwidth = true,
    cursorline = true }) do
    vim.wo[win][0][option] = value
  end
  for row, entry in pairs(explorers[buf].rows) do
    if entry.path == select then
      vim.api.nvim_win_set_cursor(win, { row, 0 })
    end
  end
end

-- The tab's explorer window, if it has one.
function M.win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[win].icarus_side and not vim.w[win].icarus_file_of then
      return win
    end
  end
end

-- Closes the right column.
function M.close()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[win].icarus_side and #vim.api.nvim_tabpage_list_wins(0) > 1 then
      vim.api.nvim_win_close(win, true)
    end
  end
end

-- A task's spec.md shown in a window that isn't a side one goes back to the side column.
vim.api.nvim_create_autocmd("BufWinEnter", {
  group = vim.api.nvim_create_augroup("icarus_explorer", { clear = true }),
  pattern = "*/tasks/*/spec.md",
  callback = function(ev)
    local win = vim.api.nvim_get_current_win()
    local side = M.win()
    if vim.w[win].icarus_side or not side then
      return
    end
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == ev.buf then
        vim.api.nvim_win_call(win, function()
          pcall(vim.cmd.buffer, "#")
        end)
        vim.api.nvim_set_current_win(M.open_file(vim.api.nvim_buf_get_name(ev.buf), side))
      end
    end)
  end,
})

return M
