-- Roles on the command line: iso <role> <action> runs the action under the role the agent states,
-- and bare iso <command> is the user's. isovim checks both against who is calling, proven by
-- ancestry (root.caller) and that agent's record; for now it only warns, so agents can switch
-- before anything is refused.
local store = require("isovim.store")
local commands = require("isovim.cli.commands")
local c = require("isovim.cli.common")

local out = c.out
local fail = c.fail

local M = {}

local RANK = commands.rank

local function warn(message)
  io.stderr:write("iso: warning: " .. message .. "\n")
end

-- The agent running this and its recorded role; nil from a plain shell, another host's ssh, or a
-- terminal agent, which is the user typing.
---@return string? address, string? role, string? ws, string? agent
local function caller()
  local ws, agent = require("isovim.root").caller()
  local record = ws and store.agent(ws, agent) or { kind = "claude" }
  if ws and require("isovim.panes").reports(record.kind) then
    return ws .. "/" .. agent, store.role(record), ws, agent
  end
end

-- iso root <address>|--clear (or nothing) is still the old iso root; any other role word, and
-- root followed by one of its actions, is a namespace.
function M.namespace(command, args)
  if not RANK[command] then
    return false
  end
  return command ~= "root" or args[1] == "help" or commands.action("root", args[1]) ~= nil
end

-- Warns when the caller isn't who iso <role> <name> is for.
local function check_role(role, name)
  local address, mine = caller()
  if not address then
    local bare = commands.find(name) and (": the user runs iso " .. name) or ""
    warn(("iso %s ... is for agents, and this isn't one%s (this will be refused later)"):format(role, bare))
  elseif mine ~= role and commands.action(mine, name) then
    warn(("you are a %s, not a %s: run iso %s %s (this will be refused later)"):format(mine, role, mine, name))
  elseif mine ~= role then
    warn(("you are a %s, not a %s, and %s isn't a %s action (this will be refused later)"):format(mine, role, name, mine))
  end
end

-- Warns an agent off a bare command, which is the user's, pointing at its role form if it has one.
-- Commands agents still run until their replacement lands (no audience) are left alone.
function M.warn_bare(entry)
  local form = entry.role_form or entry.name
  local has_form = vim.iter(commands.roles):any(function(role)
    return commands.action(role, form) ~= nil
  end)
  if entry.audience == "plumbing" or not (has_form or entry.audience == "user") then
    return
  end
  local address, role = caller()
  if not address then
    return
  elseif commands.action(role, form) then
    local instead = form ~= entry.name and (", not iso " .. entry.name) or ""
    warn(("agents run iso %s %s%s; bare iso commands are the user's and will be refused to agents later"):format(role, form, instead))
  elseif entry.audience == "user" then
    warn(("iso %s is the user's; it will be refused to agents later"):format(entry.name))
  end
end

local function browser(args)
  local node = { "node", vim.fs.dirname(require("isovim.panes").bin) .. "/iso-browser.mjs" }
  local ok, _, code = os.execute(table.concat(vim.tbl_map(vim.fn.shellescape, vim.list_extend(node, args)), " "))
  os.exit(ok and 0 or code or 1)
end

-- iso <role> <action> ...: the action's own command, after the role check.
function M.run(role, args)
  local name = table.remove(args, 1)
  if not name or name == "help" then
    out(commands.role_usage(role))
    os.exit(name and 0 or 1)
  end
  local entry = commands.action(role, name)
  if not entry then
    fail(("%s isn't a %s action; iso %s help lists them"):format(name, role, role))
  end
  check_role(role, name)
  if not entry.module then
    browser(args)
  end
  require("isovim.cli." .. entry.module)[entry.name](args)
end

-- bin/iso runs iso browser itself, after asking for these warnings.
M.__warn = function(args)
  local command = table.remove(args, 1)
  if M.namespace(command or "", args) and commands.action(command, args[1]) then
    check_role(command, args[1])
  elseif commands.find(command) then
    M.warn_bare(commands.find(command))
  end
end

return M
