-- Zen: <leader>z gives the window you're in the whole screen, as LazyVim's zen does (snacks.zen:
-- centered, the rest dimmed away), and again takes it back. A chat's conversation goes with its
-- composer, a float under it, so you can still type to the agent; the cursor goes to the composer.
-- The sidebars' explorers (floats over the screen) are hidden while it lasts. Opening a sidebar
-- (<leader>h, <leader>l) ends it, and opens that sidebar rather than toggling it shut.
local M = {}

-- In _G, so a hot reload keeps the composer float.
_G.icarus_zen = _G.icarus_zen or {}
local state = _G.icarus_zen

local COMPOSER = 5

local function snacks()
  return require("icarus.ui").snacks()
end

-- The explorers showing, hidden for zen, or shown again after it.
local function sidebars(show)
  if show then
    for _, picker in ipairs(state.hidden or {}) do
      pcall(function()
        picker.layout:unhide()
      end)
    end
    state.hidden = nil
    return
  end
  state.hidden = {}
  for _, picker in ipairs(snacks().picker.get({ source = "explorer", tab = false })) do
    if pcall(function()
      picker.layout:hide()
    end) then
      table.insert(state.hidden, picker)
    end
  end
end

function M.active()
  local zen = snacks().zen
  return zen.win ~= nil and zen.win:valid()
end

local function close_composer()
  if state.composer and vim.api.nvim_win_is_valid(state.composer) then
    vim.api.nvim_win_close(state.composer, true)
  end
  state.composer = nil
end

-- The composer under the zen window: the zen window made shorter, the composer's buffer in a float
-- below it at the same width.
local function open_composer(zen, input)
  local config = vim.api.nvim_win_get_config(zen.win)
  local height = math.max(3, config.height - COMPOSER - 1)
  vim.api.nvim_win_set_config(zen.win, { relative = config.relative, row = config.row, col = config.col,
    width = config.width, height = height })
  state.composer = vim.api.nvim_open_win(input, true, { relative = "editor", row = (config.row or 0) + height + 1,
    col = config.col, width = config.width, height = COMPOSER - 1, style = "minimal",
    zindex = (config.zindex or 50) + 1, border = { "", "─", "", "", "", "", "", "" } })
  vim.wo[state.composer].wrap, vim.wo[state.composer].linebreak = true, true
end

-- <leader>z: the window you're in, the whole screen; or back.
function M.toggle()
  if M.active() then
    return M.off()
  end
  local win = vim.api.nvim_get_current_win()
  -- A chat, from its conversation or from its composer.
  local chat_win = vim.w[win].icarus_composer_of or (vim.w[win].icarus_composer and win)
  local composer = chat_win and vim.api.nvim_win_is_valid(chat_win) and vim.w[chat_win].icarus_composer
  if composer and vim.api.nvim_win_is_valid(composer) then
    local input = vim.api.nvim_win_get_buf(composer)
    vim.api.nvim_set_current_win(chat_win)
    sidebars(false)
    snacks().zen({
      on_open = function(zen)
        open_composer(zen, input)
      end,
      on_close = function()
        close_composer()
        sidebars(true)
      end,
    })
    return
  end
  sidebars(false)
  snacks().zen({ on_close = function()
    sidebars(true)
  end })
end

-- Back out of zen, if in it; true if it was.
function M.off()
  close_composer()
  if M.active() then
    snacks().zen()
    sidebars(true)
    return true
  end
  return false
end

return M
