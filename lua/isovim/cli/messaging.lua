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

-- What an agent whose turn iso msg --now cancelled reads first.
local INTERRUPTED = "[isovim: this message interrupted your turn, which stopped where it was. Deal with it, then carry "
  .. "on with what you were doing.]"

-- Who steers another's queue or turn: the user; for an agent, whom it may restart (its own children
-- among them). A lower role doesn't interrupt a higher one's turn.
local function may_steer(ws, agent, verb, interrupts)
  local roles = require("isovim.cli.roles")
  local by, role, by_ws = roles.caller()
  if not by then
    return
  end
  local address = ws.id .. "/" .. agent.id
  if address == by then
    fail("that's for another agent's queue or turn, not your own")
  end
  roles.check_manages(by, role, by_ws, ws, address, verb)
  local command_list = require("isovim.cli.commands")
  local theirs = store.role(agent)
  if interrupts and (command_list.rank[theirs] or 0) > (command_list.rank[role] or 0) then
    fail(("a %s doesn't interrupt a %s's turn; --first puts the message ahead without touching it"):format(role, theirs))
  end
end

-- An agent sending to another says who it is, so the receiver can answer with iso send.
-- What one agent sends another is stamped by isovim with who sent it (proven, not claimed), so the
-- receiver can trust the stamp and answer to the address in it.
-- Returns once a hooked agent has taken the prompt, so a following `iso wait` waits for the answer.
---@param kind "from"|"ask"
---@param images? isovim.acp.Image[] files on this host, so they don't go to another
---@param place? "first"|"now" iso msg's --first and --now
local function deliver(query, text, kind, images, place)
  local root = require("isovim.root")
  local from_ws, from_agent = root.caller()
  local from = from_ws and root.address(from_ws, from_agent)
  local host
  host, query = split_host(query)
  if host and place then
    fail("--" .. place .. " goes only to an agent on this host")
  elseif host then
    if images and #images > 0 then
      fail("an image goes only to an agent on this host")
    end
    if from then
      text = root.stamp(kind, from, host .. ":" .. query, text) .. " " .. text
    end
    forward(host, { "send", query, text })
  end
  local ws, agent = resolve_agent(query)
  if place then
    if not agent.acp then
      fail(("--%s is for an ACP agent, and %s isn't one"):format(place, agent.name))
    end
    may_steer(ws, agent, place == "now" and "interrupts" or "puts messages ahead for", place == "now")
    ensure_running(ws, agent)
    -- Told in the message itself, so its stamp covers it.
    local ok, status = require("isovim.acp").call(ws.id, agent.id, "status")
    if place == "now" and ok and status.in_turn then
      text = INTERRUPTED .. "\n\n" .. text
    end
  end
  local message, stamp = text, nil
  if from then
    stamp = root.stamp(kind, from, root.address(ws.id, agent.id), text)
    text = stamp .. " " .. text
  end
  ensure_running(ws, agent)
  local taken = c.prompt(ws, agent, text, { from = from, kind = kind, id = stamp and stamp:match("(m%x+)%]$"), text = message,
    user = not from or nil, place = place }, images)
  if taken and taken.refused then
    fail(("%s: --%s refused: %s"):format(agent.name, place, taken.refused))
  end
  -- An ACP agent has it once its supervisor answers: sent, or queued behind the running turn.
  if taken and taken.cancelled then
    io.stderr:write(("iso: %s's turn is being cancelled; the message is %d in its queue\n"):format(agent.name, taken.position))
  elseif taken and taken.queued then
    io.stderr:write(("iso: %s is working; the message is queued (%d) for when its turn ends\n"):format(agent.name, taken.position))
  elseif not agent.acp and panes.reports(agent.kind) then
    await(ws.id, agent.id, 10, function(state)
      return state == "working" or state == "attention"
    end)
  end
end

-- Each --image <file> attaches an image, as [Image #n] in the text.
---@return isovim.acp.Image[]
local function take_images(args)
  local found = {}
  local path = c.option(args, "--image")
  while path do
    path = vim.fn.fnamemodify(path, ":p")
    local mime = require("isovim.acp.images").mime(path)
    if not mime or vim.fn.filereadable(path) == 0 then
      fail(path .. " is not a png, jpeg, gif or webp file")
    end
    found[#found + 1] = { path = path, mimeType = mime }
    path = c.option(args, "--image")
  end
  return found
end

function commands.send(args)
  local images = take_images(args)
  local query = table.remove(args, 1)
  local text = table.concat(args, " ")
  if not query or text == "" then
    fail("usage: iso send <agent> [--image <file>]... <text...>")
  end
  deliver(query, text, "from", images)
end

-- iso send, with the agent's parent or children as the target; any other target is an agent.
function commands.msg(args)
  local images = take_images(args)
  -- Only before the target: the message's own words may well say --now.
  local place
  while args[1] == "--first" or args[1] == "--now" do
    if place and place ~= args[1]:sub(3) then
      fail("--first or --now, not both")
    end
    place = table.remove(args, 1):sub(3)
  end
  local target = table.remove(args, 1)
  local text = table.concat(args, " ")
  if not target or text == "" then
    fail("usage: iso msg [--first|--now] <parent|children|agent> [--image <file>]... <text...>")
  end
  if target ~= "parent" and target ~= "children" then
    deliver(target, text, "from", images, place)
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
    deliver(address, text, "from", images, place)
  end
end

local function age(at)
  local seconds = at and os.time() - at or nil
  if not seconds then
    return "?"
  elseif seconds < 60 then
    return seconds .. "s"
  elseif seconds < 3600 then
    return math.floor(seconds / 60) .. "m"
  end
  return math.floor(seconds / 3600) .. "h"
end

-- iso queue <agent>: an agent's queued prompts, in the order they'll go: id, sender, age, text.
-- iso queue drop <agent> <id> removes one. Whom you may steer (may_steer) goes for both, and the
-- supervisor keeps what the user wrote from anyone else.
function commands.queue(args)
  local dropping = args[1] == "drop"
  if dropping then
    table.remove(args, 1)
  end
  local query, id = args[1], args[2]
  if not query or (dropping and not id) or (not dropping and id) then
    fail("usage: iso queue <agent>, or iso queue drop <agent> <id>")
  end
  local ws, agent = resolve_agent(query)
  if not agent.acp then
    fail(agent.name .. " isn't an ACP agent: it has no queue")
  end
  may_steer(ws, agent, dropping and "drops messages for" or "reads the queue of")
  local name = dropping and "queue_drop" or "queue"
  local by_user = require("isovim.cli.roles").caller() == nil
  local ok, result = require("isovim.acp").call(ws.id, agent.id, name, dropping and { id = id, user = by_user or nil } or {})
  if not ok then
    fail("could not reach " .. agent.name .. ": " .. tostring(result))
  elseif dropping then
    if result.refused then
      fail(("%s: %s"):format(id, result.refused))
    end
    out("dropped " .. id)
    return
  end
  if #result.items == 0 then
    out(agent.name .. "'s queue is empty")
  end
  for _, item in ipairs(result.items) do
    local who = item.from or ((item.via == "composer" or item.user) and "user") or item.via or "?"
    out(("%s  %s  %s  %s"):format(item.id, who, age(item.at), (item.text:gsub("%s+", " ")):sub(1, 100)))
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
  local holder = root.holder()
  if holder then
    fail(("the host root is %s, the agent with the root role: your authority goes with it, not with "
      .. "iso root"):format(holder))
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
