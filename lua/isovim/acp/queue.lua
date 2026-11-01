-- An ACP agent's prompt queue, shown on its own while prompts wait: a window under the chat's (under
-- every window showing the chat, in the TUI and in iso attach), right below the composer at the
-- chat's bottom, as tall as its lines up to a few, titled "queued · N". It opens as the first prompt
-- queues and closes when the queue empties; q hides it until another prompt queues. <leader>iq
-- goes to it, opening it even when nothing waits so you can add a line. <C-k> goes up to the
-- composer.
--
-- It's a buffer you edit: one queued prompt a line, as "#<n> <text>" (a prompt's new lines shown as
-- ⏎). Edit a line's text, reorder lines (dd p), delete them, or add a line of your own (no #n),
-- then :w, and the supervisor's queue becomes what the buffer says (isovim.acp.host's queue_set);
-- all lines deleted and :w clears it. <CR> on a line sends that prompt now (after writing what you
-- changed), which cancels the running turn. An unmodified buffer follows the queue as prompts go;
-- a modified one is never redrawn under you, nor closed while it shows. When you write, a prompt
-- that went while you edited is left out, and you're told; one that queued meanwhile is kept,
-- after yours.
--
-- The window isn't part of a layout (isovim.layout leaves it out): the chat brings it back
-- wherever it shows (M.sync).
local acp = require("isovim.acp")

local M = {}

local NL = " ⏎ "
-- The most lines it takes; more scroll.
local MAX_HEIGHT = 6

---@class isovim.acp.Queue
---@field ws string
---@field agent string
---@field ids table<integer, string> which #n is which prompt id
---@field pinned? boolean opened by <leader>iq while empty: it stays until you leave it
---@field hidden? integer hidden by q with this many queued: the next prompt brings it back

---@type table<integer, isovim.acp.Queue>
_G.isovim_acp_queues = _G.isovim_acp_queues or {}
local queues = _G.isovim_acp_queues

local function notify(text, level)
  vim.notify("isovim: " .. text, level or vim.log.levels.INFO)
end

-- This load of the module: a queue buffer bound by an older one (before a hot reload) has its keys
-- and autocmds made again by this code as it's found.
local GEN = {}
local bind

local function find(ws, agent)
  for buf, q in pairs(queues) do
    if vim.api.nvim_buf_is_valid(buf) and q.ws == ws and q.agent == agent then
      if q.gen ~= GEN then
        bind(buf, q)
      end
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
  if not vim.deep_equal(lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false)) then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
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
  local ok, result = acp.call(q.ws, q.agent, "queue_set", { items = M.parse(buf), known = vim.tbl_values(q.ids) })
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

local function chat_of(q)
  return require("isovim.acp.chat").get(q.ws, q.agent)
end

M.help = "edit lines and :w · <CR> sends one now · q hides"

