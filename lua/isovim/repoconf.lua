-- What isovim keeps for a repo besides its glyph and color (isovim.repos), in ~/.isovim/repos/<owner>/<repo>/,
-- which is yours to edit:
--   config.json     setup, teardown, run, worktree_setup: command lists in Superset's format, run in
--                   the checkout (worktree_setup in a new-layout agent's new worktree); actions:
--                   name -> command list, for `iso <role> run <action>` (isovim.cli.work).
--                   A command whose first word is a file in this folder runs that file, so scripts
--                   can live beside the config: "./setup.sh --fast".
--                   imported_from and imported_at record the one import from the repo's own files.
--   base-clone/     a clone of origin, detached at its default branch, which new-layout agents'
--                   worktrees are made from; made by M.base on request
-- and, for the repo's work, ~/.iso/<owner>/<repo>/ ($ISOVIM_WORK), whose iso/ holds isovim's own files.
-- Every write isovim makes here goes to the other hosts too, base-clone/ aside (isovim.sync).
local repos = require("isovim.repos")
local store = require("isovim.store")

local M = {}

local SCRIPTS = { "setup", "teardown", "run" }

local function git(dir, args, timeout)
  return vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true, timeout = timeout }):wait()
end

local function out(result)
  return result.code == 0 and vim.trim(result.stdout) or nil
end

local function is_command_list(value)
  return vim.islist(value) and #value > 0 and vim.iter(value):all(function(command)
    return type(command) == "string"
  end)
end

-- Copies setup, teardown and run from dir's .isovim/config.json or .superset/config.json into its
-- repo's config, once: not when the config already has any of them or records an earlier import,
-- and never over a file that isn't a JSON object. A repo with neither file is looked at again next
-- time, so one added later is still imported.
---@return boolean imported
function M.import(dir)
  local name = repos.of(dir)
  local config = name and repos.config(name)
  if not config or config.imported_from ~= nil then
    return false
  end
  for _, key in ipairs(SCRIPTS) do
    if config[key] ~= nil then
      return false
    end
  end
  local own, path = require("isovim.scripts").config(dir)
  if not own then
    return false
  end
  for _, key in ipairs(SCRIPTS) do
    if is_command_list(own[key]) then
      config[key] = own[key]
    end
  end
  config.imported_from = path
  config.imported_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  repos.set_config(name, config)
  return true
end

local function resolve(name, commands)
  if not is_command_list(commands) then
    return nil
  end
  local folder = repos.dir(name)
  return vim.tbl_map(function(command)
    local first, rest = command:match("^%s*(%S+)(.*)$")
    local path = first and not vim.startswith(first, "/") and vim.fs.normalize(folder .. "/" .. first)
    local stat = path and vim.uv.fs_stat(path)
    return stat and stat.type == "file" and vim.fn.shellescape(path) .. rest or command
  end, commands)
end

-- One of the repo's scripts (setup, teardown, run, worktree_setup), with sibling scripts as absolute
-- paths; nil when its config has none.
---@return string[]?
function M.commands(name, which)
  local config = repos.config(name)
  return config and resolve(name, config[which])
end

---@return string[]?
function M.action(name, action)
  local config = repos.config(name)
  return config and type(config.actions) == "table" and resolve(name, config.actions[action]) or nil
end

-- A checkout of the repo here: the first of the projects workspaces used or the clones found
-- (store.projects) whose origin is the repo.
local function find_checkout(name)
  for _, project in ipairs(store.projects()) do
    local dir = vim.fs.normalize(project)
    if repos.of(dir) == name then
      return dir
    end
  end
end

-- ~/.isovim/repos/<name>/base-clone, a clone of origin that worktrees and read-only agents will
-- start from. It's cloned from origin with checkout (default: one found here) as --reference and
-- then --dissociate'd, so only what the checkout lacks crosses the network, its refs are origin's
-- (none of the checkout's own branches), and it stands alone once made: removing or gc-ing the
-- checkout can't break it. It's left detached at origin's default branch, so it holds no branch a
-- worktree might want. Cloned into a temp dir and renamed in, so a failed clone never looks made.
-- Already made, it's fetched instead.
---@return string? path, string? err
function M.base(name, checkout)
  local path = repos.dir(name) .. "/base-clone"
  if vim.fn.isdirectory(path .. "/.git") == 1 then
    local fetched = git(path, { "fetch", "--quiet", "--prune", "origin" })
    if fetched.code ~= 0 then
      return nil, vim.trim(fetched.stderr)
    end
    return path
  end
  checkout = checkout or find_checkout(name)
  if not checkout then
    return nil, ("no checkout of %s found here; name one"):format(name)
  elseif repos.of(checkout) ~= name then
    return nil, ("%s is not a checkout of %s"):format(checkout, name)
  end
  local url = out(git(checkout, { "remote", "get-url", "origin" }))
  local objects = out(git(checkout, { "rev-parse", "--path-format=absolute", "--git-common-dir" }))
  local tmp = ("%s.%d.tmp"):format(path, vim.uv.os_getpid())
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  -- A partial clone's objects can't be borrowed (the clone fails on its missing bases): the base
  -- clone is cloned from origin with the same filter instead.
  local filter = out(git(checkout, { "config", "--get", "remote.origin.partialclonefilter" }))
  local clone = filter and { "git", "clone", "--quiet", "--filter=" .. filter, url, tmp }
    or { "git", "clone", "--quiet", "--reference", objects, "--dissociate", url, tmp }
  local cloned = vim.system(clone, { text = true }):wait()
  if cloned.code ~= 0 then
    vim.fn.delete(tmp, "rf")
    return nil, vim.trim(cloned.stderr)
  end
  local branch = out(git(tmp, { "symbolic-ref", "--quiet", "--short", "HEAD" }))
  git(tmp, { "checkout", "--quiet", "--detach" })
  if branch then
    git(tmp, { "branch", "--quiet", "-D", branch })
  end
  -- Another call may have made it meanwhile; theirs stands.
  if not vim.uv.fs_rename(tmp, path) then
    vim.fn.delete(tmp, "rf")
  end
  if vim.fn.isdirectory(path .. "/.git") == 0 then
    return nil, "could not move the clone into " .. path
  end
  return path
end

-- ~/.iso/<name>/, where the repo's work lives, with iso/ (and its transcripts/) made if missing.
function M.work(name)
  local dir = ("%s/%s"):format(store.work, name)
  vim.fn.mkdir(dir .. "/iso/transcripts", "p")
  return dir
end

return M
