-- Your chats: each a record {id, cwd, created, title?, session?} kept in stdpath("data")/chats.json,
-- and a status while it's open: working, idle, or needs you (a permission waits on you). Every
-- change fires User IcarusChats, which the sidebar redraws on.
local M = {}

local FILE = vim.fn.stdpath("data") .. "/chats.json"

---@class icarus.ChatRecord
---@field id string
---@field cwd string
---@field created integer
---@field title? string its first prompt's first line
---@field session? string its ACP session, loaded when it's opened again

-- In _G, so a hot reload keeps them.
_G.icarus_chats = _G.icarus_chats or { statuses = {} }
local state = _G.icarus_chats
local statuses = state.statuses ---@type table<string, "working"|"idle"|"needs you">

local function changed()
  vim.api.nvim_exec_autocmds("User", { pattern = "IcarusChats", modeline = false })
end

---@return icarus.ChatRecord[]
local function load()
  if state.records then
    return state.records
  end
  local file = io.open(FILE, "r")
  local ok, decoded = pcall(vim.json.decode, file and file:read("*a") or "[]")
  if file then
    file:close()
  end
  state.records = ok and type(decoded) == "table" and decoded or {}
  return state.records
end

function M.save()
  vim.fn.mkdir(vim.fs.dirname(FILE), "p")
  local file = assert(io.open(FILE, "w"))
  file:write(vim.json.encode(load()))
  file:close()
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

---@return icarus.ChatRecord
function M.create(cwd)
  local now = os.time()
  local record = { id = ("%d-%06d"):format(now, vim.uv.hrtime() % 1000000), cwd = cwd, created = now }
  table.insert(load(), record)
  M.save()
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
