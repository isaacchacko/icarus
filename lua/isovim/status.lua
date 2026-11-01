-- What each agent is doing, from the state file its hooks write (panes.agent_cmd).
local store = require("isovim.store")
local events = require("isovim.events")

local M = {}

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- Handles live in _G so a hot reload can close the ones the old code opened.
_G.isovim_status_handles = _G.isovim_status_handles or {}
local handles = _G.isovim_status_handles

local function mtime(path)
  local stat = vim.uv.fs_stat(path)
  return stat and (stat.mtime.sec + stat.mtime.nsec / 1e9) or 0
end

---@alias isovim.Status "working"|"attention"|"unread"|nil

-- What the hooks last wrote: ready, working, idle or attention; nil before the agent's first hook.
---@return string?
function M.state(ws, agent)
  local file = io.open(store.state_file(ws, agent))
  local state = file and file:read("*l")
  if file then
    file:close()
  end
  return state
end

-- Why it's in that state, when whoever wrote it said (the state file's second line): an ACP
-- agent's held queue says what it waits on (isovim.acp.host).
---@return string?
function M.reason(ws, agent)
  local file = io.open(store.state_file(ws, agent))
  if not file then
    return nil
  end
  file:read("*l")
  local reason = file:read("*l")
  file:close()
  return reason ~= "" and reason or nil
end

-- For what no hook reports, like Claude being interrupted. reason goes on the second line.
function M.set_state(ws, agent, state, reason)
  local previous = M.state(ws, agent)
  local file = io.open(store.state_file(ws, agent), "w")
  if file then
    file:write(state .. (reason and ("\n" .. reason:gsub("\n", " ")) or ""))
    file:close()
  end
  if state ~= previous then
    events.publish_agent(ws, agent, "status", { state = state, previous = previous or vim.NIL })
  end
end

---@return isovim.Status
function M.get(ws, agent)
  local changed = mtime(store.state_file(ws, agent))
  if changed == 0 then
    return nil
  end
  -- A decision it raised (iso ask) waits on you until you've looked at it, whatever it does next.
  if require("isovim.root").raised_at(ws, agent) > mtime(store.seen_file(ws, agent)) then
    return "attention"
  end
  local state = M.state(ws, agent)
  -- Its prompts wait on something it can't do itself (a login): it needs you until that's fixed.
  if state == "held" then
    return "attention"
  end
  if state == "working" or state == "checking" then
    return "working"
  elseif state == "waiting" then
    return "waiting"
  elseif state == "ready" then
    return nil
  end
  if changed <= mtime(store.seen_file(ws, agent)) then
    return nil
  end
  return state == "attention" and "attention" or "unread"
end

function M.mark_seen(ws, agent)
  local seen = store.seen_file(ws, agent)
  if mtime(store.state_file(ws, agent)) > mtime(seen) then
    local file = io.open(seen, "w")
    if file then
      file:write(os.time())
      file:close()
    end
  end
end

---@param status isovim.Status
---@return string icon, string? hl
function M.icon(status)
  if status == "working" then
    return SPINNER[math.floor(vim.uv.now() / 100) % #SPINNER + 1], "DiagnosticInfo"
  elseif status == "attention" then
    return "●", "DiagnosticWarn"
  elseif status == "unread" then
    return "●", "DiagnosticOk"
  elseif status == "waiting" then
    return "\u{f051f}", "Comment" -- md-timer_sand: waiting on something it started
  end
  return " "
end

function M.stop()
  for key, handle in pairs(handles) do
    if not handle:is_closing() then
      handle:close()
    end
    handles[key] = nil
  end
end

-- One watcher per directory: libuv's recursive watch is macOS/Windows only. Watching the run root too
-- picks up the dir a new workspace's first agent creates.
local function watch(dir, on_event)
  local key = "watch:" .. dir
  if handles[key] then
    return
  end
  local handle = assert(vim.uv.new_fs_event())
  if handle:start(dir, {}, on_event) then
    handles[key] = handle
  else
    handle:close()
  end
end

local function watch_all(on_event)
  watch(store.run, on_event)
  for name, type in vim.fs.dir(store.run) do
    if type == "directory" then
      watch(store.run .. "/" .. name, on_event)
    end
  end
end

---@param on_change fun() runs after any state or seen file changes
---@param on_tick fun() runs every spinner frame while animating
function M.start(on_change, on_tick)
  M.stop()
  vim.fn.mkdir(store.run, "p")
  handles.debounce = assert(vim.uv.new_timer())
  handles.spinner = assert(vim.uv.new_timer())
  local function on_event(err)
    if err then
      return
    end
    handles.debounce:stop()
    handles.debounce:start(50, 0, require("isovim.safe").ticker("the agents' states", function()
      watch_all(on_event)
      on_change()
    end))
  end
  watch_all(on_event)
  M.on_tick = on_tick
end

-- The spinner timer only runs while some agent is working.
function M.animate(on)
  local timer = handles.spinner
  if not timer then
    return
  end
  if on and not timer:is_active() then
    timer:start(100, 100, require("isovim.safe").ticker("the sidebar's spinners", M.on_tick))
  elseif not on then
    timer:stop()
  end
end

return M
