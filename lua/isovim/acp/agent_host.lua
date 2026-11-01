-- nvim -l <isovim>/lua/isovim/acp/agent_host.lua <ws>/<agent>: an ACP agent's supervisor, which its
-- tmux pane runs in place of claude (panes.agent_cmd). The work is isovim.acp.host's; this file only
-- puts isovim on the module path, as cli.lua does, so the socket's calls reach the same module.
local lua_dir = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
package.path = lua_dir .. "/?.lua;" .. lua_dir .. "/?/init.lua;" .. package.path

require("isovim.acp.host").run(_G.arg[1])
