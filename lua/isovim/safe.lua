-- What runs on its own (timers, scheduled callbacks, autocmds, the supervisors' pushes) never
-- raises into nvim's messages: an error there showed as a hit-enter prompt (or, under noice with
-- cmdheight=0, nothing at all) that held the whole TUI until a key it couldn't see. Each error's
-- stack goes to ~/.isovim/errors.log, a one-line WARN toast says which place failed, at most once
-- every five minutes for each place, and the TUI carries on.
local M = {}

M.log = require("isovim.store").root .. "/errors.log"

-- When each place last told, and how many it has kept quiet since; across hot reloads.
_G.isovim_safe = _G.isovim_safe or {}
local told = _G.isovim_safe

local QUIET_MS = 5 * 60000
local MAX_LOG_BYTES = 1024 * 1024

-- Every error, told or not, with its stack; the log moves to errors.log.1 past 1 MiB.
local function append(name, err)
  local stat = vim.uv.fs_stat(M.log)
  if stat and stat.size > MAX_LOG_BYTES then
    vim.uv.fs_rename(M.log, M.log .. ".1")
  end
  local file = io.open(M.log, "a")
  if file then
    file:write(("%s  %s\n%s\n\n"):format(os.date("%Y-%m-%d %H:%M:%S"), name, tostring(err)))
    file:close()
  end
end

function M.report(name, err)
  pcall(append, name, err)
  local now = vim.uv.now()
  local place = told[name] or { at = -QUIET_MS, quiet = 0 }
  told[name] = place
  if now - place.at < QUIET_MS then
    place.quiet = place.quiet + 1
    return
  end
  local more = place.quiet > 0 and (" (and %d more since)"):format(place.quiet) or ""
  place.at, place.quiet = now, 0
  -- Later, as the error may come in a fast event or under textlock, where a toast can't open.
  vim.schedule(function()
    local message = ("isovim: %s failed%s (see %s)"):format(name, more, vim.fn.fnamemodify(M.log, ":~"))
    pcall(vim.notify, message, vim.log.levels.WARN)
  end)
end

-- fn, made safe: an error is reported (M.report) and nothing returned.
---@generic F: function
---@param name string what it is, in the toast
---@param fn F
---@return F
function M.wrap(name, fn)
  return function(...)
    local result = vim.F.pack_len(xpcall(fn, debug.traceback, ...))
    if not result[1] then
      M.report(name, result[2])
      return
    end
    return unpack(result, 2, result.n)
  end
end

-- A hot reload (isovim.reload) unloads every isovim module and makes the open chats again, and nvim
-- can run other events in the middle of it (a long nvim_win_text_height checks for input and handles
-- what's waiting): a timer or a supervisor's push landing then found modules half loaded ("loop or
-- previous error loading module") and a chat half made. What runs again by itself skips its turn.
function M.reloading()
  return _G.isovim_reloading == true
end

-- A timer's callback: scheduled, skipped while a reload is under way, and safe. It outlives hot
-- reloads, so fn reaches the code it runs through require.
function M.ticker(name, fn)
  local report = M.report
  return vim.schedule_wrap(function(...)
    if _G.isovim_reloading then
      return
    end
    local ok, err = xpcall(fn, debug.traceback, ...)
    if not ok then
      report(name, err)
    end
  end)
end

function M.schedule(name, fn)
  vim.schedule(M.wrap(name, fn))
end

function M.schedule_wrap(name, fn)
  return vim.schedule_wrap(M.wrap(name, fn))
end

function M.defer(name, fn, ms)
  return vim.defer_fn(M.wrap(name, fn), ms)
end

return M
