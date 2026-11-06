-- A task's agents as a tree, a fork under the agent it forked from and an agent's subagents under
-- it, each with its status and how long its turn has run, for the outline (icarus.outline).
--
-- An agent's name is its file's in ~/.icarus/tasks/<slug>/org/ (a file per agent, first line
-- "chat: <chat id>", which agents rename for their role), else its chat's title. icarus makes a file
-- for an agent that has none (agent-<n>).
local chats = require("icarus.chats")
local tasks = require("icarus.tasks")

local M = {}

local GLYPH = { working = "●", ["needs you"] = "◆", idle = "○" }
local STATUS_HL = { working = "DiagnosticWarn", ["needs you"] = "DiagnosticError" }

function M.dir(slug)
  return tasks.dir(slug) .. "/org"
end

-- The chat id a file names, read again only when the file changes.
local ids = {}
function M.chat_of(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil
  end
  local seen = ids[path]
  if not (seen and seen.mtime == stat.mtime.sec and seen.size == stat.size) then
    local first = vim.fn.readfile(path, "", 1)[1] or ""
    seen = { mtime = stat.mtime.sec, size = stat.size, id = first:match("^%s*chat:%s*(%S+)") }
    ids[path] = seen
  end
  return seen.id
end

-- Makes a file for each of the task's agents that has none.
function M.ensure(task)
  local dir = M.dir(task.slug)
  vim.fn.mkdir(dir, "p")
  local have = {}
  for name, kind in vim.fs.dir(dir, { depth = 20 }) do
    if kind == "file" then
      local id = M.chat_of(dir .. "/" .. name)
      if id then
        have[id] = true
      end
    end
  end
  for _, record in ipairs(chats.on_task(task.slug)) do
    if not have[record.id] then
      local n = record.cwd:match("/agents/(%d+)$")
      local name = n and ("agent-" .. n) or ("agent-" .. record.id)
      local path = dir .. "/" .. name
      local i = 1
      while vim.fn.filereadable(path) == 1 do
        i = i + 1
        path = ("%s/%s-%d"):format(dir, name, i)
      end
      vim.fn.writefile({ "chat: " .. record.id }, path)
    end
  end
end

-- Each agent's name from its file in org/, by chat id; the default agent-<n> names don't count.
local function names(slug)
  local dir, out = M.dir(slug), {}
  for name, kind in vim.fs.dir(dir, { depth = 20 }) do
    if kind == "file" then
      local id = M.chat_of(dir .. "/" .. name)
      local base = vim.fs.basename(name)
      if id and not base:match("^agent%-") then
        out[id] = base
      end
    end
  end
  return out
end

-- The rows of the tree: {tree, glyph, hl, name, status, note, target}.
function M.rows(task)
  local records = chats.on_task(task.slug)
  local by_id, children, roots = {}, {}, {}
  for _, record in ipairs(records) do
    by_id[record.id] = record
  end
  table.sort(records, function(a, b)
    return a.id < b.id
  end)
  for _, record in ipairs(records) do
    local of = require("icarus.orchestration").parent(record)
    local parent = of and by_id[of] and of
    if parent then
      children[parent] = children[parent] or {}
      table.insert(children[parent], record)
    else
      roots[#roots + 1] = record
    end
  end
  local named = names(task.slug)
  local out = {}
  local function add(record, prefix, last, depth)
    local open = _G.icarus_open_chats and _G.icarus_open_chats[record.id]
    local now, note = require("icarus.graph").agent(record)
    local name = named[record.id] or (record.title or "new chat"):gsub("^⑂%s*", ""):gsub("^You are%s+", "")
    local branch = depth == 0 and "" or (last and "└ " or "├ ")
    local rest = depth == 0 and "" or (last and "  " or "│ ")
    out[#out + 1] = { tree = prefix .. branch, glyph = GLYPH[now] or "○", hl = STATUS_HL[now], status = now,
      name = name, note = record.retired and "retired" or note ~= "" and note ~= "not open" and note or nil,
      target = { chat = record.id } }
    local kids = {}
    for _, kid in ipairs(children[record.id] or {}) do
      kids[#kids + 1] = { record = kid }
    end
    for id, child in pairs(open and open.subagents or {}) do
      kids[#kids + 1] = { child = child, id = id }
    end
    for i, kid in ipairs(kids) do
      local kid_last = i == #kids
      local kid_prefix = prefix .. rest
      if kid.record then
        add(kid.record, kid_prefix, kid_last, depth + 1)
      else
        local sub = require("icarus.subagents")
        local running = sub.running(kid.child)
        out[#out + 1] = { tree = kid_prefix .. (kid_last and "└ " or "├ "), glyph = running and "◌" or "·",
          status = running and "working" or "idle", name = sub.label(kid.child),
          note = running and "subagent" or kid.child.state, target = { subagent = kid.id } }
      end
    end
  end
  for i, record in ipairs(roots) do
    add(record, "", i == #roots, 0)
  end
  return out
end

return M
