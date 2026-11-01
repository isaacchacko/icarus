-- What an ACP agent's sessions are made of beyond one journal: where a conversation is cut for a
-- fork or a rewind, the journal a new session starts with, the sessions an agent has had (its
-- history picker), and the per-turn git snapshots that put an agent's files back when you rewind.
--
-- Cutting. A fork point is an agent message: claude-agent-acp stamps each agent_message_chunk with
-- the messageId of the message it belongs to, and session/fork takes one in
-- _meta.jetbrains.air.fork ({version = 1, messageId}), copying the session up to and including that
-- message. M.cut finds it in the journal from the seq of the entry you're on: on an agent's message,
-- that message (and the tool calls that came with it, up to its next message or prompt); on a
-- prompt, the agent message before it, so the prompt itself is left out. No message before it means
-- the cut is before anything the agent said: a new session, not a fork.
--
-- Journals. Every session the agent leaves (for /new, /clear, /resume, a rewind) has its journal
-- kept as iso/journal/aN.sessions/<session>.jsonl, which /resume puts back; a fork or a rewind starts
-- its journal with the entries up to the cut (M.carry), so the chat shows the history it kept.
--
-- Snapshots. Before each turn the supervisor snapshots the agent's worktree (M.snapshot): a commit
-- of every file git doesn't ignore, made with a separate index so the real index and HEAD are left
-- alone, kept under refs/isovim/snapshots/<agent>/<prompt id> so gc keeps it. A rewind puts the files
-- back as they were before the rewound prompt's turn (M.restore): files changed since are checked
-- out of the snapshot and files added since are deleted; ignored files are never touched.
local journal = require("isovim.acp.journal")
local store = require("isovim.store")

local M = {}

-- What a carried journal keeps: the conversation, not the queue or the session bookkeeping.
local CARRIED = { prompt = true, update = true, permission = true, question = true, notice = true, turn = true }

local function message_id(entry)
  local update = entry.kind == "update" and entry.update or nil
  if type(update) == "table" and update.sessionUpdate == "agent_message_chunk" and type(update.messageId) == "string"
    and update.messageId ~= "" then
    return update.messageId
  end
end

-- Where a conversation is cut, from the seq of the entry you're on.
---@param how "at"|"before" at: fork at that message; before: everything before it (a rewound prompt)
---@return {messageId?: string, upto: integer} cut messageId nil: a new session, not a fork
function M.cut(entries, seq, how)
  local target
  for _, entry in ipairs(entries) do
    if entry.seq == seq then
      target = entry
    end
  end
  local function before(limit)
    local id
    for _, entry in ipairs(entries) do
      if entry.seq < limit then
        id = message_id(entry) or id
      end
    end
    return { messageId = id, upto = limit - 1 }
  end
  if not target or how == "before" or target.kind == "prompt" then
    return before(seq)
  end
  -- The message is the first messageId from here on, before the next prompt.
  local id
  for _, entry in ipairs(entries) do
    if entry.seq >= seq then
      if entry.kind == "prompt" and entry.seq > seq then
        break
      end
      id = message_id(entry)
      if id then
        break
      end
    end
  end
  if not id then
    local cut = before(seq + 1)
    return { messageId = cut.messageId, upto = seq }
  end
  local upto = seq
  for _, entry in ipairs(entries) do
    if entry.seq > seq then
      local other = message_id(entry)
      if entry.kind == "prompt" or (other and other ~= id) then
        break
      end
      upto = entry.seq
    end
  end
  return { messageId = id, upto = upto }
end

