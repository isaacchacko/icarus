-- The ACP log, one file for every chat: stdpath("log")/isovim-acp.log. Only vim.uv and string work
-- here, so it logs from libuv callbacks as well.
local M = {}

M.file = vim.fn.stdpath("log") .. "/isovim-acp.log"

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
  append(line("warn", { ... }))
end

return M
