-- isovim's event bus. Whoever changes something appends one JSON line, {topic, time, ...details}, to
-- ~/.isovim/events/events.jsonl: the TUI, any `iso` command and bin/iso-hook alike, so events flow
-- whether or not the TUI is open. A listener (`iso listen`) watches the folder for changes (kqueue/
-- FSEvents or inotify, through libuv) and reads only the bytes added since it last looked: nothing
-- runs while nothing happens. Past 1 MiB the log moves to events.jsonl.1 and a new one starts.
--
-- Topics are dot-separated parts; an address (<ws>/<agent>, <owner>/<repo>/aN) or a repo
-- (<owner>/<repo>) is one part:
--   agent.<addr>.status    its hooks wrote a new state      {addr, state, previous}
--   agent.<addr>.spawned   its program started              {addr, kind, name, role, parent}
--   agent.<addr>.exited    its program ended                {addr, reason: stopped|ended}
--   agent.<addr>.promoted  its role changed                 {addr, role, previous}
--   msg.<addr>             a message was typed into it      {addr, from, kind, id, text}
--   pr.<repo>.<n>.state|ci|review   a registered PR changed   {repo, number, url, ws, title, ..., previous}
-- Inside a part "%" is written %25 and then "." %2E (M.encode), so agent owner/site.com/a3's status
-- is agent.owner/site%2Ecom/a3.status. Every publisher builds its topic with M.topic, which encodes
-- each part (bin/iso-hook escapes the same way); patterns are matched against the encoded topic as
-- given, never decoded, and the details carry addr and repo raw.
-- Surfaces (surface.*), the root's decisions (root.*) and other hosts (host.*, <host>: prefixes)
-- publish here too once they exist.
local store = require("isovim.store")

local M = {}

M.dir = store.root .. "/events"
M.log = M.dir .. "/events.jsonl"
M.max_bytes = 1024 * 1024

-- What `iso listen` completes and its help lists.
M.topics = {
  { "agent.*.status", "an agent's state changed" },
  { "agent.*.spawned", "an agent started" },
  { "agent.*.exited", "an agent stopped or ended" },
  { "agent.*.promoted", "an agent's role changed" },
  { "msg.*", "a message reached an agent" },
  { "pr.*.*.state", "a PR opened, merged, closed or left draft" },
  { "pr.*.*.ci", "a PR's checks changed" },
  { "pr.*.*.review", "a PR's review decision changed" },
  { "**", "everything" },
}

local function now()
  local sec, usec = vim.uv.gettimeofday()
  return sec + math.floor(usec / 1000) / 1000
end

-- One part of a topic, as it's written: "%" as %25, then "." as %2E.
function M.encode(value)
  return (tostring(value):gsub("%%", "%%25"):gsub("%.", "%%2E"))
end

-- A topic from its parts, each encoded: topic("pr", "o/site.com", 7, "ci") is pr.o/site%2Ecom.7.ci.
function M.topic(...)
  return table.concat(vim.tbl_map(M.encode, { ... }), ".")
end

-- Appends the event in one write, so lines from concurrent publishers never interleave. Uses only
-- vim.uv and vim.json, so it runs from libuv callbacks too.
---@param details? table
function M.publish(topic, details)
  local line = ('{"topic":%s,"time":%s'):format(vim.json.encode(topic), vim.json.encode(now()))
  if details and next(details) then
    line = line .. "," .. vim.json.encode(details):sub(2)
  else
    line = line .. "}"
  end
  vim.uv.fs_mkdir(store.root, 448)
  vim.uv.fs_mkdir(M.dir, 448)
  local stat = vim.uv.fs_stat(M.log)
  if stat and stat.size >= M.max_bytes then
    vim.uv.fs_rename(M.log, M.log .. ".1")
  end
  local fd = vim.uv.fs_open(M.log, "a", 420)
  if fd then
    vim.uv.fs_write(fd, line .. "\n")
    vim.uv.fs_close(fd)
  end
