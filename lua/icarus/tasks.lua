-- Tasks: what icarus is organized by, apart from any project. Each is a folder under ~/.icarus/tasks:
--
--   ~/.icarus/tasks/<slug>/
--     task.json                    the task's attributes: icarus's record of them
--     task.md                      the task, in your words, under a YAML header of those attributes
--     agents/<n>/                  one agent working on it, numbered from 1, never reused
--       <repo>-<slug>-<n>/         its worktree, if it has one: a name unique on the host, as setup
--                                  scripts name compose projects, ports and hosts after the dir
--
-- The header is where you add, change and remove attributes, by hand:
--
--   ---
--   title: icarus development
--   status: spec
--   created: 2026-11-05T10:59:59
--   links:
--     - https://github.com/...
--   ---
--
-- What it says goes into task.json when task.md is read (M.read) or saved (M.sync). task.json is
-- what icarus reads from and writes to (M.set), and the header is drawn from it again whenever it's
-- gone, so a lost header loses nothing; title, status and created can't be removed, only changed.
-- Any other key is yours: a value is a string, true or false, or a list of "- item" lines.
--
-- A status is where the task sits in the loop: spec, building, review, merged, or cancelled. "(no
-- task)" is the sentinel (sentinel: true): it always exists and is always listed, has no status
-- (it's never finished) and can't be cancelled or deleted. A chat on no task is on it (icarus.chats).
-- A pinned task (pinned: true) is the same, except it has no column on the board, so it lives
-- outside the kanban: it has no status, and it can't be cancelled or deleted.
-- A deleted task's folder goes to ~/.icarus/trash.
local M = {}

M.ROOT = vim.env.ICARUS_HOME or (vim.env.HOME .. "/.icarus")
M.STATUSES = { "spec", "todo", "building", "review", "blocked", "merged", "cancelled" }
-- What each status is called and drawn as, in the list (Linear's names and glyphs). The ids are what
-- task.json and ica status use, so they stay as they are.
M.LABELS = { spec = "Backlog", todo = "Todo", building = "In Progress", review = "Review", blocked = "Blocked",
  merged = "Done", cancelled = "Cancelled" }
M.GLYPHS = { spec = "◌", todo = "○", building = "◐", review = "◉", blocked = "⊘", merged = "✓", cancelled = "" }
local T = require("icarus.theme")
M.COLORS = { spec = T.mute, todo = T.ash, building = T.sun, review = T.leaf, blocked = T.coral, merged = T.sky }
M.SENTINEL = "no-task"

-- The header's keys in this order, the rest after them by name.
local ORDER = { "title", "status", "orchestration", "auto", "sentinel", "pinned", "created", "links" }
local REQUIRED = { title = true, created = true }

---@class icarus.Task
---@field slug string
---@field dir string
---@field file string its task.md
---@field title string
---@field status? string nil for the sentinel
---@field created string
---@field links string[]
---@field sentinel? boolean
---@field pinned? boolean outside the board, with no status; can't be cancelled or deleted
---@field attrs table every attribute, as task.json has them

function M.dir(slug)
  return M.ROOT .. "/tasks/" .. slug
end

local function slugify(title)
  local slug = title:lower():gsub("[^%w]+", "-"):gsub("^-+", ""):gsub("-+$", "")
  return slug:sub(1, 48):gsub("-+$", "")
end

local function unquote(value)
  local double = value:match('^"(.*)"$')
  return double and double:gsub("\\(.)", "%1") or value:match("^'(.*)'$") or value
end

-- A value that YAML would read as something else, or not at all, is quoted.
local function quote(value)
  if value == "" or value == "true" or value == "false" or value:match("^[%s%[{&*!|>'\"%%@`#-]")
    or value:match(":%s") or value:match(":$") or value:match("%s#") or value:match("%s$") then
    return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
  end
  return value
end

-- task.md's lines as its header's attributes and the text under it; attrs is nil without a header.
-- Only plain YAML is read: key: value, a key over "- item" lines, and key: [a, "b"] on one line.
---@return table? attrs, string[] body
local function parse(lines)
  if lines[1] ~= "---" then
    return nil, lines
  end
  local attrs, list = {}, nil
  for i = 2, #lines do
    local line = lines[i]
    if line == "---" then
      return attrs, vim.list_slice(lines, i + 1)
    end
    local item = list and line:match("^%s*%-%s+(.-)%s*$")
    if item then
      table.insert(attrs[list], unquote(item))
    else
      local key, value = line:match("^([%w_-]+):%s*(.-)%s*$")
      list = nil
      local flow = key and value:match("^%[(.*)%]$")
      if key and (value == "" or flow) then
        attrs[key], list = {}, not flow and key or nil
        for item in (flow or ""):gmatch("[^,]+") do
          item = vim.trim(item)
          if item ~= "" then
            table.insert(attrs[key], unquote(item))
          end
        end
      elseif key then
        attrs[key] = value == "true" or (value ~= "false" and unquote(value))
      end
    end
  end
  -- No closing ---: not a header after all.
  return nil, lines
end

local function header(attrs)
  local keys = vim.tbl_filter(function(key)
    return not vim.tbl_contains(ORDER, key)
  end, vim.tbl_keys(attrs))
  table.sort(keys)
  local lines = { "---" }
  for _, key in ipairs(vim.list_extend(vim.deepcopy(ORDER), keys)) do
    local value = attrs[key]
    if type(value) == "table" then
      lines[#lines + 1] = key .. ":" .. (#value == 0 and " []" or "")
      for _, item in ipairs(value) do
        lines[#lines + 1] = "  - " .. quote(tostring(item))
      end
    elseif value ~= nil then
      lines[#lines + 1] = ("%s: %s"):format(key, type(value) == "boolean" and tostring(value) or quote(value))
    end
  end
  lines[#lines + 1] = "---"
  return lines
end

local function loaded_buf(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == path then
      return buf
    end
  end
end

-- task.md's lines: its buffer's if it's loaded, which may have changes not yet written.
local function file_lines(path)
  local buf = loaded_buf(path)
  if buf then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
end

-- Writes task.md as attrs' header over body; into its buffer and saved, if it's loaded.
local function write_file(slug, attrs, body)
  local path = M.dir(slug) .. "/task.md"
  local lines = vim.list_extend(header(attrs), body)
  local buf = loaded_buf(path)
  if buf then
    -- Only its header: what's typed under it stays (and is saved with it, as the header is read from disk).
    local now = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local _, under = parse(now)
    vim.api.nvim_buf_set_lines(buf, 0, #now - #under, false, header(attrs))
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
  else
    vim.fn.writefile(lines, path)
  end
end

-- The task's orchestration changed (icarus.orchestration): its agents told, once the change is in.
local function switched(slug, before, after)
  local style = require("icarus.orchestration")
  local from, to = style.style({ attrs = before }), style.style({ attrs = after })
  if from ~= to and before.title and _G.icarus_open_chats then
    vim.schedule(function()
      style.switched(slug, from, to)
    end)
  end
  local auto = after.auto == true
  if auto ~= (before.auto == true) and to == "router-worker" and before.title and _G.icarus_open_chats then
    vim.schedule(function()
      style.auto_changed(slug, auto)
    end)
  end
end

local function read_json(slug)
  local path = M.dir(slug) .. "/task.json"
  local ok, attrs = pcall(vim.json.decode, vim.fn.filereadable(path) == 1 and table.concat(vim.fn.readfile(path), "\n") or "")
  return ok and type(attrs) == "table" and attrs or nil
end

-- Written whole and renamed into place, so a reader never sees half of it.
local function write_json(slug, attrs)
  local path = M.dir(slug) .. "/task.json"
  local tmp = path .. ".tmp"
  vim.fn.writefile({ vim.json.encode(attrs) }, tmp)
  assert(vim.uv.fs_rename(tmp, path))
end

-- What task.json should hold: the header's attributes over the ones it can't lose.
local function merge(slug, stored, edited)
  local attrs = edited and vim.deepcopy(edited) or vim.deepcopy(stored)
  for key in pairs(REQUIRED) do
    if attrs[key] == nil or attrs[key] == "" and key ~= "created" then
      attrs[key] = stored[key]
    end
  end
  attrs.title = attrs.title or (slug == M.SENTINEL and "(no task)" or slug)
  attrs.created = attrs.created or ""
  if slug == M.SENTINEL then
    attrs.status, attrs.sentinel = nil, true
  else
    attrs.status = (attrs.status ~= nil and attrs.status ~= "") and attrs.status or stored.status or "spec"
    attrs.sentinel = nil
  end
  if attrs.pinned == true then
    attrs.status = nil
  else
    attrs.pinned = nil
  end
  -- A flag is on or absent, so turning one off leaves nothing in the header.
  for _, flag in ipairs({ "high", "today" }) do
    if attrs[flag] ~= true then
      attrs[flag] = nil
    end
  end
  if attrs.expected == "" then
    attrs.expected = nil
  end
  if type(attrs.links) == "string" and attrs.links ~= "" then
    attrs.links = { attrs.links }
  elseif type(attrs.links) ~= "table" then
    attrs.links = {}
  end
  return attrs
end

-- Brings task.json and task.md's header together: the header's attributes go into task.json, and a
-- header that's gone, or lost one it can't, is drawn again from task.json. It reads task.md as saved,
-- and leaves it to the next save while its buffer has changes. spec.md, task.md's old name, is renamed.
---@return table attrs
function M.sync(slug)
  local dir = M.dir(slug)
  if vim.fn.filereadable(dir .. "/task.md") == 0 and vim.fn.filereadable(dir .. "/spec.md") == 1 then
    vim.uv.fs_rename(dir .. "/spec.md", dir .. "/task.md")
  end
  local stored = read_json(slug) or {}
  local path = dir .. "/task.md"
  local edited, body = parse(vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {})
  local attrs = merge(slug, stored, edited)
  if not vim.deep_equal(attrs, stored) then
    write_json(slug, attrs)
    switched(slug, stored, attrs)
  end
  local buf = loaded_buf(path)
  if not vim.deep_equal(attrs, edited) and not (buf and vim.bo[buf].modified) then
    write_file(slug, attrs, buf and select(2, parse(file_lines(path))) or body)
  end
  return attrs
end

-- Makes the sentinel if it isn't there.
local function ensure_sentinel()
  vim.fn.mkdir(M.dir(M.SENTINEL) .. "/agents", "p")
end

-- Each task's title and status as last read, for what's drawn often (the statusline); in _G, so a
-- hot reload keeps it.
_G.icarus_task_seen = _G.icarus_task_seen or {}
local seen = _G.icarus_task_seen ---@type table<string, {title: string, status?: string}>

---@return icarus.Task?
function M.read(slug)
  local dir = M.dir(slug)
  if vim.fn.isdirectory(dir) == 0 then
    return nil
  end
  local attrs = M.sync(slug)
  seen[slug] = { title = attrs.title, status = attrs.status, orchestration = attrs.orchestration, auto = attrs.auto == true }
  return { slug = slug, dir = dir, file = dir .. "/task.md", title = attrs.title, status = attrs.status,
    created = attrs.created, links = attrs.links, sentinel = attrs.sentinel == true, pinned = attrs.pinned == true,
    today = attrs.today == true, high = attrs.high == true, attrs = attrs }
end

-- slug's title and status as last read, read now if they never were; nil for a task that's gone.
---@return {title: string, status?: string}?
function M.seen(slug)
  if not seen[slug] then
    if slug == M.SENTINEL then
      M.sentinel()
    else
      M.read(slug)
    end
  end
  return seen[slug]
end

-- The text under task.md's header.
---@param task icarus.Task
---@return string[]
function M.body(task)
  local _, body = parse(file_lines(task.file))
  return body
end

---@return icarus.Task the sentinel
function M.sentinel()
  ensure_sentinel()
  return assert(M.read(M.SENTINEL))
end

-- The pinned task (pinned: true), the one that lives outside the board, if there is one.
---@return icarus.Task?
function M.pinned()
  for _, task in ipairs(M.list()) do
    if task.pinned then
      return task
    end
  end
end

---@return icarus.Task[] the sentinel first, then newest first
function M.list()
  ensure_sentinel()
  local tasks = {}
  for name, kind in vim.fs.dir(M.ROOT .. "/tasks") do
    if (kind == "directory" or kind == "link" and vim.fn.isdirectory(M.dir(name)) == 1) and name ~= M.SENTINEL then
      tasks[#tasks + 1] = M.read(name)
    end
  end
  table.sort(tasks, function(a, b)
    return a.created > b.created
  end)
  table.insert(tasks, 1, M.sentinel())
  return tasks
end

-- Sets attributes in task.json, then task.md's header to match, keeping the text under it.
---@param task icarus.Task
---@param changes table
function M.set(task, changes)
  local attrs = M.sync(task.slug)
  local _, body = parse(file_lines(task.file))
  local before = attrs
  attrs = merge(task.slug, attrs, vim.tbl_extend("force", attrs, changes))
  seen[task.slug] = { title = attrs.title, status = attrs.status, orchestration = attrs.orchestration, auto = attrs.auto == true }
  write_json(task.slug, attrs)
  write_file(task.slug, attrs, body)
  switched(task.slug, before, attrs)
end

---@param task icarus.Task
function M.set_status(task, status)
  assert(not task.sentinel, "(no task) has no status")
  assert(not task.pinned, task.title .. " is pinned: it has no status")
  assert(vim.tbl_contains(M.STATUSES, status), "no status " .. status)
  M.set(task, { status = status })
end

-- Moves the task's folder, its agents' dirs with it, to ~/.icarus/trash.
---@param task icarus.Task
---@return string where it went
function M.delete(task)
  assert(not task.sentinel, "(no task) can't be deleted")
  assert(not task.pinned, task.title .. " is pinned and can't be deleted")
  local trash = M.ROOT .. "/trash"
  vim.fn.mkdir(trash, "p")
  local to = ("%s/%s-%s"):format(trash, task.slug, os.date("%Y%m%d-%H%M%S"))
  assert(vim.uv.fs_rename(task.dir, to))
  return to
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

-- Makes a task with nothing written under its header yet; a slug already taken gets a number.
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
  local attrs = { title = title, status = "spec", created = os.date("%Y-%m-%dT%H:%M:%S"), links = {} }
  write_json(slug, attrs)
  write_file(slug, attrs, { "" })
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
