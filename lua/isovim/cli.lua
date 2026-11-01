-- `iso <command>`: drive workspaces and their agents from a shell or an agent. bin/iso runs this
-- under `nvim -l`; when the TUI is open, changes reach it over its socket. The commands are listed
-- in isovim.cli.commands and run by the isovim.cli module each names. iso <role> <action> runs an
-- action under a role (isovim.cli.roles), which checks the caller first, as it does bare commands.
local lua_dir = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
package.path = lua_dir .. "/?.lua;" .. lua_dir .. "/?/init.lua;" .. package.path

local commands = require("isovim.cli.commands")

-- An old ~/iso moves to ~/.iso, and an old _/ to general/ and root/, first, whatever the command
-- (a stat or two once they're gone). Not for iso closed, which tmux runs as the move stops an agent
-- and which mustn't wait on it, nor iso __migrate, which is that move.
if _G.arg[1] ~= "closed" and _G.arg[1] ~= "__migrate" then
  pcall(function()
    require("isovim.migrate").run()
  end)
end

local args = vim.deepcopy(_G.arg)
local command = table.remove(args, 1)
local entry = commands.find(command)
if not entry or not entry.module then
  io.stdout:write(commands.usage(), "\n")
  os.exit((command == "help" or command == "--help" or command == "-h") and 0 or 1)
end
if commands.retired(entry) then
  io.stderr:write(("iso: iso %s was retired at the cutover: %s\n"):format(command, entry.retired))
  os.exit(1)
end
if entry.audience ~= "plumbing" then
  local roles = require("isovim.cli.roles")
  if roles.namespace(command, args) then
    roles.run(command, args)
    return
  end
  roles.warn_bare(entry)
end
require("isovim.cli." .. entry.module)[entry.name](args)
