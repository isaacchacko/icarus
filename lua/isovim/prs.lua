-- The PRs a workspace's agents registered (`iso pr`), with their state from gh, cached for a
-- minute under run/<ws>/prs.json so the sidebar never waits on the network.
local store = require("isovim.store")

local M = {}

local TTL = 60
local CLOSED_TTL = 3600
-- Each running gh holds two of the TUI's fds, and macOS gives it 256.
local MOST_LOOKUPS = 8
local fetching = {} ---@type table<string, boolean>

---@type fun(ws: string, pr: isovim.Pr, news: string)? set by the TUI to notify
M.on_news = nil

---@class isovim.Pr
---@field url string
---@field number? integer
---@field title? string
---@field state? "OPEN"|"CLOSED"|"MERGED"
---@field isDraft? boolean
---@field checks? "pass"|"fail"|"pending" CI, from the checks' rollup
---@field approved? boolean
---@field review? "APPROVED"|"CHANGES_REQUESTED"|"REVIEW_REQUIRED"
---@field createdAt? string ISO 8601, as gh gives it
---@field mergedAt? string
---@field closedAt? string

local FAILED = { FAILURE = true, TIMED_OUT = true, CANCELLED = true, ACTION_REQUIRED = true, STARTUP_FAILURE = true, ERROR = true }

-- One word for a PR's CI: any failed check fails it, else any unfinished one keeps it pending.
local function checks(rollup)
  if type(rollup) ~= "table" or #rollup == 0 then
    return nil
  end
  local pending = false
  for _, check in ipairs(rollup) do
    if FAILED[check.conclusion] or FAILED[check.state] then
      return "fail"
    end
    pending = pending or (check.status and check.status ~= "COMPLETED") or check.state == "PENDING" or check.state == "EXPECTED"
  end
  return pending and "pending" or "pass"
end

-- Accepts a PR URL or owner/repo#123.
---@return string?
function M.normalize(ref)
  if ref:match("^https://github%.com/[^/]+/[^/]+/pull/%d+") then
    return ref:match("^(https://github%.com/[^/]+/[^/]+/pull/%d+)"):lower()
  end
  local repo, number = ref:match("^([%w_.-]+/[%w_.-]+)#(%d+)$")
  return repo and ("https://github.com/%s/pull/%s"):format(repo:lower(), number) or nil
end

local function cache_file(ws)
  return store.run_dir(ws) .. "/prs.json"
end

local function read_cache(ws)
  local ok, lines = pcall(vim.fn.readfile, cache_file(ws))
  local decoded, cache = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  if not (decoded and type(cache) == "table") then
    return { fetched = 0, prs = {} }
  end
  local prs = {}
  for url, pr in pairs(cache.prs or {}) do
    prs[url:lower()] = pr
  end
  cache.prs = prs
  return cache
end

-- What changed since the last fetch goes on the event bus as pr.<owner>/<repo>.<n>.state|ci|review,
-- the repo in lowercase (events.topic encodes the parts);
-- a PR seen for the first time reports what it has.
---@param pr isovim.Pr
---@param old isovim.Pr|{}
local function publish_changes(ws, pr, old)
  local repo, number = pr.url:match("github%.com/([^/]+/[^/]+)/pull/(%d+)")
  if not repo then
    return
  end
  local events = require("isovim.events")
  local about = { repo = repo, number = tonumber(number), url = pr.url, ws = ws, title = pr.title }
  local function topic(what)
    return events.topic("pr", repo:lower(), number, what)
  end
  if pr.state ~= old.state or pr.isDraft ~= old.isDraft then
    events.publish(topic("state"), vim.tbl_extend("force", about, { state = pr.state, draft = pr.isDraft, previous = old.state }))
  end
  if pr.checks ~= old.checks then
    events.publish(topic("ci"), vim.tbl_extend("force", about, { checks = pr.checks, previous = old.checks }))
  end
  if pr.review ~= old.review then
    events.publish(topic("review"), vim.tbl_extend("force", about, { review = pr.review, previous = old.review }))
  end
end

-- Whether a fetch can leave this PR as it was: a merged one stays merged, and a closed one is rarely
-- reopened.
local function settled(pr)
  return pr and (pr.state == "MERGED" or (pr.state == "CLOSED" and os.time() - (pr.looked or 0) < CLOSED_TTL))
end

