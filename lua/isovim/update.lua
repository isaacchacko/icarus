-- isovim keeps itself up to date. The TUI fetches its own checkout's origin every minute, and at once
-- when `iso update` asks (bin/iso-hook runs it after an agent's git push), and fast-forwards the
-- checkout to origin's default branch when that's safe: on that branch, no changes to tracked files
-- (untracked ones are fine), and behind it, not diverged. Otherwise it leaves the checkout alone and
-- says why, once. It never stashes, resets or rebases. What the pull brings to lua/isovim/ hot
-- reloads (isovim.reload's watcher sees it); what's read only at startup (starter/, bin/iso) needs a
-- restart, which waits until you've been idle IDLE ms, in normal mode and no picker, then gives
-- NOTICE ms of notice that any key postpones. A restart saves what's open, the scope and the
-- composers' drafts to restart.json and exits with RESTART; bin/iso starts the TUI again (restoring
-- the plugins first when lazy-lock.json changed) and M.take_saved brings it back. The agents run in
-- tmux and their supervisors, so a restart never touches them.
local store = require("isovim.store")

local M = {}

-- What bin/iso relaunches the TUI on.
M.RESTART = 75
-- ISOVIM_SELF_UPDATE=0 turns it off (pilots do, but for checks that want it); the times can be set
-- in ms, for pilots.
M.enabled = vim.env.ISOVIM_SELF_UPDATE ~= "0"
M.INTERVAL = tonumber(vim.env.ISOVIM_UPDATE_INTERVAL) or 60000
M.IDLE = tonumber(vim.env.ISOVIM_UPDATE_IDLE) or 20000
M.NOTICE = tonumber(vim.env.ISOVIM_UPDATE_NOTICE) or 5000
local TIMEOUT = 30000
-- bin/iso's loop, which relaunches the TUI when it exits with RESTART; a TUI started before it can't.
M.can_restart = vim.env.ISOVIM_LOOP == "1"

M.repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
M.saved_file = store.root .. "/restart.json"

-- Lives in _G so a hot reload (which this module's own update may cause) keeps it.
---@class isovim.UpdateState
---@field said? string the last reason given for not updating, so it's said once
---@field restart? string[] files the last update changed that need a restart, until it happens
---@field checking? boolean a check is running; again asks for another once it ends
---@field again? boolean
---@field last_key integer vim.uv.now() of the last key you pressed
---@field notice_at? integer when the restart notice went up; a key since then postpones it
---@field waiting_on? string what the restart waits on (a file with unsaved changes), said once
_G.isovim_update = _G.isovim_update or { last_key = vim.uv.now() }
local state = _G.isovim_update

local function notify(text, level)
  Snacks.notify(text, { level = level or "info", title = "isovim" })
end

-- What changes in an update needs a restart rather than a hot reload: lazy.nvim reads starter/ once
-- at startup (but config/keymaps.lua, which isovim.reload runs again), and bin/iso is the loop the
-- TUI runs in. bin/iso-hook and lua/ are read afresh as they're used.
local function needs_restart(file)
  return file == "bin/iso" or (vim.startswith(file, "starter/") and file ~= "starter/lua/config/keymaps.lua")
end

local GIT_ENV = { GIT_TERMINAL_PROMPT = "0", GIT_SSH_COMMAND = vim.env.GIT_SSH_COMMAND or "ssh -o BatchMode=yes" }

local function result_of(r)
  return r.code == 0, vim.trim(r.stdout or ""), vim.trim(r.stderr or "")
end

-- Runs git in the checkout and, inside a coroutine, yields until it's done (the TUI's, which mustn't block).
local function git_async(...)
  local co = coroutine.running()
  vim.system({ "git", "-C", M.repo, ... }, { text = true, timeout = TIMEOUT, env = GIT_ENV }, function(r)
    vim.schedule(function()
      coroutine.resume(co, r)
    end)
  end)
  return result_of(coroutine.yield())
end

-- Runs git in the checkout and waits (iso update's).
local function git_sync(...)
  return result_of(vim.system({ "git", "-C", M.repo, ... }, { text = true, timeout = TIMEOUT, env = GIT_ENV }):wait())
end

---@class isovim.Pull
---@field state "updated"|"current"|"ahead"|"declined"|"offline"
---@field reason? string why it declined, or the fetch's error
---@field count? string how many commits an update brought
---@field subject? string the newest one's "<sha> <subject>"
---@field restart? string[] what it changed that needs a restart

-- Fetches origin's default branch (origin/HEAD, else main) and fast-forwards the checkout to it, when
-- it's on that branch, no tracked file has changes and it's behind, not diverged. git is git_async
-- or git_sync. Never stashes, resets or rebases.
---@return isovim.Pull
local function pull(git)
  local has_head, origin_head = git("symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD")
  local branch = has_head and origin_head:match("^origin/(.+)$") or "main"
  local upstream = "origin/" .. branch
  local fetched, _, fetch_err = git("fetch", "--quiet", "origin", branch)
  if not fetched then
    return { state = "offline", reason = fetch_err }
  end
  local _, head = git("rev-parse", "HEAD")
  local _, target = git("rev-parse", upstream)
  if head == target then
    return { state = "current" }
  end
  local on_branch, current = git("symbolic-ref", "--short", "-q", "HEAD")
  if not on_branch then
    return { state = "declined", reason = ("its checkout's HEAD is detached, not on %s"):format(branch) }
  elseif current ~= branch then
    return { state = "declined", reason = ("its checkout is on %s, not %s"):format(current, branch) }
  elseif not git("merge-base", "--is-ancestor", "HEAD", upstream) then
    if git("merge-base", "--is-ancestor", upstream, "HEAD") then
      return { state = "ahead", reason = ("ahead of %s: nothing to pull"):format(upstream) }
    end
    return { state = "declined", reason = ("its checkout has diverged from %s"):format(upstream) }
  end
  local _, changes = git("status", "--porcelain", "--untracked-files=no")
  if changes ~= "" then
    local files = vim.tbl_map(function(line)
      return line:sub(4)
    end, vim.split(changes, "\n", { trimempty = true }))
    local shown = table.concat(vim.list_slice(files, 1, 3), ", ") .. (#files > 3 and (", +" .. (#files - 3)) or "")
    return { state = "declined", reason = ("its checkout has local changes (%s)"):format(shown) }
  end
  local _, names = git("diff", "--name-only", "HEAD", upstream)
  local _, count = git("rev-list", "--count", "HEAD.." .. upstream)
  local merged, _, merge_err = git("merge", "--ff-only", "--quiet", upstream)
  if not merged then
    return { state = "declined", reason = "the fast-forward failed: " .. (merge_err:match("[^\n]+") or "?") }
  end
  local _, subject = git("log", "-1", "--format=%h %s", upstream)
  local files = vim.split(names, "\n", { trimempty = true })
  return { state = "updated", count = count, subject = subject, restart = vim.tbl_filter(needs_restart, files) }
end

-- One line for what a pull did, as iso update prints it and the TUI's toast starts.
function M.describe(result)
  if result.state == "updated" then
    return ("isovim updated (%s commit%s): %s"):format(result.count, result.count == "1" and "" or "s", result.subject:sub(1, 80))
  elseif result.state == "current" then
    return "isovim is up to date"
  elseif result.state == "ahead" then
    return "isovim is " .. result.reason
  elseif result.state == "offline" then
    return "isovim couldn't fetch origin: " .. result.reason
  end
  return "isovim isn't updating itself: " .. result.reason
end

-- What the TUI does with a pull, its own or iso update's: says what happened (a reason it declined
-- once, and only a check you asked for, verbose, says there was nothing to do or the fetch failed),
-- and after an update that needs a restart, arms it. lua/ hot reloads through isovim.reload.
function M.pulled(result, verbose)
  local said = state.said
  if result.state == "declined" then
    if verbose or said ~= result.reason then
      notify(M.describe(result), "warn")
    end
    state.said = result.reason
  elseif result.state ~= "offline" then
    state.said = nil
  end
  -- The sidebar's footer says why while it's blocked (M.blocked).
  if state.said ~= said then
    pcall(require("isovim.sidebar").redraw)
  end
  if result.state == "declined" then
    return
  end
  if result.state ~= "updated" then
    return verbose and notify(M.describe(result), result.state == "offline" and "warn" or "info")
  end
  local restart = result.restart or {}
  local note = ""
  if #restart > 0 then
    note = M.can_restart and "\nit restarts onto it once you've been idle a moment"
      or "\nquit and run iso to apply it (this isovim was started before it could restart itself)"
  end
  if #restart > 0 and M.can_restart then
    state.restart = vim.list_extend(state.restart or {}, restart)
  end
  notify(M.describe(result) .. note)
  if #restart > 0 and M.can_restart then
    M.arm()
  end
end

-- Why self-update is blocked now, for the sidebar's footer; nil while it isn't.
function M.blocked()
  return state.said
end

-- iso update: the pull itself, run by any process (an agent's, with or without a TUI open).
---@return isovim.Pull
function M.pull_now()
  return pull(git_sync)
end

local function update(verbose)
  M.pulled(pull(git_async), verbose)
end

-- Fetches and, when it can, fast-forwards. Never blocks: git runs in the background. verbose says
-- what it found even when there's nothing to do (a check you asked for).
function M.check(verbose)
  if not M.enabled then
    return verbose and notify("isovim's self-update is off (ISOVIM_SELF_UPDATE=0)")
  elseif state.checking then
    state.again = true
    return
  end
  state.checking = true
  coroutine.wrap(function()
    local ok, err = pcall(update, verbose)
    state.checking = false
    if not ok then
      notify("isovim's update check failed: " .. tostring(err), "error")
    end
    if state.again then
      state.again = false
      M.check()
    end
  end)()
end

-- Whether isovim can restart without losing anything of yours: no file buffer with unsaved changes.
local function unsaved()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].modified and vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= "" then
      return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")
    end
  end
end

-- Busy: not in normal mode, in a picker other than the sidebar's explorer, or in any float (a
-- prompt, a picker's input).
local function busy()
  if not vim.api.nvim_get_mode().mode:match("^n") then
    return true
  end
  if vim.api.nvim_win_get_config(0).relative ~= "" then
    return true
  end
  local ok, pickers = pcall(Snacks.picker.get)
  return ok and vim.iter(pickers or {}):any(function(picker)
    return picker.opts.source ~= "explorer"
  end)
end

-- Says once what the pending restart waits on.
local function wait_on(what)
  if what and state.waiting_on ~= what then
    notify(what, "warn")
  end
  state.waiting_on = what
end

local NOTICE_ID = "isovim_update_restart"

-- Every second while a restart is pending: once you're idle, the notice, then the restart.
function M.tick()
  if not state.restart then
    return
  end
  local now = vim.uv.now()
  if state.notice_at then
    if now - state.notice_at >= M.NOTICE then
      state.notice_at = nil
      if busy() then
        Snacks.notifier.hide(NOTICE_ID)
      else
        M.restart()
      end
    end
    return
  end
  local file = unsaved()
  if file then
    return wait_on(("isovim restarts onto its update once %s is saved"):format(file))
  end
  wait_on(nil)
  if now - state.last_key < M.IDLE or busy() then
    return
  end
  state.notice_at = now
  Snacks.notify(("isovim updated: restarting in %ds · any key to wait"):format(math.ceil(M.NOTICE / 1000)),
    { id = NOTICE_ID, title = "isovim", timeout = M.NOTICE + 1000 })
end

-- Any key resets the idle clock, and postpones a restart whose notice is up until you're idle again.
local function on_key()
  state.last_key = vim.uv.now()
  if state.notice_at then
    state.notice_at = nil
    require("isovim.safe").schedule("the restart's notice", function()
      Snacks.notifier.hide(NOTICE_ID)
      notify("isovim's restart waits until you're idle again")
    end)
  end
end

-- Starts the restart's clock: a ticker, through require so a hot reload's code runs it.
function M.arm()
  if _G.isovim_restart_timer then
    return
  end
  _G.isovim_restart_timer = vim.uv.new_timer()
  _G.isovim_restart_timer:start(1000, 1000, require("isovim.safe").ticker("the restart's clock", function()
    require("isovim.update").tick()
  end))
end

-- Run by setup, on every start and hot reload: the fetch timer, the key clock, and a pending restart's
-- ticker (a reload replaces this module, not the timers).
function M.start()
  vim.on_key(on_key, vim.api.nvim_create_namespace("isovim_update"))
  -- Ones an older isovim started, not skipping a reload, are replaced.
  if _G.isovim_update_timers ~= "ticker" then
    for _, name in ipairs({ "isovim_restart_timer", "isovim_update_timer" }) do
      if _G[name] and not _G[name]:is_closing() then
        _G[name]:close()
      end
      _G[name] = nil
    end
    _G.isovim_update_timers = "ticker"
  end
  if state.restart and M.can_restart then
    M.arm()
  end
  if M.enabled and not _G.isovim_update_timer then
    _G.isovim_update_timer = vim.uv.new_timer()
    _G.isovim_update_timer:start(math.min(5000, M.INTERVAL), M.INTERVAL, require("isovim.safe").ticker("the update check", function()
      require("isovim.update").check()
    end))
  end
end

-- What's open, for the TUI bin/iso starts next: every chat (ws/agent), the current workspace and
-- scope, and what's typed in each composer. The current workspace's splits are its layout.json.
local function save()
  local isovim = require("isovim")
  local agents, seen, drafts = {}, {}, {}
  local function add(ws, agent)
    local key = ws .. "/" .. agent
    if not seen[key] then
      seen[key] = true
      table.insert(agents, key)
    end
  end
  -- Most recently opened first; a chat's buffer may be unlisted, as another scope's are.
  for _, key in ipairs(isovim.recent_agents) do
    local ws, agent = key:match("^(.*)/([^/]+)$")
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.b[buf].isovim_id == ws and (vim.b[buf].isovim_agent or "main") == agent and vim.api.nvim_buf_is_loaded(buf) then
        add(ws, agent)
      end
    end
  end
  for _, chat in pairs(_G.isovim_acp_chats or {}) do
    if vim.api.nvim_buf_is_valid(chat.buf) then
      add(chat.ws, chat.agent)
    end
    if vim.api.nvim_buf_is_valid(chat.buf) and chat.lines then
      local lines = require("isovim.acp.chat").draft(chat)
      if vim.trim(table.concat(lines, "\n")) ~= "" then
        drafts[chat.ws .. "/" .. chat.agent] = lines
      end
    end
  end
  require("isovim.layout").save(isovim.current, isovim.is_sidebar)
  vim.fn.writefile({ vim.json.encode({ current = isovim.current, scope = isovim.current_scope, agents = agents, drafts = drafts }) },
    M.saved_file)
end

-- Restarts the TUI onto the code on disk now (bin/iso relaunches it). Refused while a file has
-- unsaved changes, and outside bin/iso's loop.
function M.restart()
  local file = unsaved()
  if file then
    return notify(("isovim can't restart: %s has unsaved changes"):format(file), "warn")
  elseif not M.can_restart then
    return notify("this isovim was started before it could restart itself: quit and run iso once", "warn")
  end
  save()
  vim.cmd("cquit " .. M.RESTART)
end

-- What the TUI before a restart saved, once: the next start reads it and it's gone.
---@return {current?: string, scope?: string, agents: string[], drafts: table<string, string[]>}?
function M.take_saved()
  local ok, lines = pcall(vim.fn.readfile, M.saved_file)
  if not ok then
    return nil
  end
  vim.fn.delete(M.saved_file)
  local decoded, saved = pcall(vim.json.decode, table.concat(lines, "\n"))
  return decoded and type(saved) == "table" and saved or nil
end

return M
