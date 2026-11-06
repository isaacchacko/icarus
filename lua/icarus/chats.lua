-- Your chats: each a record {id, cwd, created, task?, title?, session?} kept in stdpath("data")/chats.json,
-- and a status while it's open: working, idle, or needs you (a permission waits on you). Every
-- change fires User IcarusChats.
local M = {}

local FILE = vim.fn.stdpath("data") .. "/chats.json"

---@class icarus.ChatRecord
---@field id string
---@field cwd string
---@field created integer
---@field task? string the slug of the task it's on (icarus.tasks); none is the sentinel, "(no task)"
---@field title? string its first prompt's first line
---@field session? string its ACP session, loaded when it's opened again
---@field model? string the model it runs at (<leader>M); the adapter's default when none
---@field effort? string its reasoning effort, for the model (<leader>M)

-- In _G, so a hot reload keeps them.
_G.icarus_chats = _G.icarus_chats or { statuses = {} }
local state = _G.icarus_chats
local statuses = state.statuses ---@type table<string, "working"|"idle"|"needs you">

local function changed()
  vim.api.nvim_exec_autocmds("User", { pattern = "IcarusChats", modeline = false })
end

---@return icarus.ChatRecord[]
local function read()
  local file = io.open(FILE, "r")
  local ok, decoded = pcall(vim.json.decode, file and file:read("*a") or "[]")
  if file then
    file:close()
  end
  return ok and type(decoded) == "table" and decoded or {}
end

---@return icarus.ChatRecord[] oldest first
local function load()
  state.records = state.records or read()
  return state.records
end

-- Saves the list, with mine the chat this window changed. Another icarus window may have saved
-- since this one read the file: its new chats are taken in, and for the rest the file's copy wins,
-- but for mine. Written whole and renamed into place, so the other window never reads half of it.
---@param mine? icarus.ChatRecord
function M.save(mine)
  local records, here, place = load(), {}, {}
  for i, record in ipairs(records) do
    here[record.id], place[record] = record, i
  end
  for _, saved in ipairs(read()) do
    local record = here[saved.id]
    if not record then
      records[#records + 1] = saved
      place[saved] = #records
    elseif record ~= mine then
      -- In place: an open chat holds this table.
      for key, value in pairs(saved) do
        record[key] = value
      end
    end
  end
  table.sort(records, function(a, b)
    if a.created ~= b.created then
      return a.created < b.created
    end
    return place[a] < place[b]
  end)
  vim.fn.mkdir(vim.fs.dirname(FILE), "p")
  local tmp = ("%s.%d.tmp"):format(FILE, vim.uv.os_getpid())
  local file = assert(io.open(tmp, "w"))
  file:write(vim.json.encode(records))
  file:close()
  assert(vim.uv.fs_rename(tmp, FILE))
  changed()
end

---@return icarus.ChatRecord[] newest first
function M.list()
  return vim.iter(load()):rev():totable()
end

---@return icarus.ChatRecord?
function M.get(id)
  for _, record in ipairs(load()) do
    if record.id == id then
      return record
    end
  end
end

---@return icarus.ChatRecord[] the chats on task slug, newest first
function M.on_task(slug)
  local sentinel = require("icarus.tasks").SENTINEL
  return vim.tbl_filter(function(record)
    return (record.task or sentinel) == slug
  end, M.list())
end

---@param task? string the task's slug; none puts it on "(no task)"
---@return icarus.ChatRecord
function M.create(cwd, task)
  local now = os.time()
  local record = { id = ("%d-%06d"):format(now, vim.uv.hrtime() % 1000000), cwd = cwd, created = now,
    task = task or require("icarus.tasks").SENTINEL }
  table.insert(load(), record)
  M.save(record)
  return record
end

function M.status(id)
  return statuses[id] or "idle"
end

function M.set_status(id, status)
  if statuses[id] ~= status then
    statuses[id] = status
    changed()
  end
end

return M
