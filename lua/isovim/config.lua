-- ~/.isovim/config.json, all optional:
--   self       this host's name, as other hosts address its agents (<host>:<ws>/<agent>); default hostname
--   hosts      other hosts, name -> ssh host: their agents show in the sidebar and workspaces move there
--   aliases    other names for those hosts
--   repo_dirs  folders whose git repos are offered when making a workspace
local store = require("isovim.store")

local M = {}

M.path = store.root .. "/config.json"

---@return {self?: string, hosts?: table<string, string>, aliases?: table<string, string>, repo_dirs?: string[]}
function M.get()
  local ok, lines = pcall(vim.fn.readfile, M.path)
  local decoded, config = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  return decoded and type(config) == "table" and config or {}
end

return M
