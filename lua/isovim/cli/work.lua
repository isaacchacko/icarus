-- A worker's and a router's own work: iso <role> wt makes the agent's worktree, and iso <role>
-- setup|teardown|run [<action>] runs its repo's scripts there, in a pane of their own. Each acts on
-- the agent running it, known by ancestry (root.caller), never by the cwd or the environment.
-- A new-layout agent (<owner>/<repo>/aN) gets its worktree lazily, at aN/w, from the repo's base
-- clone; it starts in aN/, so `cd w` keeps it under the same Claude project. An agent of a
-- workspace has the workspace's checkout, as before.
local store = require("isovim.store")
local c = require("isovim.cli.common")

local out = c.out
local fail = c.fail
local option = c.option

local M = {}

local function note(text)
  io.stderr:write("iso: " .. text .. "\n")
end

-- The agent running this, and its record; from one of its script panes, that agent.
---@return string ws, isovim.Agent agent
local function me(action)
  local ws, id = require("isovim.root").caller()
  local agent = ws and store.agent(ws, id)
  if agent and agent.of then
    agent = store.agent(ws, agent.of)
  end
  if not agent then
    fail(("iso <role> %s acts on the agent running it, and this isn't one: run it from the agent's pane"):format(action))
  end
  return ws, agent
end

local function git(dir, args)
  local result = vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
  return result.code == 0 and vim.trim(result.stdout) or nil
end

-- The repo's worktree_setup, in the new worktree, its output on stderr (stdout is the path).
local function worktree_setup(path, base, agent)
  local line = require("isovim.scripts").line(path, base, agent.name, "worktree_setup", agent.repo)
  if not line then
    return
  end
  note("running " .. agent.repo .. "'s worktree_setup in " .. path)
  local function relay(_, data)
    if data then
      io.stderr:write(data)
    end
  end
  local result = vim.system({ "sh", "-c", line }, { cwd = path, stdout = relay, stderr = relay }):wait()
  if result.code ~= 0 then
    fail(("worktree_setup failed (exit %d); the worktree is made, at %s"):format(result.code, path))
  end
end

-- iso <role> wt [--from <branch|PR>]: the agent's worktree, made if it has none, and its path.
function M.wt(args)
  local from = option(args, "--from")
  local ws, agent = me("wt")
  local address = ws .. "/" .. agent.id
  if not store.v2(ws) then
    local dir = store.dir(ws)
    if store.branch(ws) and dir ~= store.path(ws) then
      note(("%s works in its workspace's worktree, on %s"):format(address, store.branch(ws)))
      out(dir)
      return
    end
    fail(("%s is a workspace's agent, which works in the workspace's dir (%s); a workspace gets a worktree when it's made: iso new <name> --dir <repo> --worktree [--from <branch|PR>]")
      :format(address, store.home_relative(dir)))
  end
  local path = store.dir(ws) .. "/" .. agent.id .. "/w"
  if vim.fn.isdirectory(path) == 1 then
    local branch = git(path, { "branch", "--show-current" })
    note(("%s already has its worktree%s"):format(address, branch and branch ~= "" and (", on " .. branch) or ""))
    out(path)
    return
  end
  if not agent.repo then
    fail(address .. " is in no repo, so there's nothing to make a worktree of")
  end
  local repoconf, worktree = require("isovim.repoconf"), require("isovim.worktree")
  local checkout = agent.checkout and vim.fn.isdirectory(agent.checkout) == 1 and agent.checkout or nil
  local base, err = repoconf.base(agent.repo, checkout)
  if not base then
    fail(("no base clone of %s: %s (iso repo base %s --from <checkout> makes one)"):format(agent.repo, err, agent.repo))
  end
  local made, branch
  if from then
    made, branch = worktree.create_from(base, from, path)
  else
    made, branch = worktree.create(base, agent.name, path)
  end
  if not made then
    fail("could not make the worktree: " .. branch)
  end
  store.update_agent(ws, agent.id, { branch = branch })
  note(("%s's worktree is made, on %s: cd w"):format(address, branch))
  c.tui("require('isovim').refresh()")
  worktree_setup(path, base, agent)
  out(path)
end

-- Runs one of the agent's repo scripts in a pane named after it, under Terminals.
local function run(which, action)
  local ws, agent = me(action)
  local scripts = require("isovim.scripts")
  local pane, dir = scripts.start(ws, which, store.v2(ws) and agent.id or nil)
  if not pane then
    local repo = agent.repo or require("isovim.repos").of(store.work_dir(ws, agent.id))
    local kind = scripts.names[which] and (which .. " script") or ("action " .. which)
    fail(("%s has no %s%s"):format(repo or (ws .. "/" .. agent.id), kind,
      repo and (" in " .. require("isovim.repos").dir(repo) .. "/config.json") or " (it's in no repo)"))
  end
  c.tui("require('isovim').refresh()")
  local role, pane_address = store.role(agent), ws .. "/" .. pane
  out(("%s runs in %s, in %s: iso %s peek %s shows it, iso %s wait %s waits for it to finish")
    :format(which, pane_address, dir, role, pane_address, role, pane_address))
end

function M.setup()
  run("setup", "setup")
end

function M.teardown()
  run("teardown", "teardown")
end

-- iso <role> run [<action>]: the repo's run script, or one of its actions.
function M.run(args)
  run(args[1] or "run", "run")
end

return M
