-- The TCP ports each agent's processes listen on: a dev
-- server started in a terminal or by the run script shows its :port in the sidebar, and `o` opens
-- it. Found by walking each pane's process tree against lsof's listening sockets, in the background.
local M = {}

M.by_agent = {} ---@type table<string, integer[]> "ws/agent" -> ports, lowest first

local busy = false

-- Calls on_change when any agent's ports changed.
function M.poll(on_change)
  if busy then
    return
  end
  busy = true
  local panes = vim.system({ "tmux", "-L", require("isovim.panes").socket, "list-panes", "-a", "-F", "#{session_name} #{pane_pid}" }, { text = true })
  local ps = vim.system({ "ps", "-A", "-o", "pid=,ppid=" }, { text = true })
  local started, lsof = pcall(vim.system, { "lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn" }, { text = true }, vim.schedule_wrap(function(listening)
    local children = {}
    for pid, ppid in (ps:wait().stdout or ""):gmatch("(%d+)%s+(%d+)") do
      children[ppid] = children[ppid] or {}
      table.insert(children[ppid], pid)
    end
    local ports_of = {}
    local pid
    for line in (listening.stdout or ""):gmatch("[^\n]+") do
      if line:sub(1, 1) == "p" then
        pid = line:sub(2)
      elseif line:sub(1, 1) == "n" and pid then
        local port = tonumber(line:match(":(%d+)$"))
        ports_of[pid] = ports_of[pid] or {}
        ports_of[pid][port] = true
      end
    end
    local found = {}
    for name, root in (panes:wait().stdout or ""):gmatch("(%S+) (%d+)") do
      local ws, agent = name:match("^isovim%-(%x%x%x%x%x%x)%-(%S+)$")
      if ws then
        local set, stack = {}, { root }
        while #stack > 0 do
          local at = table.remove(stack)
          for port in pairs(ports_of[at] or {}) do
            set[port] = true
          end
          vim.list_extend(stack, children[at] or {})
        end
        local ports = vim.tbl_keys(set)
        if #ports > 0 then
          table.sort(ports)
          found[ws .. "/" .. agent] = ports
        end
      end
    end
    busy = false
    if not vim.deep_equal(found, M.by_agent) then
      M.by_agent = found
      on_change()
    end
  end))
  if not started or not lsof then
    busy = false
  end
end

-- The ports of one agent, or of a whole workspace's agents when agent is nil.
---@return integer[]
function M.of(ws, agent)
  if agent then
    return M.by_agent[ws .. "/" .. agent] or {}
  end
  local all = {}
  for key, ports in pairs(M.by_agent) do
    if key:match("^" .. ws .. "/") then
      vim.list_extend(all, ports)
    end
  end
  table.sort(all)
  return all
end

return M
