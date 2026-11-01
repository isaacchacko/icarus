-- A workspace can work in its own git worktree: a new branch <prefix>/<slug> checked
-- out under ~/.isovim/worktrees/<repo>/<branch>, so agents in different workspaces never share a checkout.
-- A new-layout agent's is its aN/w, made from the repo's base clone (iso <role> wt, isovim.cli.work).
local M = {}

M.root = (vim.env.ISOVIM_HOME or vim.fs.normalize("~/.isovim")) .. "/worktrees"
M.prefix = vim.env.ISOVIM_BRANCH_PREFIX or ((vim.env.USER or "isovim") .. "/")

local function git(dir, args, timeout)
  local cmd = vim.list_extend({ "git", "-C", dir }, args)
  return vim.system(cmd, { text = true, timeout = timeout }):wait()
end

local function out(result)
  return result.code == 0 and vim.trim(result.stdout) or nil
end

-- The folder worktrees of a repo go in: its origin's name (app for acme/app.git), since clones
-- are often named after a task; else the checkout's own name.
local function repo_name(repo)
  local url = out(git(repo, { "config", "--get", "remote.origin.url" }))
  local name = url and url:match("([^/:]+)$")
  name = name and name:gsub("%.git$", "")
  return (name and name ~= "") and name or vim.fs.basename(vim.uv.fs_realpath(repo) or repo)
end

-- dir is a repo's top level (not a subdir, which would put the worktree's agents somewhere else).
function M.is_repo(dir)
  local top = out(git(dir, { "rev-parse", "--show-toplevel" }))
  return top ~= nil and vim.uv.fs_realpath(top) == vim.uv.fs_realpath(dir)
end

function M.branch_for(name)
  local slug = name:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  return M.prefix .. (slug ~= "" and slug or "workspace")
end

