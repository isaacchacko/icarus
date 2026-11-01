-- Agents that run over the Agent Client Protocol (opt-in: iso spawn --acp). Their record says
-- acp = true; their tmux pane runs a supervisor (isovim.acp.host) in place of claude's TUI, which
-- owns the ACP adapter, writes the agent's journal (isovim.acp.journal) and serves an nvim RPC
-- socket. The TUI and the iso CLI reach the agent only through that socket: a prompt goes in as a
-- request, never as keys, and one that arrives while the agent works waits in its queue.
local store = require("isovim.store")

local M = {}

---@param spec? isovim.Agent
function M.is(spec)
  return spec ~= nil and spec.acp == true
end

-- The supervisor's socket, in the agent's run dir; a path too long for a unix socket (about 104
-- bytes) is replaced by one in $TMPDIR named for it.
function M.socket(ws, agent)
  local path = store.run_dir(ws) .. "/" .. agent .. ".sock"
  if #path > 100 then
    local tmp = (vim.env.TMPDIR or "/tmp"):gsub("/$", "")
    path = ("%s/isovim-%s.sock"):format(tmp, vim.fn.sha256(path):sub(1, 16))
  end
  return path
end

-- Calls the supervisor: name is one of isovim.acp.host's calls (prompt, status, cancel).
---@return boolean ok, any result or the error
function M.call(ws, agent, name, payload)
  local sock = M.socket(ws, agent)
  if not vim.uv.fs_stat(sock) then
    return false, "its supervisor isn't up (no " .. sock .. ")"
  end
  local ok, chan = pcall(vim.fn.sockconnect, "pipe", sock, { rpc = true })
  if not ok or chan == 0 then
    return false, "could not connect to " .. sock
  end
  local called, result = pcall(vim.rpcrequest, chan, "nvim_exec_lua", "return require('isovim.acp.host').call(...)",
    { name, payload or vim.empty_dict() })
  vim.fn.chanclose(chan)
  if not called then
    return false, tostring(result)
  end
  return true, result
end

-- Waits for the supervisor to take calls, up to timeout seconds.
function M.wait_up(ws, agent, timeout)
  return vim.wait(timeout * 1000, function()
    return (M.call(ws, agent, "status"))
  end, 100)
end

return M