end

-- An agent's event, agent.<addr>.<what>, its details carrying the raw address.
---@param details? table
function M.publish_agent(ws, agent, what, details)
  local addr = ws .. "/" .. agent
  M.publish(M.topic("agent", addr, what), vim.tbl_extend("force", { addr = addr }, details or {}))
end

-- Whether a topic matches a pattern: parts split on ".", * is any one part, ** any number of them.
function M.matches(pattern, topic)
  local want = vim.split(pattern, ".", { plain = true })
  local have = vim.split(topic, ".", { plain = true })
  local function from(i, j)
    if i > #want then
      return j > #have
    elseif want[i] == "**" then
      for k = j, #have + 1 do
        if from(i + 1, k) then
          return true
        end
      end
      return false
    end
    return j <= #have and (want[i] == "*" or want[i] == have[j]) and from(i + 1, j + 1)
  end
  return from(1, 1)
end

-- A --since value: epoch seconds, or how long ago (90s, 10m, 2h, 1d).
---@return number?
function M.parse_since(text)
  local n, unit = (text or ""):match("^(%d+%.?%d*)([smhd]?)$")
  if not n then
    return nil
  elseif unit == "" then
    return tonumber(n)
  end
  return now() - tonumber(n) * ({ s = 1, m = 60, h = 3600, d = 86400 })[unit]
end

-- Calls on_event(line, event) for each event from now on, or from `since` (epoch seconds, read back
-- through the previous log too), and never returns. Each change to the folder wakes it once.
---@param on_event fun(line: string, event: table)
---@param since? number
function M.follow(on_event, since)
  local fd, inode, offset, partial
  local function emit(line)
    local ok, event = pcall(vim.json.decode, line)
    if ok and type(event) == "table" and type(event.topic) == "string" and (not since or (tonumber(event.time) or 0) >= since) then
      on_event(line, event)
    end
  end
  local function drain()
    while fd do
      local chunk = vim.uv.fs_read(fd, 65536, offset)
      if not chunk or chunk == "" then
        return
      end
      offset = offset + #chunk
      partial = partial .. chunk
      for line in partial:gmatch("([^\n]*)\n") do
        emit(line)
      end
      partial = partial:match("[^\n]*$")
    end
  end
  local function open(at_start)
    fd = vim.uv.fs_open(M.log, "r", 0)
    local stat = fd and vim.uv.fs_fstat(fd)
    inode, offset, partial = stat and stat.ino, stat and not at_start and stat.size or 0, ""
  end
  -- After the log moved aside, what was written to it before the move is read out, then the new one.
  local function catch_up()
    drain()
    local stat = vim.uv.fs_stat(M.log)
    if stat and stat.ino == inode and stat.size < offset then
      offset, partial = 0, ""
      drain()
    elseif stat and stat.ino ~= inode then
      if fd then
        vim.uv.fs_close(fd)
      end
      open(true)
      drain()
    end
  end

  vim.uv.fs_mkdir(store.root, 448)
  vim.uv.fs_mkdir(M.dir, 448)
  -- Watching before reading, so nothing written in between is missed.
  local watcher = assert(vim.uv.new_fs_event())
  watcher:start(M.dir, {}, vim.schedule_wrap(function(err)
    if not err then
      catch_up()
    end
  end))
  if since then
    local old = io.open(M.log .. ".1")
    for line in old and old:lines() or function() end do
      emit(line)
    end
    if old then
      old:close()
    end
  end
  open(since ~= nil)
  drain()
  for _, name in ipairs({ "sigterm", "sigint", "sighup" }) do
    vim.uv.new_signal():start(name, function()
      os.exit(0)
    end)
  end
  while true do
    vim.wait(2 ^ 31 - 1, function()
      return false
    end, 2 ^ 31 - 1)
  end
end

return M