-- Off the remote's default branch, freshly fetched when the network allows, else off HEAD.
local function base(repo)
  local default = out(git(repo, { "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }))
  if not default then
    return "HEAD"
  end
  git(repo, { "fetch", "--quiet", "origin", (default:gsub("^origin/", "")) }, 20000)
  return default
end

-- A branch name is taken when the repo has it; given a path (a new-layout agent's w/, whose repo is
-- a base clone that other hosts' agents push from too), also when origin has it.
---@param path? string where the worktree goes; default ~/.isovim/worktrees/<repo>/<branch>
---@return string? path, string? branch_or_err
function M.create(repo, name, path)
  local function taken(branch)
    return out(git(repo, { "rev-parse", "--verify", "--quiet", "refs/heads/" .. branch }))
      or (path and out(git(repo, { "rev-parse", "--verify", "--quiet", "refs/remotes/origin/" .. branch })))
  end
  local branch = M.branch_for(name)
  local n = 1
  while taken(branch) do
    n = n + 1
    branch = M.branch_for(name) .. "-" .. n
  end
  path = path or ("%s/%s/%s"):format(M.root, repo_name(repo), branch)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local added = git(repo, { "worktree", "add", "-b", branch, path, base(repo) })
  if added.code ~= 0 then
    return nil, vim.trim(added.stderr)
  end
  return path, branch
end

-- A worktree of a branch someone already pushed, or a PR's (its number or URL): to review it or
-- carry it on. The local branch is used if there is one; else it's made to track origin's.
---@param path? string where the worktree goes, as for M.create
---@return string? path, string? branch_or_err
function M.create_from(repo, ref, path)
  local number = ref:match("^#?(%d+)$") or ref:match("/pull/(%d+)")
  local branch = ref:gsub("^origin/", "")
  if number then
    local view = vim.system({ "gh", "pr", "view", number, "--json", "headRefName,isCrossRepository" }, { cwd = repo, text = true, timeout = 20000 }):wait()
    local ok, pr = pcall(vim.json.decode, view.code == 0 and view.stdout or "")
    if not ok or type(pr) ~= "table" then
      return nil, "could not look up PR " .. number .. ": " .. vim.trim(view.stderr or "")
    end
    -- A fork's branch isn't on origin, but GitHub keeps every PR's head there.
    branch = pr.isCrossRepository and ("pr-" .. number) or pr.headRefName
    if pr.isCrossRepository then
      git(repo, { "fetch", "--quiet", "origin", ("pull/%s/head:refs/heads/%s"):format(number, branch) }, 30000)
    end
  end
  local exists = function(ref_name)
    return out(git(repo, { "rev-parse", "--verify", "--quiet", ref_name })) ~= nil
  end
  if not exists("refs/heads/" .. branch) then
    git(repo, { "fetch", "--quiet", "origin", branch }, 30000)
    if not exists("refs/remotes/origin/" .. branch) then
      return nil, ("no branch %s here or on origin"):format(branch)
    end
  end
  path = path or ("%s/%s/%s"):format(M.root, repo_name(repo), branch)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local args = exists("refs/heads/" .. branch) and { "worktree", "add", path, branch }
    or { "worktree", "add", "--track", "-b", branch, path, "origin/" .. branch }
  local added = git(repo, args)
  if added.code ~= 0 then
    return nil, vim.trim(added.stderr)
  end
  return path, branch
end

-- A worktree for a branch that already exists, e.g. an unarchived workspace's.
---@return string? path, string? err
function M.checkout(repo, branch)
  if not M.is_repo(repo) then
    return nil, repo .. " is not a git repo here"
  end
  local path = ("%s/%s/%s"):format(M.root, repo_name(repo), branch)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local added = git(repo, { "worktree", "add", path, branch })
  if added.code ~= 0 then
    return nil, vim.trim(added.stderr)
  end
  return path
end

-- The main checkout a worktree belongs to.
function M.repo_of(path)
  local common = out(git(path, { "rev-parse", "--path-format=absolute", "--git-common-dir" }))
  return common and vim.fs.dirname(common) or nil
end

-- A commit of everything uncommitted in the checkout, untracked files too (ignored ones aside), on top
-- of HEAD, made without touching the checkout or its index; nil when git can't.
---@return string? sha
function M.snapshot(path, message)
  local index = vim.fn.tempname()
  local env = { GIT_INDEX_FILE = index }
  -- A host with no git identity still gets its snapshot.
  if not out(git(path, { "config", "user.email" })) then
    env = vim.tbl_extend("force", env, { GIT_AUTHOR_NAME = "isovim", GIT_AUTHOR_EMAIL = "isovim@localhost",
      GIT_COMMITTER_NAME = "isovim", GIT_COMMITTER_EMAIL = "isovim@localhost" })
  end
  local function indexed(args)
    return vim.system(vim.list_extend({ "git", "-C", path }, args), { text = true, env = env }):wait()
  end
  indexed({ "read-tree", "HEAD" })
  indexed({ "add", "-A" })
  local tree = out(indexed({ "write-tree" }))
  vim.fn.delete(index)
  return tree and out(indexed({ "commit-tree", tree, "-p", "HEAD", "-m", message })) or nil
end

-- For iso move: writes a bundle of the branch's commits beyond the remote default branch (the other
-- host has those) plus a commit of everything uncommitted, untracked files too, without touching
-- the checkout or its index.
---@return {branch: string, wip: string}? info, string? err
function M.pack(path, bundle)
  local branch = out(git(path, { "branch", "--show-current" }))
  if not branch then
    return nil, "its worktree is not on a branch"
  end
  local wip = M.snapshot(path, "iso move: uncommitted work")
  if not wip then
    return nil, "could not snapshot its uncommitted work"
  end
  -- The snapshot's parents hold every commit of the branch, so it alone is bundled; a branch with
  -- no commits of its own would otherwise be left out of the bundle as already there.
  local ref = "refs/iso/move-wip"
  git(path, { "update-ref", ref, wip })
  local args = { "bundle", "create", bundle, ref }
  if out(git(path, { "rev-parse", "--verify", "--quiet", "refs/remotes/origin/HEAD" })) then
    table.insert(args, "^refs/remotes/origin/HEAD")
  end
  local bundled = git(path, args)
  git(path, { "update-ref", "-d", ref })
  if bundled.code ~= 0 then
    return nil, vim.trim(bundled.stderr)
  end
  return { branch = branch, wip = wip, head = out(git(path, { "rev-parse", "HEAD" })) }
end

-- The other end of M.pack, in this host's checkout of the same repo: the branch as it was there,
-- a worktree for it, and the uncommitted work back in it, still uncommitted.
---@return string? path, string? err
function M.unpack(repo, bundle, info)
  if not M.is_repo(repo) then
    return nil, repo .. " is not a git repo here"
  end
  git(repo, { "fetch", "--quiet", "origin" }, 30000)
  local fetched = git(repo, { "fetch", "--quiet", bundle, "refs/iso/move-wip" })
  if fetched.code ~= 0 then
    return nil, vim.trim(fetched.stderr)
  end
  local incoming = info.head
  -- The branch may be here already (it was here before): take the incoming one only if it
  -- contains everything here, so no commit made on this host is lost.
  local local_ref = "refs/heads/" .. info.branch
  local exists = git(repo, { "rev-parse", "--verify", "--quiet", local_ref }).code == 0
  if exists and git(repo, { "merge-base", "--is-ancestor", local_ref, incoming }).code ~= 0 then
    return nil, ("%s here has commits the moved one lacks; merge them first"):format(info.branch)
  end
  local updated = git(repo, { "update-ref", local_ref, incoming })
  if updated.code ~= 0 then
    return nil, vim.trim(updated.stderr)
  end
  local path = ("%s/%s/%s"):format(M.root, repo_name(repo), info.branch)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local added = git(repo, { "worktree", "add", path, info.branch })
  if added.code ~= 0 then
    return nil, vim.trim(added.stderr)
  end
  git(path, { "restore", "--source=" .. info.wip, "--worktree", "--", ":/" })
  return path
end

-- After a move, a copy that still holds uncommitted work stays, but out of the way: off the branch
-- and beside its old path, so the workspace can come back to this host later.
---@return string? path where it went
function M.set_aside(path)
  git(path, { "checkout", "--quiet", "--detach" })
  local aside = path .. "-moved-" .. os.date("%Y%m%d-%H%M%S")
  local repo = M.repo_of(path)
  local moved = repo and git(repo, { "worktree", "move", path, aside })
  return moved and moved.code == 0 and aside or nil
end

-- Removes the checkout if nothing in it is uncommitted; the branch stays either way.
---@return boolean removed, string? why_not
function M.remove(path)
  if vim.fn.isdirectory(path) == 0 then
    return true
  end
  local dirty = out(git(path, { "status", "--porcelain" }))
  if dirty == nil then
    return false, "not a git worktree"
  elseif dirty ~= "" then
    return false, "it has uncommitted changes"
  end
  local removed = git(path, { "worktree", "remove", path })
  return removed.code == 0, vim.trim(removed.stderr)
end

return M
