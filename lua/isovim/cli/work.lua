-- A worker's and a router's own work: iso <role> wt makes the agent's worktree, and iso <role>
-- setup|teardown|run [<action>] runs its repo's scripts there, in a pane of their own. Each acts on
-- the agent running it, known by ancestry (root.caller), never by the cwd or the environment.
-- A new-layout agent (<owner>/<repo>/aN) gets its worktree lazily, at aN/w, from the repo's base
-- clone, on wt or on its first edit (iso __pretool); it starts in aN/, so `cd w` keeps it under
-- the same Claude project. An agent of a workspace has the workspace's checkout, as before.
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

-- The repo's worktree_setup, in the new worktree, its output on stderr (stdout is the path), or
-- appended to log.
---@return integer? code its exit code, nil when the repo has none
local function worktree_setup(path, base, agent, log)
  local line = require("isovim.scripts").line(path, base, agent.name, "worktree_setup", agent.repo)
  if not line then
    return nil
  end
  local file = log and io.open(log, "a")
  local function relay(_, data)
    if data then
      if file then
        file:write(data)
      else
        io.stderr:write(data)
      end
    end
  end
  if not file then
    note("running " .. agent.repo .. "'s worktree_setup in " .. path)
  end
  local result = vim.system({ "sh", "-c", line }, { cwd = path, stdout = relay, stderr = relay }):wait()
  if file then
    file:close()
  end
  return result.code
end

-- A new-layout agent's worktree, aN/w, made from its repo's base clone on a branch named for it
-- (or from a branch or PR) if it has none; the repo's worktree_setup runs in a new one. Offline (the
-- base clone's fetch fails), it's made from the clone's last-known origin refs, and that's logged.
---@param log? string where worktree_setup's output goes, else stderr
---@return string? path, string branch_or_err, boolean? made, integer? setup worktree_setup's exit code, string? offline
local function ensure_worktree(ws, agent, from, log)
  local path = store.dir(ws) .. "/" .. agent.id .. "/w"
  if vim.fn.isdirectory(path) == 1 then
    return path, git(path, { "branch", "--show-current" }) or ""
  elseif agent.read_only then
    return nil, ws .. "/" .. agent.id .. " is read-only: it works in the base clone and gets no worktree"
  elseif not agent.repo then
    return nil, ws .. "/" .. agent.id .. " is in no repo, so there's nothing to make a worktree of"
  end
  local repoconf, worktree = require("isovim.repoconf"), require("isovim.worktree")
  local checkout = agent.checkout and vim.fn.isdirectory(agent.checkout) == 1 and agent.checkout or nil
  local base, err = repoconf.base(agent.repo, checkout)
  local offline
  if not base then
    local clone = require("isovim.repos").dir(agent.repo) .. "/base-clone"
    if vim.fn.isdirectory(clone .. "/.git") == 0 then
      return nil, ("no base clone of %s: %s (iso repo base %s --from <checkout> makes one)"):format(agent.repo, err, agent.repo)
    end
    base = clone
    offline = ("could not fetch %s's origin (%s), so the worktree starts from the base clone's last-known origin refs")
      :format(agent.repo, (err or ""):gsub("\n", " "))
    local file = log and io.open(log, "a")
    if file then
      file:write(os.date("!%Y-%m-%dT%H:%M:%SZ "), offline, "\n")
      file:close()
    else
      note(offline)
    end
  end
  local made, branch
  if from then
    made, branch = worktree.create_from(base, from, path)
  else
    made, branch = worktree.create(base, agent.name, path)
  end
  if not made then
    return nil, "could not make the worktree: " .. branch
  end
  store.update_agent(ws, agent.id, { branch = branch })
  c.tui("require('isovim').refresh()")
  return path, branch, true, worktree_setup(path, base, agent, log), offline
end

-- For an agent moving in (isovim.move), whose worktree is made again here from its branch.
M.ensure_worktree = ensure_worktree

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
  local path, branch, made, setup = ensure_worktree(ws, agent, from)
  if not path then
    fail(branch)
  elseif not made then
    note(("%s already has its worktree%s"):format(address, branch ~= "" and (", on " .. branch) or ""))
  else
    note(("%s's worktree is made, on %s: cd w"):format(address, branch))
  end
  if setup and setup ~= 0 then
    fail(("worktree_setup failed (exit %d); the worktree is made, at %s"):format(setup, path))
  end
  out(path)
end

-- What iso __pretool tells the agent, and the edit or command refused (iso-hook passes exit code 2
-- on, which Claude reads as "blocked", with this as the reason).
local function refuse(text)
  io.stderr:write(text .. "\n")
  os.exit(2)
end

