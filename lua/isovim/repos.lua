-- Which repo a workspace works in (its git origin, as "owner/repo") and how its sidebar row draws it:
-- a glyph and a color, from ~/.isovim/repos/<owner>/<repo>/config.json, all optional:
--   glyph   any string up to two cells wide, e.g. a nerd-font glyph; default the repo glyph
--   color   a name from M.palette or "#rrggbb"; default a palette color picked by the repo's name
local store = require("isovim.store")
local icons = require("isovim.icons")

local M = {}

-- tokyonight's accents, which read on its dark background.
M.palette = {
  red = "#f7768e",
  orange = "#ff9e64",
  yellow = "#e0af68",
  lime = "#c3e88d",
  green = "#9ece6a",
  teal = "#73daca",
  cyan = "#7dcfff",
  sky = "#2ac3de",
  blue = "#7aa2f7",
  purple = "#9d7cd8",
  magenta = "#bb9af7",
  pink = "#fca7ea",
}
local PALETTE_ORDER = vim.tbl_keys(M.palette)
table.sort(PALETTE_ORDER)

-- "owner/repo" for GitHub, "host/path" for other hosts, the last two folders for a local path, all
-- lowercase (hosts ignore case); nil when the URL doesn't give a name safe as a path under ~/.isovim/repos.
function M.normalize(url)
  url = vim.trim(url):lower():gsub("/+$", ""):gsub("%.git$", "")
  local host, path = url:match("^[%w+.-]+://([^/]*)/(.*)$")
  if not host then
    host, path = url:match("^([^/]+):(.+)$")
  end
  if not host then
    path = url
  end
  host = host and host:gsub("^.*@", ""):gsub(":%d*$", "")
  local parts = vim.split(path, "/", { trimempty = true })
  if host == "github.com" or host == "www.github.com" then
    parts = vim.list_slice(parts, 1, 2)
  elseif host and host ~= "" then
    table.insert(parts, 1, host)
  else
    parts = vim.list_slice(parts, math.max(1, #parts - 1))
  end
  if #parts < 2 then
    return nil
  end
  for _, part in ipairs(parts) do
    if not part:match("^[%w._-]+$") or part:match("^%.+$") then
      return nil
    end
  end
  return table.concat(parts, "/")
end

local names = {} ---@type table<string, string|false> dir -> repo name, false outside git or without an origin

-- Asked of git once per dir per session.
function M.of(dir)
  if names[dir] == nil then
    local result = vim.system({ "git", "-C", dir, "remote", "get-url", "origin" }, { text = true }):wait()
    names[dir] = result.code == 0 and M.normalize(result.stdout) or false
  end
  return names[dir] or nil
end

-- A stable pick from the palette, so an unconfigured repo keeps its color everywhere.
local function derived_color(name)
  local hash = 5381
  for i = 1, #name do
    hash = (hash * 33 + name:byte(i)) % 2 ^ 32
  end
  return M.palette[PALETTE_ORDER[hash % #PALETTE_ORDER + 1]]
end

local function hex(color)
  if type(color) ~= "string" then
    return nil
  end
  return M.palette[color:lower()] or (color:match("^#%x%x%x%x%x%x$") and color:lower())
end

local styles = {} ---@type table<string, {stamp: string, style: {name: string, glyph: string, color: string}}>

-- The repo's glyph and color (as "#rrggbb"); its config is read again whenever the file changes.
---@return {name: string, glyph: string, color: string}
function M.style(name)
  local path = ("%s/repos/%s/config.json"):format(store.root, name)
  local stat = vim.uv.fs_stat(path)
  local stamp = stat and ("%d.%d.%d"):format(stat.mtime.sec, stat.mtime.nsec, stat.size) or ""
  local cached = styles[name]
  if cached and cached.stamp == stamp then
    return cached.style
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  local decoded, config = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  config = decoded and type(config) == "table" and config or {}
  local glyph = type(config.glyph) == "string" and config.glyph ~= "" and config.glyph or icons.get("repo")
  if vim.fn.strdisplaywidth(glyph) > 2 then
    glyph = vim.fn.strcharpart(glyph, 0, 1)
  end
  local style = { name = name, glyph = glyph, color = hex(config.color) or derived_color(name) }
  styles[name] = { stamp = stamp, style = style }
  return style
end

---@return {name: string, glyph: string, color: string}? nil outside a repo
function M.for_dir(dir)
  local name = M.of(dir)
  return name and M.style(name)
end

-- The highlight group drawing a "#rrggbb" color, defined when missing (a colorscheme change clears it).
function M.highlight(color)
  color = hex(color)
  if not color then
    return nil
  end
  local group = "IsovimRepo" .. color:sub(2)
  if vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = group })) then
    vim.api.nvim_set_hl(0, group, { fg = color })
  end
  return group
end

return M
