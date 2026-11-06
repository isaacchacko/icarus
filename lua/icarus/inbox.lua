-- What's waiting on you on a task, for the outline's ◆: comment threads whose last word is an
-- agent's, proposals not yet accepted or rejected, decisions the peers dispute (your call;
-- icarus.democracy), and agents whose last word to you asked something.
local tasks = require("icarus.tasks")

local M = {}

local function short(text, n)
  text = vim.trim((text or ""):gsub("%s+", " "))
  return vim.fn.strchars(text) > n and vim.fn.strcharpart(text, 0, n - 1) .. "…" or text
end

-- Whether the agent's last word to you asked something, read again only when its transcript changes:
-- the outline asks every second, and a long transcript takes a noticeable part of that to parse.
local asked = {}
local function asks(record)
  local base = vim.fs.normalize(vim.env.CLAUDE_CONFIG_DIR or "~/.claude")
  local stat = vim.uv.fs_stat(("%s/projects/%s/%s.jsonl"):format(base, (record.cwd:gsub("[^%w]", "-")), record.session or ""))
  if not stat then
    return false
  end
  local seen = asked[record.id]
  if not (seen and seen.mtime == stat.mtime.sec and seen.size == stat.size) then
    seen = { mtime = stat.mtime.sec, size = stat.size, asks = false }
    local said = require("icarus.acp.thread").said(record) or {}
    for i = #said, 1, -1 do
      if said[i].who ~= "tools" then
        seen.asks = said[i].who == "agent" and vim.trim(said[i].text):match("%?%s*$") ~= nil
        break
      end
    end
    asked[record.id] = seen
  end
  return seen.asks
end

-- What's waiting on you on the task slug: each in a file ({path, line}), with an agent ({chat}), or a
-- decision to make ({text, decide}).
function M.rows(slug)
  local watch = require("icarus.watch")
  local dir = tasks.dir(slug) .. "/"
  local rows = {}
  for _, open in ipairs(watch.threads_under(dir)) do
    local thread = watch.thread(open.item)
    local last = thread[#thread]
    if not open.line and open.item.anchor and vim.fn.filereadable(open.path) == 1 then
      open.line = vim.fn.index(vim.fn.readfile(open.path), open.item.anchor) + 1
      open.line = open.line > 0 and open.line or nil
    end
    if last and last.who ~= "you" then
      rows[#rows + 1] = { path = open.path, line = open.line }
    end
  end
  for _, p in ipairs(watch.proposals_under(dir)) do
    rows[#rows + 1] = { path = p.path, line = p.line }
  end
  for _, d in ipairs(require("icarus.democracy").disputed(slug)) do
    rows[#rows + 1] = { text = "disputed: " .. short(d.text, 80), decide = function()
      require("icarus.democracy").ask(slug, d.id)
    end }
  end
  for _, each in ipairs(require("icarus.democracy").landed(slug)) do
    rows[#rows + 1] = { chat = each.id }
  end
  for _, record in ipairs(require("icarus.chats").on_task(slug)) do
    if asks(record) then
      rows[#rows + 1] = { chat = record.id }
    end
  end
  return rows
end

return M
