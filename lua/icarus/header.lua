-- The header drawer: <C-k> on a task's screen opens the task's header in a split over main, the cursor
-- in it, and <C-k> again saves it and closes it. It's the same buffer the outline's header row opens
-- (icarus.head), so :w works there too. Leaving the task closes it. Anywhere else, <C-k> is the window
-- above, as <C-h>, <C-j> and <C-l> are.
local M = {}

-- In _G, so a hot reload keeps the window it has open.
_G.icarus_header = _G.icarus_header or {}
local state = _G.icarus_header

local function showing()
  return state.win and vim.api.nvim_win_is_valid(state.win)
end

function M.close()
  if not showing() then
    return
  end
  local buf = vim.api.nvim_win_get_buf(state.win)
  if vim.bo[buf].modified then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
  end
  local here = vim.api.nvim_get_current_win() == state.win
  vim.api.nvim_win_close(state.win, true)
  state.win, state.task = nil, nil
  if here then
    vim.api.nvim_set_current_win(require("icarus").main())
  end
end

local function open(task)
  local buf = require("icarus.head").buffer(task)
  local main = require("icarus").main()
  local height = math.min(vim.api.nvim_buf_line_count(buf), math.floor(vim.api.nvim_win_get_height(main) / 2))
  state.win = vim.api.nvim_open_win(buf, true, { split = "above", win = main, height = math.max(1, height) })
  state.task = task.slug
  for option, value in pairs({ number = false, relativenumber = false, signcolumn = "no", statuscolumn = "",
    winfixheight = true, wrap = false, winbar = "" }) do
    vim.wo[state.win][0][option] = value
  end
end

-- <C-k>.
function M.key()
  if showing() then
    return M.close()
  end
  local tasks = require("icarus.tasks")
  local view = require("icarus").view()
  local task = view and view.kind == "task" and tasks.read(view.task)
  if task and not task.sentinel then
    return open(task)
  end
  vim.cmd.wincmd("k")
end

-- The drawer belongs to its task's screen.
function M.sync()
  local view = require("icarus").view()
  if showing() and not (view and view.kind == "task" and view.task == state.task) then
    M.close()
  end
end

return M
