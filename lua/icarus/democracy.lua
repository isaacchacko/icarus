-- A democracy's graph (icarus.orchestration): the agents on a task are nodes, each with one claim at
-- a time, joined by typed edges that the agents wire themselves. icarus holds the graph, in the task's
-- graph.json, enforces a few rules on it, and shows it (icarus.graph).
--
--   reviews A→B    B's claim reaches the user only after A approves it
--   needs A→B      A waits on B's claim
--   contests A↔B   rival takes on one question; both go to the user
--   talks A↔B      they can message each other, with no duties
--
-- Agents move with ica: claim, done, approve, reject, spawn, edge, unedge, topology, merge, retire,
-- post, read, propose-to-peers, vote, revise, withdraw, decisions (their usage is in cli.lua).
--
-- Rules:
--   a claim reaches the user through a reviewer's approval, unless it's marked trivial
--   a cap on nodes and on a node's edges (task.md's max_nodes, max_edges)
--   agents message only along an edge, or where icarus set them to talking (M.refuse_message)
--   no deadlocks: waits (a needs edge, a vote owed, a merge bid) form a graph, and the move that would
--     close a cycle is refused. Its agent talks it out with the cycle's others; after two turns each
--     it yields. A deadlock never reaches the user
--   every voter must answer; silence never counts. A first objection sends the proposal back for one
--     revision, a second goes to the user (<leader>i, icarus.inbox)
--
-- Pressure, on a timer: an edge unused for 10 turns of either end or 30 minutes is put to both ends and
-- dropped only if neither needs it; a node blocked on a needs edge is nudged to spawn help or merge.
-- The user's edits in <leader>g go through M.user_*, which skip the rules.
local tasks = require("icarus.tasks")
local chats = require("icarus.chats")

local M = {}

M.COMMANDS = { "claim", "claims", "unclaim", "done", "approve", "reject", "spawn", "edge", "unedge", "topology", "merge",
  "retire", "post", "read", "propose-to-peers", "vote", "revise", "withdraw", "decisions" }

local MAX_NODES, MAX_EDGES = 6, 3
local PROBE_TURNS, PROBE_SECONDS = 10, 30 * 60
local NUDGE_SECONDS, REMIND_SECONDS = 15 * 60, 5 * 60
local TICK_MS = 30 * 1000

-- What `ica spawn <specialty>` briefs a specialist with.
M.SPECIALTIES = {
  ["slack-watcher"] = "You're the task's Slack watcher: read the channels it cares about (teammates' PR comments and Linear replies count) and relay each message to the agent it concerns. Never post unless an agent asks and the user has allowed it.",
  ["eval-runner"] = "You're the task's eval runner: you hold its eval queue. Agents ask you for a run; run them one at a time, or within a concurrency cap, and send back the scores. No two evals hit the same tenant or DB at once.",
  skeptic = "You're the task's skeptic: when an agent says done, fixed or works, check it independently against real data (prod, the live app, CI), not its own test, and report what you saw.",
  historian = "You're the task's historian: you know what was tried before, from git log and blame, merged and closed PRs, Linear, past agents' transcripts and memory. Brief an agent before it starts, block recovery code for a cause that's already gone, and write each new lesson where the next agent will find it.",
  ["decision-keeper"] = "You're the task's decision keeper: hold what the user has decided, in files, threads and chat, and flag work or docs that contradict it.",
  ["blast-radius"] = "You're the task's blast radius: for each change, ask who else reads that code or data (other tenants, migrations, deploy order, steps needed after merge), and write those down before merge.",
  simplifier = "You're the task's simplifier. Before code is written, walk the ladder: is this needed at all, does existing code, the stdlib, the platform or an installed dependency already do it; new code comes last. On each diff, propose deletions: defensive branches, new tables, flags, fallbacks.",
}

-- In _G, so a hot reload keeps the ticker; it calls whatever module is loaded by then.
_G.icarus_democracy = _G.icarus_democracy or {}
local state = _G.icarus_democracy
if state.timer then
  state.timer:stop()
  state.timer:close()
  state.timer = nil
end

local function path(slug, name)
  return tasks.dir(slug) .. "/" .. name
end

local function read_json(file)
  local ok, value = pcall(vim.json.decode, vim.fn.filereadable(file) == 1 and table.concat(vim.fn.readfile(file), "\n") or "")
  return ok and type(value) == "table" and value or nil
end

local function agent(id)
  local record = id and chats.get(id)
  return ((record and record.title or id or "an agent"):gsub("^⑂ ", ""))
end

local function open_chat(id)
  return (_G.icarus_open_chats or {})[id]
end

local function turns_of(id)
  local chat = open_chat(id)
  return chat and chat.turns or 0
end