local function queue_window(win)
  local wo = vim.wo[win][0]
  wo.winfixheight, wo.wrap, wo.linebreak = true, true, true
  wo.number, wo.relativenumber, wo.signcolumn, wo.statuscolumn, wo.foldcolumn = false, false, "no", "", "0"
  wo.list, wo.spell, wo.colorcolumn, wo.cursorline = false, false, "", false
  wo.fillchars = "eob: "
  -- The #n before each prompt, dim.
  if not vim.w[win].isovim_queue_match then
    vim.w[win].isovim_queue_match = vim.fn.matchadd("IsovimAcpHint", [[^#\d\+ ]], 10, -1, { window = win })
  end
end

-- The agent's queue buffer, made the first time it's needed. It hides rather than wipes when its
-- window closes, so what you were editing survives a layout rebuild.
local function buffer(ws, agent)
  local buf, q = find(ws, agent)
  if buf then
    return buf, q
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "isovim_queue"
  vim.b[buf].completion = false
  vim.b[buf].snacks_indent = false
  -- Its workspace's, so it comes and goes with the chat when you switch workspaces.
  vim.b[buf].isovim_ws = ws
  vim.b[buf].isovim_queue = true
  pcall(vim.api.nvim_buf_set_name, buf, ("isovim-acp://%s/%s/queue"):format(ws, agent))
  q = { ws = ws, agent = agent, ids = {} }
  queues[buf] = q
  bind(buf, q)
  return buf, q
end

local GROUP = vim.api.nvim_create_augroup("isovim_acp_queue", { clear = false })

-- The queue buffer's autocmds and keys, made again by each load of the module (find).
bind = function(buf, q)
  q.gen = GEN
  for _, au in ipairs(vim.api.nvim_get_autocmds({ buffer = buf })) do
    if au.group == nil or au.group == GROUP then
      vim.api.nvim_del_autocmd(au.id)
    end
  end
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = GROUP,
    buffer = buf,
    callback = function()
      write(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = GROUP,
    buffer = buf,
    callback = function()
      queues[buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = GROUP,
    buffer = buf,
    callback = function()
      queue_window(vim.api.nvim_get_current_win())
    end,
  })
  -- Opened empty by <leader>iq and left without adding a line: it goes.
  vim.api.nvim_create_autocmd("WinLeave", {
    group = GROUP,
    buffer = buf,
    callback = function()
      if q.pinned and not vim.bo[buf].modified then
        q.pinned = nil
        require("isovim.safe").schedule("the queue window", function()
          local chat = chat_of(q)
          if chat then
            M.sync(chat)
          end
        end)
      end
    end,
  })
  local map = function(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "isovim: " .. desc })
  end
  map("<CR>", function()
    send_now(buf)
  end, "send this prompt now")
  map("q", function()
    local chat = chat_of(q)
    q.pinned, q.hidden = nil, chat and #chat.queue or 0
    if chat then
      M.sync(chat)
    end
  end, "hide the queue until another prompt queues")
  map("<C-k>", function()
    local win = vim.w.isovim_queue_under
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
    end
    require("isovim.acp.chat").focus_composer(q.ws, q.agent)
  end, "up to the composer")
  pcall(vim.keymap.del, "n", "<C-j>", { buffer = buf })
  require("isovim").map_to_sidebar(buf, { "n", "i" })
end

-- The queue window under the chat's window cwin, if it has one.
local function under(buf, cwin)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.w[win].isovim_queue_under == cwin then
      return win
    end
  end
end

local function close(win)
  if win == vim.api.nvim_get_current_win() then
    local cwin = vim.w[win].isovim_queue_under
    if cwin and vim.api.nvim_win_is_valid(cwin) then
      vim.api.nvim_set_current_win(cwin)
    end
  end
  pcall(vim.api.nvim_win_close, win, false)
end

-- Shows or hides the agent's queue window under each window showing its chat, as the queue (the
-- chat's, from its journal) says: there while prompts wait, or while you're editing it.
---@param chat isovim.acp.Chat
function M.sync(chat)
  local buf, q = find(chat.ws, chat.agent)
  local count = #chat.queue
  if q and q.hidden then
    q.hidden = math.min(q.hidden, count)
    if count > q.hidden or count == 0 then
      q.hidden = nil
    end
  end
  local editing = buf and vim.bo[buf].modified and vim.fn.bufwinid(buf) ~= -1
  local want = (count > 0 or (q and q.pinned) or editing) and not (q and q.hidden)
  local chats = vim.api.nvim_buf_is_valid(chat.buf) and vim.fn.win_findbuf(chat.buf) or {}
  if not want or #chats == 0 then
    for _, win in ipairs(buf and vim.fn.win_findbuf(buf) or {}) do
      close(win)
    end
    return
  end
  if not buf then
    buf, q = buffer(chat.ws, chat.agent)
    fill(buf, chat.queue)
  end
  -- A narrow window cuts the help, not the count (%<).
  local bar = ("%%#IsovimAcpSpinnerNote# queued · %d %%<%%#IsovimAcpHint#  %s"):format(count, M.help)
  for _, cwin in ipairs(chats) do
    local win = under(buf, cwin)
    if not win then
      win = vim.api.nvim_open_win(buf, false, { split = "below", win = cwin, height = 2 })
      vim.w[win].isovim_queue_under = cwin
    end
    -- Gone already if opening it set off something that closed it.
    if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      vim.wo[win][0].winbar = bar
      -- Its lines as they wrap, and the title (the winbar counts in a window's height).
      local ok, measured = pcall(vim.api.nvim_win_text_height, win, {})
      local height = math.max(1, math.min(MAX_HEIGHT, ok and measured.all or 1)) + 1
      if vim.api.nvim_win_get_height(win) ~= height then
        vim.api.nvim_win_set_height(win, height)
      end
    end
  end
  -- One whose chat went elsewhere (another agent's chat took its window, or it closed).
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local cwin = vim.w[win].isovim_queue_under
    if not (cwin and vim.api.nvim_win_is_valid(cwin) and vim.api.nvim_win_get_buf(cwin) == chat.buf) then
      close(win)
    end
  end
end

-- The queue changed: an unmodified buffer shows it, and the windows follow (the chat calls this).
---@param chat isovim.acp.Chat
function M.refresh(chat)
  local buf, q = find(chat.ws, chat.agent)
  if buf and not vim.bo[buf].modified then
    fill(buf, chat.queue)
  end
  if q and #chat.queue > 0 then
    q.pinned = nil
  end
  M.sync(chat)
end

-- The queue window under the chat's window (the one you're in, else the first), while one shows
-- (for <C-j>).
---@param chat isovim.acp.Chat
function M.window(chat)
  local buf = find(chat.ws, chat.agent)
  local cwin = vim.api.nvim_get_current_buf() == chat.buf and vim.api.nvim_get_current_win() or vim.fn.bufwinid(chat.buf)
  return buf and cwin ~= -1 and under(buf, cwin) or nil
end

-- <leader>iq: goes to the agent's queue, opening it even when nothing waits.
function M.focus(ws, agent)
  local chat = require("isovim.acp.chat").get(ws, agent)
  if not chat then
    return notify(("%s has no chat open"):format(agent), vim.log.levels.ERROR)
  end
  local ok, result = acp.call(ws, agent, "queue")
  if not ok then
    return notify(("%s's queue: %s"):format(agent, tostring(result)), vim.log.levels.ERROR)
  end
  local buf, q = buffer(ws, agent)
  if not vim.bo[buf].modified then
    fill(buf, result.items or {})
  end
  q.pinned, q.hidden = true, nil
  M.sync(chat)
  local win = M.window(chat)
  if win then
    vim.cmd.stopinsert()
    vim.api.nvim_set_current_win(win)
  end
  return buf
end

-- The agent went away: its queue buffer goes too.
function M.close(ws, agent)
  local buf = find(ws, agent)
  if buf then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

return M