-- path, with symlinks resolved as far as it exists (a file Write makes doesn't yet).
local function real(path)
  local rest = {}
  local dir = path
  while dir and not vim.uv.fs_realpath(dir) do
    table.insert(rest, 1, vim.fs.basename(dir))
    local parent = vim.fs.dirname(dir)
    dir = parent ~= dir and parent or nil
  end
  local found = dir and vim.uv.fs_realpath(dir) or ""
  return #rest > 0 and vim.fs.joinpath(found, unpack(rest)) or found
end

-- path relative to root ("" for root itself), or nil when it isn't under it.
local function under(path, root)
  root = root and vim.uv.fs_realpath(root)
  if not root then
    return nil
  elseif path == root then
    return ""
  end
  return vim.startswith(path, root .. "/") and path:sub(#root + 2) or nil
end

-- git's subcommands that change a checkout or its refs, which a read-only agent may not run in the
-- base clone the others share. Listing ones (branch, tag, worktree list) and fetch are left alone.
local MUTATING_GIT = {}
for _, name in ipairs({ "commit", "push", "pull", "checkout", "switch", "reset", "merge", "rebase", "stash", "add",
  "rm", "mv", "restore", "clean", "cherry-pick", "revert", "am", "apply", "gc", "prune", "update-ref" }) do
  MUTATING_GIT[name] = true
end
local GIT_VALUED = { ["-C"] = true, ["-c"] = true, ["--git-dir"] = true, ["--work-tree"] = true, ["--namespace"] = true }

-- The first mutating git subcommand command runs, as `git <sub>`; nil when there's none. Each
-- part between ; & | and newlines is looked at for a git call and its subcommand.
local function mutating_git(command)
  for part in (command or ""):gmatch("[^;&|\n()]+") do
    local words = vim.split(vim.trim(part), "%s+", { trimempty = true })
    for i, word in ipairs(words) do
      if word == "git" or word:match("/git$") then
        local j = i + 1
        while words[j] and words[j]:sub(1, 1) == "-" do
          j = j + (GIT_VALUED[words[j]] and 2 or 1)
        end
        if words[j] and MUTATING_GIT[words[j]] then
          return "git " .. words[j]
        end
      end
    end
  end
end

-- iso __pretool edit|bash: iso-hook's PreToolUse for a new-layout agent (known by ancestry), the
-- tool call as JSON on stdin. A read-only agent's edits, and its git commands that would change
-- the base clone, are refused. Another agent's first edit in its repo (under aN/, the base clone or the clone it was
-- made from) makes its worktree, aN/w, and is refused with where to make it instead: the edit
-- would otherwise land outside it, so the agent makes it again under w/. An edit in the base clone
-- or in the checkout it was made from (yours) is always refused, worktree or not; anything else goes
-- through, as edits outside the repo always do.
M.__pretool = function(args)
  local which = args[1]
  local ws, id = require("isovim.root").caller()
  local agent = ws and store.v2(ws) and store.agent(ws, id)
  if not agent or agent.of or agent.kind == "terminal" or agent.kind == "command" then
    return
  end
  local ok, call = pcall(vim.json.decode, io.read("a") or "", { luanil = { object = true, array = true } })
  local input = ok and type(call) == "table" and type(call.tool_input) == "table" and call.tool_input or {}
  if which == "bash" then
    local git_call = agent.read_only and mutating_git(input.command)
    if git_call then
      refuse(("isovim refused this command: you are a read-only agent, working in %s's base clone, which other agents share, and `%s` would change it. Read, search and run what only reads; for a change, ask whoever started you for an agent with a worktree.")
        :format(agent.repo or "your repo", git_call))
    end
    return
  end
  local tool = type(call) == "table" and call.tool_name or "this edit"
  if agent.read_only then
    refuse(("isovim refused %s: you are a read-only agent, and your edits are refused. Read and search what you need; for a change, ask whoever started you for an agent with a worktree.")
      :format(tool))
  end
  local file = input.file_path or input.notebook_path
  if type(file) ~= "string" or file == "" then
    return
  end
  local cwd = type(call.cwd) == "string" and call.cwd or vim.uv.cwd()
  file = real(vim.fs.normalize(file:sub(1, 1) == "/" and file or vim.fs.joinpath(cwd, file)))
  local own = store.dir(ws) .. "/" .. agent.id
  local w = own .. "/w"
  local base = agent.repo and require("isovim.repos").dir(agent.repo) .. "/base-clone"
  local checkout = agent.checkout and vim.fn.isdirectory(agent.checkout) == 1 and agent.checkout or nil
  local in_base = under(file, base)
  local in_checkout = not in_base and checkout and under(file, checkout) or nil
  local where = in_base and "the base clone is shared and never edited"
    or ("%s is your user's own checkout, which agents never edit"):format(checkout)
  if vim.fn.isdirectory(w) == 1 then
    local rel = in_base or in_checkout
    if rel then
      refuse(("isovim refused %s: %s. Your worktree is %s: make the edit to %s."):format(tool, where, w, vim.fs.joinpath(w, rel)))
    end
    return
  end
  local rel = agent.repo and (under(file, own) or in_base or in_checkout)
  if not rel then
    return
  end
  local log = store.run_dir(ws) .. "/" .. agent.id .. ".worktree_setup.log"
  vim.fn.mkdir(store.run_dir(ws), "p")
  local path, branch, _, setup, offline = ensure_worktree(ws, agent, nil, log)
  if not path then
    -- With no worktree to send it to, an edit under aN/ goes through; never one in the base clone
    -- or your checkout.
    if in_base or in_checkout then
      refuse(("isovim refused %s: %s, and your worktree couldn't be made (%s)."):format(tool, where, branch))
    end
    return
  end
  local setup_note = setup and (setup == 0 and (" The repo's worktree_setup ran there (its output: %s)."):format(log)
    or (" The repo's worktree_setup failed there (exit %d; its output: %s)."):format(setup, log)) or ""
  local offline_note = offline and (" Offline: isovim " .. offline .. ".") or ""
  refuse(("isovim made your worktree for your first edit, at %s, on branch %s, and didn't make this edit.%s%s Work there from now on: cd %s, and make the edit to %s.")
    :format(w, branch, setup_note, offline_note, w, vim.fs.joinpath(w, rel)))
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
