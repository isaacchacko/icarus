-- Tasks: what the board's cards are (isovim.thread_board), each with its own view (isovim.task_view) and
-- the traits of a Linear issue: an id, title, markdown description, status (the board's column),
-- priority, assignee, labels, due date, estimate, relations to other tasks, its PRs and tickets, when
-- it was made and last changed, and a log of each change. A task's threads fill what sub-issues do in
-- Linear, and a thread is its conversation, so there are no sub-issues or comments; the repo is the
-- project, so no projects or cycles. A thread is on one task at most (a task entry in the thread's file).
--
-- Only the user makes or changes one, by keys: no agent can, and there's no command for it at any role.
-- Agents read them (iso <role> task ls|show, thread board, thread show, a thread's prompt), and any
-- role may link or unlink a PR or ticket, since they make most of those: linking moves nothing and
-- tells nobody. An assignee only labels the card.
--
-- They're iso/threads/tasks.jsonl in the repo's iso/ (ids k1, k2...), appended to, a JSON object a line:
--   {kind = "task", id, title, by, at}              its start, in Working
--   {kind = "set", id, field, value, by, at}        field: title, description, priority, assignee, due, estimate
--   {kind = "renamed", id, title, at}, {kind = "priority", id, value, at}    as the first tasks wrote them
--   {kind = "column", id, on, moved?, by, at}       its status. moved: the threads going into Done resolved,
--                                                   for going back to open again
--   {kind = "tag", id, name, on, by, at}            a label on it or off
--   {kind = "label", name, color, by, at}           a label of the repo's, color indexing M.PALETTE
--   {kind = "relation", id, other, type = "blocks"|"related", on, by, at}
--   {kind = "link", id, ref, type = "pr"|"linear", url?, title?, by, at}, {kind = "unlink", id, ref, by, at}
--   {kind = "thread", id, thread, on, by, at}       a thread came onto it or left, for its log
--   {kind = "deleted", id, by, at}                  its threads are on no task again
local M = {}

M.COLUMN_NAMES = { backburner = "Backburner", working = "Working", checking = "Checking", done = "Done" }
M.PRIORITIES = { [0] = "none", "urgent", "high", "medium", "low" }
M.ESTIMATES = { 1, 2, 3, 5, 8, 13 }
M.PALETTE = {
  { "red", "#E06C75" },
  { "orange", "#E8833A" },
  { "yellow", "#E5C07B" },
  { "green", "#98C379" },
  { "teal", "#56B6C2" },
  { "blue", "#61AFEF" },
  { "purple", "#C678DD" },
  { "gray", "#8A8F98" },
}

function M.file(repo)
  return require("isovim.threads").dir(repo) .. "/tasks.jsonl"
end

local function say_value(field, value)
  if value == nil or value == vim.NIL or value == "" then
    return "none"
  elseif field == "priority" then
    return M.PRIORITIES[tonumber(value) or 0] or tostring(value)
  elseif field == "assignee" then
    return M.assignee_name(value)
  end
  return tostring(value)
end

local function remove(list, match)
  for i = #list, 1, -1 do
    if match(list[i]) then
      table.remove(list, i)
    end
  end
end

local function fresh_task(entry)
  return { id = entry.id, title = entry.title or entry.id, description = "", column = "working", priority = 0, labels = {},
    blocks = {}, blocked_by = {}, related = {}, links = {}, at = entry.at or 0, last_at = entry.at or 0,
    activity = { { at = entry.at or 0, by = entry.by or "user", what = "made it" } } }
end

-- Applies one line to what's been read, noting it in the task's log.
local function apply(entry, tasks, labels)
  if entry.kind == "label" then
    if type(entry.name) == "string" then
      labels[entry.name] = tonumber(entry.color) or 1
    end
    return
  elseif entry.kind == "task" then
    if type(entry.id) == "string" then
      tasks[entry.id] = fresh_task(entry)
    end
    return
  end
  local task = tasks[entry.id]
  if not task then
    return
  end
  task.last_at = entry.at or task.last_at
  local function log(what)
    task.activity[#task.activity + 1] = { at = entry.at or 0, by = entry.by or "user", what = what }
  end
  if entry.kind == "renamed" or (entry.kind == "set" and entry.field == "title") then
    local title = entry.title or entry.value or task.title
    log(("renamed it from %q to %q"):format(task.title, title))
    task.title = title
  elseif entry.kind == "set" then
    local value = entry.value ~= vim.NIL and entry.value or nil
    if entry.field == "description" then
      log("edited the description")
      task.description = value or ""
    else
      log(("set %s %s → %s"):format(entry.field, say_value(entry.field, task[entry.field]), say_value(entry.field, value)))
      task[entry.field] = entry.field == "priority" and (tonumber(value) or 0) or value
    end
  elseif entry.kind == "priority" then
    local value = tonumber(entry.value) or 0
    log(("set priority %s → %s"):format(say_value("priority", task.priority), say_value("priority", value)))
    task.priority = value
  elseif entry.kind == "column" then
    log(("set status %s → %s%s"):format(M.COLUMN_NAMES[task.column] or task.column, M.COLUMN_NAMES[entry.on] or entry.on,
      entry.moved and #entry.moved > 0 and (", resolving " .. table.concat(entry.moved, ", ")) or ""))
    task.column, task.moved = entry.on, entry.moved
  elseif entry.kind == "tag" then
    remove(task.labels, function(name)
      return name == entry.name
    end)
    if entry.on then
      table.insert(task.labels, entry.name)
    end
    log(("%s label %s"):format(entry.on and "added" or "removed", entry.name))
  elseif entry.kind == "relation" then
    local list = entry.type == "related" and task.related or task.blocks
    remove(list, function(other)
      return other == entry.other
    end)
    if entry.on then
      table.insert(list, entry.other)
    end
    log(("%s %s %s"):format(entry.on and "added" or "removed", entry.type == "related" and "related to" or "blocks", entry.other))
  elseif entry.kind == "link" then
    remove(task.links, function(link)
      return link.ref == entry.ref
    end)
    table.insert(task.links, { ref = entry.ref, type = entry.type, url = entry.url, title = entry.title, by = entry.by, at = entry.at })
    log(("linked %s"):format(entry.ref))
  elseif entry.kind == "unlink" then
    remove(task.links, function(link)
      return link.ref == entry.ref
    end)
    log(("unlinked %s"):format(entry.ref))
  elseif entry.kind == "thread" then
    log(entry.on and ("put %s on it"):format(entry.thread) or ("took %s off it"):format(entry.thread))
  elseif entry.kind == "deleted" then
    tasks[entry.id] = nil
  end
end

-- The repo's tasks by id, deleted ones left out, and its labels (name to palette index).
---@return table<string, table> tasks, table<string, integer> labels
function M.read(repo)
  local tasks, labels = {}, {}
  local file = io.open(M.file(repo), "rb")
  if not file then
    return tasks, labels
  end
  local text = file:read("*a")
  file:close()
  for line in text:gmatch("[^\n]+") do
    local ok, entry = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(entry) == "table" then
      apply(entry, tasks, labels)
    end
  end
  -- Relations both ways, between tasks still here.
  for id, task in pairs(tasks) do
    local function here(other)
      return tasks[other] ~= nil
    end
    task.blocks = vim.tbl_filter(here, task.blocks)
    task.related = vim.tbl_filter(here, task.related)
    for _, other in ipairs(task.blocks) do
      table.insert(tasks[other].blocked_by, id)
    end
  end
  for id, task in pairs(tasks) do
    for _, other in ipairs(task.related) do
      if not vim.tbl_contains(tasks[other].related, id) then
        table.insert(tasks[other].related, id)
      end
    end
  end
  return tasks, labels
end

local function append(repo, entry)
  entry.at = entry.at or os.time()
  vim.fn.mkdir(require("isovim.threads").dir(repo), "p")
  local file = assert(io.open(M.file(repo), "ab"))
  file:write(vim.json.encode(entry) .. "\n")
  file:close()
  return entry
end

-- A new task, titled title, in Working; its id, or nil and why.
---@return string? id, string? err
function M.new(repo, title)
  title = vim.trim((title or ""):gsub("%s+", " "))
  if title == "" then
    return nil, "a task needs a title"
  end
  local n = 0
  local file = io.open(M.file(repo), "rb")
  for id in (file and file:read("*a") or ""):gmatch('"id":"k(%d+)"') do
    n = math.max(n, tonumber(id) or 0)
  end
  if file then
    file:close()
  end
  local id = "k" .. (n + 1)
  append(repo, { kind = "task", id = id, title = title, by = "user" })
  return id
end

-- A trait, from the user's keys: value nil clears it.
function M.set(repo, id, field, value)
  if field == "title" then
    value = vim.trim((value or ""):gsub("%s+", " "))
    if value == "" then
      return
    end
  end
  append(repo, { kind = "set", id = id, field = field, value = value == nil and vim.NIL or value, by = "user" })
end

function M.set_priority(repo, id, value)
  M.set(repo, id, "priority", value)
end

-- Moves a task to a column: into Done resolves its open threads, prompting nobody, and noting which;
-- out of Done opens those again, and no others. The only thing that changes its column.
function M.move(repo, id, on)
  local threads = require("isovim.threads")
  local task = M.read(repo)[id]
  if not task or task.column == on then
    return
  end
  local moved
  if on == "done" then
    moved = {}
    for _, info in ipairs(threads.list(repo, true)) do
      if info.task == id then
        if info.status ~= "resolved" then
          threads.resolve(repo, info.id, "user")
          moved[#moved + 1] = info.id
        end
        threads.dismiss(repo, info.id)
        require("isovim.surfaces").opened(repo, "threads/" .. info.id .. ".jsonl")
      end
    end
  elseif task.column == "done" then
    for _, thread in ipairs(task.moved or {}) do
      if threads.summary(threads.read(repo, thread) or {}).status == "resolved" then
        threads.resolve(repo, thread, "user", nil, true)
      end
    end
  end
  append(repo, { kind = "column", id = id, on = on, moved = moved, by = "user" })
end

-- Puts a label on the task or takes it off.
function M.tag(repo, id, name, on)
  append(repo, { kind = "tag", id = id, name = name, on = on, by = "user" })
end

-- A label of the repo's, with its color.
function M.define_label(repo, name, color)
  append(repo, { kind = "label", name = name, color = color, by = "user" })
end

-- Whether id blocks other ("blocks"), or they're related ("related").
function M.relate(repo, id, other, type_, on)
  append(repo, { kind = "relation", id = id, other = other, type = type_, on = on, by = "user" })
end

-- What a link's ref names: a PR (a URL, owner/repo#n, #n or n in repo) or a Linear ticket (its URL or its
-- identifier, ABC-123). Nil and why for anything else.
---@return {ref: string, type: "pr"|"linear", url?: string}? link, string? err
function M.parse_ref(repo, ref)
  ref = vim.trim(ref or "")
  local number = ref:match("^#?(%d+)$")
  local pr = number and repo:find("/", 1, true) and ("https://github.com/%s/pull/%s"):format(repo, number)
    or require("isovim.prs").normalize(ref)
  if pr then
    local owner_repo, n = pr:match("github%.com/([^/]+/[^/]+)/pull/(%d+)")
    return { ref = ("%s#%s"):format(owner_repo:lower(), n), type = "pr", url = pr }
  end
  local slug, ticket = ref:match("^https?://linear%.app/([^/]+)/issue/([%w]+%-%d+)")
  if slug then
    return { ref = ticket:upper(), type = "linear", url = ("https://linear.app/%s/issue/%s"):format(slug, ticket:upper()) }
  elseif ref:match("^%a[%w]*%-%d+$") then
    return { ref = ref:upper(), type = "linear" }
  end
  return nil, ("%s isn't a PR (a URL, owner/repo#n or #n) or a Linear ticket (its URL, or ABC-123)"):format(ref)
end

-- Links a PR or ticket to the task, by any role: it moves nothing and tells nobody. Its ref as stored,
-- or nil and why.
---@return string? ref, string? err
function M.link(repo, id, ref, title, by)
  if not M.read(repo)[id] then
    return nil, ("%s has no task %s"):format(repo, id)
  end
  local link, err = M.parse_ref(repo, ref)
  if not link then
    return nil, err
  end
  title = title and vim.trim(title) ~= "" and vim.trim(title) or nil
  append(repo, { kind = "link", id = id, ref = link.ref, type = link.type, url = link.url, title = title, by = by })
  -- Registered too, so its row has the state the PRs surface has.
  if link.type == "pr" and not vim.tbl_contains(require("isovim.store").prs(repo), link.url) then
    require("isovim.store").add_pr(repo, link.url, by)
  end
  return link.ref
end

---@return string? ref, string? err
function M.unlink(repo, id, ref, by)
  local task = M.read(repo)[id]
  if not task then
    return nil, ("%s has no task %s"):format(repo, id)
  end
  local link = M.parse_ref(repo, ref)
  local known = link and vim.iter(task.links):find(function(each)
    return each.ref == link.ref
  end)
  if not known then
    return nil, ("%s isn't linked to %s"):format(ref, id)
  end
  append(repo, { kind = "unlink", id = id, ref = known.ref, by = by })
  return known.ref
end

-- A thread came onto the task or left it: a line in its log.
function M.note_thread(repo, id, thread, on, by)
  if id and M.read(repo)[id] then
    append(repo, { kind = "thread", id = id, thread = thread, on = on, by = by })
  end
end

function M.delete(repo, id)
  append(repo, { kind = "deleted", id = id, by = "user" })
end

-- Where a linked ticket opens: its URL, or with only its identifier, by the workspace of any URL the
-- repo's tasks hold, else Linear's own way to one.
function M.link_url(repo, link)
  if link.url then
    return link.url
  end
  for _, task in pairs(M.read(repo)) do
    for _, each in ipairs(task.links) do
      local slug = each.type == "linear" and each.url and each.url:match("linear%.app/([^/]+)/")
      if slug then
        return ("https://linear.app/%s/issue/%s"):format(slug, link.ref)
      end
    end
  end
  return "https://linear.app/issue/" .. link.ref
end

-- An assignee, in a few letters: you, or an agent by its name.
function M.assignee_name(value)
  if not value then
    return nil
  elseif value == "user" then
    return "you"
  end
  local ws, id = value:match("^(.*)/([^/]+)$")
  local record = ws and require("isovim.store").agent(ws, id)
  return record and record.name or id or value
end

-- A task as text, for agents.
function M.summary_line(repo, task)
  local parts = { M.COLUMN_NAMES[task.column] or task.column }
  if (task.priority or 0) > 0 then
    parts[#parts + 1] = M.PRIORITIES[task.priority]
  end
  if task.assignee then
    parts[#parts + 1] = "@" .. (M.assignee_name(task.assignee) or task.assignee)
  end
  if #task.labels > 0 then
    parts[#parts + 1] = table.concat(task.labels, ",")
  end
  if task.due then
    parts[#parts + 1] = "due " .. task.due
  end
  if task.estimate then
    parts[#parts + 1] = "estimate " .. task.estimate
  end
  return ("%s  %s  [%s]"):format(task.id, task.title, table.concat(parts, ", "))
end

return M
