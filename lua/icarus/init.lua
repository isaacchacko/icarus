-- icarus: home, then the chat it opens (icarus.acp.chat), each the whole screen, or a task's screen:
-- its agent on the left and its folder and spec on the right (icarus.task_page). A new chat from
-- home runs in the dir icarus was started in, on "(no task)". Changing icarus's code
-- reloads it in place (icarus.reload), which runs setup({reload = true}) on the new code.
local chats = require("icarus.chats")
local chat = require("icarus.acp.chat")
local landing = require("icarus.landing")

local M = {}

-- In _G, so a hot reload keeps them.
_G.icarus_layout = _G.icarus_layout or {}
local layout = _G.icarus_layout ---@type {current?: string, main?: integer}

-- The chat the main window shows.
function M.current()
  return layout.current
end

-- The window home and chats show in: the last one, or the first that isn't a composer or a task's
-- right column.
local function main_win()
  if layout.main and vim.api.nvim_win_is_valid(layout.main) then
    return layout.main
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if not vim.w[win].icarus_composer_of and not vim.w[win].icarus_side then
      layout.main = win
      return win
    end
  end
  layout.main = vim.api.nvim_open_win(landing.buf(), false, { split = "right", win = -1 })
  return layout.main
end

function M.home()
  local win = main_win()
  require("icarus.explorer").close()
  chat.hide_composer(win)
  vim.api.nvim_win_set_buf(win, landing.buf())
  vim.api.nvim_set_current_win(win)
  vim.o.laststatus = 0
  landing.draw()
  layout.current = nil
end

---@param record icarus.ChatRecord
function M.open(record)
  layout.current = record.id
  vim.o.laststatus = 3
  chat.show(chat.get(record), main_win())
end

function M.new_chat()
  M.open(chats.create(vim.fn.getcwd()))
end

function M.new_task()
  require("icarus.task_page").new()
end

---@param task icarus.Task
function M.open_task(task)
  require("icarus.task_page").open(task)
end

-- Picks a task to jump to, the last opened first; "(no task)" is always there.
function M.pick_task()
  vim.ui.select(require("icarus.tasks").recent(), {
    prompt = "Task",
    format_item = function(task)
      return ("%-9s %s"):format(task.status or "", task.title)
    end,
  }, function(task)
    if task then
      M.open_task(task)
    end
  end)
end

-- Picks one of the agents on the task of the chat showing, or a new one, and shows it there.
function M.pick_agent()
  local tasks = require("icarus.tasks")
  local record = layout.current and chats.get(layout.current)
  local task = tasks.read(record and record.task or tasks.SENTINEL) or tasks.sentinel()
  local list = chats.on_task(task.slug)
  table.insert(list, { new = true })
  vim.ui.select(list, {
    prompt = "Agent on " .. task.title,
    format_item = function(each)
      return each.new and "+ new agent" or ("%-9s %s"):format(chats.status(each.id), each.title or "new chat")
    end,
  }, function(each)
    if each then
      local task_page = require("icarus.task_page")
      task_page.open(task, each.new and task_page.new_agent(task) or each)
    end
  end)
end

-- The views, each a letter after <leader>v.
local VIEWS = {
  h = { "Home", function()
    M.home()
  end },
  t = { "Last task", function()
    M.open_task(require("icarus.tasks").recent()[1])
  end },
}

-- Here, not in init.lua, so a hot reload applies them too.
local OPTIONS = { termguicolors = true, mouse = "a", splitright = true, splitbelow = true, showtabline = 0,
  ruler = false, fillchars = "eob: ", clipboard = "unnamedplus", statusline = " %{fnamemodify(getcwd(), ':~')}" }

---@param opts? {reload?: boolean}
function M.setup(opts)
  for name, value in pairs(OPTIONS) do
    vim.o[name] = value
  end
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("icarus", { clear = true }),
    callback = function()
      require("icarus.acp.chat").stop_all()
    end,
  })
  vim.keymap.set("n", "<leader>t", function()
    require("icarus").new_task()
  end, { desc = "New task" })
  vim.keymap.set("n", "<leader><leader>", function()
    require("icarus").pick_task()
  end, { desc = "Jump to a task" })
  vim.keymap.set("n", "<leader>a", function()
    require("icarus").pick_agent()
  end, { desc = "Agents on this task" })
  -- Keys without <leader> (a chat's <CR>, home's n) are listed here, so every key shows in which-key.
  vim.keymap.set("n", "<leader>?", function()
    local ok, wk = pcall(require, "which-key")
    if ok then
      wk.show({ global = false })
    else
      vim.cmd("map <buffer>")
    end
  end, { desc = "Keys in this buffer" })
  for key, view in pairs(VIEWS) do
    vim.keymap.set("n", "<leader>v" .. key, view[2], { desc = view[1] })
  end
  require("icarus.reload").watch()
  if opts and opts.reload then
    chat.rebind()
    -- Home as this code draws it, when that's what's showing.
    if not layout.current then
      M.home()
    end
    return
  end
  layout.main = vim.api.nvim_get_current_win()
  M.home()
end

return M
