-- Tab completion. `iso __complete <words...>` gets the words after iso up to the one being typed
-- (maybe empty) and prints what can go there, one `value<Tab>description` per line, then a line
-- saying what the shell adds itself: ":files", ":dirs" or ":". The shell narrows by what's typed, so
-- its own matching (zsh's case-insensitive or substring styles) still applies.
-- A Tab runs this every time, so it only reads files: no ssh and no process walk. Other hosts'
-- agents come from what their last listing left in remote.cache_dir (isovim.remote).
local store = require("isovim.store")
local commands = require("isovim.cli.commands")
local c = require("isovim.cli.common")

local out = c.out
local fail = c.fail

-- A name typed in place of an id, when the shell can take it as one word.
local function plain(name)
  return type(name) == "string" and name:match("^[%w_.-]+$") ~= nil
end

local function add_workspaces(found, list)
  for _, ws in ipairs(list) do
    found[#found + 1] = { ws.id, ws.name }
    if plain(ws.name) and ws.name ~= ws.id then
      found[#found + 1] = { ws.name, ws.name }
    end
  end
end

local function add_agents(found)
  for _, ws in ipairs(store.list()) do
    for _, agent in ipairs(store.agents(ws.id)) do
      local about = ws.name .. " · " .. agent.name .. (agent.hidden and " (hidden)" or "")
      found[#found + 1] = { ws.id .. "/" .. agent.id, about }
      if plain(ws.name) and plain(agent.name) and (ws.name ~= ws.id or agent.name ~= agent.id) then
        found[#found + 1] = { ws.name .. "/" .. agent.name, about }
      end
    end
  end
end

local function add_remote_agents(found)
  local dir = require("isovim.remote").cache_dir
  for file in vim.fs.dir(dir) do
    local host = file:match("^(.+)%.json$")
    local ok, lines = pcall(vim.fn.readfile, dir .. "/" .. file)
    local decoded, rows = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
    for _, row in ipairs(host and decoded and type(rows) == "table" and rows or {}) do
      if type(row) == "table" and row.id and not row.hidden then
        found[#found + 1] = { host .. ":" .. row.id, ("%s · %s · %s"):format(host, row.workspace, row.agent) }
      end
    end
  end
end

local KINDS = {
  ws = function(found)
    add_workspaces(found, store.list())
  end,
  archived = function(found)
    add_workspaces(found, store.archived())
  end,
  agent = add_agents,
  address = function(found)
    add_agents(found)
    add_remote_agents(found)
  end,
  host = function(found)
    local remote = require("isovim.remote")
    for name, host in pairs(remote.peers()) do
      found[#found + 1] = { name, host }
    end
    for alias, name in pairs(require("isovim.config").get().aliases or {}) do
      found[#found + 1] = { alias, "= " .. tostring(name) }
    end
  end,
  kind = function(found)
    for _, kind in ipairs(require("isovim.panes").kinds) do
      found[#found + 1] = { kind }
    end
  end,
  role = function(found)
    for _, role in ipairs(store.roles) do
      found[#found + 1] = { role }
    end
  end,
  -- Event patterns: each topic for any agent or PR, and everything about one agent or one PR, their
  -- parts encoded as topics have them (a repo's "." as %2E).
  topic = function(found)
    local events = require("isovim.events")
    for _, topic in ipairs(events.topics) do
      found[#found + 1] = { topic[1], topic[2] }
    end
    local prs = {}
    for _, ws in ipairs(store.list()) do
      for _, agent in ipairs(store.agents(ws.id)) do
        local address = ws.id .. "/" .. agent.id
        local about = ws.name .. " · " .. agent.name
        found[#found + 1] = { events.topic("agent", address) .. ".*", about }
        found[#found + 1] = { events.topic("msg", address), "messages to " .. about }
      end
      for _, url in ipairs(store.prs(ws.id)) do
        local repo, number = url:match("github%.com/([^/]+/[^/]+)/pull/(%d+)")
        if repo and not prs[url] then
          prs[url] = true
          found[#found + 1] = { events.topic("pr", repo, number) .. ".*", ws.name }
        end
      end
    end
  end,
  command = function(found)
    for _, entry in ipairs(commands.list) do
      if not entry.hidden then
        found[#found + 1] = { entry.name, commands.summary(entry) }
      end
    end
  end,
}

local DIRECTIVES = { path = ":files", dir = ":dirs" }

-- What can stand for one word written as usage writes it ("parent|children|<address>").
---@return table[] candidates, string directive
local function expand(pattern)
  local found, directive = {}, ":"
  for part in vim.gsplit((pattern or ""):gsub("%.%.%.$", ""), "|", { plain = true }) do
    local kind = part:match("^<(.+)>$")
    if not kind then
      if part ~= "" then
        found[#found + 1] = { part }
      end
    elseif KINDS[kind] then
      KINDS[kind](found)
    else
      directive = DIRECTIVES[kind] or directive
    end
  end
  return found, directive
end

-- Candidates for the last of words, which follow a command (or subcommand) described by spec.
local function complete(spec, words)
  local flags = spec.flags or {}
  local current, previous = words[#words], words[#words - 1]
  if previous and flags[previous] then
    return expand(flags[previous])
  end
  local before = {}
  local i = 1
  while i < #words do
    local word = words[i]
    if flags[word] ~= nil then
      i = i + (flags[word] and 2 or 1)
    else
      if spec.subs and spec.subs[word] then
        return complete(spec.subs[word], vim.list_slice(words, i + 1))
      end
      before[#before + 1] = word
      i = i + 1
    end
  end
  if vim.startswith(current, "-") then
    local found = {}
    for name, kind in pairs(flags) do
      if kind or not vim.tbl_contains(words, name) then
        found[#found + 1] = { name, kind or nil }
      end
    end
    return found, ":"
  end
  if spec.subs then
    return #before == 0 and vim.tbl_map(function(name)
      return { name }
    end, vim.tbl_keys(spec.subs)) or {}, ":"
  end
  local args = spec.args or {}
  local last = args[#args]
  local pattern = args[#before + 1] or (last and last:match("%.%.%.$") and last)
  return expand(pattern)
end

-- After iso <role>: its actions, then what the action takes. iso root also still takes the old
-- iso root's <agent> or --clear.
local function complete_role(role, words)
  local old = role == "root" and commands.find("root")
  if #words == 1 then
    local found, directive = {}, ":"
    if old then
      found, directive = complete(old, words)
    end
    for _, name in ipairs(commands.actions(role)) do
      found[#found + 1] = { name, commands.summary(commands.action(role, name)) }
    end
    found[#found + 1] = { "help", "this role's actions" }
    return found, directive
  end
  local action = commands.action(role, words[1])
  if action then
    return complete(action, vim.list_slice(words, 2))
  end
  return old and complete(old, words) or {}, ":"
end

local M = {}

function M.__complete(words)
  if #words == 0 then
    words = { "" }
  end
  local found, directive
  if #words == 1 then
    found, directive = expand("<command>")
  elseif commands.rank[words[1]] then
    found, directive = complete_role(words[1], vim.list_slice(words, 2))
  else
    local entry = commands.find(words[1])
    found, directive = {}, ":"
    if entry then
      found, directive = complete(entry, vim.list_slice(words, 2))
    end
  end
  table.sort(found, function(a, b)
    return a[1] < b[1]
  end)
  for _, candidate in ipairs(found) do
    out(candidate[2] and candidate[1] .. "\t" .. candidate[2] or candidate[1])
  end
  out(directive)
end

local ZSH = [=[
# iso's Tab completion for zsh: `iso __complete` says what can come next.
_iso() {
  local -a lines described bare
  local line directive ret=1
  lines=("${(@f)$(command iso __complete "${(@)words[2,CURRENT]}" 2>/dev/null)}")
  directive=${lines[-1]}
  for line in "${(@)lines[1,-2]}"; do
    [[ -z $line ]] && continue
    if [[ $line == *$'\t'* ]]; then
      described+=("${${line%%$'\t'*}//:/\\:}:${line#*$'\t'}")
    else
      bare+=("$line")
    fi
  done
  (( ${#described} )) && _describe -t values iso described && ret=0
  (( ${#bare} )) && compadd -a bare && ret=0
  case $directive in
    :files) _files && ret=0 ;;
    :dirs) _files -/ && ret=0 ;;
  esac
  return ret
}
compdef _iso iso]=]

local BASH = [=[
# iso's Tab completion for bash: `iso __complete` says what can come next.
_iso() {
  local typed="${COMP_LINE:0:COMP_POINT}" line value current
  local -a words
  # Split on spaces only, so <host>:<ws>/<agent> stays one word.
  read -ra words <<<"$typed"
  [[ $typed == *[[:space:]] || ${#words[@]} -eq 0 ]] && words+=("")
  current="${words[${#words[@]}-1]}"
  COMPREPLY=()
  while IFS= read -r line; do
    case $line in
    :dirs) while IFS= read -r value; do COMPREPLY+=("$value"); done < <(compgen -d -- "$current") ;;
    :*) ;;
    *)
      value="${line%%$'\t'*}"
      [[ $value == "$current"* ]] && COMPREPLY+=("$value")
      ;;
    esac
  done < <(command iso __complete "${words[@]:1}" 2>/dev/null)
  # Readline replaces only what follows the last : of the word.
  if [[ $current == *:* && $COMP_WORDBREAKS == *:* ]]; then
    local i prefix="${current%:*}:"
    for i in "${!COMPREPLY[@]}"; do COMPREPLY[i]="${COMPREPLY[i]#"$prefix"}"; done
  fi
}
# With nothing offered (a file argument, free text) bash completes file names itself.
complete -o default -F _iso iso]=]

function M.completion(args)
  local script = ({ zsh = ZSH, bash = BASH })[args[1] or ""]
  if not script then
    fail("usage: iso completion zsh|bash")
  end
  out(script)
end

return M
