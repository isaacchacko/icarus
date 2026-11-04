-- What runs on its own (timers, scheduled callbacks, autocmds, the supervisors' pushes) never
-- raises into nvim's messages: an error there showed as a hit-enter prompt (or, under noice with
-- cmdheight=0, nothing at all) that held the whole TUI until a key it couldn't see. Each error's
-- stack goes to ~/.isovim/errors.log, a one-line WARN toast says which place failed, at most once
-- every five minutes for each place, and the TUI carries on.
local M = {}

M.log = require("isovim.store").root .. "/errors.log"

-- A callback in a fast event (fs_event, a uv timer, a process's exit) can't run a module's top level,
-- whose nvim API calls fail there. Lua marks a module as loading before running it and leaves the mark
-- when that fails, so the next require anywhere says "loop or previous error loading module", which
-- fails a hot reload that has unloaded everything. A searcher runs before that mark: refusing here
-- gives the callback a clear error and leaves the module loadable.
if not _G.isovim_fast_require_guard then
  _G.isovim_fast_require_guard = true
  table.insert(package.loaders, 1, function(name)
    if (name == "isovim" or name:match("^isovim%.")) and vim.in_fast_event() then
      error(("%s isn't loaded, and a fast event can't load it: take what the callback needs before it starts"):format(name), 0)
    end
  end)
end

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

-- Into errors.log and nowhere else, for what told its own way.
function M.log_error(name, err)
  pcall(append, name, err)
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

-- What only reaches :messages or the notifier goes in errors.log too: a callback's error (E5108, a
-- raw luv callback's) that nothing caught, or a toast at error level. Each once, across hot reloads.
_G.isovim_logged = _G.isovim_logged or { lines = {}, toast = 0 }

local function log_messages()
  local seen = _G.isovim_logged.lines
  local lines = vim.split(vim.fn.execute("messages"), "\n", { plain = true })
  local i = 1
  while i <= #lines do
    local line = lines[i]
    if (line:match("%f[%w]E%d%d%d+:") or line:match("^Error ")) and not seen[line] then
      seen[line] = true
      local block = { line }
      while lines[i + 1] and #block < 30 and (lines[i + 1]:match("^%s") or lines[i + 1]:match("^stack traceback")) do
        i = i + 1
        block[#block + 1] = lines[i]
      end
      append(":messages", table.concat(block, "\n"))
    end
    i = i + 1
  end
end

local function log_toasts()
  local logged = _G.isovim_logged
  for _, toast in ipairs(Snacks.notifier.get_history()) do
    if toast.id > logged.toast then
      logged.toast = toast.id
      -- isovim.reload logs its own, with what it was for.
      if toast.level == "error" and not tostring(toast.msg):match("^isovim reload failed") then
        append("the notifier", tostring(toast.msg))
      end
    end
  end
end

-- Looks every 30s, once a TUI's up; it outlives hot reloads.
function M.watch_errors()
  if _G.isovim_log_timer then
    return
  end
  _G.isovim_log_timer = assert(vim.uv.new_timer())
  _G.isovim_log_timer:start(5000, 30000, M.ticker("logging what reached :messages", function()
    require("isovim.safe").log_scan()
  end))
end

function M.log_scan()
  log_messages()
  pcall(log_toasts)
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
-- Whether nvim refuses text changes right now (E565): textlock holds while an expression mapping, a
-- statusline or the like runs, and a supervisor's RPC can land inside one, as can anything run from
-- a vim.wait there. There's no asking for it directly, so a hidden scratch buffer is written to,
-- which changes nothing anyone sees. In a fast event no API call would work either.
function M.text_locked()
  if vim.in_fast_event() then
    return true
  end
  local buf = _G.isovim_probe_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    local ok, made = pcall(vim.api.nvim_create_buf, false, true)
    if not ok then
      return true
    end
    buf = made
    vim.bo[buf].undolevels = -1
    _G.isovim_probe_buf = buf
  end
  local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, {})
  return not ok and tostring(err):find("E565", 1, true) ~= nil
end

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
