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
  local function status()
    return call("return require('isovim.pilot').status()")
  end
  local me = pilot_name()
  local function as_holder(action, ...)
    local done = call("return require('isovim.pilot').as_holder(...)", me, action, ...)
    if done.refused then
      fail(("pilot %s refused: %s"):format(action, done.refused))
    end
    return done.result
  end
  local sub = table.remove(args, 1)
  if sub == "request" then
    local reason = table.concat(args, " ")
    -- A nil result would come back over RPC as vim.NIL, which is truthy.
    local busy = call("return require('isovim.pilot').request(...) or false", me, reason ~= "" and reason or "no reason given")
    if busy then
      out(busy)
      os.exit(1)
    end
    local now
    vim.wait(300000, function()
      now = status()
      return now.state ~= "asking" or now.holder ~= me
    end, 300)
    local allowed = now.state == "active" and now.holder == me
    out(allowed and "allowed" or now.state == "asking" and now.holder == me and "no answer" or "denied")
    os.exit(allowed and 0 or 1)
  elseif sub == "keys" then
    as_holder("keys", args[1] or fail("usage: iso pilot keys <keys>"))
  elseif sub == "screen" then
    out(as_holder("screen"))
  elseif sub == "status" then
    local now = status()
    out(now.holder and now.state .. " " .. now.holder or now.state)
  elseif sub == "release" then
    as_holder("release")
  else
    fail("usage: iso pilot request|keys|screen|status|release")
  end
end

return commands
