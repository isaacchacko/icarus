-- `iso <command>`: drive workspaces and their agents from a shell or an agent. bin/iso runs this
-- under `nvim -l`; when the TUI is open, changes reach it over its socket. The commands are listed
-- in isovim.cli.commands and run by the isovim.cli module each names.
local lua_dir = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
package.path = lua_dir .. "/?.lua;" .. lua_dir .. "/?/init.lua;" .. package.path

local commands = require("isovim.cli.commands")

local args = vim.deepcopy(_G.arg)
local command = table.remove(args, 1)
local entry = commands.find(command)
if not entry or not entry.module then
  io.stdout:write(commands.usage(), "\n")
  os.exit((command == "help" or command == "--help" or command == "-h") and 0 or 1)
end
require("isovim.cli." .. entry.module)[entry.name](args)
