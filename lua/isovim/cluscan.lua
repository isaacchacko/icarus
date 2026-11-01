-- The cutover's clu-system preflight. clu (Isaac's likeness, ~/Programs/clu-system) drives isovim
-- from its bin, skills and hooks, and enforcement refuses some of what they run. M.scan greps them
-- (not discs, which are CLU's own notes) for iso commands and sorts each one found:
--   refused  enforcement refuses it: a retired command, spawn --legacy, agent --hidden, a role
--            action no role has, and in a skill (which an agent follows) a bare command that is the
--            user's. The plan lists these as warnings; they don't block the cutover.
--   guarded  a line clu's own enforce check keeps from running once enforcement is on: in Python,
--            behind `if not enforced()`, after an `if v0: ... return` (v0 = enforced()), in the else
--            of `x if v0 else f()`, or in a function only called so; in a skill, on a line that says
--            it's for a legacy agent, or in the block a line ending in ":" opens that way, up to
--            "Otherwise", a heading or the new layout.
--   named    a skill naming a command rather than running it: `iso ask` right after "as" or "bare".
local store = require("isovim.store")
local commands = require("isovim.cli.commands")

local M = {}

-- Where clu-system is: ISOVIM_CLU_SYSTEM, else the repo isovim's idle hook links to, else
-- ~/Programs/clu-system.
function M.dir()
  if vim.env.ISOVIM_CLU_SYSTEM and vim.env.ISOVIM_CLU_SYSTEM ~= "" then
    return vim.fs.normalize(vim.env.ISOVIM_CLU_SYSTEM)
  end
  local hook = vim.uv.fs_realpath(store.root .. "/hooks/idle")
  local linked = hook and vim.fs.dirname(vim.fs.dirname(hook))
  if linked and vim.uv.fs_stat(linked .. "/bin/clu") then
    return linked
  end
  return vim.fs.normalize("~/Programs/clu-system")
end

M.SCANNED = { "bin", "skills", "hooks" }

-- Words of a shell command line, quotes taken off; it ends at ; | & ) or a backtick.
local function words(text)
  local list, i = {}, 1
  while i <= #text do
    local c = text:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif c:match("[;|&)`]") then
      break
    elseif c == '"' or c == "'" then
      local close = text:find(c, i + 1, true) or #text + 1
      list[#list + 1] = text:sub(i + 1, close - 1)
      i = close + 1
    else
      local stop = text:find("[%s;|&)`]", i) or #text + 1
      list[#list + 1] = text:sub(i, stop - 1)
      i = stop
    end
  end
  return list
end

-- The string literals of a Python call's arguments on its line, from just after its "(" (or
-- "iso",): nil when the first argument isn't one (iso(role, ...), a variable command).
local function literals(text)
  local at, quote = text:match("^%s*[fr]?()([\"'])")
  if not at then
    return nil
  end
  local list = {}
  for _, value in text:sub(at):gmatch("([\"'])(.-)%1") do
    list[#list + 1] = value
  end
  return list
end

local function has(list, word)
  return vim.tbl_contains(list, word)
end

-- Why enforcement refuses iso <args...>, or nil when it doesn't (or args isn't a command at all:
-- prose, a placeholder). agent: run by an agent (a skill), to which the user's bare commands are refused.
---@return string? why, string? shown
function M.why(args, agent)
  local first = args[1]
  if not first or first == "" then
    return nil
  end
  local role = commands.rank[first] and first or (first:match("^%${?ISOVIM_ROLE") and "*") or nil
  if role then
    local action = args[2]
    if not action or not action:match("^[%w_-]+$") then
      return nil
    end
    local roles = role == "*" and commands.roles or { role }
    local entry
    for _, r in ipairs(roles) do
      entry = entry or commands.action(r, action)
    end
    local shown = ("iso %s %s"):format(role == "*" and "<role>" or role, action)
    if not entry then
      return ("%s isn't a%s action"):format(action, role == "*" and "ny role's" or (" " .. role)), shown
    elseif entry.retired then
      return "retired: " .. entry.retired, shown
    end
    return nil
  end
  local entry = first:match("^[%w_-]+$") and commands.find(first)
  if not entry then
    return nil
  end
  local shown = "iso " .. first
  if entry.retired then
    return "retired: " .. entry.retired, shown
  elseif first == "spawn" and has(args, "--legacy") then
    return "--legacy was retired: iso spawn starts an agent over ACP", shown .. " --legacy"
  elseif first == "agent" and has(args, "--hidden") then
    return "hidden agents were retired: every agent shows under its repo", shown .. " --hidden"
  end
  if agent and entry.audience ~= "plumbing" then
    local form = entry.role_form or entry.name
    local has_form = vim.iter(commands.roles):any(function(r)
      return commands.action(r, form) ~= nil
    end)
    if has_form then
      return ("bare, an agent's is iso <role> %s"):format(form), shown
    elseif entry.audience == "user" then
      return "bare, and the user's: refused to agents", shown
    end
  end
  return nil
end

-- Python: is line n kept from running once enforcement is on?
local function indent(line)
  return #line:match("^%s*")
end

local function blank(line)
  return line:match("^%s*$") or line:match("^%s*#")
end

local function python_guards(lines)
  local guards = { ["enforced()"] = true }
  for _, line in ipairs(lines) do
    local name = line:match("^%s*([%a_][%w_]*)%s*=%s*enforced%(%)%s*$")
    if name then
      guards[name] = true
    end
  end
  return guards
end

local function condition(header, guards)
  local cond = header:match("^if%s+(.-)%s*:$")
  if not cond then
    return nil
  end
  if guards[cond] then
    return "on"
  end
  local negated = cond:match("^not%s+(.+)$")
  return negated and guards[negated] and "off" or nil
end

-- Whether the block under the header at line i ends in a return, sys.exit or raise.
local function exits(lines, i)
  local base, body = indent(lines[i]), nil
  for j = i + 1, #lines do
    if not blank(lines[j]) then
      local ind = indent(lines[j])
      if ind <= base then
        break
      end
      body = body or ind
      if ind == body and (lines[j]:match("^%s*return%f[%W]") or lines[j]:match("^%s*raise%f[%W]") or lines[j]:match("^%s*sys%.exit%(")) then
        return true
      end
    end
  end
  return false
end

local python_guarded

local function function_guarded(lines, name, guards, depth)
  local calls = 0
  for m, line in ipairs(lines) do
    local at = line:find("%f[%w_]" .. vim.pesc(name) .. "%(")
    if at and not line:match("^%s*def%s") and not blank(line) then
      calls = calls + 1
      local before = line:sub(1, at - 1)
      local in_else = false
      for guard in pairs(guards) do
        in_else = in_else or before:find("if%s+" .. vim.pesc(guard) .. "%s+else%s") ~= nil
      end
      if not in_else and not python_guarded(lines, m, guards, depth + 1) then
        return false
      end
    end
  end
  return calls > 0
end

python_guarded = function(lines, n, guards, depth)
  if depth > 6 then
    return false
  end
  local cur = indent(lines[n])
  for i = n - 1, 1, -1 do
    local line = lines[i]
    if not blank(line) then
      local ind, header = indent(line), vim.trim(line)
      if ind < cur then
        cur = ind
        local cond = condition(header, guards)
        if cond == "off" then
          return true
        elseif header == "else:" then
          for k = i - 1, 1, -1 do
            if not blank(lines[k]) and indent(lines[k]) <= ind then
              if indent(lines[k]) == ind and condition(vim.trim(lines[k]), guards) == "on" then
                return true
              end
              if indent(lines[k]) < ind or not vim.trim(lines[k]):match("^elif") then
                break
              end
            end
          end
        end
        local name = header:match("^def%s+([%a_][%w_]*)%s*%(")
        if name then
          return function_guarded(lines, name, guards, depth)
        end
      elseif ind == cur and condition(header, guards) == "on" and exits(lines, i) then
        return true
      end
    end
  end
  return false
end

local MARKERS = { "legacy workspace", "legacy agent", "before isovim's cutover", "before the cutover" }

local function marked(line)
  local lower = line:lower()
  for _, marker in ipairs(MARKERS) do
    if lower:find(marker, 1, true) then
      return true
    end
  end
  return false
end

local function ends_region(line)
  local lower = vim.trim(line):lower():gsub("^[-*]%s+", "")
  return lower:match("^#") or lower:match("^otherwise") or lower:find("after the cutover", 1, true)
    or lower:find("new-layout", 1, true)
end

-- The iso commands in a file: {line, args, guarded, named}.
local function hits(path, rel)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or #lines == 0 then
    return {}
  end
  local found = {}
  local function add(n, args, guarded, named)
    found[#found + 1] = { file = rel, line = n, args = args, guarded = guarded or nil, named = named or nil }
  end
  if rel:match("%.md$") then
    local fence, region = false, false
    for n, line in ipairs(lines) do
      if line:match("^%s*```") then
        fence = not fence
      elseif not fence and ends_region(line) and not marked(line) then
        region = false
      end
      local guarded = region or marked(line)
      if fence and not line:match("^%s*```") then
        local code = line:gsub("%s#.*$", "")
        for at in code:gmatch("()%f[%w]iso%s") do
          local prev = at > 1 and code:sub(at - 1, at - 1) or " "
          if prev:match("[%s(;|&$]") or at == 1 then
            add(n, words(code:sub(at + 4)), guarded)
          end
        end
      elseif not fence then
        for before, span in line:gmatch("()`([^`]+)`") do
          local code = span
          if code:match("^iso%s") then
            local lead = line:sub(1, before - 1):lower()
            add(n, words(code:sub(5)), guarded, lead:match("%f[%w]as%s+$") or lead:match("%f[%w]bare%s+$"))
          end
        end
        if marked(line) and vim.trim(line):match(":$") then
          region = true
        end
      end
    end
    return found
  end
  local python = rel:match("%.py$") or (lines[1] or ""):match("^#!.*python")
  if python then
    local guards = python_guards(lines)
    for n, line in ipairs(lines) do
      if not blank(line) then
        for _, pattern in ipairs({ "%f[%w_]iso%(()", "[\"']iso[\"']%s*,()" }) do
          for at in line:gmatch(pattern) do
            local args = literals(line:sub(at))
            if args then
              add(n, args, python_guarded(lines, n, guards, 0))
            end
          end
        end
      end
    end
    return found
  end
  if not ((lines[1] or ""):match("^#!.*sh") or rel:match("%.sh$")) then
    return found
  end
  for n, line in ipairs(lines) do
    if not blank(line) then
      local code = line:gsub("%s#.*$", "")
      for at in code:gmatch("()%f[%w]iso%s") do
        local prev = at > 1 and code:sub(at - 1, at - 1) or " "
        if prev:match("[%s(;|&`]") then
          add(n, words(code:sub(at + 4)), false)
        end
      end
    end
  end
  return found
end

---@return table? scan {dir, refused = {}, guarded = {}, named = {}}, nil when there's no clu-system
function M.scan(dir)
  dir = dir or M.dir()
  if vim.fn.isdirectory(dir) == 0 then
    return nil
  end
  local scan = { dir = dir, refused = {}, guarded = {}, named = {} }
  local files = {}
  for _, top in ipairs(M.SCANNED) do
    local root = dir .. "/" .. top
    if vim.fn.isdirectory(root) == 1 then
      for name, kind in vim.fs.dir(root, { depth = 6 }) do
        local stat = kind == "file" and vim.uv.fs_stat(root .. "/" .. name)
        if stat and stat.size < 1024 * 1024 then
          files[#files + 1] = top .. "/" .. name
        end
      end
    end
  end
  table.sort(files)
  for _, rel in ipairs(files) do
    local agent = vim.startswith(rel, "skills/")
    for _, hit in ipairs(hits(dir .. "/" .. rel, rel)) do
      local why, shown = M.why(hit.args, agent)
      if why then
        hit.why, hit.shown = why, shown
        local list = hit.named and scan.named or hit.guarded and scan.guarded or scan.refused
        list[#list + 1] = hit
      end
    end
  end
  return scan
end

return M
