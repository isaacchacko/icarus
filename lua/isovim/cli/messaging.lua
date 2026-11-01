-- Commands that carry words between agents and to you: send, msg, ask, the root and its stamps.
local store = require("isovim.store")
local panes = require("isovim.panes")
local c = require("isovim.cli.common")

local out = c.out
local fail = c.fail
local resolve_agent = c.resolve_agent
local split_host = c.split_host
local tui = c.tui
local await = c.await
local ensure_running = c.ensure_running
local flag = c.flag
local forward = c.forward

local commands = {}

-- An agent sending to another says who it is, so the receiver can answer with iso send.
-- What one agent sends another is stamped by isovim with who sent it (proven, not claimed), so the
-- receiver can trust the stamp and answer to the address in it.
-- Returns once a hooked agent has taken the prompt, so a following `iso wait` waits for the answer.
---@param kind "from"|"ask"
local function deliver(query, text, kind)
  local root = require("isovim.root")
  local from_ws, from_agent = root.caller()
  local from = from_ws and root.address(from_ws, from_agent)
  local host
  host, query = split_host(query)
  if host then
    if from then
      text = root.stamp(kind, from, host .. ":" .. query, text) .. " " .. text
    end
    forward(host, { "send", query, text })
  end
  local ws, agent = resolve_agent(query)
  local message, stamp = text, nil
  if from then
    stamp = root.stamp(kind, from, root.address(ws.id, agent.id), text)
    text = stamp .. " " .. text
  end
  ensure_running(ws, agent)
  local result = panes.send(ws.id, agent.id, text)
  if result.code ~= 0 then
    fail("could not type into " .. agent.name .. ": " .. (result.stderr or ""))
  end
  require("isovim.events").publish("msg." .. ws.id .. "/" .. agent.id,
    { from = from, kind = kind, id = stamp and stamp:match("(m%x+)%]$"), text = message })
  if panes.reports(agent.kind) then
    await(ws.id, agent.id, 10, function(state)
      return state == "working" or state == "attention"
    end)
  end
end

function commands.send(args)
  local query = table.remove(args, 1)
  local text = table.concat(args, " ")
  if not query or text == "" then
    fail("usage: iso send <agent> <text...>")
  end
  deliver(query, text, "from")
end

-- iso send, with the agent's parent or children as the target; any other target is an agent.
function commands.msg(args)
  local target = table.remove(args, 1)
  local text = table.concat(args, " ")
  if not target or text == "" then
    fail("usage: iso msg <parent|children|agent> <text...>")
  end
  if target ~= "parent" and target ~= "children" then
    deliver(target, text, "from")
    return
  end
  local ws, agent = require("isovim.root").caller()
  if not ws then
    fail("iso msg " .. target .. " runs inside an agent: it means that agent's " .. target)
  end
  local to = target == "parent" and { store.agent(ws, agent).parent } or store.children(ws, agent)
  if #to == 0 then
    fail(("%s/%s has no %s"):format(ws, agent, target))
  end
  for _, address in ipairs(to) do
    out(address)
    deliver(address, text, "from")
  end
end

-- A worker's question goes to the root; the root's own (or any agent's while there's no root) is
-- raised to you, and the agent shows in the Inbox until you've looked at it.
function commands.ask(args)
  local root = require("isovim.root")
  local question = table.concat(args, " ")
  local ws, agent = root.caller()
  if not ws then
    fail("iso ask runs from inside an isovim agent")
  elseif question == "" then
    fail("usage: iso ask <question...>")
  end
  local boss = root.get()
  if boss and boss ~= root.address(ws, agent) then
    deliver(boss, question, "ask")
    out(("Asked the root (%s). Its answer comes into this chat stamped [from %s · root · m...]; "
      .. "carry on with what doesn't depend on it."):format(boss, boss))
    return
  end
  root.raise(ws, agent, question)
  tui("require('isovim').refresh()")
  out("Raised to the user. End your turn on this question in your own chat, with the evidence and "
    .. "your recommendation; the Inbox shows it to them.")
end

-- The root: shown, or set by the user from a shell, by the root handing over, or claimed by an agent
-- while there is none. Agents can't make themselves root over another.
function commands.root(args)
  local root = require("isovim.root")
  local current = root.get()
  if #args == 0 then
    out(current or "no root")
    return
  end
  local target
  local host, rest = split_host(args[1])
  if args[1] == "--clear" then
    target = nil
  elseif host then
    -- A root on another host is named as that host names it, <host>:<ws>/<agent>.
    target = args[1]:match("^([^:]+):") .. ":" .. rest
  else
    local ws, agent = resolve_agent(rest)
    target = root.address(ws.id, agent.id)
  end
  local ws, agent = root.caller()
  local caller = ws and root.address(ws, agent)
  if caller and caller ~= current and not (current == nil and target == caller) then
    fail(("only the user, or the root itself, can change the root (it is %s)"):format(current or "unset"))
  end
  root.set(target)
  out(target or "no root")
  tui("require('isovim').refresh()")
end

-- What isovim recorded for a stamp id: who sent it, to whom, and how it began. A stamp from another
-- host is in that host's ledger, so the other hosts are asked too (--here: this host only).
function commands.verify(args)
  local json = flag(args, "--json")
  local here = flag(args, "--here")
  local entry = args[1] and require("isovim.root").find(args[1])
  local remote = require("isovim.remote")
  for _, host in pairs(not entry and not here and args[1] and remote.peers() or {}) do
    local result = remote.run(host, { "verify", args[1], "--json", "--here" }, 5000)
    local ok, decoded = pcall(vim.json.decode, result.code == 0 and result.stdout or "")
    if ok and type(decoded) == "table" then
      entry = decoded
      break
    end
  end
  if not entry then
    fail(("no stamp %s: not sent through isovim on this host or its others"):format(args[1] or ""))
  end
  if json then
    out(vim.json.encode(entry))
    return
  end
  out(("%s: from %s%s to %s, %s: %s"):format(entry.id, entry.from, entry.root and " (root)" or "", entry.to,
    os.date("%Y-%m-%d %H:%M", entry.at), entry.preview))
end

return commands
