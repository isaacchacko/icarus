-- iso cutover (docs/design.md "Cutover"): v0 starts fresh rather than migrating. M.plan looks at the
-- legacy layout and changes nothing: the workspaces in ~/.isovim/workspaces and the archive, their
-- agents, the worktrees isovim made, their pins, PR registrations and tasks, and the repos they work
-- in. M.render writes the plan as the text the user approves. M.run carries it out in four steps and
-- stops at the first failure, so nothing is moved if a push failed:
--   1. each worktree with uncommitted work or unpushed commits is pushed to its origin, as a
--      wip/<ws>/<agent> branch. The uncommitted part goes as a snapshot commit (worktree.snapshot),
--      made without touching the checkout.
--   2. every legacy agent is stopped. New-layout agents keep running.
--   3. each repo they worked in gets its config (glyph and color, its scripts imported once), its
--      base clone and its work dir.
--   4. the old layout is moved, not deleted, into ~/.isovim/legacy-backup-<date>/, with a README
--      there saying how to undo it. Each worktree is repaired as soon as it's moved, so git still
--      knows it there, and locked, so git worktree prune (or gc's) never drops it. Then
--      config.json's enforce is set.
-- The dry run checks what the run needs first, and blocks the plan when it can't finish: each
-- push's origin, and for each repo to seed, its origin (the base clone is cloned or fetched from
-- it) and a place to clone into. A run that stops in step 4 leaves a backup with no plan in it;
-- the next run goes on into that one, and repairs and locks any worktree in a backup that git
-- lost track of or that isn't locked (moved by a run from before this was done).
-- Kept: the conversations in ~/.claude/projects, ~/.isovim/repos, events, config.json and the
-- new layout's agents, which keep running. Nothing is restarted: the legacy agents start cold.
local store = require("isovim.store")

local M = {}

M.plan_file = store.root .. "/cutover-plan.txt"
M.log_file = store.root .. "/cutover.log"

-- Reading must never write: no index refresh (status), no credential prompt.
local READ = { GIT_OPTIONAL_LOCKS = "0", GIT_TERMINAL_PROMPT = "0" }

local function git(dir, args, timeout)
  return vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true, timeout = timeout, env = READ }):wait()
end

local function out(result)
  return result.code == 0 and vim.trim(result.stdout) or nil
end

local function first_line(text)
  return vim.trim((text or ""):match("[^\n]*") or "")
end

