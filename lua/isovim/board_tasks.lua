-- Tasks: what the thread board's cards are (isovim.thread_board). Only the user makes, renames, moves or
-- deletes one, by the board's keys: no agent can, and there's no command for it at any role. Agents read
-- them, in iso <role> thread board, a thread's prompt and thread show. A task has threads, each on one
-- task at most (a task entry in the thread's own file).
--
-- They're iso/threads/tasks.jsonl in the repo's iso/ (ids k1, k2...), appended to, a JSON object a line:
--   {kind = "task", id, title, by, at}               its start, in Working
--   {kind = "renamed", id, title, at}
--   {kind = "column", id, on = "backburner"|"working"|"checking"|"done", moved?, at}   moved: the threads
--                                                    that going into Done resolved, for H to open again
--   {kind = "priority", id, value (0-4), at}
--   {kind = "deleted", id, at}                       its threads are on no task again
local M = {}

function M.file(repo)
  return require("isovim.threads").dir(repo) .. "/tasks.jsonl"
end

-- The repo's tasks by id, deleted ones left out.
---@return table<string, {id: string, title: string, column: string, priority: integer, at: integer, moved?: string[]}>
function M.read(repo)
  local tasks = {}
  local file = io.open(M.file(repo), "rb")
  if not file then
    return tasks
  end
  local text = file:read("*a")
  file:close()
  for line in text:gmatch("[^\n]+") do
    local ok, entry = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(entry) == "table" and type(entry.id) == "string" then
      if entry.kind == "task" then
        tasks[entry.id] = { id = entry.id, title = entry.title or entry.id, column = "working", priority = 0, at = entry.at or 0, last_at = entry.at or 0 }
      else
        local task = tasks[entry.id]
        if task then
          task.last_at = entry.at or task.last_at
          if entry.kind == "renamed" then
            task.title = entry.title or task.title
          elseif entry.kind == "column" then
            task.column, task.moved = entry.on, entry.moved
          elseif entry.kind == "priority" then
            task.priority = tonumber(entry.value) or 0
          elseif entry.kind == "deleted" then
            tasks[entry.id] = nil
          end
        end
      end
    end
  end
  return tasks
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

function M.rename(repo, id, title)
  title = vim.trim((title or ""):gsub("%s+", " "))
  if title ~= "" then
    append(repo, { kind = "renamed", id = id, title = title })
  end
end

function M.set_column(repo, id, on, moved)
  append(repo, { kind = "column", id = id, on = on, moved = moved })
end

function M.set_priority(repo, id, value)
  append(repo, { kind = "priority", id = id, value = value })
end

function M.delete(repo, id)
  append(repo, { kind = "deleted", id = id })
end

return M
