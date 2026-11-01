-- What runs on its own (timers, scheduled callbacks, autocmds, the supervisors' pushes) never
-- raises into nvim's messages: an error there showed as a hit-enter prompt (or, under noice with
-- cmdheight=0, nothing at all) that held the whole TUI until a key it couldn't see. Each error is
-- a WARN toast with its stack instead, at most once a minute for each place, and the TUI carries on.
local M = {}

-- When each place last told, and how many it has kept quiet since; across hot reloads.
_G.isovim_safe = _G.isovim_safe or {}
local told = _G.isovim_safe

local QUIET_MS = 60000

function M.report(name, err)
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
    pcall(vim.notify, ("isovim: %s failed%s: %s"):format(name, more, tostring(err)), vim.log.levels.WARN)
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
