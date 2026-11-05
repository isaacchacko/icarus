-- isovim: the sidebar of your chats on the left, and beside it the main window, which shows home or
-- a chat (isovim.acp.chat). A new chat runs in the dir isovim was started in. Changing isovim's code
-- reloads it in place (isovim.reload), which runs setup({reload = true}) on the new code.
local chats = require("isovim.chats")
local chat = require("isovim.acp.chat")
local sidebar = require("isovim.sidebar")
local landing = require("isovim.landing")

local M = {}

-- In _G, so a hot reload keeps them.
_G.isovim_layout = _G.isovim_layout or {}
local layout = _G.isovim_layout ---@type {current?: string, sidebar?: integer, main?: integer}

-- The chat the main window shows.
function M.current()
  return layout.current
end

-- The window home and chats show in: the last one, or the first that isn't the sidebar or a composer.
local function main_win()
  if layout.main and vim.api.nvim_win_is_valid(layout.main) then
    return layout.main
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= layout.sidebar and not vim.w[win].isovim_composer_of then
      layout.main = win
      return win
    end
  end
  layout.main = vim.api.nvim_open_win(landing.buf(), false, { split = "right", win = layout.sidebar })
  return layout.main
end

function M.home()
  local win = main_win()
  chat.hide_composer(win)
  vim.api.nvim_win_set_buf(win, landing.buf())
  vim.api.nvim_set_current_win(win)
  layout.current = nil
  sidebar.refresh()
end

---@param record isovim.ChatRecord
function M.open(record)
  layout.current = record.id
  chat.show(chat.get(record), main_win())
  sidebar.refresh()
end

function M.new_chat()
  M.open(chats.create(vim.fn.getcwd()))
end

---@param opts? {reload?: boolean}
function M.setup(opts)
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("isovim", { clear = true }),
    callback = function()
      require("isovim.acp.chat").stop_all()
    end,
  })
  require("isovim.reload").watch()
  if opts and opts.reload then
    sidebar.rebind()
    landing.buf()
    chat.rebind()
    return
  end
  layout.main = vim.api.nvim_get_current_win()
  layout.sidebar = sidebar.open()
  M.home()
end

return M
