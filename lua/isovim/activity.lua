-- An agent's activity over the last 10 minutes, for its row in the sidebar: 8 buckets of its journal's
-- lines, so stuck reads differently from busy. A journal grows to tens of MB and streams while it
-- does, so only what's new since the last look is read (the end of it, the first time), its "ts"s
-- counted without decoding a line, and one no line has reached in 10 minutes isn't read at all.
local M = {}

local BUCKETS, SECONDS = 8, 75
local FIRST_READ = 256 * 1024
local BARS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

local seen = {} ---@type table<string, {offset: integer, counts: table<integer, integer>}> by journal path

local function read_new(path, size, state)
  local from = math.max(state.offset, size - FIRST_READ)
  local file = vim.uv.fs_open(path, "r", 420)
  local data = file and vim.uv.fs_read(file, size - from, from)
  if file then
    vim.uv.fs_close(file)
  end
  -- Through its last whole line; the rest is read when it's finished.
  local whole = data and data:find("\n[^\n]*$")
  if not whole then
    return
  end
  state.offset = from + whole
  for ts in data:sub(1, whole):gmatch('"ts":(%d+)') do
    local bucket = math.floor(tonumber(ts) / SECONDS)
    state.counts[bucket] = (state.counts[bucket] or 0) + 1
  end
end

-- The agent's trace, one bar a bucket, oldest first, a blank where nothing happened and taller by
-- each doubling of lines; nil if nothing did in all of them.
---@return string?
function M.trace(ws, agent)
  local path = require("isovim.acp.journal").path(ws, agent)
  local stat = vim.uv.fs_stat(path)
  local now = os.time()
  if not stat or now - stat.mtime.sec >= BUCKETS * SECONDS then
    seen[path] = nil
    return nil
  end
  local state = seen[path]
  -- A journal shorter than we've read is a new one (a session started over).
  if not state or stat.size < state.offset then
    state = { offset = 0, counts = {} }
    seen[path] = state
  end
  if stat.size > state.offset then
    read_new(path, stat.size, state)
  end
  local newest = math.floor(now / SECONDS)
  local bars, any = {}, false
  for bucket = newest - BUCKETS + 1, newest do
    local count = state.counts[bucket]
    any = any or count ~= nil
    bars[#bars + 1] = count and BARS[math.min(#BARS, 1 + math.floor(math.log(count) / math.log(2)))] or " "
  end
  for bucket in pairs(state.counts) do
    if bucket <= newest - BUCKETS then
      state.counts[bucket] = nil
    end
  end
  return any and table.concat(bars) or nil
end

return M
