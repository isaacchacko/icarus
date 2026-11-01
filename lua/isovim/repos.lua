-- Which repo a workspace works in (its git origin, as "owner/repo") and how its sidebar row draws it:
-- a glyph and a color, from ~/.isovim/repos/<owner>/<repo>/config.json:
--   glyph   any string up to two cells wide, e.g. a nerd-font glyph
--   color   a name from M.palette or "#rrggbb"
-- (its scripts, actions and base clone are isovim.repoconf's)
-- A repo first seen without a color is given one: the default glyph (unless it has a glyph) and the next
-- palette color are written into its config, which from then on is the one source of truth. The next
-- color is the palette's entry at (number of repo configs that have a color) mod (palette size), so repos
-- take the colors in the order they're first seen, wrapping round when the palette runs out. The default
-- glyph and the palette come from repo_defaults in ~/.isovim/config.json.
local config = require("isovim.config")
local store = require("isovim.store")
local icons = require("isovim.icons")

local M = {}

-- tokyonight's accents, which read on its dark background, in the order repos take them by default.
local ACCENTS = {
  { "red", "#f7768e" },
  { "orange", "#ff9e64" },
  { "yellow", "#e0af68" },
  { "lime", "#c3e88d" },
  { "green", "#9ece6a" },
  { "teal", "#73daca" },
  { "cyan", "#7dcfff" },
  { "sky", "#2ac3de" },
  { "blue", "#7aa2f7" },
  { "purple", "#9d7cd8" },
  { "magenta", "#bb9af7" },
  { "pink", "#fca7ea" },
}
M.palette = {} ---@type table<string, string> name -> "#rrggbb"
local DEFAULT_PALETTE = {}
for _, accent in ipairs(ACCENTS) do
  M.palette[accent[1]] = accent[2]
  DEFAULT_PALETTE[#DEFAULT_PALETTE + 1] = accent[1]
end

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

-- The URL a checkout's repo is named by: its origin, or its only remote when it has no origin
-- (a clone whose remote is called github, say).
function M.remote_url(dir)
  local result = vim.system({ "git", "-C", dir, "remote", "get-url", "origin" }, { text = true }):wait()
  if result.code == 0 then
    return vim.trim(result.stdout)
  end
  local listed = vim.system({ "git", "-C", dir, "remote" }, { text = true }):wait()
  local remotes = listed.code == 0 and vim.split(vim.trim(listed.stdout), "\n", { trimempty = true }) or {}
  if #remotes ~= 1 then
    return nil
  end
  result = vim.system({ "git", "-C", dir, "remote", "get-url", remotes[1] }, { text = true }):wait()
  return result.code == 0 and vim.trim(result.stdout) or nil
end

-- Asked of git once per dir per session.
function M.of(dir)
  if names[dir] == nil then
    local url = M.remote_url(dir)
    names[dir] = url and M.normalize(url) or false
  end
  return names[dir] or nil
end

local function hex(color)
  if type(color) ~= "string" then
    return nil
  end
  return M.palette[color:lower()] or (color:match("^#%x%x%x%x%x%x$") and color:lower())
end

-- The glyph and palette new repos are given: repo_defaults from config.json, else the repo glyph and ACCENTS.
---@return {glyph: string, palette: string[]}
function M.defaults()
  local defaults = config.get().repo_defaults
  defaults = type(defaults) == "table" and defaults or {}
  local palette = vim.islist(defaults.palette) and vim.tbl_filter(hex, defaults.palette) or {}
  local glyph = type(defaults.glyph) == "string" and defaults.glyph ~= "" and defaults.glyph or icons.get("repo")
  return { glyph = glyph, palette = #palette > 0 and palette or DEFAULT_PALETTE }
end

-- A repo's config: {} when it has no file, nil when its file isn't a JSON object.
local function read(path)
  if not vim.uv.fs_stat(path) then
    return {}
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  local decoded, repo_config = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  local object = decoded and type(repo_config) == "table" and not (vim.islist(repo_config) and #repo_config > 0)
  return object and repo_config or nil
end

-- Every repo's config.json, never looking inside a base clone, which can be a big repo with its own.
local function config_paths()
  local root, paths = store.root .. "/repos", {}
  local function outside_clones(dir)
    return vim.fs.basename(dir) ~= "base-clone"
  end
  for path, kind in vim.fs.dir(root, { depth = 8, skip = outside_clones }) do
    if kind == "file" and vim.fs.basename(path) == "config.json" then
      paths[#paths + 1] = root .. "/" .. path
    end
  end
  return paths
end

local function next_color(palette)
  local taken = 0
  for _, path in ipairs(config_paths()) do
    local repo_config = read(path)
    if repo_config and hex(repo_config.color) then
      taken = taken + 1
    end
  end
  return palette[taken % #palette + 1]
end

-- Written to a temp file and renamed over the old one, so no reader ever sees half of it.
local function write(path, repo_config)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local tmp = ("%s.%d.tmp"):format(path, vim.uv.os_getpid())
  local lines = vim.split(vim.json.encode(repo_config, { indent = "  " }), "\n")
  local ok = pcall(vim.fn.writefile, lines, tmp)
  if not (ok and vim.uv.fs_rename(tmp, path)) then
    vim.fn.delete(tmp)
    return
  end
  -- The other hosts get it too.
  require("isovim.sync").changed()
end

-- ~/.isovim/repos/<name>: the repo's config.json, the scripts it names, its base clone.
function M.dir(name)
  return ("%s/repos/%s"):format(store.root, name)
end

-- The repos set up on this host, ~/.isovim/repos/<owner>/<repo>, sorted.
---@return string[]
function M.list()
  local root, names = store.root .. "/repos", {}
  for path, kind in vim.fs.dir(root, { depth = 2 }) do
    if kind == "directory" and path:find("/") then
      names[#names + 1] = path
    end
  end
  table.sort(names)
  return names
end

-- The repo's config: {} when it has no file, nil when its file isn't a JSON object.
function M.config(name)
  return read(M.dir(name) .. "/config.json")
end

function M.set_config(name, repo_config)
  write(M.dir(name) .. "/config.json", repo_config)
end

local function stamp_of(path)
  local stat = vim.uv.fs_stat(path)
  return stat and ("%d.%d.%d"):format(stat.mtime.sec, stat.mtime.nsec, stat.size) or ""
end

local styles = {} ---@type table<string, {stamp: string, style: {name: string, glyph: string, color: string}}>

-- The repo's glyph and color (as "#rrggbb"), written into its config the first time it's seen without a
-- color; the config is read again whenever the file changes. A file that isn't a JSON object is never
-- written over: until it's fixed the repo shows the default glyph and the color it would be given.
---@return {name: string, glyph: string, color: string}
function M.style(name)
  local path = M.dir(name) .. "/config.json"
  local cached = styles[name]
  if cached and cached.stamp == stamp_of(path) then
    return cached.style
  end
  local defaults = M.defaults()
  local repo_config = read(path)
  if repo_config and repo_config.color == nil then
    repo_config.glyph = repo_config.glyph == nil and defaults.glyph or repo_config.glyph
    repo_config.color = next_color(defaults.palette)
    write(path, repo_config)
  end
  repo_config = repo_config or {}
  local glyph = type(repo_config.glyph) == "string" and repo_config.glyph ~= "" and repo_config.glyph or defaults.glyph
  if vim.fn.strdisplaywidth(glyph) > 2 then
    glyph = vim.fn.strcharpart(glyph, 0, 1)
  end
  local style = { name = name, glyph = glyph, color = hex(repo_config.color) or hex(next_color(defaults.palette)) }
  styles[name] = { stamp = stamp_of(path), style = style }
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
