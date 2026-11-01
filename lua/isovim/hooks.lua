-- Your own scripts in ~/.isovim/hooks/, run on isovim's events. Each is any executable file:
--   idle   once every agent has been quiet for the config's idle_after minutes (default 30); runs
--          once per quiet spell, with ISOVIM_QUIET (seconds) set. Checked while the TUI is open.
local store = require("isovim.store")
local panes = require("isovim.panes")
local status = require("isovim.status")

local M = {}

M.dir = store.root .. "/hooks"

function M.run(name, env)
  local path = M.dir .. "/" .. name
  if vim.fn.executable(path) == 1 then
    vim.system({ path }, { env = env, detach = true })
    return true
  end
  return false
end

local function mtime(path)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.mtime.sec or 0
end

-- When anything last happened in any agent; nil while one is working.
---@return integer?
function M.last_activity()
  local latest = 0
  for ws, agents in pairs(panes.sessions()) do
    for agent, at in pairs(agents) do
      local state = status.state(ws, agent)
      if state == "working" or state == "checking" then
        return nil
      end
      latest = math.max(latest, at, mtime(store.state_file(ws, agent)))
    end
  end
  return latest
end

-- Kept in _G so a hot reload doesn't fire the same quiet spell twice.
_G.isovim_idle_fired_for = _G.isovim_idle_fired_for

function M.check_idle()
  local latest = M.last_activity()
  local idle_after = (tonumber(require("isovim.config").get().idle_after) or 30) * 60
  if not latest or os.time() - latest < idle_after or _G.isovim_idle_fired_for == latest then
    return
  end
  _G.isovim_idle_fired_for = latest
  M.run("idle", { ISOVIM_QUIET = tostring(os.time() - latest) })
end
M.check_idle = require("isovim.safe").wrap("the idle check", M.check_idle)

return M
