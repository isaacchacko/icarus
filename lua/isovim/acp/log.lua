-- The ACP supervisor's log: debug lines go to a file (run/<scope>/<aN>.acp.log, set by
-- isovim.acp.host), and warnings to the pane's stderr too, so a look at the pane shows them. Only
-- vim.uv and string work here, so it logs from libuv callbacks as well.
local M = {}

M.file = nil ---@type string?

local function line(level, parts)
  local text = table.concat(vim.tbl_map(function(part)
    return type(part) == "string" and part or vim.inspect(part)
  end, parts), " ")
  return ("%s %s %s\n"):format(os.date("%F %T"), level, text)
end

local function append(text)
  if not M.file then
    return
  end
  local fd = vim.uv.fs_open(M.file, "a", 420)
  if fd then
    vim.uv.fs_write(fd, text)
    vim.uv.fs_close(fd)
  end
end

function M.debug(...)
  append(line("debug", { ... }))
end

function M.warn(...)
  local text = line("warn", { ... })
  append(text)
  io.stderr:write(text)
end

return M
