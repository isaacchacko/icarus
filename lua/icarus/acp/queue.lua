-- A chat's prompt queue, from isovim's: a window under the chat while prompts wait, titled
-- "queued · N", that opens as the first prompt queues and closes when the queue empties. q hides it
-- until another prompt queues; <leader>q goes to it, opening it even when nothing waits, so you can
-- add a line.
--
-- It's a buffer you edit: one queued prompt a line, "#<n> <text>" (a prompt's new lines shown as ⏎).
-- Edit a line's text, reorder lines (dd p), delete them, or add a line of your own (no #n), then :w,
-- and the session's queue becomes what the buffer says; all lines deleted and :w clears it. <CR> on
-- a line sends that prompt now (after writing what you changed), interrupting the running turn. An
-- unmodified buffer follows the queue as prompts go; a modified one is never redrawn under you, nor
-- closed while it shows. When you write, a prompt that went while you edited is left out, and you're
-- told; one that queued meanwhile is kept, after yours.
local M = {}

local NL = " ⏎ "
-- The most lines it takes; more scroll.
local MAX_HEIGHT = 6

M.help = "edit lines and :w · <CR> sends one now · q hides"

---@class icarus.acp.Queue
---@field buf integer
---@field ids table<integer, table> which #n is which queued prompt
---@field pinned? boolean opened by <leader>q while empty: it stays until you leave it
---@field hidden? integer hidden by q with this many queued: the next prompt brings it back
---@field key? string what it last showed, so a refresh with nothing new does nothing

-- In _G, so a hot reload keeps them; by chat id.
_G.icarus_queues = _G.icarus_queues or {}
local queues = _G.icarus_queues ---@type table<string, icarus.acp.Queue>

local function chat_of(id)
  local record = require("icarus.chats").get(id)
  return record and require("icarus.acp.chat").get(record)
end

-- The session's queue, each prompt a table (one queued as a string, by code before a hot reload,
-- becomes one in place).
local function prompts(chat)
  local queue = chat.session.queue
  for i, prompt in ipairs(queue) do
    if type(prompt) == "string" then
      queue[i] = { text = prompt }
    end
  end
  return queue
end

local function shown(prompt)
  return ((prompt.display or prompt.text or ""):gsub("\n", NL))
end

local function fill(q, chat)
  local lines = {}
  q.ids = {}
  for i, prompt in ipairs(prompts(chat)) do
    q.ids[i] = prompt
    lines[i] = ("#%d %s"):format(i, shown(prompt))
  end
  if not vim.deep_equal(lines, vim.api.nvim_buf_get_lines(q.buf, 0, -1, false)) then
    vim.api.nvim_buf_set_lines(q.buf, 0, -1, false, lines)
  end
  vim.bo[q.buf].modified = false
end

