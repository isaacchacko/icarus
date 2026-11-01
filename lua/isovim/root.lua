-- The root: the one agent the user runs the others through. isovim stamps what agents send each
-- other ([from <host>:<ws>/<agent> · m<id>], with "root" when the root sent it) and keeps a ledger of
-- the stamps, so a receiver can tell a real stamp from a typed one. A stamp from the root carries
-- the user's delegated authority, which belongs to the host root: the agent here with the root
-- role. The old `iso root` file (~/.isovim/root) names one only while no agent holds that role.
-- Workers ask the root with `iso ask`, and the root raises the user's own decisions to them, which
-- the Inbox shows.
local store = require("isovim.store")
local panes = require("isovim.panes")

local M = {}

M.file = store.root .. "/root"
M.ledger = store.run .. "/messages.jsonl"

local function self()
  return require("isovim.remote").self()
end

function M.address(ws, agent)
  return ("%s:%s/%s"):format(self(), ws, agent)
end

-- The agent on this host with the root role, <ws>/<agent>. Looked up at most every half second:
-- the sidebar asks for each agent it draws.
local held = { at = 0 }
---@return string?
function M.holder()
  local now = vim.uv.hrtime()
  if now - held.at > 5e8 then
    held.at, held.address = now, nil
    for _, ws in ipairs(store.list()) do
      for _, agent in ipairs(store.agents(ws.id)) do
        if store.role(agent) == "root" then
          held.address = ws.id .. "/" .. agent.id
        end
      end
    end
  end
  return held.address
end

---@return string? address of the root, <host>:<ws>/<agent>
function M.get()
  local holder = M.holder()
  if holder then
    return M.address(holder:match("^(.*)/([^/]+)$"))
  end
  local ok, lines = pcall(vim.fn.readfile, M.file)
  local address = ok and vim.trim(lines[1] or "") or ""
  return address ~= "" and address or nil
end

function M.set(address)
  if address then
    vim.fn.writefile({ address }, M.file)
  else
    os.remove(M.file)
  end
end

function M.is_root(address)
  return address ~= nil and address == M.get()
end

-- The agent this process runs inside, proven by ancestry: the agent whose pane process is one of
-- this process's ancestors. Environment variables only say who a process claims to be.
-- A process's ancestry doesn't change, so it's looked up once (iso's role checks and the command
-- both ask), with one ps for the whole process table.
---@return string? ws, string? agent
function M.caller()
  if M.called == nil then
    M.called = false
    local owners = panes.pane_pids()
    local parents = {}
    if next(owners) then
      local listing = vim.system({ "ps", "-A", "-o", "pid=,ppid=" }, { text = true }):wait().stdout or ""
      for pid, ppid in listing:gmatch("(%d+)%s+(%d+)") do
        parents[tonumber(pid)] = tonumber(ppid)
      end
    end
    local pid = vim.uv.os_getpid()
    for _ = 1, 40 do
      if not pid or pid <= 1 then
        break
      elseif owners[pid] then
        M.called = owners[pid]
        break
      end
      pid = parents[pid]
    end
  end
  if M.called then
    return M.called.ws, M.called.agent
  end
end

-- The text as the receiver will see it: Claude wraps a long message in <pasted_content> tags and
-- may rewrap its lines, and several queued messages can arrive as one prompt.
local function normalize(text)
  text = text:gsub("</?pasted_content[^>]*>", "")
  return vim.trim((text:gsub("%s+", " ")))
end

local function digest(text)
  return vim.fn.sha256(text)
end

