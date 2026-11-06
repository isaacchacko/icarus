-- The right column: a window files open in, with snacks' explorer beside it, which <leader>l opens
-- and closes. A file picked in the explorer opens in that window, never in the agent's. The window is a
-- side window (vim.w.icarus_side), which icarus never shows a chat in, and a task's task.md that
-- lands anywhere else in the tab goes to the side instead.
local M = {}

local WIDTH = 0.5
-- The tree needs a few names' width; the file gets the rest of the right column.
local TREE = 30

-- The tab's right column, if it has one.
function M.win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[win].icarus_side then
      return win
    end
  end
end

-- The right column, made if it's gone.
local function side_win()
  local win = M.win()
  if win then
    return win
  end
  win = vim.api.nvim_open_win(0, false, { split = "right", win = -1, width = math.floor(vim.o.columns * WIDTH) })
  vim.w[win].icarus_side, vim.w[win].snacks_main = true, true
  vim.wo[win][0].wrap, vim.wo[win][0].linebreak = true, true
  return win
end

-- Opens path in the right column; returns its window.
function M.open_file(path)
  local win = side_win()
  -- Already showing, it stays as it is: :edit on it would reload it, and refuse to over unsaved edits.
  if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == vim.fs.normalize(path) then
    return win
  end
  vim.api.nvim_win_call(win, function()
    vim.cmd.edit(vim.fn.fnameescape(path))
  end)
  return win
end

local function picker()
  -- tab = false: one still on its way to the screen counts too. The agent sidebar (icarus.org) is
  -- an explorer too, and not this one.
  for _, each in ipairs(require("icarus.ui").snacks().picker.get({ source = "explorer", tab = false })) do
    if not each.opts.icarus_org then
      return each
    end
  end
end

-- Shows root's tree as a sidebar at the right of the right column, the cursor on select, if it isn't
-- showing already, and focus moves to it if focus. The agent keeps its half of the screen.
function M.show(root, select, focus)
  local win = side_win()
  local open = picker()
  if open and open:cwd() == root then
    return
  elseif open then
    open:close()
  end
  require("icarus.ui").explorer({
    cwd = root,
    focus = focus and "list" or false,
    follow_file = false,
    -- It shows a moment later, and the split it makes evens out every window's width. Then the tree
    -- takes TREE columns and the file the rest of the right column.
    on_show = function(explorer)
      if select then
        require("snacks.explorer.actions").update(explorer, { target = select })
      end
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_width(explorer.layout.root.win, TREE)
        vim.api.nvim_win_set_width(win, math.max(1, math.floor(vim.o.columns * WIDTH) - TREE - 1))
      end
    end,
    layout = { preset = "sidebar", preview = false, layout = { position = "right" } },
    -- Closing it by hand is <leader>l's, so a task remembers it.
    win = { list = { keys = { q = { function()
      require("icarus").toggle_explorer()
    end, desc = "Close the explorer" } } } },
  })
end

-- Whether the right column's explorer is open.
function M.open_now()
  return picker() ~= nil
end

-- Opens or closes the explorer, showing root.
---@return boolean open whether it's open now
function M.toggle(root)
  local open = picker()
  if open then
    open:close()
  else
    M.show(root, nil, true)
  end
  return not open
end

-- Closes the explorer, if it's open, keeping the right column.
function M.hide()
  local open = picker()
  if open then
    open:close()
  end
end

-- Closes the right column.
function M.close()
  local open = picker()
  if open then
    open:close()
  end
  local win = M.win()
  if win and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.api.nvim_win_close(win, true)
  end
end

-- A task's task.md shown in a window that isn't a side one goes back to the side column.
vim.api.nvim_create_autocmd("BufWinEnter", {
  group = vim.api.nvim_create_augroup("icarus_explorer", { clear = true }),
  pattern = "*/tasks/*/task.md",
  callback = function(ev)
    local win = vim.api.nvim_get_current_win()
    if vim.w[win].icarus_side or not M.win() then
      return
    end
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == ev.buf then
        vim.api.nvim_win_call(win, function()
          pcall(vim.cmd.buffer, "#")
        end)
        vim.api.nvim_set_current_win(M.open_file(vim.api.nvim_buf_get_name(ev.buf)))
      end
    end)
  end,
})

return M
