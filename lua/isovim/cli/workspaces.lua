-- Commands on whole workspaces: create, name, place, move, archive, and their PRs and pins.
local store = require("isovim.store")
local panes = require("isovim.panes")
local prs = require("isovim.prs")
local c = require("isovim.cli.common")

local out = c.out
local fail = c.fail
local unique = c.unique
local resolve = c.resolve
local resolve_agent = c.resolve_agent
local caller_address = c.caller_address
local tui = c.tui
local word = c.word
local option = c.option
local flag = c.flag

local commands = {}

function commands.new(args)
  local dir = option(args, "--dir")
  local from = option(args, "--from")
  local worktree = flag(args, "--worktree")
  worktree = from or worktree
  local name = table.concat(args, " ")
  if name == "" then
    fail("usage: iso new <name> [--dir path] [--worktree | --from <branch|PR>]")
  end
  if dir and vim.fn.isdirectory(dir) == 0 then
    fail(dir .. " is not a directory")
  end
  if worktree and not (dir and require("isovim.worktree").is_repo(dir)) then
    fail("--worktree and --from need --dir at a git repo's top level")
  end
  local id, err = store.create(name, dir, worktree)
  if not id then
    fail("could not make the worktree: " .. err)
  end
  if worktree then
    require("isovim.scripts").start(id, "setup")
  end
  local parent = caller_address()
  if parent then
    store.update_agent(id, "main", { parent = parent })
  end
  out(id)
  tui("require('isovim').refresh()")
end

-- Agents started after this run in the new dir; running ones keep theirs until restarted.
function commands.dir(args)
  local ws = resolve(args[1])
  if args[2] and store.v2(ws.id) then
    fail(ws.name .. " is a repo: each of its agents works in its own dir")
  elseif args[2] and args[2] ~= "-" then
    if vim.fn.isdirectory(args[2]) == 0 then
      fail(args[2] .. " is not a directory")
    end
    store.set_dir(ws.id, args[2])
    tui("require('isovim').refresh()")
  elseif args[2] == "-" then
    store.set_dir(ws.id, nil)
    tui("require('isovim').refresh()")
  end
  out(store.dir(ws.id))
end

-- <ws>/<agent> renames the agent, e.g. a terminal after what runs in it.
function commands.rename(args)
  local target = table.remove(args, 1)
  local name = table.concat(args, " ")
  if not target or name == "" then
    fail("usage: iso rename <ws|agent> <name>")
  end
  if target:find("/") then
    local ws, agent = resolve_agent(target)
    store.update_agent(ws.id, agent.id, { name = name })
  else
    store.rename(resolve(target).id, name)
  end
  tui("require('isovim').refresh()")
end

function commands.move(args)
  local force = flag(args, "--force")
  local all = flag(args, "--all")
  local host = args[2] or fail("usage: iso move <ws|owner/repo/aN> <host>")
  -- --all: every agent of a new-layout repo (or general), checked first so a refusal moves none.
  if all then
    local key = store.canon(args[1])
    if not store.valid_key(key) or not vim.uv.fs_stat(store.dir(key)) then
      fail(("--all moves a repo's agents: %q isn't a repo here (owner/repo, or general)"):format(args[1]))
    end
    local ok, message = require("isovim.move").send_repo(key, host)
    tui("require('isovim').refresh()")
    if not ok then
      fail(("could not move %s to %s: %s"):format(key, host, message))
    end
    out(("%s moved to %s: %s"):format(key, host, message))
    return
  end
  -- A new-layout agent moves on its own, by its exact address; it's never moved mid-turn.
  if args[1] and args[1]:find("/", 1, true) then
    local ws, agent = resolve_agent(args[1], true)
    if not store.v2(ws.id) then
      fail(("%s is a workspace's agent; a workspace moves whole: iso move %s %s"):format(args[1], ws.id, host))
    end
    local ok, message = require("isovim.move").send_agent(ws.id, agent, host)
    if not ok then
      fail(("could not move %s/%s to %s: %s"):format(ws.id, agent.id, host, message))
    end
    tui("require('isovim').refresh()")
    out(("%s/%s moved to %s as %s"):format(ws.id, agent.id, host, message))
    return
  end
  local ws = resolve(args[1], true)
  if not force then
    for _, agent in ipairs(store.agents(ws.id)) do
      if word(ws.id, agent.id) == "working" then
        fail(agent.name .. " is working; wait for it or pass --force")
      end
    end
  end
  local ok, err = require("isovim.move").send(ws, host)
  if not ok then
    fail("could not move " .. ws.name .. " to " .. host .. ": " .. err)
  end
  tui("require('isovim').refresh()")
  -- On success err is a note, e.g. a worktree kept here because it held uncommitted work.
  out(ws.name .. " moved to " .. host .. (err and "; " .. err or ""))