-- The old stores, folded into a new graph.
local function migrate(slug, graph)
  for _, claim in ipairs(read_json(path(slug, "claims.json")) or {}) do
    graph.nodes[claim.by] = { claim = { id = claim.id, what = claim.what, status = "open", approvals = {} } }
    graph.claims_made = math.max(graph.claims_made or 0, tonumber(claim.id:match("%d+")) or 0)
  end
  for _, d in ipairs(read_json(path(slug, "decisions.json")) or {}) do
    d.voters, d.votes, d.turns, d.agreed = vim.tbl_keys(d.turns or {}), {}, nil, nil
    graph.decisions[#graph.decisions + 1] = d
    graph.decisions_made = math.max(graph.decisions_made or 0, tonumber(d.id:match("%d+")) or 0)
  end
end

local function load(slug)
  local graph = read_json(path(slug, "graph.json")) or {}
  for _, key in ipairs({ "nodes", "edges", "decisions", "bids", "deadlocks", "cursors" }) do
    graph[key] = graph[key] or {}
  end
  if vim.fn.filereadable(path(slug, "graph.json")) == 0 then
    migrate(slug, graph)
  end
  for _, record in ipairs(chats.on_task(slug)) do
    if not record.retired then
      graph.nodes[record.id] = graph.nodes[record.id] or {}
    end
  end
  return graph
end

-- decisions.md, for the user to read.
local function render(slug, graph)
  local lines = { "# decisions", "", "Written by icarus from the peers' `ica propose-to-peers`. Your calls on disputed ones go through <leader>i.", "" }
  for i = #graph.decisions, 1, -1 do
    local d = graph.decisions[i]
    lines[#lines + 1] = ("## %s · %s · by %s"):format(d.id, d.status, agent(d.by))
    lines[#lines + 1] = ""
    vim.list_extend(lines, vim.split(d.text, "\n", { plain = true }))
    for _, o in ipairs(d.objections or {}) do
      lines[#lines + 1] = ("- objection, %s: %s"):format(agent(o.by), o.why)
    end
    if d.call then
      lines[#lines + 1] = "- your call: " .. d.call
    end
    lines[#lines + 1] = ""
  end
  vim.fn.writefile(lines, path(slug, "decisions.md"))
end

local function save(slug, graph)
  local tmp = path(slug, "graph.json.tmp")
  vim.fn.writefile({ vim.json.encode(graph) }, tmp)
  assert(vim.uv.fs_rename(tmp, path(slug, "graph.json")))
  -- Folded in by now (migrate).
  vim.fn.delete(path(slug, "claims.json"))
  vim.fn.delete(path(slug, "decisions.json"))
  if #graph.decisions > 0 then
    render(slug, graph)
  end
end

-- Sends the agent a message, opening its chat if it's closed.
local function tell(id, text, display)
  local record = chats.get(id)
  if not record or record.retired then
    return
  end
  local chat = open_chat(id) or require("icarus.acp.chat").get(record)
  chat.session:prompt("icarus: " .. text, nil, display or ("◉ " .. vim.fn.strcharpart(text, 0, 60)))
end

local function live(graph)
  local out = {}
  for id in pairs(graph.nodes) do
    local record = chats.get(id)
    if record and not record.retired then
      out[#out + 1] = id
    end
  end
  table.sort(out)
  return out
end

local function edge_of(graph, kind, from, to)
  for _, edge in ipairs(graph.edges) do
    local same = edge.from == from and edge.to == to
    local mirrored = (kind == "contests" or kind == "talks") and edge.from == to and edge.to == from
    if edge.type == kind and (same or mirrored) then
      return edge
    end
  end
end

local function new_edge(graph, kind, from, to)
  local edge = { type = kind, from = from, to = to, at = os.time(), used = os.time(), turns = { [from] = turns_of(from), [to] = turns_of(to) } }
  graph.edges[#graph.edges + 1] = edge
  return edge
end

local function outgoing(graph, id)
  local n = 0
  for _, edge in ipairs(graph.edges) do
    if edge.from == id then
      n = n + 1
    end
  end
  return n
end

local function reviewers(graph, id)
  local out = {}
  for _, edge in ipairs(graph.edges) do
    if edge.type == "reviews" and edge.to == id then
      out[#out + 1] = edge.from
    end
  end
  return out
end

local function neighbors(graph, id)
  local out, seen = {}, {}
  for _, edge in ipairs(graph.edges) do
    local other = edge.from == id and edge.to or edge.to == id and edge.from or nil
    if other and not seen[other] then
      seen[other] = true
      out[#out + 1] = other
    end
  end
  return out
end

local function landed(graph, id)
  local node = graph.nodes[id]
  return node and node.claim and node.claim.status == "approved"
end

-- Who waits on whom now: a needs edge on a claim that hasn't landed, a vote owed, a merge bid.
local function waits(graph)
  local out = {}
  local function wait(from, to)
    out[from] = out[from] or {}
    out[from][to] = true
  end
  for _, edge in ipairs(graph.edges) do
    if edge.type == "needs" and not landed(graph, edge.to) then
      wait(edge.from, edge.to)
    end
  end
  for _, d in ipairs(graph.decisions) do
    if d.status == "open" then
      for _, voter in ipairs(d.voters) do
        if not d.votes[voter] then
          wait(d.by, voter)
        end
      end
    end
  end
  for _, bid in ipairs(graph.bids) do
    wait(bid.from, bid.to)
  end
  return out
end

-- The agents on the cycle that from waiting on to would close, from first; nil if none would.
local function cycle(graph, from, to)
  local adjacent, seen = waits(graph), {}
  local function walk(id, trail)
    if id == from then
      return trail
    end
    if seen[id] then
      return nil
    end
    seen[id] = true
    for after in pairs(adjacent[id] or {}) do
      local found = walk(after, after == from and trail or vim.list_extend(vim.list_slice(trail), { after }))
      if found then
        return found
      end
    end
  end
  return walk(to, { from, to })
end

-- Refuses from's move that would close members: the others hear, and it yields after two turns each.
local function deadlock(graph, members, from, what)
  local turns = {}
  for _, id in ipairs(members) do
    turns[id] = turns_of(id)
  end
  graph.deadlocks[#graph.deadlocks + 1] = { members = members, last = from, what = what, turns = turns }
  local names = table.concat(vim.tbl_map(agent, members), " → ")
  for _, id in ipairs(members) do
    if id ~= from then
      tell(id, ("%s is deadlocked with you: %s. Reason it out with them now; if you haven't after two turns each, %s yields."):format(
        agent(from), names, agent(from)), "◉ deadlock")
    end
  end
  return ("refused: that closes a deadlock (%s). Reason it out with them (ica msg); if you haven't after two turns each, you yield."):format(names)
end

local function caps(slug)
  local task = tasks.read(slug)
  local attrs = task and task.attrs or {}
  return tonumber(attrs.max_nodes) or MAX_NODES, tonumber(attrs.max_edges) or MAX_EDGES
end

-- Why from can't wire an edge of kind to to, if it can't.
local function refuse_edge(slug, graph, kind, from, to)
  local _, cap = caps(slug)
  if from == to then
    return "that's you"
  elseif not vim.tbl_contains({ "reviews", "needs", "contests", "talks" }, kind) then
    return "no edge type " .. tostring(kind) .. ": reviews, needs, contests or talks"
  elseif not vim.tbl_contains(live(graph), to) then
    return ("no agent %s on this task (ica agents lists them)"):format(to)
  elseif edge_of(graph, kind, from, to) then
    return ("you already have %s with %s"):format(kind, agent(to))
  elseif outgoing(graph, from) >= cap then
    return ("you're at the cap of %d edges: unedge one, merge or retire first"):format(cap)
  end
  if kind == "needs" then
    local members = cycle(graph, from, to)
    if members then
      return deadlock(graph, members, from, "needs " .. agent(to))
    end
  end
end

-- Whether unwiring edge would leave a claim with no way to the user.
local function last_review(graph, edge)
  local node = graph.nodes[edge.to]
  return edge.type == "reviews" and node and node.claim and not node.claim.trivial and #reviewers(graph, edge.to) <= 1
end

local function drop_edge(graph, target)
  graph.edges = vim.tbl_filter(function(edge)
    return edge ~= target
  end, graph.edges)
end

local function next_id(graph, prefix)
  local key = prefix == "C" and "claims_made" or "decisions_made"
  graph[key] = (graph[key] or 0) + 1
  return prefix .. graph[key]
end

local function find_decision(graph, id)
  id = (id or ""):upper()
  for _, d in ipairs(graph.decisions) do
    if d.id == id then
      return d
    end
  end
end

-- Everyone on the task hears how a decision came out.
local function announce(graph, d)
  local text = ({
    agreed = ("decision %s is agreed: %s"):format(d.id, d.text),
    disputed = ("decision %s is disputed and has gone to the user. Wait for their call before acting on it."):format(d.id),
    decided = ("the user made the call on decision %s: %s"):format(d.id, d.call or ""),
    withdrawn = ("decision %s was withdrawn by %s."):format(d.id, agent(d.by)),
  })[d.status]
  for _, id in ipairs(live(graph)) do
    tell(id, text, ("◉ %s %s"):format(d.id, d.status))
  end
end

local function send_for_votes(d)
  for _, voter in ipairs(d.voters) do
    tell(voter, ("%s proposes decision %s:\n\n%s\n\nYou must answer: `ica vote agree %s`, or `ica vote object %s <why, in a line>`."):format(
      agent(d.by), d.id, d.text, d.id, d.id), ("◉ %s from %s"):format(d.id, agent(d.by)))
  end
  d.reminded = os.time()
end

-- Its claim landed: whoever needs it hears.
local function land(graph, id)
  local claim = graph.nodes[id].claim
  claim.status = "approved"
  tell(id, ("your claim is approved and has reached the user: %s. Next: claim related work if there is any, or `ica retire`."):format(claim.what))
  for _, edge in ipairs(graph.edges) do
    if edge.type == "needs" and edge.to == id then
      tell(edge.from, ("%s landed: %s"):format(agent(id), claim.what))
    end
  end
end

-- id leaves the graph: its edges go to whoever needed it, and its session stops once its turn ends.
local function retire(graph, id)
  local needers, onward = {}, {}
  for _, edge in ipairs(graph.edges) do
    if edge.type == "needs" and edge.to == id then
      needers[#needers + 1] = edge.from
    elseif edge.from == id and edge.type ~= "talks" and edge.type ~= "contests" then
      onward[#onward + 1] = edge
    end
  end
  for _, needer in ipairs(needers) do
    for _, edge in ipairs(onward) do
      if edge.to ~= needer and not edge_of(graph, edge.type, needer, edge.to) then
        new_edge(graph, edge.type, needer, edge.to)
      end
    end
  end
  graph.edges = vim.tbl_filter(function(edge)
    return edge.from ~= id and edge.to ~= id
  end, graph.edges)
  graph.bids = vim.tbl_filter(function(bid)
    return bid.from ~= id and bid.to ~= id
  end, graph.bids)
  for _, d in ipairs(graph.decisions) do
    d.voters = vim.tbl_filter(function(voter)
      return voter ~= id
    end, d.voters or {})
  end
  graph.nodes[id] = nil
  local record = chats.get(id)
  if record then
    record.retired = true
    chats.save(record)
  end
  require("icarus.watch").release(id)
  state.leaving = state.leaving or {}
  state.leaving[id] = true
end

-- child folds into parent: what's its goes there, and it retires.
local function fold(graph, child, parent, handoff)
  local mine, theirs = graph.nodes[child].claim, graph.nodes[parent].claim
  if mine and mine.status ~= "approved" then
    if theirs and theirs.status ~= "approved" then
      theirs.what = theirs.what .. " + " .. mine.what
    else
      graph.nodes[parent].claim = mine
    end
  end
  for _, edge in ipairs(vim.list_slice(graph.edges)) do
    local from = edge.from == child and parent or edge.from
    local to = edge.to == child and parent or edge.to
    if from ~= to and (edge.from == child or edge.to == child) and not edge_of(graph, edge.type, from, to) then
      new_edge(graph, edge.type, from, to)
    end
  end
  for _, d in ipairs(graph.decisions) do
    d.by = d.by == child and parent or d.by
  end
  require("icarus.watch").reassign(child, parent)
  retire(graph, child)
  tell(parent, ("%s merged into you. Its claims and comment threads are yours now. Its handoff:\n\n%s"):format(agent(child), handoff),
    ("◉ %s merged in"):format(agent(child)))
end

-- Arguments after the first few, as one text.
local function rest(argv, from)
  return table.concat(vim.list_slice(argv, from), " ")
end

-- The agent an argument names.
local function who(argv, at)
  return ((argv[at] or ""):gsub("^icarus://agent/", ""))
end

local handlers = {}

function handlers.claim(me, _, graph, argv)
  local trivial = argv[1] == "--trivial"
  local what = rest(argv, trivial and 2 or 1)
  if what == "" then
    return false, "usage: ica claim [--trivial] <what>"
  end
  local node = graph.nodes[me]
  if node.claim and node.claim.status ~= "approved" then
    return false, ("you already hold %s (%s): one claim at a time. ica done, or ica unclaim"):format(node.claim.id, node.claim.what)
  end
  local others = {}
  for _, id in ipairs(live(graph)) do
    local claim = graph.nodes[id].claim
    if id ~= me and claim then
      others[#others + 1] = ("%s %s (%s): %s"):format(claim.id, agent(id), claim.status, claim.what)
    end
  end
  node.claim = { id = next_id(graph, "C"), what = what, status = "open", trivial = trivial or nil, approvals = {} }
  return true, ("claimed %s: %s%s"):format(node.claim.id, what, #others > 0
    and ("\nthe others' (if one overlaps yours, sort it out with its agent, or ica merge):\n" .. table.concat(others, "\n")) or "")
end

function handlers.claims(me, _, graph)
  local lines = {}
  for _, id in ipairs(live(graph)) do
    local claim = graph.nodes[id].claim
    if claim then
      lines[#lines + 1] = ("%s %s%s, %s%s: %s"):format(claim.id, agent(id), id == me and " (you)" or "", claim.status,
        claim.trivial and ", trivial" or "", claim.what)
    end
  end
  return true, #lines > 0 and table.concat(lines, "\n") or "nothing claimed"
end

function handlers.unclaim(me, _, graph)
  local claim = graph.nodes[me].claim
  if not claim then
    return false, "you hold no claim"
  end
  graph.nodes[me].claim = nil
  return true, "gave up " .. claim.id
end

function handlers.done(me, _, graph)
  local claim = graph.nodes[me].claim
  if not claim or claim.status ~= "open" then
    return false, claim and (claim.id .. " is already " .. claim.status) or "you hold no claim"
  end
  if claim.trivial then
    land(graph, me)
    return true, claim.id .. " is trivial, so it's reached the user"
  end
  local names = reviewers(graph, me)
  if #names == 0 then
    return false, ("%s has no reviewer, and only a reviewer's approval takes it to the user. Get one (they run `ica edge reviews %s`; or ica spawn skeptic), or claim it --trivial"):format(claim.id, me)
  end
  claim.status, claim.approvals = "review", {}
  for _, id in ipairs(names) do
    tell(id, ("%s says its claim is done: %s. Review it, then `ica approve %s`, or `ica reject %s <why>`."):format(agent(me), claim.what, me, me))
  end
  return true, ("%s went to %d reviewer(s)"):format(claim.id, #names)
end

function handlers.approve(me, _, graph, argv)
  local target = who(argv, 1)
  local node = graph.nodes[target]
  if not edge_of(graph, "reviews", me, target) then
    return false, ("you don't review %s"):format(target)
  elseif not (node and node.claim and node.claim.status == "review") then
    return false, ("%s has nothing in review"):format(agent(target))
  end
  node.claim.approvals[me] = true
  for _, id in ipairs(reviewers(graph, target)) do
    if not node.claim.approvals[id] then
      return true, ("approved; %s still has to"):format(agent(id))
    end
  end
  land(graph, target)
  return true, "approved: it's reached the user"
end

function handlers.reject(me, _, graph, argv)
  local target, why = who(argv, 1), rest(argv, 2)
  local node = graph.nodes[target]
  if why == "" then
    return false, "usage: ica reject <agent> <why>"
  elseif not edge_of(graph, "reviews", me, target) or not (node and node.claim and node.claim.status == "review") then
    return false, ("you don't have %s in review"):format(target)
  end
  node.claim.status = "open"
  tell(target, ("%s rejected your claim: %s. Fix it and `ica done` again."):format(agent(me), why))
  return true, "sent back to " .. agent(target)
end

function handlers.spawn(me, slug, graph, argv)
  local job = rest(argv, 1)
  if job == "" then
    return false, "usage: ica spawn <job|specialty>"
  end
  local nodes, edges = caps(slug)
  if #live(graph) >= nodes then
    return false, ("you're at the cap of %d agents: merge or retire first"):format(nodes)
  elseif outgoing(graph, me) >= edges then
    return false, ("you're at the cap of %d edges, and a spawn adds one: unedge one, merge or retire first"):format(edges)
  end
  local ok, out = require("icarus.watch").fork({ chat = me, text = M.SPECIALTIES[job] or job })
  if not ok then
    return false, out
  end
  local id = (out:gsub("^icarus://agent/", ""))
  graph.nodes[id] = { specialty = M.SPECIALTIES[job] and job or nil }
  new_edge(graph, "needs", me, id)
  local record = chats.get(id)
  if record then
    record.parent = false
    chats.save(record)
  end
  return true, out .. " (you need it: it tells you when it lands)"
end

function handlers.edge(me, slug, graph, argv)
  if argv[1] == "--keep" or argv[1] == "--drop" then
    local kind, other = argv[2] or "", who(argv, 3)
    local edge = edge_of(graph, kind, me, other) or edge_of(graph, kind, other, me)
    if not (edge and edge.probe) then
      return false, "no question open on that edge"
    end
    edge.probe[me] = argv[1]
    if edge.probe[edge.from] == "--drop" and edge.probe[edge.to] == "--drop" then
      drop_edge(graph, edge)
      return true, "dropped"
    elseif argv[1] == "--keep" then
      edge.probe, edge.used, edge.turns = nil, os.time(), { [edge.from] = turns_of(edge.from), [edge.to] = turns_of(edge.to) }
      return true, "kept"
    end
    return true, "noted: it's dropped if the other agrees"
  end
  local kind, target = argv[1], who(argv, 2)
  local why = refuse_edge(slug, graph, kind, me, target)
  if why then
    return false, why
  end
  new_edge(graph, kind, me, target)
  tell(target, ("%s wired %s to you."):format(agent(me), kind))
  return true, ("%s %s"):format(kind, agent(target))
end

function handlers.unedge(me, _, graph, argv)
  local kind, target = argv[1] or "", who(argv, 2)
  local edge = edge_of(graph, kind, me, target) or edge_of(graph, kind, target, me)
  if not edge then
    return false, ("no %s edge with %s"):format(kind, target)
  elseif last_review(graph, edge) then
    return false, ("that's %s's only way to the user: wire another reviewer first"):format(agent(edge.to))
  end
  drop_edge(graph, edge)
  return true, "unwired"
end

function handlers.topology(_, slug, graph, argv)
  local kind, nodes, wanted = argv[1], live(graph), {}
  if kind == "ring" and #nodes >= 2 then
    for i, id in ipairs(nodes) do
      wanted[#wanted + 1] = { "reviews", id, nodes[i % #nodes + 1] }
    end
  elseif kind == "debate" and #nodes == 3 then
    wanted = { { "contests", nodes[1], nodes[2] }, { "reviews", nodes[3], nodes[1] }, { "reviews", nodes[3], nodes[2] } }
  elseif kind == "mesh" and #nodes >= 2 and #nodes <= 4 then
    for _, a in ipairs(nodes) do
      for _, b in ipairs(nodes) do
        if a ~= b then
          wanted[#wanted + 1] = { "reviews", a, b }
        end
      end
    end
  else
    return false, ("can't make a %s of %d agents: ring takes 2 or more, debate exactly 3, mesh 2 to 4"):format(tostring(kind), #nodes)
  end
  for _, each in ipairs(wanted) do
    if not edge_of(graph, each[1], each[2], each[3]) then
      local why = refuse_edge(slug, graph, each[1], each[2], each[3])
      if why then
        return false, why
      end
      new_edge(graph, each[1], each[2], each[3])
    end
  end
  for _, id in ipairs(nodes) do
    tell(id, ("the task's agents are wired as a %s; ica agents shows your edges."):format(kind))
  end
  return true, ("wired a %s of %d"):format(kind, #nodes)
end

function handlers.merge(me, _, graph, argv)
  local answer = argv[1] == "--accept" or argv[1] == "--decline"
  local other = who(argv, answer and 2 or 1)
  if answer then
    local bid
    for _, each in ipairs(graph.bids) do
      if each.from == other and each.to == me then
        bid = each
      end
    end
    if not bid then
      return false, ("%s has no bid on you"):format(agent(other))
    end
    local text = rest(argv, 3)
    if text == "" then
      return false, ("usage: ica merge %s <agent> <%s>"):format(argv[1], argv[1] == "--accept" and "handoff" or "why")
    end
    graph.bids = vim.tbl_filter(function(each)
      return each ~= bid
    end, graph.bids)
    if argv[1] == "--decline" then
      tell(other, ("%s declined your merge: %s"):format(agent(me), text))
      return true, "declined"
    end
    fold(graph, me, other, text)
    return true, ("you're merged into %s: your session ends with this turn"):format(agent(other))
  end
  if not vim.tbl_contains(live(graph), other) or other == me then
    return false, ("no other agent %s (ica agents lists them)"):format(other)
  end
  local members = cycle(graph, me, other)
  if members then
    local why = deadlock(graph, members, me, "merging " .. agent(other))
    graph.deadlocks[#graph.deadlocks].accept = other
    return false, why
  end
  graph.bids[#graph.bids + 1] = { from = me, to = other, at = os.time() }
  tell(other, ("%s bids to absorb you: it believes it's the parent and you're the child. Talk it out with `ica msg`. If you agree, `ica merge --accept %s <handoff>` ends you with your work handed over; if not, `ica merge --decline %s <why>`, and bid for it yourself if you think it's the other way round."):format(
    agent(me), me, me), "◉ merge bid")
  return true, "bid sent to " .. agent(other)
end

function handlers.retire(me, _, graph)
  local claim = graph.nodes[me].claim
  if claim and claim.status ~= "approved" then
    return false, ("%s hasn't reached the user: ica done first, or ica unclaim"):format(claim.id)
  end
  retire(graph, me)
  return true, "you've left the graph: your session ends with this turn"
end

function handlers.post(me, slug, _, argv)
  local text = rest(argv, 1)
  if text == "" then
    return false, "usage: ica post <text>"
  end
  local file = assert(io.open(path(slug, "channel.jsonl"), "a"))
  file:write(vim.json.encode({ by = me, at = os.time(), text = text }) .. "\n")
  file:close()
  return true, "posted"
end

function handlers.read(me, slug, graph)
  local file = path(slug, "channel.jsonl")
  local lines = vim.fn.filereadable(file) == 1 and vim.fn.readfile(file) or {}
  local out = {}
  for i = (graph.cursors[me] or 0) + 1, #lines do
    local ok, post = pcall(vim.json.decode, lines[i])
    if ok then
      out[#out + 1] = ("%s%s: %s"):format(os.date("%H:%M ", post.at), post.by == me and "you" or agent(post.by), post.text)
    end
  end
  graph.cursors[me] = #lines
  return true, #out > 0 and table.concat(out, "\n") or "nothing new"
end

handlers["propose-to-peers"] = function(me, _, graph, argv)
  local text = rest(argv, 1)
  if text == "" then
    return false, "usage: ica propose-to-peers <what>"
  end
  local voters = neighbors(graph, me)
  if #voters == 0 then
    voters = vim.tbl_filter(function(id)
      return id ~= me
    end, live(graph))
  end
  for _, voter in ipairs(voters) do
    local members = cycle(graph, me, voter)
    if members then
      return false, deadlock(graph, members, me, "a vote from " .. agent(voter))
    end
  end
  local d = { id = next_id(graph, "D"), by = me, text = text, at = os.time(), status = "open", voters = voters, votes = {}, objections = {} }
  graph.decisions[#graph.decisions + 1] = d
  if #voters == 0 then
    d.status = "agreed"
    return true, d.id .. " is agreed: you've no peers to ask"
  end
  send_for_votes(d)
  return true, ("proposed %s to %d peer(s); each must answer, and you'll hear how it comes out"):format(d.id, #voters)
end

function handlers.vote(me, _, graph, argv)
  local kind, d = argv[1], find_decision(graph, argv[2])
  if not d then
    return false, ("no decision %s (ica decisions lists them)"):format(tostring(argv[2]))
  elseif d.status ~= "open" then
    return false, ("%s is %s"):format(d.id, d.status)
  elseif not vim.tbl_contains(d.voters, me) then
    return false, ("you don't vote on %s"):format(d.id)
  end
  if kind == "object" then
    local why = rest(argv, 3)
    if why == "" then
      return false, "usage: ica vote object <id> <why, in a line>"
    end
    table.insert(d.objections, { by = me, why = why })
    if d.revised then
      d.status = "disputed"
      announce(graph, d)
    else
      d.status = "revising"
      tell(d.by, ("%s objects to %s: %s\nRevise it once: `ica revise %s <new text>`, or `ica withdraw %s`."):format(agent(me), d.id, why, d.id, d.id))
    end
    return true, ("%s: %s"):format(d.id, d.status)
  elseif kind ~= "agree" then
    return false, "usage: ica vote agree <id> | ica vote object <id> <why>"
  end
  d.votes[me] = "agree"
  for _, voter in ipairs(d.voters) do
    if not d.votes[voter] then
      return true, d.id .. ": noted"
    end
  end
  d.status = "agreed"
  announce(graph, d)
  return true, d.id .. ": agreed"
end

function handlers.revise(me, _, graph, argv)
  local d, text = find_decision(graph, argv[1]), rest(argv, 2)
  if not d or d.by ~= me or d.status ~= "revising" or text == "" then
    return false, "usage: ica revise <id of your objected decision> <new text>"
  end
  d.text, d.status, d.votes, d.revised = text, "open", {}, true
  send_for_votes(d)
  return true, d.id .. " went back to your peers; another objection sends it to the user"
end

function handlers.withdraw(me, _, graph, argv)
  local d = find_decision(graph, argv[1])
  if not d or d.by ~= me or (d.status ~= "open" and d.status ~= "revising") then
    return false, ("no open decision %s of yours"):format(tostring(argv[1]))
  end
  d.status = "withdrawn"
  announce(graph, d)
  return true, d.id .. " withdrawn"
end

function handlers.decisions(_, _, graph)
  local lines = {}
  for _, d in ipairs(graph.decisions) do
    lines[#lines + 1] = ("%s %s, by %s: %s%s"):format(d.id, d.status, agent(d.by), (d.text:gsub("\n", " ")):sub(1, 140),
      d.call and (" — the user's call: " .. d.call) or "")
  end
  return true, #lines > 0 and table.concat(lines, "\n") or "no decisions yet"
end

-- What ica asks of the graph (icarus.watch's remote).
---@return boolean ok, string result, boolean here
function M.remote(cmd, args)
  local chat = args.chat and open_chat(args.chat)
  if not chat then
    return false, "chat " .. tostring(args.chat) .. " isn't open in this icarus", false
  end
  local slug = chat.record.task
  local task = slug and tasks.read(slug)
  if not task or task.sentinel then
    return false, "you're not on a task", true
  end
  local style = require("icarus.orchestration").style(task)
  if style ~= "democracy" then
    return false, ("ica %s is for a democracy; this task is %s"):format(cmd, style), true
  end
  local graph = load(slug)
  local ok, out = handlers[cmd](args.chat, slug, graph, args.argv or {})
  save(slug, graph)
  state.slugs = state.slugs or {}
  state.slugs[slug] = true
  M.start()
  return ok, out, true
end

-- An agent's specialty, claim and edges, for ica agents and the graph.
function M.describe(slug, id)
  local graph = load(slug)
  local node = graph.nodes[id]
  if not node then
    return nil
  end
  local parts = {}
  if node.specialty then
    parts[#parts + 1] = node.specialty
  end
  if node.claim then
    parts[#parts + 1] = ("%s %s: %s"):format(node.claim.id, node.claim.status, node.claim.what)
  end
  for _, edge in ipairs(graph.edges) do
    if edge.from == id then
      parts[#parts + 1] = ("%s → %s"):format(edge.type, agent(edge.to))
    elseif edge.to == id and (edge.type == "contests" or edge.type == "talks") then
      parts[#parts + 1] = ("%s ↔ %s"):format(edge.type, agent(edge.from))
    elseif edge.to == id then
      parts[#parts + 1] = ("%s by %s"):format(edge.type == "reviews" and "reviewed" or "needed", agent(edge.from))
    end
  end
  return parts
end

-- Why from can't message to, if it can't: agents talk along edges, or where icarus set them to talking
-- (a merge bid, a vote, a deadlock).
function M.refuse_message(slug, from, to)
  local task = tasks.read(slug)
  if not task or require("icarus.orchestration").style(task) ~= "democracy" then
    return nil
  end
  local graph = load(slug)
  for _, edge in ipairs(graph.edges) do
    if (edge.from == from and edge.to == to) or (edge.from == to and edge.to == from) then
      return nil
    end
  end
  for _, bid in ipairs(graph.bids) do
    if (bid.from == from and bid.to == to) or (bid.from == to and bid.to == from) then
      return nil
    end
  end
  for _, d in ipairs(graph.decisions) do
    local voter = vim.tbl_contains(d.voters or {}, from) and to == d.by or vim.tbl_contains(d.voters or {}, to) and from == d.by
    if voter and (d.status == "open" or d.status == "revising") then
      return nil
    end
  end
  for _, each in ipairs(graph.deadlocks) do
    if vim.tbl_contains(each.members, from) and vim.tbl_contains(each.members, to) then
      return nil
    end
  end
  return ("you've no edge with %s: wire one first, with ica edge reviews|needs|contests|talks %s"):format(agent(to), to)
end

-- from messaged to: their edge counts as used.
function M.messaged(slug, from, to)
  local task = tasks.read(slug)
  if not task or require("icarus.orchestration").style(task) ~= "democracy" then
    return
  end
  local graph = load(slug)
  for _, edge in ipairs(graph.edges) do
    if (edge.from == from and edge.to == to) or (edge.from == to and edge.to == from) then
      edge.used, edge.turns, edge.probe = os.time(), { [edge.from] = turns_of(edge.from), [edge.to] = turns_of(edge.to) }, nil
    end
  end
  save(slug, graph)
end

-- A task's agents become a graph: their jobs, by their titles, become claims.
function M.seed(slug)
  local graph = load(slug)
  for _, id in ipairs(live(graph)) do
    local node, record = graph.nodes[id], chats.get(id)
    if not node.claim and record.title then
      node.claim = { id = next_id(graph, "C"), what = (record.title:gsub("^⑂ ", "")), status = "open", approvals = {} }
    end
  end
  save(slug, graph)
  state.slugs = state.slugs or {}
  state.slugs[slug] = true
  M.start()
end

local function tick_one(slug)
  local graph = load(slug)
  local now = os.time()
  -- Deadlocks whose two turns are up: the last to join yields.
  local here = live(graph)
  graph.deadlocks = vim.tbl_filter(function(each)
    for _, id in ipairs(each.members) do
      if not vim.tbl_contains(here, id) then
        return false
      end
      if turns_of(id) < (each.turns[id] or 0) + 2 then
        return true
      end
    end
    tell(each.last, ("your deadlock with %s has had its two turns, so you yield: give up on %s and go with what the others decided.%s"):format(
      table.concat(vim.tbl_map(agent, each.members), ", "), each.what,
      each.accept and (" You're the child: `ica merge --accept %s <handoff>`."):format(each.accept) or ""), "◉ you yield")
    return false
  end, graph.deadlocks)
  for _, edge in ipairs(graph.edges) do
    -- Unused edges are put to their ends.
    local idle = now - (edge.used or now) >= PROBE_SECONDS or turns_of(edge.from) - (edge.turns[edge.from] or 0) >= PROBE_TURNS
      or turns_of(edge.to) - (edge.turns[edge.to] or 0) >= PROBE_TURNS
    if idle and not edge.probe and not last_review(graph, edge) then
      edge.probe = { at = now }
      for _, pair in ipairs({ { edge.from, edge.to }, { edge.to, edge.from } }) do
        tell(pair[1], ("your %s edge with %s hasn't been used in a while. Still needed? `ica edge --keep %s %s`, or `ica edge --drop %s %s`."):format(
          edge.type, agent(pair[2]), edge.type, pair[2], edge.type, pair[2]), "◉ edge unused")
      end
    end
    -- Blocked on a claim that hasn't landed.
    if edge.type == "needs" and not landed(graph, edge.to) and now - (edge.nudged or edge.at) >= NUDGE_SECONDS then
      edge.nudged = now
      tell(edge.from, ("you've been waiting on %s a while. Spawn help (ica spawn), or merge with it (ica merge)."):format(agent(edge.to)), "◉ blocked")
    end
  end
  -- Votes still owed; one whose last voter retired is settled.
  for _, d in ipairs(graph.decisions) do
    local owed = d.status == "open" and vim.tbl_filter(function(voter)
      return not d.votes[voter]
    end, d.voters) or {}
    if d.status == "open" and #owed == 0 then
      d.status = "agreed"
      announce(graph, d)
    elseif #owed > 0 and now - (d.reminded or d.at) >= REMIND_SECONDS then
      d.reminded = now
      for _, voter in ipairs(owed) do
        tell(voter, ("you owe a vote on %s: `ica vote agree %s`, or `ica vote object %s <why>`."):format(d.id, d.id, d.id), "◉ vote owed")
      end
    end
  end
  save(slug, graph)
end

function M.tick()
  for id in pairs(state.leaving or {}) do
    local chat = open_chat(id)
    if not (chat and chat.busy) then
      state.leaving[id] = nil
      if chat then
        require("icarus.acp.chat").stop(id)
      end
    end
  end
  for slug in pairs(state.slugs or {}) do
    local task = tasks.read(slug)
    if task and require("icarus.orchestration").style(task) == "democracy" then
      pcall(tick_one, slug)
    else
      state.slugs[slug] = nil
    end
  end
end

-- The ticker, once.
function M.start()
  if not state.ticker then
    state.ticker = assert(vim.uv.new_timer())
    state.ticker:start(TICK_MS, TICK_MS, vim.schedule_wrap(function()
      require("icarus.democracy").tick()
    end))
  end
end

-- The tasks already democracies, as icarus starts.
function M.resume()
  state.slugs = state.slugs or {}
  for _, task in ipairs(tasks.list()) do
    if require("icarus.orchestration").style(task) == "democracy" then
      state.slugs[task.slug] = true
      M.start()
    end
  end
end

-- What the user reads and does (icarus.inbox, icarus.graph).

function M.graph(slug)
  return load(slug)
end

function M.disputed(slug)
  return vim.tbl_filter(function(d)
    return d.status == "disputed"
  end, load(slug).decisions)
end

-- The claims that have reached the user: {id, claim, against} (the agents contesting it).
function M.landed(slug)
  local graph, out = load(slug), {}
  for _, id in ipairs(live(graph)) do
    if landed(graph, id) then
      local against = {}
      for _, edge in ipairs(graph.edges) do
        if edge.type == "contests" and (edge.from == id or edge.to == id) then
          against[#against + 1] = edge.from == id and edge.to or edge.from
        end
      end
      out[#out + 1] = { id = id, claim = graph.nodes[id].claim, against = against }
    end
  end
  return out
end

-- The user's call on a disputed decision.
function M.call(slug, id, call)
  local graph = load(slug)
  local d = find_decision(graph, id)
  if d and d.status == "disputed" then
    d.status, d.call = "decided", call
    announce(graph, d)
    save(slug, graph)
  end
end

function M.ask(slug, id)
  local d = find_decision(load(slug), id)
  if not d then
    return
  end
  local sides = { ("%s (%s): %s"):format(d.id, agent(d.by), (d.text:gsub("\n", " "))) }
  for _, o in ipairs(d.objections or {}) do
    sides[#sides + 1] = ("  against, %s: %s"):format(agent(o.by), o.why)
  end
  vim.ui.input({ prompt = table.concat(sides, "\n") .. "\nYour call: " }, function(call)
    if call and vim.trim(call) ~= "" then
      M.call(slug, id, vim.trim(call))
    end
  end)
end

function M.user_edge(slug, kind, from, to)
  local graph = load(slug)
  if from ~= to and not edge_of(graph, kind, from, to) then
    new_edge(graph, kind, from, to)
    tell(from, ("the user wired %s from you to %s."):format(kind, agent(to)))
    tell(to, ("the user wired %s from %s to you."):format(kind, agent(from)))
    save(slug, graph)
  end
end

function M.user_unedge(slug, edge)
  local graph = load(slug)
  local found = edge_of(graph, edge.type, edge.from, edge.to)
  if found then
    drop_edge(graph, found)
    tell(edge.from, ("the user removed your %s edge with %s."):format(edge.type, agent(edge.to)))
    tell(edge.to, ("the user removed the %s edge from %s."):format(edge.type, agent(edge.from)))
    save(slug, graph)
  end
end

-- The user merges child into parent: no talking it out, it just hands over.
function M.user_merge(slug, parent, child)
  local graph = load(slug)
  graph.bids[#graph.bids + 1] = { from = parent, to = child, at = os.time() }
  tell(child, ("the user is merging you into %s. Run `ica merge --accept %s <handoff>` now."):format(agent(parent), parent), "◉ merge")
  save(slug, graph)
end

return M
