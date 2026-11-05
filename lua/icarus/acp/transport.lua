-- The stdio transport to an ACP agent: spawns it with pipes, frames its stdout as newline-delimited
-- JSON and always keeps reading it (an agent whose stdout isn't drained stalls its tools), keeps the
-- tail of its stderr for the exit report, and stops the whole process group.
--
-- Vendored from agentic.nvim (lua/agentic/acp/acp_transport.lua at f0bef08), MIT:
--   Copyright (c) 2025 Carlos Gomes
--   Permission is hereby granted, free of charge, to any person obtaining a copy of this software
--   and associated documentation files (the "Software"), to deal in the Software without
--   restriction, subject to the conditions in LICENSE.agentic beside this file: the above copyright
--   notice and this permission notice shall be included in all copies or substantial portions of
--   the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
-- icarus's changes: its own log (icarus.acp.log), icarus's code style, env entries set to false are
-- removed, no reconnect (the supervisor owns restarts), a cwd, and the exit code passed on.
local log = require("icarus.acp.log")
local uv = vim.uv

local M = {}

---@class icarus.acp.TransportConfig
---@field command string
---@field args? string[]
---@field env? table<string, string|false> added to the inherited env; false removes a name
---@field cwd? string

---@class icarus.acp.TransportCallbacks
---@field on_state_change fun(state: "connecting"|"connected"|"disconnected"|"error")
---@field on_message fun(message: table) called from a libuv callback: schedule anything heavier
---@field on_exit? fun(code: integer, signal: integer, stderr: string[])

-- Known stderr lines from the adapters that aren't errors.
local IGNORE_STDERR_PATTERNS = {
  "Session not found",
  "session/prompt",
  "Spawning Claude Code process",
  "does not appear in the file:",
  "No onPostToolUseHook found",
  "Spawning Claude Code:",
  "[PreToolUseHook]",
}

local STDERR_TAIL = 50

-- `luanil` decodes JSON null as nil, not vim.NIL.
---@return boolean ok, table|string decoded
function M.decode_line(line)
  return pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
end

-- Every process below pid now, as {pid, pgid}, and pid's own process group. Claude runs an agent's
-- background shells (run_in_background) in process groups of their own, so stopping the adapter's
-- group leaves them running; stop() asks for these first, while they're still below it (once their
-- parent is gone they belong to init, and nothing finds them).
---@return {pid: integer, pgid: integer}[] found, integer? own_pgid
function M.descendants(pid)
  local ps = io.popen("ps -A -o pid= -o ppid= -o pgid= 2>/dev/null")
  if not ps then
    return {}
  end
  local listing = ps:read("*a") or ""
  ps:close()
  local children, groups = {}, {}
  for line in listing:gmatch("[^\n]+") do
    local child, parent, pgid = line:match("^%s*(%d+)%s+(%d+)%s+(%d+)")
    if child then
      child, parent, pgid = tonumber(child), tonumber(parent), tonumber(pgid)
      groups[child] = pgid
      children[parent] = children[parent] or {}
      table.insert(children[parent], child)
    end
  end
  local found, todo = {}, { pid }
  while #todo > 0 do
    for _, child in ipairs(children[table.remove(todo)] or {}) do
      found[#found + 1] = { pid = child, pgid = groups[child] }
      todo[#todo + 1] = child
    end
  end
  return found, groups[pid]
end

-- Stops every process below pid (descendants), each process group of theirs that isn't pid's own
-- whole, then any left with SIGKILL.
function M.kill_descendants(found, own_pgid)
  local function signal(sig)
    for _, proc in ipairs(found) do
      if proc.pgid and proc.pgid ~= own_pgid and proc.pgid > 1 then
        uv.kill(-proc.pgid, sig)
      end
      uv.kill(proc.pid, sig)
    end
  end
  local function gone()
    for _, proc in ipairs(found) do
      if uv.kill(proc.pid, 0) == 0 then
        return false
      end
    end
    return true
  end
  if #found == 0 then
    return
  end
  signal(15)
  for _ = 1, 10 do
    if gone() then
      return
    end
    uv.sleep(50)
  end
  signal(9)
end

---@param config icarus.acp.TransportConfig
---@param callbacks icarus.acp.TransportCallbacks
function M.create_stdio_transport(config, callbacks)
  local transport = { stdin = nil, stdout = nil, process = nil, pid = nil } ---@type table

  function transport:send(data)
    if self.stdin and not self.stdin:is_closing() then
      self.stdin:write(data .. "\n")
      return true
    end
    return false
  end

  function transport:start()
    callbacks.on_state_change("connecting")
    local command = vim.fn.exepath(vim.fn.expand(config.command))
    if command == "" then
      callbacks.on_state_change("error")
      error(("Command not found: %s"):format(config.command))
    end
    local stdin, stdout, stderr = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
    if not stdin or not stdout or not stderr then
      callbacks.on_state_change("error")
      error("Failed to create pipes for ACP agent")
    end
    local stderr_tail = {}
    local args = vim.deepcopy(config.args or {})

    -- uv.spawn replaces the whole environment, so the inherited one is passed on explicitly.
    local env_map = vim.fn.environ()
    env_map.NODE_NO_WARNINGS = "1"
    env_map.IS_AI_TERMINAL = "1"
    for key, value in pairs(config.env or {}) do
      env_map[key] = value or nil
    end
    local env = {}
    for key, value in pairs(env_map) do
      env[#env + 1] = key .. "=" .. value
    end

    local handle, pid = uv.spawn(command, {
      args = args,
      env = env,
      cwd = config.cwd,
      stdio = { stdin, stdout, stderr },
      -- A new process group (setsid), so stop() can signal all of it with uv.kill(-pid), and reap
      -- wrappers that don't forward signals.
      detached = true,
    }, function(code, signal)
      log.debug(("ACP agent exited: %s %s, code %s, signal %s"):format(config.command, table.concat(args, " "), code, signal))
      if code ~= 0 and #stderr_tail > 0 then
        log.warn(("ACP agent %s failed (exit code %d):\n%s"):format(config.command, code, table.concat(stderr_tail, "\n")))
      end
      callbacks.on_state_change("disconnected")
      if self.process then
        self.process:close()
        self.process = nil
      end
      if callbacks.on_exit then
        callbacks.on_exit(code, signal, stderr_tail)
      end
    end)
    if not handle then
      stdin:close()
      stdout:close()
      stderr:close()
      callbacks.on_state_change("error")
      error(("Failed to spawn ACP agent process: %s"):format(tostring(pid)))
    end
    log.debug("spawned ACP agent process, pid", tostring(pid))
    self.process = handle
    self.pid = tonumber(pid)
    self.stdin = stdin
    self.stdout = stdout
    callbacks.on_state_change("connected")

    local chunks = ""
    stdout:read_start(function(err, data)
      if err then
        log.warn("ACP stdout error: " .. err)
        callbacks.on_state_change("error")
        return
      end
      if data then
        chunks = chunks .. data
        -- Complete lines are messages; a partial last line waits for the rest.
        local lines = vim.split(chunks, "\n", { plain = true })
        chunks = lines[#lines]
        for i = 1, #lines - 1 do
          local line = vim.trim(lines[i])
          if line ~= "" then
            local ok, message = M.decode_line(line)
            if ok and type(message) == "table" then
              callbacks.on_message(message)
            else
              log.warn("Failed to parse JSON-RPC message: " .. line)
            end
          end
        end
      end
    end)

    stderr:read_start(function(_, data)
      if not data then
        return
      end
      local trimmed = vim.trim(data)
      if trimmed ~= "" then
        stderr_tail[#stderr_tail + 1] = trimmed
        if #stderr_tail > STDERR_TAIL then
          table.remove(stderr_tail, 1)
        end
      end
      for _, pattern in ipairs(IGNORE_STDERR_PATTERNS) do
        if data:find(pattern, 1, true) then
          return
        end
      end
      log.debug("ACP stderr:", data)
    end)
  end

  function transport:stop()
    if self.process and not self.process:is_closing() then
      local process, pid = self.process, self.pid
      self.process, self.pid = nil, nil
      -- The whole group, so a wrapper's children go too, and the background shells in groups of their own.
      if pid then
        pcall(M.kill_descendants, M.descendants(pid))
        pcall(uv.kill, -pid, 15)
        pcall(uv.kill, -pid, 9)
      end
      -- libuv tolerates close after exit; the exit callback's own close is guarded.
      process:close()
    end
    if self.stdin then
      self.stdin:close()
      self.stdin = nil
    end
    if self.stdout then
      self.stdout:close()
      self.stdout = nil
    end
    callbacks.on_state_change("disconnected")
  end

  return transport
end

return M