local function read_json(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  local decoded, value = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  return decoded and type(value) == "table" and value or nil
end

local function short(path)
  return store.home_relative(path)
end

local function real(path)
  return vim.uv.fs_realpath(path) or path
end

-- The legacy workspaces under root (workspaces/ or archive/), by id.
local function workspaces(root, archived)
  local list = {}
  for id, kind in vim.fs.dir(root) do
    local meta = kind == "directory" and read_json(root .. "/" .. id .. "/.isovim.json")
    if meta then
      local pins = {}
      -- pinned is isovim's; pins and surfaced are what clu wrote before it.
      for _, key in ipairs({ "pinned", "pins", "surfaced" }) do
        for _, pin in ipairs(vim.islist(meta[key]) and meta[key] or {}) do
          if type(pin) == "table" and type(pin.path) == "string" then
            pins[#pins + 1] = pin
          end
        end
      end
      local agents = vim.islist(meta.agents) and meta.agents or { { id = "main", name = "main", kind = "claude" } }
      list[#list + 1] = {
        id = id,
        name = type(meta.name) == "string" and meta.name or id,
        path = root .. "/" .. id,
        dir = type(meta.dir) == "string" and vim.fs.normalize(meta.dir) or nil,
        repo = type(meta.repo) == "string" and vim.fs.normalize(meta.repo) or nil,
        agents = vim.tbl_filter(function(agent)
          return type(agent) == "table" and type(agent.id) == "string"
        end, agents),
        pins = pins,
        prs = vim.tbl_filter(function(pr)
          return type(pr) == "string"
        end, vim.islist(meta.prs) and meta.prs or {}),
        archived = archived or nil,
      }
    end
  end
  table.sort(list, function(a, b)
    return a.id < b.id
  end)
  return list
end

-- Every checkout under root (a dir holding .git), not looking inside one.
local function checkouts(root)
  local found = {}
  local function walk(dir, depth)
    if vim.uv.fs_stat(dir .. "/.git") then
      found[#found + 1] = dir
      return
    end
    if depth < 6 then
      for name, kind in vim.fs.dir(dir) do
        if kind == "directory" then
          walk(dir .. "/" .. name, depth + 1)
        end
      end
    end
  end
  if vim.fn.isdirectory(root) == 1 then
    walk(root, 0)
  end
  table.sort(found)
  return found
end

-- What git says of a checkout: linked (a worktree of main), its branch, whether it has uncommitted
-- changes and how many commits no origin branch has.
local function inspect_tree(path)
  local tree = { path = path }
  local dirs = out(git(path, { "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir" }))
  local gitdir, common = unpack(vim.split(dirs or "", "\n"))
  if not common then
    tree.problem = "git can't read it"
    return tree
  end
  tree.linked = gitdir ~= common
  tree.main = vim.fs.dirname(common)
  tree.branch = out(git(path, { "branch", "--show-current" }))
  tree.branch = tree.branch ~= "" and tree.branch or nil
  local status = out(git(path, { "status", "--porcelain" }))
  local head = out(git(path, { "rev-parse", "--verify", "--quiet", "HEAD" }))
  if not status or not head then
    tree.problem = head and "git status fails in it" or "it has no commits"
    return tree
  end
  tree.dirty = status ~= ""
  tree.origin = out(git(path, { "remote", "get-url", "origin" }))
  tree.unpushed = tree.origin and tonumber(out(git(path, { "rev-list", "--count", "HEAD", "--not", "--remotes=origin" })) or "") or 0
  return tree
end

-- The agent a workspace's work is pushed for: its first visible claude or codex agent, else its first.
local function owner(ws)
  for _, agent in ipairs(ws.agents) do
    if not agent.hidden and (agent.kind == "claude" or agent.kind == "codex") then
      return agent.id
    end
  end
  return ws.agents[1] and ws.agents[1].id or "main"
end

local function safe_ref(name)
  return (name:gsub("[^%w._/-]", "-"):gsub("/+", "/"):gsub("%.%.", "-"):gsub("^[/.-]+", ""):gsub("[/.]+$", ""))
end

-- The backups so far, legacy-backup-<date>[-n], in order.
local function backups()
  local list = {}
  for name, kind in vim.fs.dir(store.root) do
    local date, n = name:match("^legacy%-backup%-(%d+%-%d+%-%d+)%-?(%d*)$")
    if kind == "directory" and date then
      list[#list + 1] = { path = store.root .. "/" .. name, date = date, n = tonumber(n) or 1 }
    end
  end
  table.sort(list, function(a, b)
    if a.date ~= b.date then
      return a.date < b.date
    end
    return a.n < b.n
  end)
  return vim.tbl_map(function(b)
    return b.path
  end, list)
end

-- Where the old layout goes: the backup of a run that stopped partway (a finished one has its plan
-- in it), when none of rels is there yet; else legacy-backup-<date>, numbered when that's taken.
---@return string path, boolean? unfinished
local function backup_dir(rels)
  for _, path in ipairs(backups()) do
    local free = not vim.uv.fs_stat(path .. "/cutover-plan.txt") and vim.iter(rels):all(function(rel)
      return not vim.uv.fs_lstat(path .. "/" .. rel)
    end)
    if free then
      return path, true
    end
  end
  local base = ("%s/legacy-backup-%s"):format(store.root, os.date("%Y-%m-%d"))
  local path, n = base, 1
  while vim.uv.fs_stat(path) do
    n = n + 1
    path = base .. "-" .. n
  end
  return path
end

-- A linked worktree's admin dir in its main repo (from its .git file), and what that says of it:
-- whether it points back at path, and whether it's locked. nil when path's .git isn't such a file.
---@return {admin: string, there: boolean, known: boolean, locked: boolean}?
local function linked_state(path)
  local ok, lines = pcall(vim.fn.readfile, path .. "/.git")
  local admin = ok and (lines[1] or ""):match("^gitdir:%s*(.-)%s*$")
  if not admin then
    return nil
  end
  if not admin:match("^/") then
    admin = vim.fs.normalize(path .. "/" .. admin)
  end
  local state = { admin = admin, there = vim.fn.isdirectory(admin) == 1 }
  local back_ok, back = pcall(vim.fn.readfile, admin .. "/gitdir")
  local points = back_ok and vim.trim(back[1] or "") or ""
  state.known = state.there and points ~= "" and real(vim.fs.dirname(points)) == real(path)
  state.locked = state.there and vim.uv.fs_stat(admin .. "/locked") ~= nil
  return state
end

local TASK_ORDER = { "todo", "doing", "waiting", "blocked", "done" }

---@return table plan
function M.plan()
  local panes = require("isovim.panes")
  local repos = require("isovim.repos")
  local worktree = require("isovim.worktree")
  local plan = { host = require("isovim.remote").self(), pushes = {}, trees = {}, stops = {}, orphans = {}, seeds = {},
    moves = {}, blocked = {}, projects = {} }
  plan.live = workspaces(store.workspaces)
  plan.archived = workspaces(store.archive, true)

  -- Which agents are running: their tmux sessions.
  local sessions = panes.sessions()
  local known = {}
  for _, ws in ipairs(plan.live) do
    for _, agent in ipairs(ws.agents) do
      agent.running = (sessions[ws.id] or {})[agent.id] ~= nil
      known[ws.id .. "/" .. agent.id] = true
      if agent.running then
        plan.stops[#plan.stops + 1] = { ws = ws.id, agent = agent.id }
      end
    end
  end
  for ws, agents in pairs(sessions) do
    if not store.v2(ws) then
      for agent in pairs(agents) do
        if not known[ws .. "/" .. agent] then
          plan.orphans[#plan.orphans + 1] = { ws = ws, agent = agent }
        end
      end
    end
  end
  table.sort(plan.orphans, function(a, b)
    return a.ws .. "/" .. a.agent < b.ws .. "/" .. b.agent
  end)
  vim.list_extend(plan.stops, plan.orphans)

  -- The worktrees: every checkout under ~/.isovim/worktrees, and any workspace's dir that is a
  -- worktree elsewhere (pushed, but left where it is).
  local by_path = {}
  local function add_tree(path, outside)
    local key = real(path)
    if not by_path[key] then
      local tree = inspect_tree(path)
      tree.outside = outside or nil
      by_path[key] = tree
      plan.trees[#plan.trees + 1] = tree
    end
    return by_path[key]
  end
  for _, path in ipairs(checkouts(worktree.root)) do
    add_tree(path)
  end
  local inside = real(worktree.root) .. "/"
  for _, ws in ipairs(vim.list_extend(vim.list_extend({}, plan.live), plan.archived)) do
    local dir = ws.dir and vim.fn.isdirectory(ws.dir) == 1 and ws.dir
    if dir then
      local tree = by_path[real(dir)]
      if not tree and not vim.startswith(real(dir) .. "/", inside) then
        local linked = inspect_tree(dir)
        if linked.linked then
          tree = add_tree(dir, true)
        elseif not ws.archived and not linked.problem then
          plan.projects[#plan.projects + 1] = { ws = ws.id, dir = dir }
        end
      end
      if tree and not tree.ws then
        tree.ws, tree.ws_name, tree.agent, tree.archived = ws.id, ws.name, owner(ws), ws.archived
      end
    end
  end
  for _, tree in ipairs(plan.trees) do
    if tree.problem then
      goto continue
    end
    tree.push = tree.dirty or tree.unpushed > 0
    if tree.ws then
      tree.wip = ("wip/%s/%s"):format(tree.ws, safe_ref(tree.agent))
    else
      local rel = vim.startswith(real(tree.path), inside) and real(tree.path):sub(#inside + 1) or vim.fs.basename(tree.path)
      tree.wip = "wip/" .. safe_ref(tree.branch or rel)
    end
    if tree.push and not tree.origin then
      plan.blocked[#plan.blocked + 1] = ("%s has work to push and no origin to push it to"):format(short(tree.path))
    elseif tree.push then
      local remote = git(tree.path, { "ls-remote", "origin", "refs/heads/" .. tree.wip }, 30000)
      tree.reachable = remote.code == 0
      tree.remote_sha = tree.reachable and (remote.stdout:match("^(%x+)") or nil) or nil
      if not tree.reachable then
        tree.unreachable = first_line(remote.stderr ~= "" and remote.stderr or ("git exited " .. remote.code))
        plan.blocked[#plan.blocked + 1] = ("%s: its origin %s can't be reached (%s)"):format(short(tree.path), tree.origin,
          tree.unreachable)
      end
      plan.pushes[#plan.pushes + 1] = tree
    end
    ::continue::
  end

  -- The repos to seed: the ones the live workspaces and the worktrees work in, from the checkout
  -- each was made from (a worktree's main checkout), the first found for each repo.
  local seen = {}
  local function seed(dir)
    if not dir or vim.fn.isdirectory(dir) == 0 then
      return
    end
    local name = repos.of(dir)
    if not name or seen[name] then
      return
    end
    seen[name] = true
    local config = repos.config(name)
    local scripts = config and (config.imported_from ~= nil or config.setup ~= nil or config.teardown ~= nil or config.run ~= nil)
    local _, own = require("isovim.scripts").config(dir)
    plan.seeds[#plan.seeds + 1] = {
      name = name,
      checkout = dir,
      origin = out(git(dir, { "remote", "get-url", "origin" })),
      config = config == nil and "broken" or vim.uv.fs_stat(repos.dir(name) .. "/config.json") and "there" or "new",
      import = not scripts and config ~= nil and own or nil,
      base = repos.dir(name) .. "/base-clone",
      base_there = vim.fn.isdirectory(repos.dir(name) .. "/base-clone/.git") == 1,
      work = store.work .. "/" .. name,
      work_there = vim.fn.isdirectory(store.work .. "/" .. name .. "/iso") == 1,
    }
  end
  for _, ws in ipairs(plan.live) do
    local tree = ws.dir and by_path[real(ws.dir)]
    seed(ws.repo or (tree and tree.main) or ws.dir)
  end
  for _, tree in ipairs(plan.trees) do
    seed(tree.main)
  end
  table.sort(plan.seeds, function(a, b)
    return a.name < b.name
  end)
  -- Seeding must be able to finish before step 2 stops anyone: each base clone is cloned (or, when
  -- it's there, fetched) from origin.
  local reached = {}
  local function reach(dir, url)
    if reached[url] == nil then
      local remote = git(dir, { "ls-remote", "--quiet", "origin", "HEAD" }, 30000)
      reached[url] = remote.code == 0 or first_line(remote.stderr ~= "" and remote.stderr or ("git exited " .. remote.code))
    end
    return reached[url]
  end
  local function writable(path)
    while path ~= "/" and not vim.uv.fs_stat(path) do
      path = vim.fs.dirname(path)
    end
    return vim.uv.fs_access(path, "W") == true
  end
  for _, entry in ipairs(plan.seeds) do
    local from = entry.base_there and entry.base or entry.checkout
    local url = entry.base_there and out(git(entry.base, { "remote", "get-url", "origin" })) or entry.origin
    local why
    if not url then
      why = ("%s has no origin to %s from"):format(short(from), entry.base_there and "fetch" or "clone")
    else
      local ok = reach(from, url)
      if ok ~= true then
        why = ("its origin %s can't be reached (%s), so its base clone can't be %s"):format(url, ok,
          entry.base_there and "fetched" or "made")
      elseif not entry.base_there and vim.uv.fs_stat(entry.base) then
        why = ("%s is there and isn't a clone"):format(short(entry.base))
      elseif not entry.base_there and not writable(entry.base) then
        why = ("its base clone can't be made in %s: not writable"):format(short(vim.fs.dirname(entry.base)))
      elseif not writable(entry.work) then
        why = ("its work dir can't be made in %s: not writable"):format(short(vim.fs.dirname(entry.work)))
      end
    end
    if why then
      entry.problem = why
      plan.blocked[#plan.blocked + 1] = ("seeding %s: %s"):format(entry.name, why)
    end
  end

  -- What moves into the backup.
  local function move(rel, what)
    local from = store.root .. "/" .. rel
    if vim.uv.fs_lstat(from) then
      plan.moves[#plan.moves + 1] = { from = from, rel = rel, what = what }
    end
  end
  move("workspaces", ("%d workspaces"):format(#plan.live))
  move("archive", ("%d archived workspaces"):format(#plan.archived))
  local moved_trees = #vim.tbl_filter(function(tree)
    return not tree.outside
  end, plan.trees)
  move("worktrees", ("%d worktrees, each repaired and locked as it's moved, so git still knows it there"):format(moved_trees)
    .. " and git worktree prune leaves it")
  local legacy_runs = {}
  for name, kind in vim.fs.dir(store.run) do
    if kind == "directory" and name:match("^%x%x%x%x%x%x$") then
      legacy_runs[#legacy_runs + 1] = name
    end
  end
  table.sort(legacy_runs)
  for _, name in ipairs(legacy_runs) do
    move("run/" .. name, "a workspace's run state")
  end
  local ok, root_lines = pcall(vim.fn.readfile, store.root .. "/root")
  local root_file = ok and vim.trim(table.concat(root_lines, " ")) or ""
  plan.old_root = root_file ~= "" and root_file or nil
  move("root", "the old root pointer" .. (plan.old_root and (": " .. plan.old_root) or ""))
  move("session.json", "the TUI's open workspaces")
  plan.backup, plan.resumed = backup_dir(vim.tbl_map(function(m)
    return m.rel
  end, plan.moves))
  -- Earlier runs of this cutover that stopped partway (no plan in them) and that this run doesn't
  -- go on into: what they moved is there, and the README here puts it back too.
  plan.earlier = {}
  for _, path in ipairs(backups()) do
    local holds = vim.iter(vim.fs.dir(path)):any(function(name)
      return name ~= M.readme
    end)
    if path ~= plan.backup and holds and not vim.uv.fs_stat(path .. "/cutover-plan.txt") then
      plan.earlier[#plan.earlier + 1] = path
    end
  end
  for _, m in ipairs(plan.moves) do
    m.to = plan.backup .. "/" .. m.rel
  end

  -- Worktrees already in a backup that git lost track of or that aren't locked: moved by a run from
  -- before they were repaired and locked as they moved (or one that stopped between the two).
  plan.repairs, plan.lost = {}, {}
  for _, backup in ipairs(backups()) do
    for _, path in ipairs(checkouts(backup .. "/worktrees")) do
      local state = linked_state(path)
      if state and not state.there then
        plan.lost[#plan.lost + 1] = path
      elseif state and (not state.known or not state.locked) then
        plan.repairs[#plan.repairs + 1] = { path = path, repair = not state.known or nil, lock = not state.locked or nil }
      end
    end
  end

  -- The agents still in the old _/, while its move to general/ waits (isovim.migrate
  -- defers it while one is mid-turn, or while a running one's kind isn't logged in): new-layout
  -- agents too, which keep running and move once it can.
  plan.pending = {}
  local migrate = require("isovim.migrate")
  if migrate.pending() then
    local old = store.work .. "/_/iso/agents"
    for name, kind in vim.fs.dir(old) do
      local id = kind == "file" and name:match("^(a%d+)%.json$")
      if id then
        plan.pending[#plan.pending + 1] = { address = "_/" .. id }
      end
    end
    table.sort(plan.pending, function(a, b)
      return tonumber(a.address:match("%d+")) < tonumber(b.address:match("%d+"))
    end)
  end

  plan.clu = require("isovim.cluscan").scan()
  plan.clu_dir = require("isovim.cluscan").dir()

  -- What stays, for the record.
  local claude = vim.fs.normalize(vim.env.CLAUDE_CONFIG_DIR or "~/.claude") .. "/projects"
  plan.claude_projects = claude
  local v2 = 0
  for _, ws in ipairs(store.list()) do
    -- _/'s own are counted as pending.
    if store.v2(ws.id) and ws.id ~= store.OLD then
      v2 = v2 + #store.agents(ws.id)
    end
  end
  plan.v2_agents = v2 + #plan.pending
  local moving = { workspaces = true, archive = true, worktrees = true, root = true, ["session.json"] = true,
    ["cutover-plan.txt"] = true, ["cutover.log"] = true, run = true, repos = true, events = true, ["config.json"] = true }
  plan.rest = {}
  for name, kind in vim.fs.dir(store.root) do
    if not moving[name] and not name:match("^legacy%-backup%-") then
      plan.rest[#plan.rest + 1] = name .. (kind == "directory" and "/" or "")
    end
  end
  table.sort(plan.rest)
  return plan
end

local function tasks_line(agent)
  local counts = {}
  for _, task in ipairs(vim.islist(agent.tasks) and agent.tasks or {}) do
    local status = type(task) == "table" and task.status or "todo"
    counts[status] = (counts[status] or 0) + 1
  end
  local parts = {}
  for _, status in ipairs(TASK_ORDER) do
    if counts[status] then
      parts[#parts + 1] = ("%d %s"):format(counts[status], status)
    end
  end
  return #parts > 0 and table.concat(parts, ", ") or nil
end

local function tree_state(tree)
  if tree.problem then
    return tree.problem .. ": moved as it is"
  end
  local parts = {}
  if tree.dirty then
    parts[#parts + 1] = "uncommitted changes"
  end
  if tree.unpushed > 0 then
    parts[#parts + 1] = ("%d unpushed commit%s"):format(tree.unpushed, tree.unpushed == 1 and "" or "s")
  end
  return #parts > 0 and table.concat(parts, ", ") or "clean, every commit on origin"
end

---@return string
function M.render(plan)
  local lines = {}
  local function add(text, ...)
    lines[#lines + 1] = select("#", ...) > 0 and text:format(...) or text
  end
  add("iso cutover plan for %s (isovim home %s, work %s)", plan.host, short(store.root), short(store.work))
  add("Nothing has changed yet. iso cutover --yes does exactly this, and only while this file")
  add("matches a fresh dry run. It stops at the first failure: one in steps 1-3 moves nothing, and")
  add("one in step 4 leaves what it moved in the backup, whose README.md says how to put it back.")
  if #plan.blocked > 0 then
    add("")
    add("BLOCKED: iso cutover --yes refuses until these are fixed:")
    for _, why in ipairs(plan.blocked) do
      add("  - %s", why)
    end
  end

  add("")
  if not plan.clu then
    add("clu-system: none at %s", short(plan.clu_dir))
  else
    add("clu-system: %s (its bin, skills and hooks; discs aren't read)", short(plan.clu.dir))
    local function list(hits)
      for _, hit in ipairs(hits) do
        add("    %s:%d: %s: %s", hit.file, hit.line, hit.shown, hit.why)
      end
    end
    if #plan.clu.refused > 0 then
      add("  WARNING, refused once enforcement is on, so these fail after the cutover (they don't block it):")
      list(plan.clu.refused)
    else
      add("  nothing in them is refused once enforcement is on")
    end
    if #plan.clu.guarded > 0 then
      add("  legacy-only, guarded by clu's enforce check (they don't run once enforcement is on):")
      list(plan.clu.guarded)
    end
    if #plan.clu.named > 0 then
      add("  named, not run:")
      list(plan.clu.named)
    end
  end

  add("")
  add("Legacy workspaces: %d, and %d archived", #plan.live, #plan.archived)
  for _, ws in ipairs(vim.list_extend(vim.list_extend({}, plan.live), plan.archived)) do
    add("  %s  %s%s", ws.id, ws.name, ws.archived and "  (archived)" or "")
    add("    dir: %s%s", short(ws.dir or ws.path), ws.dir and "" or " (its own)")
    if ws.repo then
      add("    repo: %s", short(ws.repo))
    end
    for _, agent in ipairs(ws.agents) do
      local role = agent.role and agent.role ~= "worker" and (", " .. agent.role) or ""
      local state = ws.archived and "" or agent.running and ", running" or ", stopped"
      local tasks = tasks_line(agent)
      add("    agent %s (%s%s%s)%s", agent.id, agent.kind or "claude", role, state, tasks and ("  tasks: " .. tasks) or "")
    end
    for _, pin in ipairs(ws.pins) do
      add("    pin %s%s", pin.path, type(pin.label) == "string" and pin.label ~= "" and ("  \"" .. pin.label .. "\"") or "")
    end
    for _, pr in ipairs(ws.prs) do
      add("    PR %s", pr)
    end
  end
  add("  Their pins, PR registrations and tasks are dropped: v0 has none of them. They stay")
  add("  readable in the backup's .isovim.json files.")

  add("")
  add("1. Push work to wip/ branches (%d of %d worktrees)", #plan.pushes, #plan.trees)
  for _, tree in ipairs(plan.trees) do
    local whose = tree.ws and ("%s/%s, %s"):format(tree.ws, tree.agent, tree.ws_name) or "no workspace"
    add("  %s  (%s%s)", short(tree.path), whose, tree.branch and (", branch " .. tree.branch) or ", detached")
    if tree.push then
      local remote = tree.unreachable and "UNREACHABLE"
        or tree.remote_sha and ("already there at %s, which stays in its history"):format(tree.remote_sha:sub(1, 12))
        or "a new branch"
      add("    %s -> %s on %s (%s)", tree_state(tree), tree.wip, tree.origin or "no origin", remote)
    else
      add("    %s: nothing to push", tree_state(tree))
    end
    if tree.outside then
      add("    outside %s: left where it is", short(require("isovim.worktree").root))
    end
  end
  if #plan.trees == 0 then
    add("  (no worktrees)")
  end
  add("  Uncommitted work goes as one snapshot commit on top of HEAD; the checkout itself is left")
  add("  alone. Untracked files that aren't gitignored go in the snapshot too, so a .env that isn't")
  add("  gitignored is pushed to the wip branch: gitignore or move any secret first. Gitignored files")
  add("  (node_modules, a gitignored .env) aren't pushed; they stay in the backup.")

  add("")
  add("2. Stop the legacy agents (%d running); new-layout agents keep running", #plan.stops)
  for _, stop in ipairs(plan.stops) do
    add("  %s/%s%s", stop.ws, stop.agent, vim.tbl_contains(plan.orphans, stop) and "  (a tmux session with no workspace)" or "")
  end
  if #plan.stops == 0 then
    add("  (none running)")
  end

  add("")
  add("3. Seed the repos (%d)", #plan.seeds)
  for _, seed in ipairs(plan.seeds) do
    add("  %s, from %s (origin %s)", seed.name, short(seed.checkout), seed.origin or "none")
    local config = seed.config == "broken" and "isn't a JSON object: left alone"
      or seed.config == "there" and "kept" or "made, with a glyph and color"
    add("    config %s: %s%s", short(require("isovim.repos").dir(seed.name) .. "/config.json"), config,
      seed.import and ("; scripts imported from " .. short(seed.import)) or "")
    add("    base clone %s: %s", short(seed.base),
      seed.base_there and "already there, fetched" or ("cloned from origin, with %s as reference"):format(short(seed.checkout)))
    add("    work dir %s: %s", short(seed.work), seed.work_there and "already there" or "made")
  end
  if #plan.seeds == 0 then
    add("  (no repos)")
  end
  add("  config.json: kept, with the role prompts seeded where missing (%s/prompts), and", short(store.root))
  add("  \"enforce\": true added once everything else has run")

  add("")
  add("4. Move the old layout into %s/ (moved, not deleted)%s", short(plan.backup),
    plan.resumed and ", an earlier run's that stopped partway" or "")
  for _, move in ipairs(plan.moves) do
    add("  %s  %s", short(move.from), move.what)
  end
  if #plan.moves == 0 then
    add("  (nothing to move)")
  end
  for _, fix in ipairs(plan.repairs) do
    add("  %s: in a backup already; %s", short(fix.path), fix.repair and "repair it (git doesn't know it there) and lock it"
      or "lock it, so git worktree prune leaves it")
  end
  for _, path in ipairs(plan.lost) do
    add("  %s: git no longer knows it (pruned): its files are there, but it can't be repaired", short(path))
  end
  for _, path in ipairs(plan.earlier) do
    add("  %s/ holds what an earlier run that stopped partway moved: it's left there", short(path))
  end
  add("  %s/README.md then says how to undo all of it%s", short(plan.backup),
    #plan.earlier > 0 and (", from every backup above") or "")

  add("")
  add("Kept")
  add("  %s: the old conversations, untouched", short(plan.claude_projects))
  add("  %s/repos, %s/events, %s/config.json", short(store.root), short(store.root), short(store.root))
  add("  new-layout agents: %d under %s, and their run state", plan.v2_agents, short(store.work))
  if #plan.pending > 0 then
    add("    %d of them still in %s/_/: %s", #plan.pending, short(store.work), table.concat(vim.tbl_map(function(agent)
      return agent.address
    end, plan.pending), ", "))
    add("    _/ moves to general/ once none there is mid-turn and the running ones are logged in")
  end
  if #plan.rest > 0 then
    add("  also left as they are in %s: %s", short(store.root), table.concat(plan.rest, ", "))
  end
  for _, project in ipairs(plan.projects) do
    add("  %s: %s's project dir, yours, untouched", short(project.dir), project.ws)
  end

  add("")
  add("Afterwards nothing restarts. Only the legacy agents in step 2 are stopped, and they start cold")
  add("(iso spawn). New-layout agents keep running.")
  if plan.old_root then
    local host, named = plan.old_root:match("^([^:]+):(.+)$")
    local stopped = host == plan.host and vim.iter(plan.stops):any(function(stop)
      return stop.ws .. "/" .. stop.agent == named
    end)
    add("The old root pointer (%s) moves to the backup%s.", plan.old_root,
      host and host ~= plan.host and (": that agent is on " .. host .. ", which this cutover doesn't touch")
        or stopped and ": that agent is a legacy one, stopped in step 2 with the others" or "")
  end
  add("Enforcement is then on: role mismatches and agents running your commands are refused, and")
  add("the retired commands fail, naming what replaced them.")
  return table.concat(lines, "\n") .. "\n"
end

local function log(line)
  local file = io.open(M.log_file, "a")
  if file then
    file:write(os.date("%Y-%m-%dT%H:%M:%S "), line, "\n")
    file:close()
  end
  io.stdout:write(line, "\n")
end
M.log = log

-- Each step stops on its first failure, returning why.
local function push(plan)
  local worktree = require("isovim.worktree")
  for _, tree in ipairs(plan.pushes) do
    local sha = tree.dirty and worktree.snapshot(tree.path, ("iso cutover: uncommitted work of %s"):format(tree.ws and (tree.ws .. "/" .. tree.agent) or short(tree.path)))
      or out(git(tree.path, { "rev-parse", "HEAD" }))
    if not sha then
      return ("could not snapshot %s"):format(short(tree.path))
    end
    -- A wip branch already there (an earlier run's) stays in the new tip's history, so the push
    -- is a fast-forward and loses nothing.
    if tree.remote_sha then
      local fetched = vim.system({ "git", "-C", tree.path, "fetch", "--quiet", "origin", "refs/heads/" .. tree.wip },
        { text = true, timeout = 300000, env = { GIT_TERMINAL_PROMPT = "0" } }):wait()
      if fetched.code ~= 0 then
        return ("could not fetch %s from %s: %s"):format(tree.wip, tree.origin, first_line(fetched.stderr))
      end
      local there = out(git(tree.path, { "rev-parse", "FETCH_HEAD" }))
      if there and git(tree.path, { "merge-base", "--is-ancestor", there, sha }).code ~= 0 then
        local env = vim.tbl_extend("force", READ, { GIT_AUTHOR_NAME = "isovim", GIT_AUTHOR_EMAIL = "isovim@localhost",
          GIT_COMMITTER_NAME = "isovim", GIT_COMMITTER_EMAIL = "isovim@localhost" })
        sha = vim.system({ "git", "-C", tree.path, "commit-tree", sha .. "^{tree}", "-p", sha, "-p", there, "-m",
          ("iso cutover: %s, keeping what %s held"):format(short(tree.path), tree.wip) }, { text = true, env = env }):wait()
        sha = out(sha)
        if not sha then
          return ("could not join %s's work with %s"):format(short(tree.path), tree.wip)
        end
      end
    end
    local pushed = vim.system({ "git", "-C", tree.path, "push", "--quiet", "origin", sha .. ":refs/heads/" .. tree.wip },
      { text = true, timeout = 300000, env = { GIT_TERMINAL_PROMPT = "0" } }):wait()
    local there = pushed.code == 0 and out(git(tree.path, { "ls-remote", "origin", "refs/heads/" .. tree.wip }, 30000))
    if not there or not vim.startswith(there, sha) then
      return ("could not push %s to %s on %s: %s"):format(short(tree.path), tree.wip, tree.origin, first_line(pushed.stderr))
    end
    log(("pushed %s to %s on %s at %s"):format(short(tree.path), tree.wip, tree.origin, sha:sub(1, 12)))
  end
end

local function stop(plan)
  local panes = require("isovim.panes")
  for _, agent in ipairs(plan.stops) do
    panes.stop(agent.ws, agent.agent)
    if not vim.wait(5000, function()
      return not panes.running(agent.ws, agent.agent)
    end, 100) then
      return ("could not stop %s/%s"):format(agent.ws, agent.agent)
    end
    -- A session with no workspace has no run dir to move: leave none behind.
    local moving = vim.iter(plan.moves):any(function(move)
      return move.from == store.run_dir(agent.ws)
    end)
    if vim.tbl_contains(plan.orphans, agent) and not moving then
      os.remove(panes.stopped_file(agent.ws, agent.agent))
      vim.uv.fs_rmdir(store.run_dir(agent.ws))
    end
    log(("stopped %s/%s"):format(agent.ws, agent.agent))
  end
end

local function seed(plan)
  local repos, repoconf = require("isovim.repos"), require("isovim.repoconf")
  for _, entry in ipairs(plan.seeds) do
    repos.style(entry.name)
    if entry.import and repoconf.import(entry.checkout) then
      log(("imported %s's scripts from %s"):format(entry.name, short(entry.import)))
    end
    local base, err = repoconf.base(entry.name, entry.checkout)
    if not base then
      return ("could not make %s's base clone: %s"):format(entry.name, err)
    end
    repoconf.work(entry.name)
    log(("seeded %s: config, base clone %s, work dir %s"):format(entry.name, short(base), short(entry.work)))
  end
  local ok, err = pcall(require("isovim.config").seed_prompts)
  if not ok then
    return "could not seed the role prompts: " .. tostring(err)
  end
  log("seeded the role prompts into config.json")
end

M.readme = "README.md"

-- A moved worktree's main checkout still points at the old path until it's repaired; locked, git
-- worktree prune (and gc's, after three months) leaves it even if the backup moves.
local function keep(plan, path, repair)
  if repair then
    local repaired = vim.system({ "git", "-C", path, "worktree", "repair" }, { text = true }):wait()
    if repaired.code ~= 0 then
      log(("warning: git worktree repair in %s failed: %s"):format(short(path), first_line(repaired.stderr)))
    end
  end
  local state = linked_state(path)
  if state and state.there and not state.locked then
    local reason = ("isovim's legacy backup; %s/%s says how to undo the cutover"):format(plan.backup, M.readme)
    local locked = vim.system({ "git", "-C", path, "worktree", "lock", "--reason", reason, path }, { text = true }):wait()
    if locked.code ~= 0 then
      log(("warning: git worktree lock of %s failed: %s"):format(short(path), first_line(locked.stderr)))
    end
  end
  log(("kept %s: %srepaired and locked"):format(short(path), repair and "" or "already known, "))
end

local function shell(path)
  return vim.fn.shellescape(path)
end

-- The backup's README: how to put back what's in it, made from what's there, so it holds for a run
-- that stopped partway too.
local function write_readme(plan)
  local b = plan.backup
  local parts = vim.list_extend(vim.deepcopy(plan.earlier or {}), { b })
  local lines = {
    ("# The isovim cutover of %s: how to undo it"):format(plan.host),
    "",
    ("iso cutover moved the legacy layout here, out of %s, and turned enforcement on. Nothing"):format(store.root),
    "was deleted. If the cutover stopped partway, what it hadn't moved yet is still where it was,",
    "and this lists only what's in its backups.",
    "",
    "With the isovim TUI closed, in a plain shell:",
    "",
    ("1. Turn enforcement off: in %s/config.json delete the \"enforce\": true entry (and the"):format(store.root),
    "   comma before it). Until then, ISOVIM_ENFORCE=0 in front of a command turns it off for that one.",
    "2. Run these, in order:",
    "",
    "```sh",
    "# Empty dirs made since (the TUI makes workspaces/ and archive/ on start) would take the moves inside.",
    ("rmdir %s %s %s 2>/dev/null || true"):format(shell(store.workspaces), shell(store.archive), shell(store.root .. "/worktrees")),
  }
  if #parts > 1 then
    lines[#lines + 1] = ("# This cutover's runs moved it into %d backups: %s."):format(#parts,
      table.concat(vim.tbl_map(short, parts), ", "))
  end
  -- What a part holds goes back from the oldest backup holding it; a later backup's copy of the same
  -- thing is an empty dir the TUI made in between (or there's nothing to put back), left alone.
  local back = {}
  local function empty_dir(path)
    local stat = vim.uv.fs_lstat(path)
    return stat and stat.type == "directory" and vim.fs.dir(path)() == nil
  end
  local function mv(part, rel)
    local from = part .. "/" .. rel
    if not vim.uv.fs_lstat(from) or (back[rel] and empty_dir(from)) then
      return
    end
    if back[rel] then
      lines[#lines + 1] = ("# %s and %s both hold %s: put this one's contents back by hand"):format(short(back[rel]),
        short(part), rel)
      return
    end
    back[rel] = part
    lines[#lines + 1] = ("mv %s %s"):format(shell(from), shell(store.root .. "/" .. rel))
  end
  local runs, trees = {}, {}
  for _, part in ipairs(parts) do
    for name, kind in vim.fs.dir(part .. "/run") do
      if kind == "directory" and not vim.tbl_contains(runs, name) then
        runs[#runs + 1] = name
      end
    end
    for _, path in ipairs(checkouts(part .. "/worktrees")) do
      trees[#trees + 1] = { part = part, path = path }
    end
  end
  table.sort(runs)
  for _, part in ipairs(parts) do
    for _, rel in ipairs({ "workspaces", "archive", "worktrees", "root", "session.json" }) do
      mv(part, rel)
    end
  end
  if #runs > 0 then
    lines[#lines + 1] = ("mkdir -p %s"):format(shell(store.run))
  end
  for _, part in ipairs(parts) do
    for _, name in ipairs(runs) do
      mv(part, "run/" .. name)
    end
  end
  if #trees > 0 then
    lines[#lines + 1] = "# Tell git where each worktree is again, and unlock it."
  end
  for _, tree in ipairs(trees) do
    if back.worktrees == tree.part then
      local to = store.root .. "/worktrees/" .. tree.path:sub(#(tree.part .. "/worktrees/") + 1)
      local state = linked_state(tree.path)
      lines[#lines + 1] = ("git -C %s worktree repair"):format(shell(to))
      if state and state.locked then
        lines[#lines + 1] = ("git -C %s worktree unlock %s"):format(shell(to), shell(to))
      end
    end
  end
  vim.list_extend(lines, {
    "```",
    "",
    "3. Start the TUI (iso): the legacy workspaces are back, and their agents start as before.",
    "",
    "Left as they are, with nothing to undo: the wip/ branches pushed to origin, the repos' configs",
    ("and base clones in %s/repos, the work dirs in %s, the role prompts in config.json, and the"):format(store.root, store.work),
    ("conversations in ~/.claude/projects. %s, the approved plan, is kept here."):format("cutover-plan.txt"),
  })
  vim.fn.writefile(lines, b .. "/" .. M.readme)
  -- An earlier part's own README covers only itself: it points here.
  for _, part in ipairs(plan.earlier or {}) do
    local path = part .. "/" .. M.readme
    local ok, old = pcall(vim.fn.readfile, path)
    if ok and not vim.tbl_contains(old, M.later_note) then
      local pointer = ("A later run of the same cutover went on into %s: follow %s/%s instead, which puts back"):format(b, b, M.readme)
      vim.fn.writefile(vim.list_extend({ M.later_note, pointer, "what's here too.", "" }, old), path)
    end
  end
end

M.later_note = "NOTE: this backup is part of a cutover split across backups."

local function wipe(plan)
  for _, move in ipairs(plan.moves) do
    if vim.uv.fs_lstat(move.to) then
      return move.to .. " is already there"
    end
  end
  vim.fn.mkdir(plan.backup, "p")
  local function moves()
    for _, fix in ipairs(plan.repairs) do
      keep(plan, fix.path, fix.repair)
    end
    local old = require("isovim.worktree").root .. "/"
    for _, move in ipairs(plan.moves) do
      vim.fn.mkdir(vim.fs.dirname(move.to), "p")
      local ok, err = vim.uv.fs_rename(move.from, move.to)
      if not ok then
        return ("could not move %s to %s: %s"):format(short(move.from), short(move.to), err)
      end
      log(("moved %s to %s"):format(short(move.from), short(move.to)))
      if move.rel == "worktrees" then
        for _, tree in ipairs(plan.trees) do
          if not tree.outside and not tree.problem and vim.startswith(tree.path, old) then
            keep(plan, plan.backup .. "/worktrees/" .. tree.path:sub(#old + 1), true)
          end
        end
      end
    end
  end
  local err = moves()
  write_readme(plan)
  log(("how to undo it: %s/%s"):format(plan.backup, M.readme))
  return err
end

-- Runs the plan's steps in order; nil, why at the first failure.
---@return boolean? ok, string? err
function M.run(plan)
  log(("cutover of %s started: %d pushes, %d agents to stop, %d repos to seed, %d moves into %s"):format(plan.host,
    #plan.pushes, #plan.stops, #plan.seeds, #plan.moves, short(plan.backup)))
  for i, step in ipairs({ { "push", push }, { "stop", stop }, { "seed", seed }, { "wipe", wipe } }) do
    local err = step[2](plan)
    if err then
      log(("step %d (%s) failed, so the cutover stopped there: %s"):format(i, step[1], err))
      return nil, err
    end
  end
  vim.fn.mkdir(plan.backup, "p")
  vim.uv.fs_rename(M.plan_file, plan.backup .. "/cutover-plan.txt")
  -- (the plan in it marks the backup finished: a later run starts a new one)
  local ok, err = require("isovim.config").enforce()
  if not ok then
    log("cut over, but enforce could not be set: " .. tostring(err))
    return nil, err
  end
  require("isovim.sync").changed()
  log(("cutover of %s done: the old layout is in %s; enforce is on"):format(plan.host, short(plan.backup)))
  return true
end

return M
