-- isovim: the sidebar of your chats on the left, and beside it the main window, which shows home or
-- a chat (isovim.acp.chat). A new chat runs in the dir isovim was started in.
local chats = require("isovim.chats")
local chat = require("isovim.acp.chat")
local sidebar = require("isovim.sidebar")
local landing = require("isovim.landing")

local M = {}

M.current = nil ---@type string? the chat the main window shows

local sidebar_win ---@type integer?
local main ---@type integer?

-- The window home and chats show in: the last one, or the first that isn't the sidebar or a composer.
local function main_win()
  if main and vim.api.nvim_win_is_valid(main) then
    return main
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= sidebar_win and not vim.w[win].isovim_composer_of then
      main = win
      return win
    end
  end
  main = vim.api.nvim_open_win(landing.buf(), false, { split = "right", win = sidebar_win })
  return main
end

function M.home()
  local win = main_win()
  chat.hide_composer(win)
  vim.api.nvim_win_set_buf(win, landing.buf())
  vim.api.nvim_set_current_win(win)
  M.current = nil
  sidebar.refresh()
end

---@param record isovim.ChatRecord
function M.open(record)
  M.current = record.id
  chat.show(chat.get(record), main_win())
  sidebar.refresh()
end

function M.new_chat()
  M.open(chats.create(vim.fn.getcwd()))
end

function M.setup()
  main = vim.api.nvim_get_current_win()
  sidebar_win = sidebar.open()
  M.home()
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("isovim", { clear = true }),
    callback = chat.stop_all,
  })
end

return M
