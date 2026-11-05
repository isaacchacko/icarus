-- ~/.isovim/config.json, all optional:
--   self       this host's name, as other hosts address its agents (<host>:<ws>/<agent>); default hostname
--   hosts      other hosts, name -> ssh host: their agents show in the sidebar and workspaces move there
--   aliases    other names for those hosts
--   repo_dirs  more folders whose git repos are offered when making a workspace, besides ~ and the usual
--              code folders (~/code, ~/src, ~/Programs, ...)
--   prompts    role -> file (worker, router, root; relative to ~) added to what agents of
--              that role are told at launch, after isovim's own words and instructions.md. isovim
--              seeds ~/.isovim/prompts/<role>.md (from prompts/ in this tree) when one is missing,
--              never writing over one, and names it here for a role that has no entry; null for a
--              role gives it no prompt file
--   prompt_plugins  role, or dedicated-router for a router dedicated to a task or component -> a file of
--              your own (relative to ~), told after the role's prompt: what you add to it while isovim's
--              prompt keeps updating beneath it. isovim never seeds or writes one, and changing one
--              tells those agents on their next restart
--   repo_defaults  {glyph, palette}: the glyph and the list of colors (names or "#rrggbb") written into a
--              repo's config when it's first seen; default the repo glyph and the 12 palette colors from
--              red to pink. Repos take the colors in the order they're first seen, wrapping round.
--   dedicated_label  what a router dedicated to a task is called on its card and in its view; default
--              "dedicated"
--   enforce    true once iso cutover has run on this host (M.enforced)
--   browser_tab_idle  seconds a tab in isovim's Chrome may go unused, its owner not working, before
--              it's closed (isovim.browser); default 3600, 0 closes only tabs whose owner is gone
--   thread_root_grace  minutes a thread sits on your turn before root mode's root is told (and at
--              least this long between those messages), in medic mode; in either, how long one
--              open in front of you holds the root back with no key pressed; default 5
--   compact_at the context size, in tokens, past which a router's or root's session is
--              compacted when a turn ends (isovim.acp.host); default 250000, 0 turns it off
local store = require("isovim.store")

local M = {}

M.path = store.root .. "/config.json"

---@return {self?: string, hosts?: table<string, string>, aliases?: table<string, string>, repo_dirs?: string[], prompts?: table<string, string>, prompt_plugins?: table<string, string>, repo_defaults?: {glyph?: string, palette?: string[]}}
function M.get()
  local ok, lines = pcall(vim.fn.readfile, M.path)
  local decoded, config = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  config = decoded and type(config) == "table" and config or {}
  -- The root was called repo-root, and a root entry beside that one is the host root's, which is gone.
  for _, files in ipairs({ config.prompts, config.prompt_plugins }) do
    if type(files) == "table" and files["repo-root"] ~= nil then
      files.root, files["repo-root"] = files["repo-root"], nil
    end
  end
  return config
end

-- What a router dedicated to a task is called on the board.
---@return string
function M.dedicated_label()
  local label = M.get().dedicated_label
  return type(label) == "string" and label ~= "" and label or "dedicated"
end

-- How long, in seconds, a tab may go unused before it's closed; 0 is never for that reason.
---@return number
function M.browser_tab_idle()
  local idle = M.get().browser_tab_idle
  return type(idle) == "number" and idle >= 0 and idle or 3600
end

-- How long, in minutes, the root stays out of a thread on the user's turn.
---@return number
function M.thread_root_grace()
  local grace = M.get().thread_root_grace
  return type(grace) == "number" and grace >= 0 and grace or 5
end

-- The context size past which a long-lived role's session is compacted; 0 is never.
---@return integer
function M.compact_at()
  local at = M.get().compact_at
  return type(at) == "number" and at >= 0 and at or 250000
end

-- Enforcement: role mismatches and agents running the user's commands are refused rather than
-- warned about, and the commands v0 retired fail. iso cutover turns it on (config "enforce": true,
-- this host's own, never synced); ISOVIM_ENFORCE=1 or 0 overrides the config.
function M.enforced()
  local env = vim.env.ISOVIM_ENFORCE
  if env and env ~= "" then
    return env == "1"
  end
  return M.get().enforce == true
end

-- Sets "enforce": true in config.json, keeping the rest of the file as written.
---@return boolean? ok, string? err
function M.enforce()
  local ok, lines = pcall(vim.fn.readfile, M.path)
  local text = ok and table.concat(lines, "\n") or ""
  local decoded, config = pcall(vim.json.decode, text ~= "" and text or "{}")
  if not decoded or type(config) ~= "table" or (vim.islist(config) and next(config)) then
    return nil, M.path .. " isn't a JSON object"
  end
  if config.enforce == true then
    return true
  end
  local new
  if config.enforce ~= nil then
    new = text:gsub('("enforce"%s*:%s*)[^,}%s]+', "%1true", 1)
  elseif next(config) == nil then
    new = '{\n  "enforce": true\n}'
  else
    new = text:gsub("%s*}%s*$", ',\n  "enforce": true\n}', 1)
  end
  local check_ok, check = pcall(vim.json.decode, new)
  if not check_ok or type(check) ~= "table" or check.enforce ~= true then
    config.enforce = true
    new = vim.json.encode(config)
  end
  local tmp = M.path .. ".tmp"
  vim.fn.writefile(vim.split(new, "\n"), tmp)
  return vim.uv.fs_rename(tmp, M.path)
end

local function role_file(files, role)
  local path = type(files) == "table" and files[role]
  if type(path) ~= "string" or path == "" then
    return nil
  end
  path = vim.fs.normalize(path)
  return vim.startswith(path, "/") and path or vim.fs.joinpath(vim.uv.os_homedir(), path)
end

-- The prompt file configured for a role, as an absolute path, or nil.
---@return string?
function M.prompt_file(role)
  return role_file(M.get().prompts, role)
end

-- The file of your own added to a role's prompt, as an absolute path, or nil. A dedicated router's
-- comes by its own key, not the router's.
---@param key string a role, or dedicated-router
---@return string?
function M.prompt_plugin(key)
  return role_file(M.get().prompt_plugins, key)
end

function M.plugin_keys()
  return vim.list_extend({ "dedicated-router" }, store.roles)
end

-- The role prompts isovim ships, prompts/<role>.md in this tree (this file is lua/isovim/config.lua).
local here = debug.getinfo(1, "S").source:sub(2)
M.shipped_prompts = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.uv.fs_realpath(here) or here))) .. "/prompts"
M.prompts_dir = store.root .. "/prompts"
M.prompt_roles = { "worker", "router", "root" }

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