-- Looks each PR up, MOST_LOOKUPS at a time, and rewrites the cache; on_done runs on the main loop. A
-- PR that can't be looked up keeps what the cache had.
local function fetch(ws, urls, on_done)
  if fetching[ws] then
    return
  end
  fetching[ws] = true
  local before = read_cache(ws).prs
  local prs, todo = {}, {}
  for _, url in ipairs(urls) do
    prs[url] = before[url]
    if not settled(before[url]) then
      todo[#todo + 1] = url
    end
  end
  local function finish()
    fetching[ws] = nil
    -- News worth a notification: checks that finished, a PR merged.
    for url, pr in pairs(prs) do
      local old = before[url]
      publish_changes(ws, pr, old or {})
      if old and M.on_news then
        if old.checks == "pending" and (pr.checks == "pass" or pr.checks == "fail") then
          M.on_news(ws, pr, pr.checks == "pass" and "checks passed" or "checks failed")
        elseif old.state == "OPEN" and pr.state == "MERGED" then
          M.on_news(ws, pr, "merged")
        end
      end
    end
    vim.fn.mkdir(store.run_dir(ws), "p")
    vim.fn.writefile({ vim.json.encode({ fetched = os.time(), prs = prs }) }, cache_file(ws))
    on_done()
  end
  local fields = "number,title,state,isDraft,url,statusCheckRollup,reviewDecision,createdAt,mergedAt,closedAt"
  local next_up, running = 1, 0
  local function look_up()
    while running < MOST_LOOKUPS and next_up <= #todo do
      local url = todo[next_up]
      next_up = next_up + 1
      running = running + 1
      -- Starting one can fail (out of fds): it counts as looked up, or the fetch would never end and
      -- this workspace's PRs would freeze.
      local started = pcall(vim.system, { "gh", "pr", "view", url, "--json", fields }, { text = true }, function(result)
        local ok, pr = pcall(vim.json.decode, result.stdout or "")
        if ok and type(pr) == "table" then
          pr.checks, pr.approved = checks(pr.statusCheckRollup), pr.reviewDecision == "APPROVED" or nil
          pr.review = pr.reviewDecision ~= "" and pr.reviewDecision or nil
          pr.statusCheckRollup, pr.reviewDecision = nil, nil
          pr.looked = os.time()
          prs[url] = pr
        end
        vim.schedule(function()
          running = running - 1
          look_up()
        end)
      end)
      if not started then
        running = running - 1
      end
    end
    if running == 0 then
      vim.schedule(finish)
    end
  end
  look_up()
end

-- A worktree workspace's PR is the one for its branch, found in the background
-- and registered once it exists, without waiting for an agent to run `iso pr`.
function M.discover(ws, dir, branch, on_found)
  vim.system({ "gh", "pr", "list", "--head", branch, "--state", "all", "--json", "url", "--limit", "1" }, { cwd = dir, text = true }, function(result)
    local ok, found = pcall(vim.json.decode, result.code == 0 and result.stdout or "")
    local url = ok and type(found) == "table" and found[1] and found[1].url
    if url and not vim.tbl_contains(store.prs(ws), url:lower()) then
      vim.schedule(function()
        store.add_pr(ws, url)
        on_found()
      end)
    end
  end)
end

-- The workspace's PRs, newest registered first, with whatever state the cache has; refetches
-- in the background when stale and calls on_update once fresh states are in.
---@return isovim.Pr[]
-- What was last fetched for the workspace's PRs, without fetching: url -> PR.
---@return table<string, isovim.Pr>
function M.cached(ws)
  return read_cache(ws).prs
end

function M.list(ws, on_update)
  local urls = store.prs(ws)
  local cache = read_cache(ws)
  local missing = vim.iter(urls):any(function(url)
    return cache.prs[url] == nil
  end)
  if #urls > 0 and (missing or os.time() - cache.fetched > TTL) then
    fetch(ws, urls, on_update)
  end
  local list = {}
  for i = #urls, 1, -1 do
    list[#list + 1] = cache.prs[urls[i]] or { url = urls[i] }
  end
  return list
end

-- gh's 2026-11-01T18:04:05Z as epoch seconds; nil for none.
function M.time(iso)
  local y, mo, d, h, mi, s = tostring(iso or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z$")
  if not y then
    return nil
  end
  local utc = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
  -- os.time read it as local time: move it by the offset local time has from UTC.
  local now = os.time()
  return utc + os.difftime(now, os.time(os.date("!*t", now)))
end

-- Whether a PR waits on you: open and ready (not a draft), its CI green and no changes asked for, so
-- it waits on your review or your merge.
---@param pr isovim.Pr
function M.needs_you(pr)
  return pr.state == "OPEN" and not pr.isDraft and pr.checks == "pass" and pr.review ~= "CHANGES_REQUESTED"
end

-- The groups a router made of its repo's PRs (iso <role> pr group), in their order, from
-- iso/prs.groups.json: {name, note?, prs: urls}; a PR is in one at most. {} when it made none.
---@return {name: string, note?: string, prs: string[]}[]
function M.groups(repo)
  local path = require("isovim.surfaces").dir(repo) .. "/prs.groups.json"
  local ok, lines = pcall(vim.fn.readfile, path)
  local decoded, value = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  local groups = decoded and type(value) == "table" and type(value.groups) == "table" and value.groups or {}
  for _, group in ipairs(groups) do
    group.prs = vim.tbl_map(string.lower, group.prs or {})
  end
  return groups
end

-- Writes the repo's groups, through a temp file so a reader never sees half of them.
function M.save_groups(repo, groups)
  local dir = require("isovim.surfaces").dir(repo)
  vim.fn.mkdir(dir, "p")
  local tmp = ("%s/.prs.groups.json.%d.tmp"):format(dir, vim.uv.os_getpid())
  vim.fn.writefile({ vim.json.encode({ groups = groups }) }, tmp)
  assert(vim.uv.fs_rename(tmp, dir .. "/prs.groups.json"))
end

---@param pr isovim.Pr
---@return string icon, string hl
function M.icon(pr)
  if pr.state == "MERGED" then
    return "\u{f419}", "Special"
  elseif pr.state == "CLOSED" then
    return "\u{f4dc}", "DiagnosticError"
  elseif pr.isDraft then
    return "\u{f4dd}", "Comment"
  elseif pr.state == "OPEN" then
    return "\u{f407}", "DiagnosticOk"
  end
  return "…", "Comment"
end

-- CI and review marks for a PR's row.
---@return {[1]: string, [2]: string}[]
function M.marks(pr)
  local marks = {}
  if pr.state == "OPEN" and pr.checks then
    local mark = ({ pass = { "✓", "DiagnosticOk" }, fail = { "✗", "DiagnosticError" }, pending = { "●", "DiagnosticWarn" } })[pr.checks]
    marks[#marks + 1] = { " " .. mark[1], mark[2] }
  end
  if pr.state == "OPEN" and pr.approved then
    marks[#marks + 1] = { " approved", "DiagnosticOk" }
  end
  return marks
end

return M
