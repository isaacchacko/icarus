-- Tasks: what icarus is organized by, apart from any project. Each is a folder under ~/.icarus/tasks:
--
--   ~/.icarus/tasks/<slug>/
--     spec.md                      what the task is, in your words: plain text and nothing else
--     task.json                    {title, status, created, links}
--     agents/<n>/                  one agent working on it, numbered from 1, never reused
--       <repo>-<slug>-<n>/         its worktree, if it has one: a name unique on the host, as setup
--                                  scripts name compose projects, ports and hosts after the dir
--
-- A status is where the task sits in the loop: spec, building, review, merged. "(no task)" is the
-- sentinel: it always exists and is always listed, has no status (it's never finished) and nothing
-- deletes it. A chat on no task is on it (icarus.chats).
local M = {}

M.ROOT = vim.env.ICARUS_HOME or (vim.env.HOME .. "/.icarus")
M.STATUSES = { "spec", "building", "review", "merged" }
M.SENTINEL = "no-task"

---@class icarus.Task
---@field slug string
---@field dir string
---@field spec string its spec.md
---@field title string
---@field status? string nil for the sentinel
---@field created string
---@field links string[]
---@field sentinel? boolean

function M.dir(slug)
  return M.ROOT .. "/tasks/" .. slug
end

local function slugify(title)
  local slug = title:lower():gsub("[^%w]+", "-"):gsub("^-+", ""):gsub("-+$", "")
  return slug:sub(1, 48):gsub("-+$", "")
end

local function write_meta(slug, meta)
  vim.fn.writefile({ vim.json.encode(meta) }, M.dir(slug) .. "/task.json")
end

-- A spec.md from before task.json: its frontmatter moves to task.json, and the "# What" and "# Why"
-- headings it was made with go if nothing was written under them; the rest is kept as written.
local function migrate(slug)
  local path = M.dir(slug) .. "/spec.md"
  local lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
  local meta, links, body, in_links = { links = {} }, {}, lines, false
  if lines[1] == "---" then
    for i = 2, #lines do
      local line = lines[i]
      if line == "---" then
        body = vim.list_slice(lines, i + 1)
        break
      end
      local item = in_links and line:match("^%s*%-%s+(.+)$")
      if item then
        links[#links + 1] = item
      else
        local key, value = line:match("^(%w+):%s*(.-)%s*$")
        in_links = key == "links"
        if key and key ~= "links" and value ~= "" then
          meta[key] = value
        end
      end
    end
  end
  meta.links = links
  local kept = {}
  for i, line in ipairs(body) do
    local next_text = vim.iter(vim.list_slice(body, i + 1)):find(function(each)
      return vim.trim(each) ~= ""
    end)
    local empty_scaffold = (line == "# What" or line == "# Why") and (not next_text or next_text:match("^#"))
    if not empty_scaffold and not (#kept == 0 and vim.trim(line) == "") then
      kept[#kept + 1] = line
    end
  end
  while #kept > 0 and vim.trim(kept[#kept]) == "" do
    kept[#kept] = nil
  end
  meta.title = meta.title or slug
  meta.status = meta.status or "spec"
  meta.created = meta.created or os.date("%Y-%m-%dT%H:%M:%S")
  write_meta(slug, meta)
  vim.fn.writefile(kept, path)
end

-- Makes the sentinel if it isn't there.
local function ensure_sentinel()
  local dir = M.dir(M.SENTINEL)
  if vim.fn.filereadable(dir .. "/task.json") == 1 then
    return
  end
  vim.fn.mkdir(dir .. "/agents", "p")
  if vim.fn.filereadable(dir .. "/spec.md") == 0 then
    vim.fn.writefile({}, dir .. "/spec.md")
  end
  write_meta(M.SENTINEL, { title = "(no task)", sentinel = true, created = "", links = {} })
end

---@return icarus.Task?
function M.read(slug)
  local dir = M.dir(slug)
  if vim.fn.isdirectory(dir) == 0 then
    return nil
  end
  if vim.fn.filereadable(dir .. "/task.json") == 0 then
    migrate(slug)
  end
  local ok, meta = pcall(vim.json.decode, table.concat(vim.fn.readfile(dir .. "/task.json"), "\n"))
  meta = ok and type(meta) == "table" and meta or {}
  return { slug = slug, dir = dir, spec = dir .. "/spec.md", title = meta.title or slug,
    status = not meta.sentinel and (meta.status or "spec") or nil, created = meta.created or "",
    links = meta.links or {}, sentinel = meta.sentinel == true }
end

---@return icarus.Task the sentinel
function M.sentinel()
  ensure_sentinel()
  return assert(M.read(M.SENTINEL))
end

---@return icarus.Task[] the sentinel first, then newest first
function M.list()
  ensure_sentinel()
  local tasks = {}
  for name, kind in vim.fs.dir(M.ROOT .. "/tasks") do
    if kind == "directory" and name ~= M.SENTINEL then
      tasks[#tasks + 1] = M.read(name)
    end
  end
  table.sort(tasks, function(a, b)
    return a.created > b.created
  end)
  table.insert(tasks, 1, M.sentinel())
  return tasks
end

-- Marks the task opened now, for M.recent.
function M.touch(slug)
  vim.fn.writefile({ tostring(os.time()) }, M.dir(slug) .. "/.opened")
end

local function opened(task)
  local line = vim.fn.filereadable(task.dir .. "/.opened") == 1 and vim.fn.readfile(task.dir .. "/.opened")[1]
  return tonumber(line) or 0
end

---@return icarus.Task[] the last opened first, then the newest
function M.recent()
  local list = M.list()
  local at = {}
  for _, task in ipairs(list) do
    at[task.slug] = opened(task)
  end
  table.sort(list, function(a, b)
    if at[a.slug] ~= at[b.slug] then
      return at[a.slug] > at[b.slug]
    end
    return a.created > b.created
  end)
  return list
end

-- Makes a task with an empty spec to write; a slug already taken gets a number.
---@return icarus.Task
function M.create(title)
  local base = slugify(title)
  base = base ~= "" and base ~= M.SENTINEL and base or "task"
  local slug, n = base, 1
  while vim.fn.isdirectory(M.dir(slug)) == 1 do
    n = n + 1
    slug = ("%s-%d"):format(base, n)
  end
  vim.fn.mkdir(M.dir(slug) .. "/agents", "p")
  write_meta(slug, { title = title, status = "spec", created = os.date("%Y-%m-%dT%H:%M:%S"), links = {} })
  vim.fn.writefile({}, M.dir(slug) .. "/spec.md")
  return assert(M.read(slug))
end

-- A new agent's folder under the task, numbered after the last one.
---@return integer n, string dir
function M.new_agent(slug)
  local agents = M.dir(slug) .. "/agents"
  vim.fn.mkdir(agents, "p")
  local last = 0
  for name in vim.fs.dir(agents) do
    last = math.max(last, tonumber(name) or 0)
  end
  local dir = ("%s/%d"):format(agents, last + 1)
  vim.fn.mkdir(dir, "p")
  return last + 1, dir
end

-- Where agent n's worktree of repo goes.
function M.worktree(slug, n, repo)
  return ("%s/agents/%d/%s-%s-%d"):format(M.dir(slug), n, repo, slug, n)
end

return M
