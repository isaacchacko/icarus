-- An ACP agent's prompt queue as a buffer you edit (<leader>iq): one queued prompt a line, as
-- "#<n> <text>" (a prompt's new lines shown as ⏎). Edit a line's text, reorder lines (dd p),
-- delete them, or add a line of your own (no #n), then :w, and the supervisor's queue becomes what
-- the buffer says (isovim.acp.host's queue_set); all lines deleted and :w clears it. <CR> on a line
-- sends that prompt now (after writing what you changed), which cancels the running turn. q closes.
-- An unmodified buffer follows the queue as prompts go; a prompt that went while you edited is
-- left out when you write, and you're told.
local acp = require("isovim.acp")

local M = {}

local NL = " ⏎ "

---@type table<integer, {ws: string, agent: string, ids: table<integer, string>}>
_G.isovim_acp_queues = _G.isovim_acp_queues or {}
local queues = _G.isovim_acp_queues

local function notify(text, level)
  vim.notify("isovim: " .. text, level or vim.log.levels.INFO)
end

local function find(ws, agent)
  for buf, q in pairs(queues) do
    if vim.api.nvim_buf_is_valid(buf) and q.ws == ws and q.agent == agent then
      return buf, q
    end
  end
end

-- The lines for items, and which #n is which prompt id.
local function lines_of(items)
  local lines, ids = {}, {}
  for i, item in ipairs(items) do
    ids[i] = item.id
    lines[i] = ("#%d %s"):format(i, (item.text or ""):gsub("\n", NL))
  end
  return lines, ids
end

local function fill(buf, items)
  local q = queues[buf]
  local lines
  lines, q.ids = lines_of(items)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
end

-- What the buffer says the queue is: {id?, text} per non-empty line.
function M.parse(buf)
  local q = queues[buf]
  local items = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local n, text = line:match("^#(%d+) ?(.*)$")
    local id = n and q.ids[tonumber(n)]
    text = (id and text or line):gsub(vim.pesc(NL), "\n")
    if vim.trim(text) ~= "" then
      items[#items + 1] = { id = id, text = text }
    end
  end
  return items
end

local function write(buf)
  local q = queues[buf]
  local ok, result = acp.call(q.ws, q.agent, "queue_set", { items = M.parse(buf) })
  if not ok then
    notify("could not change the queue: " .. tostring(result), vim.log.levels.ERROR)
    return false
  end
  if result.gone and #result.gone > 0 then
    notify(("%d of the prompts you edited went before you wrote; they're left out"):format(#result.gone), vim.log.levels.WARN)
  end
  fill(buf, result.items or {})
  return true
end

local function send_now(buf)
  local q = queues[buf]
  local row = vim.api.nvim_win_get_cursor(0)[1]
  if vim.bo[buf].modified and not write(buf) then
    return
  end
  -- Its place after the write: the same line, unless lines without text went.
  local id = q.ids[row] or q.ids[#q.ids]
  if not id then
    return notify("nothing queued to send")
  end
  local ok, result = acp.call(q.ws, q.agent, "queue_send_now", { id = id })
  if not ok then
    return notify("could not send it: " .. tostring(result), vim.log.levels.ERROR)
  end
end

-- Redraws an open, unmodified queue buffer with items (the chat calls this as the queue changes).
function M.refresh(ws, agent, items)
  local buf = find(ws, agent)
  if buf and not vim.bo[buf].modified then
    fill(buf, items)
  end
end

M.help = " edit, reorder or delete lines, :w applies · <CR> sends that one now (cancels the turn) · q closes"

-- Opens the agent's queue in a split under win (default: the current window).
function M.open(ws, agent, win)
  local ok, result = acp.call(ws, agent, "queue")
  if not ok then
    return notify(("%s's queue: %s"):format(agent, tostring(result)), vim.log.levels.ERROR)
  end
  local buf = find(ws, agent)
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "isovim_queue"
    vim.b[buf].completion = false
    pcall(vim.api.nvim_buf_set_name, buf, ("isovim-acp://%s/%s/queue"):format(ws, agent))
    queues[buf] = { ws = ws, agent = agent, ids = {} }
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer = buf,
      callback = function()
        write(buf)
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      callback = function()
        queues[buf] = nil
      end,
    })
    local map = function(lhs, fn, desc)
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "isovim: " .. desc })
    end
    map("<CR>", function()
      send_now(buf)
    end, "send this prompt now")
    map("q", function()
      vim.cmd("close")
    end, "close the queue")
  end
  fill(buf, result.items or {})
  local shown = vim.fn.bufwinid(buf)
  if shown == -1 then
    shown = vim.api.nvim_open_win(buf, true, { split = "below", win = win or 0, height = math.max(3, math.min(10, #result.items + 1)) })
  end
  vim.api.nvim_set_current_win(shown)
  vim.wo[shown][0].winbar = "%#Comment#" .. M.help
  vim.wo[shown][0].wrap = true
  return buf
end

return M