end

function commands.archived()
  for _, ws in ipairs(store.archived()) do
    out(("%s  %s  %s"):format(ws.id, os.date("%F %R", ws.archived), ws.name))
  end
end

function commands.unarchive(args)
  local ws = unique(args[1] or fail("usage: iso unarchive <ws>"), store.archived(), function(ws)
    return { ws.id, ws.name }
  end, "archived workspace")
  local ok, err = store.unarchive(ws.id)
  if not ok then
    fail(err)
  end
  tui("require('isovim').refresh()")
  out(ws.name .. " is back" .. (err and "; " .. err or ""))
end

function commands.archive(args)
  local ws = resolve(args[1], true)
  if store.v2(ws.id) then
    fail(select(2, store.archive_workspace(ws.id)))
  end
  panes.stop_all(ws.id)
  store.reparent(ws.id)
  local ok, err, note = store.archive_workspace(ws.id)
  if not ok then
    fail(err)
  end
  if note then
    out(ws.name .. " archived; " .. note)
  end
  tui("require('isovim').refresh()")
end

function commands.pr(args)
  -- The groups of a repo's PRs, a router's or a root's (isovim.cli.surfaces.pr_grouping).
  if args[1] == "group" or args[1] == "ungroup" or args[1] == "groups" then
    return require("isovim.cli.surfaces").pr_grouping(args)
  end
  local ws = resolve(args[1])
  local url = args[2] and prs.normalize(args[2]) or fail("usage: iso pr <ws> <pr url|owner/repo#n>")
  local by = caller_address()
  store.add_pr(ws.id, url, by)
  -- During a turn on a thread of a task, it goes on that task.
  local threads = require("isovim.threads")
  local turn = by and not store.is_pseudo(ws.id) and threads.turn_thread(ws.id, by)
  local task = turn and threads.related(ws.id, turn)
  if task and require("isovim.board_tasks").link(ws.id, task, url, nil, by) then
    io.stderr:write(("iso: linked to task %s, as %s, the thread of this turn, is on it\n"):format(task, turn))
  end
  tui("require('isovim').refresh()")
end

function commands.prs(args)
  local json = flag(args, "--json")
  local ws = resolve(args[1])
  local list = prs.list(ws.id, function() end)
  -- A cold cache is fetched in the background; wait for it here.
  if vim.iter(list):any(function(pr)
    return pr.state == nil
  end) then
    vim.wait(15000, function()
      return vim.iter(prs.list(ws.id, function() end)):all(function(pr)
        return pr.state ~= nil
      end)
    end, 200)
    list = prs.list(ws.id, function() end)
  end
  if json then
    out(vim.json.encode(list))
    return
  end
  for _, pr in ipairs(list) do
    local ci = pr.state == "OPEN" and pr.checks and (" [ci " .. pr.checks .. (pr.approved and ", approved" or "") .. "]") or ""
    out(("%-7s %-6s %s%s %s"):format(pr.state or "?", pr.number and "#" .. pr.number or "", pr.title or "", ci, pr.url))
  end
end

-- Pins a file or folder under the workspace in the sidebar; Enter there opens it.
function commands.pin(args)
  local label = option(args, "--label")
  local ws = resolve(args[1])
  local path = args[2] and vim.fn.fnamemodify(vim.fs.normalize(args[2]), ":p"):gsub("/$", "")
  if not path or not vim.uv.fs_stat(path) then
    fail("usage: iso pin <ws> <existing file or folder> [--label text]")
  end
  store.pin(ws.id, path, label)
  tui("require('isovim').refresh()")
end

function commands.unpin(args)
  local ws = resolve(args[1])
  if not args[2] then
    fail("usage: iso unpin <ws> <path>")
  end
  store.unpin(ws.id, vim.fn.fnamemodify(vim.fs.normalize(args[2]), ":p"):gsub("/$", ""))
  tui("require('isovim').refresh()")
end

return commands
