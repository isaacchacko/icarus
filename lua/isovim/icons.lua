-- isovim's glyphs and their colors, for the sidebar, the Inbox and the tab bar.
-- cod-claude and cod-openai are newer than the Symbols Nerd Font Ghostty 1.4 bundles (3.4): the
-- terminal needs Symbols Nerd Font Mono 3.5+ installed and, in Ghostty,
-- `font-codepoint-map = U+EC81-U+EC82=Symbols Nerd Font Mono`.
local M = {}

---@type table<string, {[1]: string, [2]: string}> name -> {glyph, highlight group}
M.map = {
  workspace = { "\u{f07b}", "Directory" }, -- fa-folder
  workspace_current = { "\u{f07c}", "Directory" }, -- fa-folder_open
  repo = { "\u{f401}", "Directory" }, -- oct-repo
  claude = { "\u{ec82}", "IsovimClaude" }, -- cod-claude
  codex = { "\u{ec81}", "MiniIconsGrey" }, -- cod-openai
  terminal = { "\u{f489}", "MiniIconsGrey" }, -- oct-terminal
  host = { "\u{f108}", "Title" }, -- fa-desktop
  shell = { "\u{f489}", "MiniIconsGrey" }, -- oct-terminal
  command = { "\u{f018d}", "MiniIconsGrey" }, -- md-console
  script = { "\u{f06a9}", "Comment" }, -- md-robot: a pane a repo script started
  user = { "\u{f0004}", "Directory" }, -- md-account: you, who posted last in a thread
  router = { "\u{f0469}", "Special" }, -- md-router_wireless: a repo's router, by role rather than kind
  root = { "\u{f01a5}", "Special" }, -- md-crown: Root, the host root's pseudo-repo
  general = { "\u{f0ac}", "Directory" }, -- fa-globe: General, agents in no repo and files outside every repo
  terminals = { "\u{f018d}", "Directory" }, -- md-console: Terminals, terminals and repo script panes
  landing = { "\u{f015}", "Title" }, -- fa-home: the landing page's tab
}

-- Words a surface's icon may be instead of a glyph (markdown frontmatter's icon: mail), each a
-- Material Design glyph of the Symbols Nerd Font.
M.words = {
  mail = "\u{f01ee}", email = "\u{f01ee}", chart = "\u{f0128}", graph = "\u{f012a}", doc = "\u{f0219}",
  document = "\u{f0219}", note = "\u{f039e}", bug = "\u{f00e4}", rocket = "\u{f14de}", star = "\u{f04ce}",
  check = "\u{f012c}", done = "\u{f012c}", warning = "\u{f0026}", alert = "\u{f0026}", info = "\u{f02fc}",
  idea = "\u{f0335}", bulb = "\u{f0335}", calendar = "\u{f00ed}", clock = "\u{f0150}", book = "\u{f14f7}",
  code = "\u{f0169}", search = "\u{f0349}", lock = "\u{f033e}", money = "\u{f01c1}", person = "\u{f0004}",
  user = "\u{f0004}", team = "\u{f0849}", people = "\u{f0849}", link = "\u{f0337}", image = "\u{f02e9}",
  table = "\u{f04eb}", list = "\u{f0279}", flag = "\u{f023b}", fire = "\u{f0238}", heart = "\u{f02d1}",
  pin = "\u{f0403}", map = "\u{f034d}", plan = "\u{f034d}", test = "\u{f0668}", pr = "\u{f04c2}",
  branch = "\u{f062c}", chat = "\u{f0b79}", message = "\u{f0369}", bell = "\u{f009a}", settings = "\u{f0493}",
  home = "\u{f02dc}", folder = "\u{f024b}", tool = "\u{f08ea}", bolt = "\u{f140b}", eye = "\u{f0208}",
  pencil = "\u{f03eb}", edit = "\u{f03eb}", trophy = "\u{f0538}", package = "\u{f03d6}", cloud = "\u{f015f}",
  database = "\u{f01bc}", web = "\u{f059f}", school = "\u{f0474}", clipboard = "\u{f014d}", inbox = "\u{f0687}",
}

function M.setup()
  vim.api.nvim_set_hl(0, "IsovimClaude", { fg = "#d97757", default = true })
end

---@return string glyph, string hl
function M.get(name)
  local icon = M.map[name] or M.map.command
  return icon[1], icon[2]
end

---@param agent {kind: string, role?: string}
function M.agent(agent)
  return M.get(agent.role == "router" and "router" or agent.kind)
end

return M
