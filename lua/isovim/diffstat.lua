-- How much a workspace has changed, for its sidebar row: lines added and removed
-- since its branch left the remote's default branch, committed or not. Fetched in the background,
-- at most every few seconds per dir; until then the last count shows.
local M = {}

local TTL = 5
local cache = {} ---@type table<string, {added?: integer, removed?: integer, at: integer, busy?: boolean}>

local function count(dir, base, done)
  vim.system({ "git", "-C", dir, "diff", "--numstat", base }, { text = true }, function(result)
    local added, removed = 0, 0
    for a, r in (result.stdout or ""):gmatch("(%d+)%s+(%d+)") do
      added, removed = added + tonumber(a), removed + tonumber(r)
    end
    done(result.code == 0 and added or nil, removed)
  end)
end

local function fetch(dir, on_update)
  local entry = cache[dir]
  entry.busy = true
  vim.system({ "git", "-C", dir, "merge-base", "HEAD", "refs/remotes/origin/HEAD" }, { text = true }, function(base)
    count(dir, base.code == 0 and vim.trim(base.stdout) or "HEAD", function(added, removed)
      local changed = entry.added ~= added or entry.removed ~= removed
      entry.added, entry.removed, entry.at, entry.busy = added, added and removed, os.time(), nil
      if changed then
        vim.schedule(on_update)
      end
    end)
  end)
end

---@return integer? added, integer? removed nil until known, or when dir isn't in git
function M.get(dir, on_update)
  local entry = cache[dir]
  if not entry then
    entry = { at = 0 }
    cache[dir] = entry
  end
  if not entry.busy and os.time() - entry.at >= TTL then
    fetch(dir, on_update)
  end
  return entry.added, entry.removed
end

return M
