-- ~/.isovim/config.json, all optional:
--   self       this host's name, as other hosts address its agents (<host>:<ws>/<agent>); default hostname
--   hosts      other hosts, name -> ssh host: their agents show in the sidebar and workspaces move there
--   aliases    other names for those hosts
--   repo_dirs  more folders whose git repos are offered when making a workspace, besides ~ and the usual
--              code folders (~/code, ~/src, ~/Programs, ...)
--   prompts    role -> file (root, router, worker; relative to ~) added to what agents of that role are
--              told at launch, after instructions.md
--   repo_defaults  {glyph, palette}: the glyph and the list of colors (names or "#rrggbb") written into a
--              repo's config when it's first seen; default the repo glyph and the 12 palette colors from
--              red to pink. Repos take the colors in the order they're first seen, wrapping round.
local store = require("isovim.store")

local M = {}

M.path = store.root .. "/config.json"

---@return {self?: string, hosts?: table<string, string>, aliases?: table<string, string>, repo_dirs?: string[], prompts?: table<string, string>, repo_defaults?: {glyph?: string, palette?: string[]}}
function M.get()
  local ok, lines = pcall(vim.fn.readfile, M.path)
  local decoded, config = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
  return decoded and type(config) == "table" and config or {}
end

-- The prompt file configured for a role, as an absolute path, or nil.
---@return string?
function M.prompt_file(role)
  local prompts = M.get().prompts
  local path = type(prompts) == "table" and prompts[role]
  if type(path) ~= "string" or path == "" then
    return nil
  end
  path = vim.fs.normalize(path)
  return vim.startswith(path, "/") and path or vim.fs.joinpath(vim.uv.os_homedir(), path)
end

return M
