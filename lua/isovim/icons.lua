-- isovim's glyphs and their colors, for the sidebar, the Inbox and the tab bar.
-- cod-claude and cod-openai are newer than the Symbols Nerd Font Ghostty 1.4 bundles (3.4): the
-- terminal needs Symbols Nerd Font Mono 3.5+ installed and, in Ghostty,
-- `font-codepoint-map = U+EC81-U+EC82=Symbols Nerd Font Mono`.
local M = {}

---@type table<string, {[1]: string, [2]: string}> name -> {glyph, highlight group}
M.map = {
  workspace = { "\u{f07b}", "Directory" }, -- fa-folder
  workspace_current = { "\u{f07c}", "Directory" }, -- fa-folder_open
  claude = { "\u{ec82}", "IsovimClaude" }, -- cod-claude
  codex = { "\u{ec81}", "MiniIconsGrey" }, -- cod-openai
  terminal = { "\u{f489}", "MiniIconsGrey" }, -- oct-terminal
  host = { "\u{f108}", "Title" }, -- fa-desktop
  shell = { "\u{f489}", "MiniIconsGrey" }, -- oct-terminal
  command = { "\u{f018d}", "MiniIconsGrey" }, -- md-console
}

function M.setup()
  vim.api.nvim_set_hl(0, "IsovimClaude", { fg = "#d97757", default = true })
end

---@return string glyph, string hl
function M.get(name)
  local icon = M.map[name] or M.map.command
  return icon[1], icon[2]
end

---@param agent {kind: string}
function M.agent(agent)
  return M.get(agent.kind)
end

return M