-- Makes the session's queue what the buffer says.
local function write(id)
  local q, chat = queues[id], chat_of(id)
  if not (q and chat) then
    return false
  end
  local queue = prompts(chat)
  local waiting, known = {}, {}
  for _, prompt in ipairs(queue) do
    waiting[prompt] = true
  end
  for _, prompt in pairs(q.ids) do
    known[prompt] = true
  end
  local new, gone = {}, 0
  for _, line in ipairs(vim.api.nvim_buf_get_lines(q.buf, 0, -1, false)) do
    local n, text = line:match("^#(%d+) ?(.*)$")
    local prompt = n and q.ids[tonumber(n)]
    text = vim.trim(((prompt and text or line):gsub(vim.pesc(NL), "\n")))
    if prompt and not waiting[prompt] then
      gone = gone + 1
    elseif prompt then
      if text ~= vim.trim(shown(prompt):gsub(vim.pesc(NL), "\n")) and text ~= "" then
        prompt.text, prompt.display = text, nil
      end
      if text ~= "" then
        new[#new + 1] = prompt
      end
    elseif text ~= "" then
      new[#new + 1] = { text = text }
    end
  end
  -- Queued while you edited: kept, after yours.
  for _, prompt in ipairs(queue) do
    if not known[prompt] then
      new[#new + 1] = prompt
    end
  end
  for i = #queue, 1, -1 do
    queue[i] = nil
  end
  vim.list_extend(queue, new)
  if gone > 0 then
    vim.notify(("%d of the prompts you edited went before you wrote; they're left out"):format(gone), vim.log.levels.WARN)
  end
  q.key = nil
  fill(q, chat)
  M.refresh(chat)
  return true
end

local function send_now(id)
  local q, chat = queues[id], chat_of(id)
  if not (q and chat) then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  if vim.bo[q.buf].modified and not write(id) then
    return
  end
  local prompt = q.ids[row] or q.ids[#q.ids]
  local queue = prompts(chat)
  local at
  for i, each in ipairs(queue) do
    if each == prompt then
      at = i
    end
  end
  if not at then
    return vim.notify("Nothing queued to send")
  end
  table.remove(queue, at)
  table.insert(queue, 1, prompt)
  local session = chat.session
  if session.busy then
    -- Its turn ends cancelled, and the session sends the queue's first.
    session:cancel()
  elseif session.ready then
    table.remove(queue, 1)
    session:deliver(prompt)
  end
  M.refresh(chat)
end

local function setup_window(win)
  local wo = vim.wo[win][0]
  wo.winfixheight, wo.wrap, wo.linebreak = true, true, true
  wo.number, wo.relativenumber, wo.signcolumn, wo.statuscolumn, wo.foldcolumn = false, false, "no", "", "0"
  wo.list, wo.spell, wo.colorcolumn, wo.cursorline = false, false, "", false
  wo.fillchars = "eob: "
  if not vim.w[win].icarus_queue_match then
    vim.w[win].icarus_queue_match = vim.fn.matchadd("IcarusAcpHint", [[^#\d\+ ]], 10, -1, { window = win })
  end
end

-- The chat's queue buffer, made the first time it's needed. It hides rather than wipes when its
-- window closes, so what you were editing survives.
local function queue_of(chat)
  local id = chat.record.id
  local q = queues[id]
  if q and vim.api.nvim_buf_is_valid(q.buf) then
    return q
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "icarus_queue"
  pcall(vim.api.nvim_buf_set_name, buf, "icarus://queue/" .. id)
  q = { buf = buf, ids = {} }
  queues[id] = q
  local group = vim.api.nvim_create_augroup("icarus_queue_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", { group = group, buffer = buf, callback = function()
    require("icarus.acp.queue").write(id)
  end })
  vim.api.nvim_create_autocmd("BufWinEnter", { group = group, buffer = buf, callback = function()
    setup_window(vim.api.nvim_get_current_win())
  end })
  -- Opened empty by <leader>q and left without adding a line: it goes.
  vim.api.nvim_create_autocmd("WinLeave", { group = group, buffer = buf, callback = function()
    if q.pinned and not vim.bo[buf].modified then
      q.pinned = nil
      vim.schedule(function()
        local each = chat_of(id)
        if each then
          M.refresh(each, true)
        end
      end)
    end
  end })
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end
  map("<CR>", function()
    require("icarus.acp.queue").send_now(id)
  end, "Send this prompt now")
  map("q", function()
    local each = chat_of(id)
    q.pinned, q.hidden = nil, each and #each.session.queue or 0
    if each then
      M.refresh(each, true)
    end
  end, "Hide the queue until another prompt queues")
  return q
end

-- The queue window under the chat's window cwin, if it has one.
local function under(q, cwin)
  for _, win in ipairs(vim.fn.win_findbuf(q.buf)) do
    if vim.w[win].icarus_queue_of == cwin then
      return win
    end
  end
end

local function close(win)
  if win == vim.api.nvim_get_current_win() then
    local cwin = vim.w[win].icarus_queue_of
    if cwin and vim.api.nvim_win_is_valid(cwin) then
      vim.api.nvim_set_current_win(cwin)
    end
  end
  pcall(vim.api.nvim_win_close, win, false)
end

-- Shows or hides the chat's queue window under each window showing it: there while prompts wait,
-- or while you're editing it. Cheap when nothing changed, as the spinner calls it.
---@param force? boolean
function M.refresh(chat, force)
  local q = queues[chat.record.id]
  local queue = prompts(chat)
  local count = #queue
  local wins = require("icarus.acp.thread").windows(chat)
  local key = table.concat(vim.tbl_map(tostring, queue), ",") .. "|" .. table.concat(wins, ",")
  if q and not force and q.key == key then
    return
  end
  if q then
    q.key = key
    if q.hidden then
      q.hidden = math.min(q.hidden, count)
      if count > q.hidden or count == 0 then
        q.hidden = nil
      end
    end
    if not vim.bo[q.buf].modified then
      fill(q, chat)
    end
    if count > 0 then
      q.pinned = nil
    end
  end
  local editing = q and vim.bo[q.buf].modified and vim.fn.bufwinid(q.buf) ~= -1
  local want = (count > 0 or (q and q.pinned) or editing) and not (q and q.hidden)
  if not want or #wins == 0 then
    for _, win in ipairs(q and vim.fn.win_findbuf(q.buf) or {}) do
      close(win)
    end
    return
  end
  if not q then
    q = queue_of(chat)
    q.key = key
    fill(q, chat)
  end
  -- A narrow window cuts the help, not the count (%<).
  local bar = ("%%#IcarusAcpSpinnerNote# queued · %d %%<%%#IcarusAcpHint#  %s"):format(count, M.help)
  for _, cwin in ipairs(wins) do
    local win = under(q, cwin)
    -- A float (zen) can't be split.
    if not win and vim.api.nvim_win_get_config(cwin).relative == "" then
      win = vim.api.nvim_open_win(q.buf, false, { split = "below", win = cwin, height = 2 })
      vim.w[win].icarus_queue_of = cwin
      setup_window(win)
    end
    if win and vim.api.nvim_win_is_valid(win) then
      vim.wo[win][0].winbar = bar
      -- Its lines as they wrap, and the title (the winbar counts in a window's height).
      local ok, measured = pcall(vim.api.nvim_win_text_height, win, {})
      local height = math.max(1, math.min(MAX_HEIGHT, ok and measured.all or 1)) + 1
      if vim.api.nvim_win_get_height(win) ~= height then
        vim.api.nvim_win_set_height(win, height)
      end
    end
  end
  -- One whose chat went elsewhere (another chat took its window, or it closed).
  for _, win in ipairs(vim.fn.win_findbuf(q.buf)) do
    local cwin = vim.w[win].icarus_queue_of
    if not (cwin and vim.api.nvim_win_is_valid(cwin) and vim.tbl_contains(require("icarus.acp.thread").windows(chat), cwin)) then
      close(win)
    end
  end
end

-- Closes the queue windows under the chat window win (home taking it).
function M.hide(win)
  for _, each in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[each].icarus_queue_of == win then
      close(each)
    end
  end
end

-- <leader>q: goes to the chat's queue, opening it even when nothing waits.
function M.focus(chat)
  local q = queue_of(chat)
  if not vim.bo[q.buf].modified then
    fill(q, chat)
  end
  q.pinned, q.hidden = true, nil
  M.refresh(chat, true)
  local cwin = require("icarus.acp.thread").windows(chat)[1] or -1
  local win = cwin ~= -1 and under(q, cwin)
  if win then
    vim.cmd.stopinsert()
    vim.api.nvim_set_current_win(win)
  end
end

M.write = write
M.send_now = send_now

return M