-- The entries a new session's journal starts with: the conversation up to seq upto (all of it when
-- nil), renumbered from 1.
function M.carry(entries, upto)
  local kept = {}
  for _, entry in ipairs(entries) do
    if CARRIED[entry.kind] and (not upto or entry.seq <= upto) then
      local copy = vim.deepcopy(entry)
      copy.seq = #kept + 1
      kept[#kept + 1] = copy
    end
  end
  return kept
end

function M.archive_dir(ws, agent)
  return journal.dir(ws) .. "/" .. agent .. ".sessions"
end

function M.archive(ws, agent, session)
  return M.archive_dir(ws, agent) .. "/" .. session .. ".jsonl"
end

-- The journal's file replaced with entries, in one rename, so a reader sees the old one or the new
-- one (another inode, which a chat's follower takes as a journal to read again from the start).
-- The old one is kept as session's archive, when there's a session.
function M.replace_journal(ws, agent, entries, session)
  local path = journal.path(ws, agent)
  vim.fn.mkdir(journal.dir(ws), "p")
  local tmp = ("%s.%d.tmp"):format(path, vim.uv.os_getpid())
  local lines = {}
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = vim.json.encode(entry)
  end
  vim.fn.writefile(lines, tmp)
  if session and vim.uv.fs_stat(path) then
    vim.fn.mkdir(M.archive_dir(ws, agent), "p")
    vim.uv.fs_rename(path, M.archive(ws, agent, session))
  end
  assert(vim.uv.fs_rename(tmp, path))
end

-- A kept journal's entries (M.archive), or nil.
function M.read_archive(ws, agent, session)
  local path = M.archive(ws, agent, session)
  if not vim.uv.fs_stat(path) then
    return nil
  end
  local entries = {}
  for _, line in ipairs(vim.fn.readfile(path)) do
    local ok, entry = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(entry) == "table" then
      entries[#entries + 1] = entry
    end
  end
  return entries
end

-- history

---@class isovim.acp.SessionRecord
---@field id string
---@field started number epoch seconds
---@field how string new, fork, rewind, resume, load
---@field title? string its first prompt
---@field used? number when it was last the agent's session

-- The sessions the agent has had, newest first, from its record.
---@return isovim.acp.SessionRecord[]
function M.list(ws, agent)
  local spec = store.agent(ws, agent) or {}
  local list = vim.deepcopy(type(spec.sessions) == "table" and spec.sessions or {})
  table.sort(list, function(a, b)
    return (a.used or a.started or 0) > (b.used or b.started or 0)
  end)
  return list
end

-- Records session id as the agent's (fields: how, title), keeping it once in its history.
function M.note(ws, agent, id, fields)
  local spec = store.agent(ws, agent)
  if not spec or not store.v2(ws) then
    return
  end
  local list = type(spec.sessions) == "table" and spec.sessions or {}
  local found
  for _, item in ipairs(list) do
    if item.id == id then
      found = item
    end
  end
  if not found then
    found = { id = id, started = os.time() }
    list[#list + 1] = found
  end
  for key, value in pairs(fields or {}) do
    if key ~= "title" or not found.title then
      found[key] = value
    end
  end
  found.used = os.time()
  store.update_agent(ws, agent, { sessions = list })
end

-- snapshots

local IDENTITY = { GIT_AUTHOR_NAME = "isovim", GIT_AUTHOR_EMAIL = "isovim@localhost", GIT_COMMITTER_NAME = "isovim",
  GIT_COMMITTER_EMAIL = "isovim@localhost" }

local function git(dir, args, env)
  local cmd = { "git", "-C", dir }
  vim.list_extend(cmd, args)
  local result = vim.system(cmd, { text = true, env = env }):wait()
  return result.code == 0, vim.trim(result.stdout or ""), vim.trim(result.stderr or "")
end

-- The git checkout the agent's files are in: its worktree (aN/w) once it has one, else its dir
-- when that's in a checkout; nil when there's none.
function M.checkout(ws, agent)
  for _, dir in ipairs({ store.work_dir(ws, agent), store.agent_dir(ws, agent) }) do
    if vim.fn.isdirectory(dir) == 1 then
      local ok, top = git(dir, { "rev-parse", "--show-toplevel" })
      if ok and top ~= "" then
        return top
      end
    end
  end
end

-- A tree of every file in top git doesn't ignore, through a temp index seeded from the real one
-- (so unchanged files aren't hashed again); the temp index's path is returned too, to remove.
local function tree_of(top)
  local _, git_index = git(top, { "rev-parse", "--path-format=absolute", "--git-path", "index" })
  local index = vim.fn.tempname()
  if git_index ~= "" and vim.uv.fs_stat(git_index) then
    vim.uv.fs_copyfile(git_index, index)
  end
  local env = { GIT_INDEX_FILE = index }
  local added = git(top, { "add", "-A", "--", "." }, env)
  local ok, tree = git(top, { "write-tree" }, env)
  os.remove(index)
  return added and ok and tree ~= "" and tree or nil
end

-- Snapshots the agent's files before a turn; nil when they're in no checkout.
---@return {commit: string, dir: string}?
function M.snapshot(ws, agent, prompt_id)
  local top = M.checkout(ws, agent)
  local tree = top and tree_of(top)
  if not tree then
    return nil
  end
  local args = { "commit-tree", tree, "-m", ("isovim: %s/%s before %s"):format(ws, agent, prompt_id) }
  local has_head, head = git(top, { "rev-parse", "-q", "--verify", "HEAD^{commit}" })
  if has_head and head ~= "" then
    vim.list_extend(args, { "-p", head })
  end
  local ok, commit = git(top, args, IDENTITY)
  if not ok or commit == "" then
    return nil
  end
  git(top, { "update-ref", ("refs/isovim/snapshots/%s/%s"):format(agent, prompt_id), commit })
  return { commit = commit, dir = top }
end

-- Puts dir's files back as the snapshot has them: changed files from it, added files deleted.
---@return {restored: integer, deleted: integer}? done, string? err
function M.restore(dir, commit)
  local now = tree_of(dir)
  if not now then
    return nil, "could not read " .. dir .. "'s files"
  end
  local ok, diff, err = git(dir, { "diff-tree", "-r", "--no-renames", "--name-status", "-z", commit, now })
  if not ok then
    return nil, err
  end
  local fields = vim.split(diff, "\0", { plain = true, trimempty = true })
  local checkout, deleted = {}, 0
  for i = 1, #fields - 1, 2 do
    local status, path = fields[i], fields[i + 1]
    if status == "A" then
      os.remove(dir .. "/" .. path)
      deleted = deleted + 1
    else
      checkout[#checkout + 1] = path
    end
  end
  if #checkout > 0 then
    local index = vim.fn.tempname()
    local env = { GIT_INDEX_FILE = index }
    local read = git(dir, { "read-tree", commit }, env)
    local args = { "checkout-index", "-f", "--" }
    vim.list_extend(args, checkout)
    local wrote, _, why = git(dir, args, env)
    os.remove(index)
    if not (read and wrote) then
      return nil, why
    end
  end
  return { restored = #checkout, deleted = deleted }
end

return M
