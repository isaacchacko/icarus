-- The files your CLAUDE.md files import with @path, which claude-agent-acp doesn't expand (it loads
-- the CLAUDE.md files themselves), so an ACP agent's supervisor (isovim.acp.host) appends them to
-- its session prompt. The CLAUDE.md files are Claude Code's: $CLAUDE_CONFIG_DIR/CLAUDE.md (else
-- ~/.claude/CLAUDE.md), then CLAUDE.md, .claude/CLAUDE.md and CLAUDE.local.md in the agent's dir
-- and every dir above it. As Claude Code reads them: an import is @ at the start of a line or after
-- whitespace, outside code spans and fenced blocks; its path is relative to the file it's in (or
-- ~/ or absolute); imported files import too, five deep; a file that doesn't exist is skipped.
local M = {}

M.depth = 5
M.max_bytes = 64 * 1024

local function read(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local text = file:read(M.max_bytes) or ""
  file:close()
  return text
end

local function real(path)
  return vim.uv.fs_realpath(path)
end

function M.user_dir()
  return vim.fs.normalize(vim.env.CLAUDE_CONFIG_DIR or "~/.claude")
end

-- The CLAUDE.md files Claude Code loads for a session in dir, user's first.
---@return string[]
function M.memory_files(dir)
  local files = {}
  local function add(path)
    if vim.fn.filereadable(path) == 1 then
      files[#files + 1] = path
    end
  end
  add(M.user_dir() .. "/CLAUDE.md")
  local dirs = {}
  local at = real(dir) or dir
  while at do
    table.insert(dirs, 1, at)
    local up = vim.fs.dirname(at)
    at = up ~= at and up or nil
  end
  for _, each in ipairs(dirs) do
    local base = each == "/" and "" or each
    add(base .. "/CLAUDE.md")
    add(base .. "/.claude/CLAUDE.md")
    add(base .. "/CLAUDE.local.md")
  end
  return files
end

-- The @paths in text, in order, leaving out code spans and fenced blocks.
---@return string[]
function M.refs(text)
  local refs = {}
  local fenced = false
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^%s*```") or line:match("^%s*~~~") then
      fenced = not fenced
    elseif not fenced then
      local plain = line:gsub("`[^`]*`", "")
      for ref in (" " .. plain):gmatch("%s@([^%s]+)") do
        -- Trailing punctuation belongs to the sentence, not the path.
        ref = ref:gsub("[%.,;:%)%]]+$", "")
        if ref ~= "" then
          refs[#refs + 1] = ref
        end
      end
    end
  end
  return refs
end

local function resolve(ref, from)
  if vim.startswith(ref, "~/") or ref == "~" then
    return vim.fs.normalize(ref)
  elseif vim.startswith(ref, "/") then
    return ref
  end
  return vim.fs.dirname(from) .. "/" .. ref
end

---@class isovim.acp.Import
---@field path string
---@field by string the file that imports it
---@field text string

-- Every file the CLAUDE.md files of a session in dir import, each once, in the order found.
---@return isovim.acp.Import[]
function M.collect(dir)
  local seen, imports = {}, {}
  local memory = M.memory_files(dir)
  for _, path in ipairs(memory) do
    seen[real(path) or path] = true
  end
  local function walk(path, text, depth)
    if depth > M.depth then
      return
    end
    for _, ref in ipairs(M.refs(text)) do
      local target = resolve(ref, path)
      local key = real(target)
      if key and not seen[key] and vim.fn.isdirectory(key) == 0 then
        local body = read(key)
        if body then
          seen[key] = true
          imports[#imports + 1] = { path = target, by = path, text = body }
          walk(target, body, depth + 1)
        end
      end
    end
  end
  for _, path in ipairs(memory) do
    walk(path, read(path) or "", 1)
  end
  return imports
end

-- What the session prompt gets: the imported files' contents, or "" when there are none.
---@param imports isovim.acp.Import[]
function M.prompt(imports)
  if #imports == 0 then
    return ""
  end
  local parts = { "Files your CLAUDE.md files import with @path, expanded here because this session's loader doesn't:" }
  for _, import in ipairs(imports) do
    parts[#parts + 1] = ("Contents of %s (imported by %s):\n\n%s"):format(import.path, import.by, vim.trim(import.text))
  end
  return table.concat(parts, "\n\n")
end

return M
