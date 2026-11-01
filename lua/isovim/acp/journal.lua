-- An ACP agent's journal: everything its session did, one JSON line per entry, appended by its
-- supervisor (isovim.acp.host) and read by whoever shows the chat (isovim.acp.chat), which replays
-- it from the start and then follows it. It lives in the repo's iso/, as iso/journal/aN.jsonl.
--
-- Each line is {seq, ts, kind, ...}: seq counts up from 1 within the file, ts is epoch seconds.
--   session   {how: new|resume|load|fork|rewind, sessionId, imports?, previous?, cleared?, from?,
--             prompt?, files?}                    the session the supervisor holds, and the files
--                                                 its CLAUDE.md files @import; previous is the one
--                                                 it left (/new, /clear, /resume, a rewind), from
--                                                 the agent a fork came from, files what a rewind
--                                                 did to the files (isovim.acp.sessions)
--   mode      {modeId}                            the permission mode it set (bypassPermissions)
--   prompt    {id, text, via, from?, message?, stamp?}  a prompt sent to the agent: via is iso
--                                                 (iso send/msg), composer (the TUI), spawn, or
--                                                 claude (typed on Claude's screen, iso handover),
--                                                 load (from a loaded session's replay);
--                                                 from is the sender's address and message the
--                                                 message's kind, for iso send/msg; nil for you
--   queued    {id, text, via, from?, position}    a prompt held until the running turn ends
--   queue     {items: {id, text, via, from?}[]}   the whole queue after an edit, reorder, clear or
--                                                 send-now (a push is a queued entry)
--   update    {update, handover?}                 a raw ACP session/update, as the agent sent it
--                                                 (or made from Claude's transcript after a handover)
--   handover  {state: start|end, sessionId?, code?} the session was handed to Claude's own screen,
--                                                 or came back (code: claude's exit code)
--   turn      {state: start|end, stopReason?, id, snapshot?, snapshot_dir?}  a turn began or ended
--                                                 (stopReason from the agent); snapshot is the
--                                                 commit of the files before it, in snapshot_dir
--   permission {tool, toolCallId?, decision, repo?, name?, by?}  a permission the agent asked
--                                                 for: asked (its question surface repo/name),
--                                                 then allowed, denied or cancelled
--   question  {state: asked|answered|cancelled, id, questions?, answers?}  what the agent asked
--                                                 you (AskUserQuestion), as question surfaces
--   notice    {text}                              the supervisor's own words: errors, restarts
-- Raw updates are kept as they came so the renderer stays faithful to the protocol and new update
-- kinds need no change here.
local store = require("isovim.store")

local M = {}

function M.dir(ws)
  return store.path(ws) .. "/journal"
end

function M.path(ws, agent)
  return M.dir(ws) .. "/" .. agent .. ".jsonl"
end

local function now()
  local sec, usec = vim.uv.gettimeofday()
  return sec + math.floor(usec / 1000) / 1000
end

local function decode(line)
  local ok, entry = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  return ok and type(entry) == "table" and entry or nil
end

-- The last seq in the file: the last whole line that decodes, read back from the end a block at a
-- time, so a line longer than a block (a big tool result) is read whole.
local function last_seq(path)
  local fd = vim.uv.fs_open(path, "r", 0)
  if not fd then
    return 0
  end
  local pos = vim.uv.fs_fstat(fd).size
  -- The pieces of the line that starts before pos, nearest first once concatenated.
  local head = {}
  while pos > 0 do
    local from = math.max(0, pos - 65536)
    local chunk = vim.uv.fs_read(fd, pos - from, from) or ""
    pos = from
    if pos > 0 and not chunk:find("\n", 1, true) then
      table.insert(head, 1, chunk)
    else
      local lines = vim.split(chunk .. table.concat(head), "\n", { plain = true })
      head = pos > 0 and { table.remove(lines, 1) } or {}
      for i = #lines, 1, -1 do
        local entry = decode(lines[i])
        if entry and tonumber(entry.seq) then
          vim.uv.fs_close(fd)
          return tonumber(entry.seq)
        end
      end
    end
  end
  vim.uv.fs_close(fd)
  return 0
end

---@class isovim.acp.Writer
---@field path string
---@field seq integer

-- A writer that appends to the agent's journal, carrying on from its last seq. Each entry is one
-- write, so a reader never sees half of a line it hasn't been told is complete.
---@return isovim.acp.Writer
function M.writer(ws, agent)
  local path = M.path(ws, agent)
  vim.fn.mkdir(M.dir(ws), "p")
  local writer = { path = path, seq = last_seq(path) }
  function writer.append(kind, fields)
    writer.seq = writer.seq + 1
    local entry = vim.tbl_extend("force", fields or {}, { seq = writer.seq, ts = now(), kind = kind })
    local fd = vim.uv.fs_open(path, "a", 420)
    if fd then
      vim.uv.fs_write(fd, vim.json.encode(entry) .. "\n")
      vim.uv.fs_close(fd)
    end
    return entry
  end
  return writer
end

---@return table[] entries
function M.read(ws, agent)
  local entries = {}
  local file = io.open(M.path(ws, agent))
  for line in file and file:lines() or function() end do
    entries[#entries + 1] = decode(line)
  end
  if file then
    file:close()
  end
  return entries
end

-- Calls on_entry for every entry from the start, then for each one appended, until the returned
-- stop() is called; drain() reads what's been added at once. A journal that's replaced (another
-- inode) or cut short starts over, after on_reset. It watches the journal's folder (FSEvents/kqueue or inotify, through libuv), as
-- isovim.events does, and reads only what was added; on_entry runs on the main loop.
---@param on_entry fun(entry: table)
---@param on_reset? fun()
---@return fun() stop, fun() drain
function M.follow(ws, agent, on_entry, on_reset)
  local path = M.path(ws, agent)
  vim.fn.mkdir(M.dir(ws), "p")
  local inode, offset, partial = nil, 0, ""
  local stopped = false
  local function drain()
    if stopped then
      return
    end
    local stat = vim.uv.fs_stat(path)
    if not stat then
      return
    end
    if (inode and stat.ino ~= inode) or stat.size < offset then
      offset, partial = 0, ""
      if on_reset then
        on_reset()
      end
    end
    inode = stat.ino
    if stat.size == offset then
      return
    end
    local fd = vim.uv.fs_open(path, "r", 0)
    if not fd then
      return
    end
    while true do
      local chunk = vim.uv.fs_read(fd, 65536, offset)
      if not chunk or chunk == "" then
        break
      end
      offset = offset + #chunk
      -- Up to the chunk's last newline. Anchored, so a chunk with none (part of a line over 64 KiB)
      -- is one scan; unanchored, the match is tried from every start and takes most of a minute.
      local cut = chunk:match("^.*()\n")
      cut = cut and #partial + cut
      partial = partial .. chunk
      if cut then
        for line in partial:sub(1, cut):gmatch("([^\n]*)\n") do
          local entry = decode(line)
          if entry then
            on_entry(entry)
          end
        end
        partial = partial:sub(cut + 1)
      end
    end
    vim.uv.fs_close(fd)
  end
  -- Watching before reading, so nothing written in between is missed.
  local watcher = assert(vim.uv.new_fs_event())
  watcher:start(M.dir(ws), {}, vim.schedule_wrap(function(err)
    if not err then
      drain()
    end
  end))
  drain()
  return function()
    stopped = true
    if not watcher:is_closing() then
      watcher:stop()
      watcher:close()
    end
  end, drain
end

return M
