-- A worker's and a router's own work: iso <role> wt makes the agent's worktree, and iso <role>
-- setup|teardown|run [<action>] runs its repo's scripts there, in a pane of their own. Each acts on
-- the agent running it, known by ancestry (root.caller), never by the cwd or the environment.
-- A new-layout agent (<owner>/<repo>/aN) gets its worktree lazily, at aN/<repo>-aN (store.worktree_name,
-- with aN/w a symlink to it), from the repo's base clone, on wt or on its first edit (iso __pretool);
-- it starts in aN/, so cd-ing there keeps it under the same Claude project. Everything handed to the
-- agent or a script names the real path, never w/. An agent of a workspace has the workspace's
-- checkout, as before.
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
  local line = require("isovim.scripts").line(path, base, agent.name, "worktree_setup", agent.repo, nil,
    vim.fs.basename(path))
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

-- A new-layout agent's worktree, aN/<repo>-aN with aN/w linked to it, made from its repo's base
-- clone on a branch named for it (or from a branch or PR) if it has none; the repo's worktree_setup
-- runs in a new one. Offline (the base clone's fetch fails), it's made from the clone's last-known
-- origin refs, and that's logged. The path returned is the real one.
---@param log? string where worktree_setup's output goes, else stderr
---@return string? path, string branch_or_err, boolean? made, integer? setup worktree_setup's exit code, string? offline
local function ensure_worktree(ws, agent, from, log)
  local existing = store.worktree(ws, agent.id)
  if existing then
    return existing, git(existing, { "branch", "--show-current" }) or ""
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
  local own = store.dir(ws) .. "/" .. agent.id
  local name = store.worktree_name(ws, agent.id)
  local path = own .. "/" .. name
  local made, branch
  if from then
    made, branch = worktree.create_from(base, from, path)
  else
    made, branch = worktree.create(base, agent.name, path)
  end
  if not made then
    return nil, "could not make the worktree: " .. branch
  end
  M.link_w(own, name)
  store.update_agent(ws, agent.id, { branch = branch })
  c.tui("require('isovim').refresh()")
  return path, branch, true, worktree_setup(path, base, agent, log), offline
end

-- For an agent moving in (isovim.move), whose worktree is made again here from its branch.
M.ensure_worktree = ensure_worktree

-- aN/w, a relative symlink to the worktree's dir name, unless something else is there already.
function M.link_w(own, name)
  local w = own .. "/w"
  local stat = vim.uv.fs_lstat(w)
  if stat and stat.type == "link" then
    os.remove(w)
  elseif stat then
    return
  end
  vim.uv.fs_symlink(name, w)
end

-- Whether the agent's repo has a setup script and it has never run for this agent: no record of
-- its run, nor a setup pane of the agent's (one from before the record).
local function setup_unrun(ws, agent, path)
  if agent.setup_ran or not require("isovim.scripts").line(path, path, agent.name, "setup", agent.repo, true) then
    return false
  end
  return not vim.iter(store.agents(ws)):any(function(pane)
    return pane.of == agent.id and require("isovim.scripts").of(pane) == "setup"
  end)
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
  local path, branch, made, setup = ensure_worktree(ws, agent, from)
  if not path then
    fail(branch)
  elseif not made then
    note(("%s already has its worktree%s"):format(address, branch ~= "" and (", on " .. branch) or ""))
  else
    note(("%s's worktree is made, on %s: cd %s"):format(address, branch, path))
  end
  if setup and setup ~= 0 then
    fail(("worktree_setup failed (exit %d); the worktree is made, at %s"):format(setup, path))
  end
  if setup_unrun(ws, agent, path) then
    note(("%s has a setup script that hasn't run in this worktree, and never runs by itself: iso %s setup runs it")
      :format(agent.repo, store.role(agent)))
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

-- The clone of repo that path is in (the top of the nearest enclosing dir holding a .git whose
-- origin is repo: a worktree, or a submodule's parent, too) and path relative to it; nil when none is.
---@return string? top, string? rel
local function clone_of(path, repo)
  local dir = path
  while dir and dir ~= "" do
    if vim.uv.fs_stat(dir .. "/.git") and require("isovim.repos").of(dir) == repo then
      return dir, under(path, dir)
    end
    local parent = vim.fs.dirname(dir)
    dir = parent ~= dir and parent or nil
  end
end

-- The clone of a repo isovim knows (its key has a dir under ~/.isovim/repos) that path is in, other
-- than repo: the nearest enclosing dir holding a .git whose origin is such a repo, its key, and path
-- relative to it; nil when none is. Repos isovim doesn't know (~/.clu/discs, dotfiles) are never one.
---@return string? top, string? key, string? rel
local function known_clone(path, repo)
  local repos = require("isovim.repos")
  local dir = path
  while dir and dir ~= "" do
    if vim.uv.fs_stat(dir .. "/.git") then
      local key = repos.of(dir)
      if key and key ~= repo and vim.fn.isdirectory(repos.dir(key)) == 1 then
        return dir, key, under(path, dir)
      end
    end
    local parent = vim.fs.dirname(dir)
    dir = parent ~= dir and parent or nil
  end
end

-- Whether path is somewhere the agent (aN in ws) never edits: the base clone, its record's checkout,
-- any other clone or worktree of its repo outside its own worktree (yours anywhere, or another
-- agent's), whatever its record says, or a clone of any other repo isovim knows, for every agent (general/ and
-- root/ ones too). Returns path relative to that clone, why, and the other repo's key when it's that;
-- nil when it's none.
---@return string? rel, string? why, string? other
local function forbidden(path, ws, agent)
  local mine = store.worktree(ws, agent.id)
  if mine and under(path, mine) then
    return nil
  end
  local base = agent.repo and require("isovim.repos").dir(agent.repo) .. "/base-clone"
  local rel = under(path, base)
  if rel then
    return rel, "the base clone is shared and never edited"
  end
  local checkout = agent.checkout and vim.fn.isdirectory(agent.checkout) == 1 and agent.checkout or nil
  rel = checkout and under(path, checkout)
  if rel then
    return rel, ("%s is your user's own checkout, which agents never edit"):format(checkout)
  end
  local top
  if agent.repo then
    top, rel = clone_of(path, agent.repo)
  end
  if top then
    return rel, ("%s is a clone of %s outside your worktree (your user's, or another agent's), which agents never edit")
      :format(top, agent.repo)
  end
  local key
  top, key, rel = known_clone(path, agent.repo)
  if top then
    return rel, ("%s is a clone of %s, a repo isovim knows, and agents never edit a clone of one (your user's, or another agent's), only their own worktree of it")
      :format(top, key), key
  end
end

-- What to do instead of changing a clone of other, a known repo that isn't the agent's.
local function spawn_into(agent, other)
  return ("To change %s, spawn an agent into it: iso %s spawn --repo %s <task> (or --repo <that clone's dir>, when no workspace here works in %s yet).")
    :format(other, store.role(agent), other, other)
end

-- git's subcommands that change a checkout or its refs, which a read-only agent may not run in the
-- base clone the others share, and no agent runs in a clone of its repo outside its own worktree.
-- Listing ones (branch, tag, worktree list) and fetch are left alone.
local MUTATING_GIT = {}
for _, name in ipairs({ "commit", "push", "pull", "checkout", "switch", "reset", "merge", "rebase", "stash", "add",
  "rm", "mv", "restore", "clean", "cherry-pick", "revert", "am", "apply", "gc", "prune", "update-ref" }) do
  MUTATING_GIT[name] = true
end
local GIT_VALUED = { ["-C"] = true, ["-c"] = true, ["--git-dir"] = true, ["--work-tree"] = true, ["--namespace"] = true }
local GIT_DIRS = { ["-C"] = true, ["--git-dir"] = true, ["--work-tree"] = true }

-- Each mutating git call command makes, as {sub = "git <sub>", dir = the dir it acts on}: cwd, as a
-- cd or pushd earlier in the command moves it, or what -C, --git-dir or --work-tree names. Each part
-- between ; & | ( ) and newlines is looked at for a cd, or a git call and its subcommand.
local function mutating_git(command, cwd)
  local calls = {}
  local function at(dir, word)
    word = word:gsub("^['\"]", ""):gsub("['\"]$", "")
    word = word == "~" and (vim.env.HOME or "/") or word:gsub("^~/", (vim.env.HOME or "") .. "/")
    return word:sub(1, 1) == "/" and word or vim.fs.joinpath(dir, word)
  end
  for part in (command or ""):gmatch("[^;&|\n()]+") do
    local words = vim.split(vim.trim(part), "%s+", { trimempty = true })
    if (words[1] == "cd" or words[1] == "pushd") and words[2] ~= "-" then
      cwd = words[2] and at(cwd, words[2]) or vim.env.HOME or cwd
    end
    for i, word in ipairs(words) do
      if word == "git" or word:match("/git$") then
        local dir, j = cwd, i + 1
        while words[j] and words[j]:sub(1, 1) == "-" do
          local flag, value = words[j]:match("^(%-%-[%w-]+)=(.*)$")
          if GIT_DIRS[flag or words[j]] and (value or words[j + 1]) then
            dir = at(dir, value or words[j + 1])
          end
          j = j + ((not value and GIT_VALUED[words[j]]) and 2 or 1)
        end
        if words[j] and MUTATING_GIT[words[j]] then
          calls[#calls + 1] = { sub = "git " .. words[j], dir = real(vim.fs.normalize(dir)) }
        end
      end
    end
  end
  return calls
end

-- iso __pretool edit|bash: iso-hook's PreToolUse for a new-layout agent (known by ancestry), the
-- tool call as JSON on stdin. A read-only agent's edits, and its git commands that would change
-- the base clone, are refused. Another agent's first edit in its repo (under aN/, or in any clone or
-- worktree of the repo: the base clone, the clone it was made from, yours anywhere, another agent's)
-- makes its worktree, aN/<repo>-aN, and is refused with where to make it instead: the edit would
-- otherwise land outside it, so the agent makes it again there. An edit in a clone of its repo
-- outside its own worktree is always refused, worktree or not and whatever its record says, and so
-- is a mutating git command there. So is any agent's (general/ and root/ ones too) in a clone of another repo isovim
-- knows, with word to spawn an agent into that repo; anything else goes through, as edits in repos
-- isovim doesn't know (~/.clu/discs, dotfiles) and outside any repo always do.
M.__pretool = function(args)
  local which = args[1]
  local ws, id = require("isovim.root").caller()
  local agent = ws and store.v2(ws) and store.agent(ws, id)
  if not agent or agent.of or agent.kind == "terminal" or agent.kind == "command" then
    return
  end
  local ok, call = pcall(vim.json.decode, io.read("a") or "", { luanil = { object = true, array = true } })
  call = ok and type(call) == "table" and call or {}
  local input = type(call.tool_input) == "table" and call.tool_input or {}
  local cwd = type(call.cwd) == "string" and call.cwd or vim.uv.cwd()
  local own = store.dir(ws) .. "/" .. agent.id
  local w = store.worktree(ws, agent.id)
  if which == "bash" then
    local calls = mutating_git(input.command, cwd)
    if agent.read_only and calls[1] then
      refuse(("isovim refused this command: you are a read-only agent, working in %s's base clone, which other agents share, and `%s` would change it. Read, search and run what only reads; for a change, ask whoever started you for an agent with a worktree.")
        :format(agent.repo or "your repo", calls[1].sub))
    end
    for _, git_call in ipairs(calls) do
      local _, why, other = forbidden(git_call.dir, ws, agent)
      if why then
        local there = other and spawn_into(agent, other) or w and ("Your worktree is %s: run it there."):format(w)
          or ("Make your worktree with iso %s wt (it prints its path) and run it there."):format(store.role(agent))
        refuse(("isovim refused this command: `%s` would change %s, and %s. %s"):format(git_call.sub, git_call.dir, why, there))
      end
    end
    return
  end
  local tool = call.tool_name or "this edit"
  if agent.read_only then
    refuse(("isovim refused %s: you are a read-only agent, and your edits are refused. Read and search what you need; for a change, ask whoever started you for an agent with a worktree.")
      :format(tool))
  end
  local file = input.file_path or input.notebook_path
  if type(file) ~= "string" or file == "" then
    return
  end
  file = real(vim.fs.normalize(file:sub(1, 1) == "/" and file or vim.fs.joinpath(cwd, file)))
  local in_clone, where, other = forbidden(file, ws, agent)
  if other then
    refuse(("isovim refused %s: %s. %s"):format(tool, where, spawn_into(agent, other)))
  end
  if w then
    if in_clone then
      refuse(("isovim refused %s: %s. Your worktree is %s: make the edit to %s."):format(tool, where, w, vim.fs.joinpath(w, in_clone)))
    end
    return
  end
  -- Under aN/ before the worktree exists, the path meant in it (so w/x or <repo>-aN/x is x).
  local mine = under(file, own)
  local name = store.worktree_name(ws, agent.id)
  for _, dir in ipairs({ "w", name }) do
    mine = mine and (mine == dir and "" or vim.startswith(mine, dir .. "/") and mine:sub(#dir + 2) or mine)
  end
  local rel = agent.repo and (mine or in_clone)
  if not rel then
    if in_clone then
      refuse(("isovim refused %s: %s."):format(tool, where))
    end
    return
  end
  local log = store.run_dir(ws) .. "/" .. agent.id .. ".worktree_setup.log"
  vim.fn.mkdir(store.run_dir(ws), "p")
  local path, branch, _, setup, offline = ensure_worktree(ws, agent, nil, log)
  if not path then
    -- With no worktree to send it to, an edit under aN/ goes through; never one in a clone of the repo.
    if in_clone then
      refuse(("isovim refused %s: %s, and your worktree couldn't be made (%s)."):format(tool, where, branch))
    end
    return
  end
  local setup_note = setup and (setup == 0 and (" The repo's worktree_setup ran there (its output: %s)."):format(log)
    or (" The repo's worktree_setup failed there (exit %d; its output: %s)."):format(setup, log)) or ""
  local offline_note = offline and (" Offline: isovim " .. offline .. ".") or ""
  refuse(("isovim made your worktree for your first edit, at %s, on branch %s, and didn't make this edit.%s%s Work there from now on: cd %s, and make the edit to %s.")
    :format(path, branch, setup_note, offline_note, path, vim.fs.joinpath(path, rel)))
end

-- The host ports a docker ps Ports column publishes ("0.0.0.0:5432->5432/tcp, :::8000-8001->...").
local function host_ports(column)
  local ports = {}
  for from, to in (column or ""):gmatch(":(%d+)%-?(%d*)%->") do
    for port = tonumber(from), tonumber(to ~= "" and to or from) do
      ports[port] = true
    end
  end
  return ports
end

-- Why setup in dir would collide with another stack running on this host (docker ps): one of the
-- same compose project, or one publishing a port that dir's compose file publishes (docker compose
-- config, run with the scripts' env); one line each. Containers of the stack dir runs already are
-- its own. Nothing when docker isn't there or doesn't answer in a few seconds.
---@return string[]
local function clashes(dir, env)
  if vim.fn.executable("docker") == 0 then
    return {}
  end
  local ps = vim.system({ "docker", "ps", "--format",
    '{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.project.working_dir"}}\t{{.Names}}\t{{.Ports}}' },
    { text = true, timeout = 3000 }):wait()
  if ps.code ~= 0 or vim.trim(ps.stdout or "") == "" then
    return {}
  end
  local mine = vim.uv.fs_realpath(dir) or dir
  local project = env.COMPOSE_PROJECT_NAME
  local wanted = {}
  local config = vim.system({ "docker", "compose", "config", "--format", "json" },
    { cwd = dir, env = env, text = true, timeout = 5000 }):wait()
  local ok, compose = pcall(vim.json.decode, config.code == 0 and config.stdout or "", { luanil = { object = true, array = true } })
  for _, service in pairs(ok and type(compose) == "table" and type(compose.services) == "table" and compose.services or {}) do
    for _, port in ipairs(type(service) == "table" and type(service.ports) == "table" and service.ports or {}) do
      local published = type(port) == "table" and tonumber(port.published)
      if published then
        wanted[published] = true
      end
    end
  end
  local lines, seen = {}, {}
  for line in ps.stdout:gmatch("[^\n]+") do
    local name_of, workdir, container, ports = unpack(vim.split(line, "\t", { plain = true }))
    local real = workdir ~= "" and (vim.uv.fs_realpath(workdir) or workdir) or nil
    local own = real and (real == mine or vim.startswith(real, mine .. "/"))
    if not own then
      local rel = real and under(real, store.work)
      local whose = rel and rel:match("^(.-/a%d+)/") or real or ("container " .. container)
      if project and name_of == project and not seen[whose] then
        seen[whose] = true
        lines[#lines + 1] = ("compose project %s is running already, from %s"):format(project, whose)
      end
      for port in pairs(host_ports(ports)) do
        if wanted[port] then
          wanted[port] = nil
          lines[#lines + 1] = ("port %d, which the compose file publishes, is taken by %s (%s)"):format(port, container, whose)
        end
      end
    end
  end
  return lines
end

-- Runs one of the agent's repo scripts in a pane named after it, under Terminals.
local function run(which, action)
  local ws, agent = me(action)
  local scripts = require("isovim.scripts")
  if which == "setup" and store.v2(ws) and agent.repo then
    local dir = store.work_dir(ws, agent.id)
    local env = scripts.env(dir, dir, agent.name, agent.repo, store.worktree_name(ws, agent.id))
    for _, line in ipairs(clashes(dir, env)) do
      note(("setup may collide with another stack: %s"):format(line))
    end
  end
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
