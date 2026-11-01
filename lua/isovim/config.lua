-- ~/.isovim/config.json, all optional:
--   self       this host's name, as other hosts address its agents (<host>:<ws>/<agent>); default hostname
--   hosts      other hosts, name -> ssh host: their agents show in the sidebar and workspaces move there
--   aliases    other names for those hosts
--   repo_dirs  more folders whose git repos are offered when making a workspace, besides ~ and the usual
--              code folders (~/code, ~/src, ~/Programs, ...)
--   prompts    role -> file (worker, router, repo-root, root; relative to ~) added to what agents of
--              that role are told at launch, after isovim's own words and instructions.md. isovim
--              seeds ~/.isovim/prompts/<role>.md (from prompts/ in this tree) when one is missing,
--              never writing over one, and names it here for a role that has no entry; null for a
--              role gives it no prompt file
--   repo_defaults  {glyph, palette}: the glyph and the list of colors (names or "#rrggbb") written into a
--              repo's config when it's first seen; default the repo glyph and the 12 palette colors from
--              red to pink. Repos take the colors in the order they're first seen, wrapping round.
local store = require("isovim.store")

local M = {}

M.path = store.root .. "/config.json"

---@return {self?: string, hosts?: table<string, string>, aliases?: table<string, string>, repo_dirs?: string[], prompts?: table<string, string>, repo_defaults?: {glyph?: string, palette?: string[]}}
function M.get()
  local ok, lines = pcall(vim.fn.readfile, M.path)
  local decoded, config = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  return decoded and type(config) == "table" and config or {}
end

-- The prompt file configured for a role, as an absolute path, or nil.
---@return string?
function M.prompt_file(role)
  local prompts = M.get().prompts
  local path = type(prompts) == "table" and prompts[role]
  if type(path) ~= "string" or path == "" then
    return nil
  end
  path = vim.fs.normalize(path)
  return vim.startswith(path, "/") and path or vim.fs.joinpath(vim.uv.os_homedir(), path)
end

-- The role prompts isovim ships, prompts/<role>.md in this tree (this file is lua/isovim/config.lua).
local here = debug.getinfo(1, "S").source:sub(2)
M.shipped_prompts = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.uv.fs_realpath(here) or here))) .. "/prompts"
M.prompts_dir = store.root .. "/prompts"
M.prompt_roles = { "worker", "router", "repo-root", "root" }

-- A role's seeded prompt file, ~/.isovim/prompts/<role>.md.
function M.seeded_prompt(role)
  return M.prompts_dir .. "/" .. role .. ".md"
end

-- Whether a prompt file still says what isovim shipped for the role (nobody has edited it).
function M.is_shipped(role, path)
  local function read(file)
    local ok, lines = pcall(vim.fn.readfile, file)
    return ok and table.concat(lines, "\n") or nil
  end
  local mine = path and read(path)
  return mine ~= nil and mine == read(M.shipped_prompts .. "/" .. role .. ".md")
end

-- First run, and every launch after: each role's default prompt file is copied to
-- ~/.isovim/prompts/<role>.md when it's missing (never over one), and config.json's prompts gets an
-- entry for each role that has none, so a prompt you set, or null for none, is always kept. It's
-- written as ~/.isovim/... when isovim's home is the usual one, as config.json syncs to hosts whose
-- home dirs differ. A config.json that isn't a JSON object is left alone.
function M.seed_prompts()
  vim.fn.mkdir(M.prompts_dir, "p")
  for _, role in ipairs(M.prompt_roles) do
    local from = M.shipped_prompts .. "/" .. role .. ".md"
    if vim.uv.fs_stat(from) and not vim.uv.fs_stat(M.seeded_prompt(role)) then
      vim.uv.fs_copyfile(from, M.seeded_prompt(role), { excl = true })
    end
  end
  local exists = vim.uv.fs_stat(M.path) ~= nil
  local config = {}
  if exists then
    local ok, lines = pcall(vim.fn.readfile, M.path)
    local decoded, value = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
    if not decoded or type(value) ~= "table" or (vim.islist(value) and next(value) ~= nil) then
      return
    end
    config = value
  end
  local prompts = config.prompts
  if prompts ~= nil and (type(prompts) ~= "table" or (vim.islist(prompts) and next(prompts) ~= nil)) then
    return
  end
  local home = vim.fs.normalize("~/.isovim")
  local add, missing = {}, false
  for _, role in ipairs(M.prompt_roles) do
    if prompts == nil or prompts[role] == nil then
      local path = M.seeded_prompt(role)
      add[role] = store.root == home and ("~/.isovim/prompts/" .. role .. ".md") or path
      missing = true
    end
  end
  if not missing then
    return
  end
  -- jq keeps the file's own keys in their order; the user's entries win over the defaults.
  local result = vim.system({ "jq", "--argjson", "add", vim.json.encode(add), ".prompts = ($add + (.prompts // {}))" },
    { stdin = exists and table.concat(vim.fn.readfile(M.path), "\n") or "{}", text = true }):wait()
  if result.code ~= 0 or vim.trim(result.stdout or "") == "" then
    return
  end
  local tmp = M.path .. ".seed.tmp"
  vim.fn.mkdir(store.root, "p")
  if vim.fn.writefile(vim.split(vim.trim(result.stdout), "\n"), tmp) == 0 and vim.uv.fs_rename(tmp, M.path) then
    require("isovim.sync").changed()
  end
end

return M
