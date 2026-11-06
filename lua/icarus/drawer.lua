-- The drawer: the top bar grown downward, <leader>i, on every view but home, so everything under it
-- moves down rather than being covered. The bar keeps icarus's name; the drawer's line is the view's
-- title: on a task its title, status and what's left of its expected duration as a bar that drains.
-- It's a window across the whole screen, on the bar's background, and it can't be entered.
local tasks = require("icarus.tasks")

local M = {}

local REFRESH_MS = 5000
local CELLS = 16
local NS = vim.api.nvim_create_namespace("icarus_drawer")

-- In _G, so a hot reload keeps it: whether it's open, its window, its timer.
_G.icarus_drawer = _G.icarus_drawer or {}
local state = _G.icarus_drawer

-- 90m, 4h, 2d: the largest unit that fits.
local function duration(seconds)
  seconds = math.abs(seconds)
  local n, unit = seconds / 60, "m"
  if seconds >= 86400 then
    n, unit = seconds / 86400, "d"
  elseif seconds >= 3600 then
    n, unit = seconds / 3600, "h"
  end
  return ("%d%s"):format(math.floor(n), unit)
end

-- The task's title, status and SLA bar as {text, group} chunks.
local function task_title(task)
  local chunks = { { " " .. task.title, "IcarusTopTask" } }
  if task.status then
    chunks[#chunks + 1] = { "   ", "IcarusTopBar" }
    chunks[#chunks + 1] = { tasks.GLYPHS[task.status] .. " ", "IcarusTopStatus_" .. task.status }
    chunks[#chunks + 1] = { tasks.LABELS[task.status], "IcarusTopDim" }
  end
  local sla = task.status ~= "merged" and tasks.sla(task)
  if sla then
    local filled = math.max(0, math.ceil(CELLS * sla.left / sla.expected))
    chunks[#chunks + 1] = { "   ", "IcarusTopBar" }
    chunks[#chunks + 1] = { ("▰"):rep(filled), "IcarusTopFill" }
    chunks[#chunks + 1] = { ("▱"):rep(CELLS - filled), sla.left < 0 and "IcarusTopOver" or "IcarusTopDim" }
    chunks[#chunks + 1] = { " " .. duration(sla.left) .. (sla.left < 0 and " over" or " left"),
      sla.left < 0 and "IcarusTopOver" or "IcarusTopDim" }
  end
  return chunks
end

local function view_title(view)
  local task = view.kind == "task" and tasks.read(view.task)
  if task then
    return task_title(task)
  end
  return { { " " .. (view.kind == "list" and "task list" or require("icarus").view_name(view) or ""), "IcarusTopTask" } }
end

local function draw(buf, view)
  local chunks = view_title(view)
  local line = table.concat(vim.tbl_map(function(chunk)
    return chunk[1]
  end, chunks))
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  local col = 0
  for _, chunk in ipairs(chunks) do
    vim.api.nvim_buf_set_extmark(buf, NS, 0, col, { end_col = col + #chunk[1], hl_group = chunk[2] })
    col = col + #chunk[1]
  end
end

local function stop()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

-- Closes the window, whatever state.open says.
function M.close()
  stop()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
end

-- Whether it's showing, so the bar leaves the title to it.
function M.showing()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

-- The drawer as it should be for the view on screen. It has to be made after any window that spans
-- the screen's height, or it won't span the width over them: icarus.outline closes it first.
function M.sync()
  local view = require("icarus").view()
  if not (state.open and view and view.kind ~= "home") then
    M.close()
  else
    if not M.showing() then
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = "wipe"
      state.win = vim.api.nvim_open_win(buf, false, { split = "above", win = -1, height = 1, style = "minimal" })
      vim.w[state.win].icarus_drawer = true
      vim.wo[state.win].winfixheight = true
      vim.wo[state.win].fillchars = "horiz: ,horizdown: ,horizup: ,vertleft: ,vertright: ,verthoriz: "
      vim.wo[state.win].winhighlight = "Normal:IcarusTopBar,NormalNC:IcarusTopBar,EndOfBuffer:IcarusTopBar,WinSeparator:IcarusTopBar"
    end
    draw(vim.api.nvim_win_get_buf(state.win), view)
    if not state.timer then
      state.timer = assert(vim.uv.new_timer())
      state.timer:start(REFRESH_MS, REFRESH_MS, vim.schedule_wrap(function()
        pcall(M.sync)
      end))
    end
  end
  vim.cmd.redrawtabline()
end

-- <leader>i: open, or closed.
function M.toggle()
  state.open = not state.open
  M.sync()
end

-- Anything that lands in it (<C-k>, a click) goes back to main.
vim.api.nvim_create_autocmd("WinEnter", {
  group = vim.api.nvim_create_augroup("icarus_drawer", { clear = true }),
  callback = function()
    if vim.w.icarus_drawer then
      vim.schedule(function()
        vim.api.nvim_set_current_win(require("icarus").main())
      end)
    end
  end,
})

-- After a hot reload, this code's timer.
stop()
vim.schedule(function()
  require("icarus.drawer").sync()
end)

return M
