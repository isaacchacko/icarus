-- A workspace's scripts, in Superset's format so repos set up for Superset work unchanged: "setup",
-- "teardown" and "run" command lists, run in the workspace's checkout with Superset's variables set.
-- They come from the repo's config (isovim.repoconf), into which the repo's own .isovim/config.json or
-- .superset/config.json is imported once; a script the config lacks is still read from those files.
local M = {}

-- The repo's own scripts file in dir, and its path.
---@return {setup?: string[], teardown?: string[], run?: string[]}?, string?
function M.config(dir)
  for _, name in ipairs({ ".isovim/config.json", ".superset/config.json" }) do
    local path = dir .. "/" .. name
    local ok, lines = pcall(vim.fn.readfile, path)
    if ok then
      local decoded, config = pcall(vim.json.decode, table.concat(lines, "\n"))
      if decoded and type(config) == "table" then
        return config, path
      end
    end
  end
end

---@return string[]?
local function commands(dir, which)
  local repoconf, name = require("isovim.repoconf"), require("isovim.repos").of(dir)
  if name then
    repoconf.import(dir)
    local configured = repoconf.commands(name, which)
    if configured then
      return configured
    end
  end
  local config = M.config(dir)
  local listed = config and config[which]
  return type(listed) == "table" and #listed > 0 and listed or nil
end

-- The commands of one script as a shell line, with Superset's variables; nil if there are none.
---@param root string the repo's main checkout
function M.line(dir, root, name, which)
  local listed = commands(dir, which)
  if not listed then
    return nil
  end
  local env = {
    SUPERSET_ROOT_PATH = root,
    SUPERSET_WORKSPACE_PATH = dir,
    SUPERSET_WORKSPACE_NAME = name,
  }
  local exports = {}
  for key, value in pairs(env) do
    exports[#exports + 1] = ("export %s=%s"):format(key, vim.fn.shellescape(value))
  end
  table.sort(exports)
  return table.concat(exports, "; ") .. "; " .. table.concat(listed, " && ")
end

-- Runs a workspace's setup or run script as a terminal of its own, named after it, which ends in a
-- shell so the output stays; running it again restarts it. Returns the agent id, or nil if the
-- repo has no such script.
function M.start(ws, which)
  local store, panes, worktree = require("isovim.store"), require("isovim.panes"), require("isovim.worktree")
  local dir = store.dir(ws)
  local line = M.line(dir, worktree.repo_of(dir) or dir, store.name(ws), which)
  if not line then
    return nil
  end
  -- It reports like an agent: working while it runs, then finished (a toast, the Inbox).
  local hook = vim.fn.shellescape(panes.hook_script)
  local cmd = ("%s prompt </dev/null; %s; code=$?; %s stop </dev/null; "):format(hook, line, hook)
    .. ("[ $code -eq 0 ] || echo 'iso: the %s script failed (exit '$code')'; exec ${SHELL:-sh} -l"):format(which)
  local agent = store.agent(ws, which)
  if agent then
    store.update_agent(ws, which, { cmd = cmd })
    panes.stop(ws, which)
  else
    agent = store.add_agent(ws, { kind = "command", name = which, cmd = cmd })
  end
  panes.start(ws, store.agent(ws, agent.id), dir)
  return agent.id
end

return M
