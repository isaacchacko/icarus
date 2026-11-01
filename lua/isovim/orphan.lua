-- The TUI's nvim server (nvim --embed, the child of the nvim you see) ends when its UI goes, but
-- not while it waits on a key: one stuck at a prompt when its terminal closed went on under
-- launchd, still holding ~/.isovim/nvim.sock and its swap files, and when it did exit it removed
-- the socket's path, by then the next TUI's. A libuv timer runs even while nvim waits on a key, so
-- it notices the parent's gone and ends the server: SIGTERM while the socket's path is still its
-- own (nvim keeps the swap files of changed buffers and removes the path), SIGKILL once another
-- server has bound it, which removes nothing. The server names itself in isovim.server, so bin/iso
-- can kill one that's still there before it starts a TUI.
local store = require("isovim.store")

local M = {}

M.file = store.root .. "/isovim.server"

-- In _G, so a hot reload neither starts a second timer nor forgets the socket.
_G.isovim_orphan = _G.isovim_orphan or {}
local state = _G.isovim_orphan

-- This server (re)bound the socket: its inode, to tell its own path from another server's.
function M.bound()
  local stat = vim.uv.fs_stat(store.socket)
  state.ino = stat and vim.tbl_contains(vim.fn.serverlist(), store.socket) and stat.ino or nil
end

function M.start()
  if state.timer or not vim.tbl_contains(vim.v.argv, "--embed") then
    return
  end
  M.bound()
  local pid, parent, socket = vim.uv.os_getpid(), vim.uv.os_getppid(), store.socket
  vim.fn.writefile({ tostring(pid) }, M.file)
  state.timer = vim.uv.new_timer()
  -- A fast callback: libuv calls only, no nvim API.
  state.timer:start(2000, 2000, function()
    if vim.uv.os_getppid() == parent then
      return
    end
    state.timer:stop()
    local stat = vim.uv.fs_stat(socket)
    vim.uv.kill(pid, stat and stat.ino == state.ino and "sigterm" or "sigkill")
  end)
end

-- On a clean exit: the file goes if it still names this server.
function M.stop()
  local ok, lines = pcall(vim.fn.readfile, M.file)
  if ok and lines[1] == tostring(vim.uv.os_getpid()) then
    vim.fn.delete(M.file)
  end
end

return M
