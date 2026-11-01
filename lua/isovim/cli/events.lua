-- iso listen: the events on isovim's bus (isovim.events) whose topics match, one JSON line each;
-- and iso closed, which publishes an agent whose program ended on its own.
local events = require("isovim.events")
local store = require("isovim.store")
local panes = require("isovim.panes")
local status = require("isovim.status")
local c = require("isovim.cli.common")

local commands = {}

-- Streams until killed, which suits a Monitor; --once ends on the first match.
function commands.listen(args)
  local once = c.flag(args, "--once")
  local since = c.option(args, "--since")
  if #args == 0 then
    c.fail("usage: iso listen <pattern>... [--once] [--since <epoch|90s|10m|2h|1d>]")
  end
  local from = since and (events.parse_since(since) or c.fail("--since takes epoch seconds or 90s, 10m, 2h, 1d"))
  events.follow(function(line, event)
    for _, pattern in ipairs(args) do
      if events.matches(pattern, event.topic) then
        -- Whoever read the output has gone (a closed pipe): nothing left to do.
        if not io.stdout:write(line, "\n") or not io.stdout:flush() then
          os.exit(0)
        end
        if once then
          os.exit(0)
        end
        return
      end
    end
  end, from)
end

-- tmux's session-closed hook (panes.start), with the session's name. One isovim stopped was marked
-- and published by panes.stop; any other ended on its own: it's published as exited, and a
-- terminal's state says so, so the TUI drops it.
function commands.closed(args)
  local ws, agent = panes.decode(args[1])
  if not ws then
    return
  end
  local mark = panes.stopped_file(ws, agent)
  local marked = vim.uv.fs_stat(mark)
  os.remove(mark)
  -- A mark whose hook never ran (tmux quits with its last session) is stale by the next end.
  if marked and marked.mtime.sec >= os.time() - 10 then
    return
  end
  local spec = store.agent(ws, agent)
  if spec and (spec.kind == "terminal" or spec.kind == "command") then
    status.set_state(ws, agent, "exited")
  end
  events.publish(events.agent_topic(ws, agent, "exited"), { reason = "ended" })
end

return commands
