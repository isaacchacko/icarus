-- A workspace's scripts, in Superset's format so repos set up for Superset work unchanged: "setup",
-- "teardown" and "run" command lists, run in the workspace's checkout with Superset's variables set.
-- They come from the repo's config (isovim.repoconf), into which the repo's own .isovim/config.json or
-- .superset/config.json is imported once; a script the config lacks is still read from those files.
-- Any other name is one of the config's actions. A new-layout agent's run in its work dir
-- (store.work_dir: its worktree aN/w, else aN), by iso <role> setup|teardown|run (isovim.cli.work).
local M = {}

-- The scripts with a name of their own; any other name is an action.
M.names = { setup = true, teardown = true, run = true, worktree_setup = true }

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

---@param repo? string the repo's name, when dir may not say (a new-layout agent's dir before its worktree)
---@param lookup? boolean only read: no import from dir's own files (a teardown, whose dir may hold anything)
---@return string[]?
local function commands(dir, which, repo, lookup)
  local repoconf = require("isovim.repoconf")
  local name = repo or require("isovim.repos").of(dir)
  if name then
    if not lookup then
      repoconf.import(dir)
    end
    local configured
    if M.names[which] then
      configured = repoconf.commands(name, which)
    else
      configured = repoconf.action(name, which)
    end
    if configured then
      return configured
    end
  end
  local config = M.names[which] and M.config(dir)
  local listed = config and config[which]
  return type(listed) == "table" and #listed > 0 and listed or nil
end

-- The commands of one script (or action) as a shell line, with Superset's variables; nil if there
-- are none.
---@param root string the repo's main checkout
---@param repo? string the repo's name, as for commands
---@param lookup? boolean as for commands
function M.line(dir, root, name, which, repo, lookup)
  local listed = commands(dir, which, repo, lookup)
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

-- Runs a script or action as a terminal of its own, named after it, which ends in a shell so the
-- output stays; running it again restarts it. A workspace's runs in its checkout. In a repo key,
-- `owner` is the aN it runs for: it runs in that agent's work dir, and is a pane of its own (an aN
-- too) with `of` naming the agent. Its record says which script it runs, which lists it under
-- Terminals. Returns the pane's agent id and dir, or nil if the repo has no such script.
---@param owner? string the agent it runs for, in a repo key
---@return string? agent, string? dir
function M.start(ws, which, owner)
  local store, panes, worktree = require("isovim.store"), require("isovim.panes"), require("isovim.worktree")
  local v2 = store.v2(ws)
  local record = v2 and owner and store.agent(ws, owner)
  if v2 and not record then
    return nil
  end
  local dir = v2 and store.work_dir(ws, owner) or store.dir(ws)
  local name = v2 and record.name or store.name(ws)
  local line = M.line(dir, worktree.repo_of(dir) or dir, name, which, v2 and record.repo or nil)
  if not line then
    return nil
  end
  -- It reports like an agent: working while it runs, then finished (a toast, the Inbox).
  local hook = vim.fn.shellescape(panes.hook_script)
  local cmd = ("%s prompt </dev/null; %s; code=$?; %s stop </dev/null; "):format(hook, line, hook)
    .. ("[ $code -eq 0 ] || echo 'iso: the %s script failed (exit '$code')'; exec ${SHELL:-sh} -l"):format(which)
  local agent = vim.iter(store.agents(ws)):find(function(agent)
    return M.of(agent) == which and agent.of == (v2 and owner or nil) and (v2 or agent.id == which)
  end)
  if agent then
    store.update_agent(ws, agent.id, { cmd = cmd, script = which })
    panes.stop(ws, agent.id)
  else
    local err
    agent, err = store.add_agent(ws, { kind = "command", name = which, cmd = cmd, script = which, of = v2 and owner or nil })
    if not agent then
      error(err)
    end
  end
  panes.start(ws, store.agent(ws, agent.id), dir)
  return agent.id, dir
end

-- The script a pane started by M.start runs ("setup", "run", an action), from its record; nil for any
-- other agent. A pane made before records said so is known by the line M.start gave it.
---@param agent isovim.Agent
function M.of(agent)
  if agent.kind ~= "command" then
    return nil
  end
  return agent.script or (agent.cmd and agent.cmd:match("echo 'iso: the (%w+) script failed")) or nil
end

return M
