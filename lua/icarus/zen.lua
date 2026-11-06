-- Zen: <leader>z gives the window you're in the whole screen, as LazyVim's zen does (snacks.zen:
-- centered, the rest dimmed away), and again takes it back. A chat goes with its composer, as it's
-- the same buffer. The sidebars' explorers (floats over the screen) are hidden while it lasts.
-- Opening a sidebar (<leader>h, <leader>l) ends it, and opens that sidebar rather than toggling it
-- shut.
local M = {}

-- In _G, so a hot reload keeps what's hidden.
_G.icarus_zen = _G.icarus_zen or {}
local state = _G.icarus_zen

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

-- <leader>z: the window you're in, the whole screen; or back.
function M.toggle()
  if M.active() then
    return M.off()
  end
  sidebars(false)
  snacks().zen({ on_close = function()
    sidebars(true)
  end })
end

-- Back out of zen, if in it; true if it was.
function M.off()
  if M.active() then
    snacks().zen()
    sidebars(true)
    return true
  end
  return false
end

return M