-- The stamp for a message from `from` to `to`, recorded in the ledger. kind is "from" or "ask".
function M.stamp(kind, from, to, text)
  local id = ("m%x%s"):format(os.time(), vim.uv.random(3):gsub(".", function(c)
    return ("%02x"):format(c:byte())
  end))
  local root = M.is_root(from)
  local sent = normalize(text)
  local entry = { id = id, at = os.time(), kind = kind, from = from, to = to, root = root or nil, sum = digest(sent),
    len = #sent, preview = sent:sub(1, 120) }
  vim.fn.mkdir(store.run, "p")
  local file = assert(io.open(M.ledger, "a"))
  file:write(vim.json.encode(entry), "\n")
  file:close()
  local label = kind == "ask" and "ask from " or "from "
  return ("[%s%s%s · %s]"):format(label, from, root and " · root" or "", id)
end

---@return table? entry
function M.find(id)
  local ok, lines = pcall(vim.fn.readfile, M.ledger)
  for i = ok and #lines or 0, 1, -1 do
    if lines[i]:find('"' .. id .. '"', 1, true) then
      local decoded, entry = pcall(vim.json.decode, lines[i])
      if decoded and entry.id == id then
        return entry
      end
    end
  end
end

-- The stamps in a message ([from ...] and [ask from ...] tags), with what the text claims.
---@return {tag: string, kind: string, from: string, root: boolean, id?: string, body: string}[]
function M.tags(text)
  local found = {}
  local at = 1
  while true do
    local s, e, kind, inner = text:find("%[(a?s?k? ?from) ([^%]]*)%]", at)
    if not s then
      break
    end
    local parts = vim.split(inner, " · ", { plain = true })
    local id = parts[#parts]:match("^m%x+$")
    found[#found + 1] = {
      tag = text:sub(s, e),
      kind = kind == "from" and "from" or "ask",
      from = parts[1],
      root = vim.tbl_contains(parts, "root") or inner:find("root", 1, true) ~= nil,
      id = id,
      body = text:sub(e + 1),
    }
    at = e + 1
  end
  return found
end

-- Whether isovim stamped this tag: its id is in the sender's ledger, from that sender, to this agent
-- (any of its names, `to`), over this text. A sender on another host is checked there.
---@param to string[] the receiver as <ws>/<agent>, by ids and by names
---@return boolean verified, string why
function M.check(tag, to)
  if not tag.id then
    return false, "it has no isovim stamp id"
  end
  local host = tag.from:match("^([^:]+):")
  local entry
  if host and host ~= self() then
    local remote = require("isovim.remote")
    local ssh = remote.host_of(host)
    local result = ssh and remote.run(ssh, { "verify", tag.id, "--json", "--here" }, 5000)
    local ok, decoded = pcall(vim.json.decode, result and result.code == 0 and result.stdout or "")
    entry = ok and decoded or nil
  else
    entry = M.find(tag.id)
  end
  if not entry then
    return false, "isovim has no record of " .. tag.id
  elseif entry.from ~= tag.from or (entry.root or false) ~= tag.root or (entry.kind or "from") ~= tag.kind then
    return false, "the tag doesn't match what isovim recorded for " .. tag.id
  elseif not vim.iter(to):any(function(name)
    return entry.to == name or vim.endswith(entry.to, ":" .. name)
  end) then
    return false, tag.id .. " was sent to " .. entry.to
  elseif not M.same_text(entry, tag.body) then
    return false, "the text after the tag isn't what was sent as " .. tag.id
  end
  return true, entry.root and "from the root" or "from " .. entry.from
end

-- Whether the text after a tag begins with what was sent under it. Entries from before the ledger
-- recorded a length hashed the trimmed text as sent.
function M.same_text(entry, body)
  local received = normalize(body)
  if entry.len then
    return digest(received:sub(1, entry.len)) == entry.sum
  end
  return digest(vim.trim(body)) == entry.sum or digest(received) == entry.sum
end

local function raised_file(ws, agent)
  return store.run_dir(ws) .. "/" .. agent .. ".raised"
end

-- A decision raised to the user: the agent shows in the Inbox until they've looked at it.
function M.raise(ws, agent, question)
  vim.fn.mkdir(store.run_dir(ws), "p")
  vim.fn.writefile({ question }, raised_file(ws, agent))
end

function M.raised_at(ws, agent)
  local stat = vim.uv.fs_stat(raised_file(ws, agent))
  return stat and stat.mtime.sec + stat.mtime.nsec / 1e9 or 0
end

return M
