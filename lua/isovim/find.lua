-- iso find: which agent was on something. Each of this host's agents is scored by where the query
-- turns up: its workspace or agent name, branch, PRs, what it's on now, and its conversation, as
-- the plain text its hooks keep in transcripts/<agent>.txt (iso/transcript.lua).
local store = require("isovim.store")
local panes = require("isovim.panes")

local M = {}

local WEIGHTS = { name = 10, branch = 8, pr = 8, doing = 6 }

local function contains(text, query)
  return text and text:lower():find(query, 1, true) ~= nil
end

-- Matches in the plain-text transcripts: file -> {count, snippet, line, col}, from two rg runs:
-- one counting, one finding the first match.
local function search(files, query)
  local found = {}
  if #files == 0 or vim.fn.executable("rg") == 0 then
    return found
  end
  local base = { "rg", "--no-heading", "--with-filename", "-i", "-F" }
  local counts = vim.system(vim.list_extend(vim.list_extend(vim.deepcopy(base), { "-c", query }), files), { text = true }):wait()
  for file, count in (counts.stdout or ""):gmatch("([^\n]+):(%d+)\n") do
    found[file] = { count = tonumber(count) }
  end
  local first = vim.list_extend(vim.deepcopy(base), { "-m", "1", "--column", "-n", query })
  local lines = vim.system(vim.list_extend(first, files), { text = true }):wait()
  for line in (lines.stdout or ""):gmatch("[^\n]+") do
    for file, hit in pairs(found) do
      if not hit.line and vim.startswith(line, file .. ":") then
        local row, col, text = line:sub(#file + 2):match("^(%d+):(%d+):(.*)$")
        local at = tonumber(col)
        hit.line, hit.col = tonumber(row), at
        hit.snippet = vim.trim(text:sub(math.max(1, at - 60), at + #query + 60))
      end
    end
  end
  return found
end

-- This host's agents that match, best first: {id, workspace, agent, kind, score, where, match}.
---@return table[]
function M.here(query)
  query = vim.trim(query):lower()
  local titles = panes.titles()
  local candidates, files = {}, {}
  for _, ws in ipairs(store.list()) do
    local branch = store.branch(ws.id)
    local prs = require("isovim.prs").cached(ws.id)
    for _, agent in ipairs(store.agents(ws.id)) do
      local hits = {}
      local function hit(where, text)
        hits[#hits + 1] = { where = where, text = text }
      end
      if contains(ws.name, query) or contains(agent.name, query) then
        hit("name", ws.name .. " · " .. agent.name)
      end
      if contains(branch, query) then
        hit("branch", branch)
      end
      for url, pr in pairs(prs) do
        local label = ("#%s %s"):format(pr.number or url:match("%d+$"), pr.title or "")
        if contains(label, query) or contains(url, query) then
          hit("pr", label)
        end
      end
      local doing = panes.subtitle(agent.kind, titles[ws.id .. "/" .. agent.id])
      if contains(doing, query) then
        hit("doing", doing)
      end
      local file = require("isovim.transcript").path(ws.id, agent.id)
      if vim.uv.fs_stat(file) then
        files[#files + 1] = file
      else
        file = nil
      end
      candidates[#candidates + 1] = { ws = ws, agent = agent, hits = hits, file = file }
    end
    -- An agent iso <role> rm removed keeps its transcript, headed "# <name> (removed ...)".
    local dir = vim.fs.dirname(require("isovim.transcript").path(ws.id, "a0"))
    for name, kind in vim.fn.isdirectory(dir) == 1 and vim.fs.dir(dir) or function() end do
      local id = kind == "file" and name:match("^(a%d+)%.txt$")
      local file = id and not store.agent(ws.id, id) and dir .. "/" .. name
      local head = file and (vim.fn.readfile(file, "", 1)[1] or ""):match("^# (.+ %(removed .*%))$")
      if head then
        local hits = contains(head, query) and { { where = "name", text = ws.name .. " · " .. head } } or {}
        files[#files + 1] = file
        candidates[#candidates + 1] = { ws = ws, agent = { id = id, name = head, kind = "claude" }, hits = hits, file = file }
      end
    end
  end
  local in_transcripts = search(files, query)
  local rows = {}
  for _, c in ipairs(candidates) do
    local score = 0
    for _, h in ipairs(c.hits) do
      score = score + WEIGHTS[h.where]
    end
    local said = c.file and in_transcripts[c.file]
    if said then
      -- Many mentions count, but less than being named for it.
      score = score + math.min(5, 1 + math.floor(math.log(said.count, 2)))
      c.hits[#c.hits + 1] = { where = "transcript", text = said.snippet or (said.count .. " mentions") }
      c.line, c.col = said.line, said.col
    end
    -- The line shown is what says the most: the name is in the row already.
    local best = c.hits[1]
    for _, h in ipairs(c.hits) do
      if best.where == "name" and h.where ~= "name" then
        best = h
      end
    end
    if score > 0 then
      rows[#rows + 1] = {
        id = c.ws.id .. "/" .. c.agent.id,
        workspace = c.ws.name,
        agent = c.agent.name,
        kind = c.agent.kind,
        score = score,
        where = best.where,
        match = best.text,
        file = c.line and c.file or nil,
        line = c.line,
        col = c.col,
      }
    end
  end
  table.sort(rows, function(a, b)
    return a.score > b.score
  end)
  return rows
end

return M
