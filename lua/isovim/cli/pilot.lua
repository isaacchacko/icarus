-- iso pilot: an agent asks to drive the open TUI, then types into it and reads its screen.
local store = require("isovim.store")
local c = require("isovim.cli.common")

local out = c.out
local fail = c.fail
local tui = c.tui

local commands = {}

-- Agents run with $ISOVIM_STATE at run/<ws>/<agent>.state, which names who is asking.
local function pilot_name()
  local ws_id, agent_id = (vim.env.ISOVIM_STATE or ""):match("([^/]+)/([^/]+)%.state$")
  local ws = ws_id and vim.iter(store.list()):find(function(ws)
    return ws.id == ws_id
  end)
  if not ws then
    return "An agent"
  end
  local agent = vim.iter(store.agents(ws.id)):find(function(agent)
    return agent.id == agent_id
  end)
  return ws.name .. " · " .. (agent and agent.name or agent_id)
end

function commands.pilot(args)
  local function call(code, ...)
    local open, result = tui(code, ...)
    if not open then
      fail("the TUI is not open")
    end
    return result
  end
  local function state()
    return call("return require('isovim.pilot').state()")
  end
  local sub = table.remove(args, 1)
  if sub == "request" then
    local reason = table.concat(args, " ")
    call("require('isovim.pilot').request(...)", pilot_name(), reason ~= "" and reason or "no reason given")
    vim.wait(300000, function()
      return state() ~= "asking"
    end, 300)
    local now = state()
    out(now == "active" and "allowed" or now == "asking" and "no answer" or "denied")
    os.exit(now == "active" and 0 or 1)
  elseif sub == "keys" then
    call("require('isovim.pilot').input(...)", args[1] or fail("usage: iso pilot keys <keys>"))
  elseif sub == "screen" then
    out(call("return require('isovim.pilot').screen()"))
  elseif sub == "status" then
    out(state())
  elseif sub == "release" then
    call("require('isovim.pilot').release(...)")
  else
    fail("usage: iso pilot request|keys|screen|status|release")
  end
end

return commands
