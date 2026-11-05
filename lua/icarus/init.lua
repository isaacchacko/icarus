-- icarus: home, then the chat it opens (icarus.acp.chat), each the whole screen. A new chat runs in
-- the dir icarus was started in. Changing icarus's code
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

-- The window home and chats show in: the last one, or the first that isn't a composer.
local function main_win()
  if layout.main and vim.api.nvim_win_is_valid(layout.main) then
    return layout.main
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if not vim.w[win].icarus_composer_of then
      layout.main = win
      return win
    end
  end
  layout.main = vim.api.nvim_open_win(landing.buf(), false, { split = "right", win = -1 })
  return layout.main
end

function M.home()
  local win = main_win()
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
