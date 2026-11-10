-- Watch, and the agent's comments and proposals in a buffer, as icarus's first prototype had them.
--
-- <leader>w on a file: the agent on the left watches it. It gets the buffer, numbered, then the user's
-- edits to it as a diff on the agent's next turn, and is told to stay quiet and answer in the buffer.
-- A diff waiting behind a busy agent takes in the edits after it.
--
-- On a router task the lead watches every markdown file in the task's folder, without being asked
-- and without being told: the file is simply theirs (M.follow).
--
-- Nothing here runs on a timer, and nothing starts a turn unless you do: a line with @claude does as
-- you leave insert mode, and <leader>* reads the whole buffer to the agent. Each turn and each :w commit
-- what you've typed to ~/.icarus/edits, saved or not, so every change has a history in git.
--
-- Comments: ica comment <file> <line|text> <comment...|-> puts one on a line: the line goes yellow
-- with "▸ za" after it. A comment stays until it's dismissed: a line rewritten keeps it where it
-- was. In a watched file, <leader>c on a line starts one of yours (teal), which the
-- agent is sent; a comment is a thread, and <leader>c on one adds your reply to it, the agent's with
-- ica comment <file> --reply <id> <text>. They're kept per file (in stdpath("data")/comments), found
-- again by their line's text; one whose line is deleted moves to the line that took its place.
--
-- za on a comment or a proposal opens it in a float under its line (over it, near the window's
-- bottom), a buffer of its own, wrapped, with the cursor in it: you move, scroll and yank in it as
-- in any buffer. q, za or <Esc> closes it, as does leaving it.
--
-- Requests: select text and <leader>a, with a message or none, or write a line with @claude. The
-- agent gets a selection with its id; it pulses blue and can't be edited until the agent answers
-- with ica propose <id> [--note <text>] [<replacement...|->]: the old text struck through, the new
-- under it in green, the note over it. The agent proposes on lines of its own choosing too, unasked
-- or for an @claude line: ica propose <file> <start> <end> [--note <text>] [<replacement...|->].
-- On a proposal <leader>y takes it, <leader>c replies (the agent gets it again, with your reply)
-- and <leader>n dismisses it; on a comment <leader>n dismisses that. On either, <leader>+ asks for
-- more detail and <leader>- for fewer words, each with a message if you like: a proposal comes back
-- as a new one, a comment is rewritten in place (ica comment <file> --replaces <id>). These keys exist only while
-- the cursor is on one, so which-key shows them only there.
--
-- ica reaches this icarus over its socket (ICARUS_SERVER) and calls M.remote.
local T = require("icarus.theme")

local M = {}

local NS = vim.api.nvim_create_namespace("icarus_watch")
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local EDITS = require("icarus.tasks").ROOT .. "/edits"
local STORE = vim.fn.stdpath("data") .. "/comments"

-- In _G, so a hot reload keeps them.
_G.icarus_watch = _G.icarus_watch or {}
local state = _G.icarus_watch
state.bufs = state.bufs or {} ---@type table<integer, {chat: string, base: string, sent_base?: string, pending?: table, timer: uv.uv_timer_t, winbar?: string}>
state.comments = state.comments or {} ---@type table<integer, {anchor: string, text: string, open?: boolean, mark?: integer}[]>
state.reqs = state.reqs or {} ---@type table<string, {id: string, buf: integer, mark: integer, chat?: string, pending?: boolean, frozen?: string, proposal?: {text?: string, note?: string}}>
local watched, comments, reqs = state.bufs, state.comments, state.reqs

local function highlights()
  vim.api.nvim_set_hl(0, "IcarusComment", { bg = T.sun, fg = T.ink, default = true })
  vim.api.nvim_set_hl(0, "IcarusCommentYou", { bg = T.teal, fg = T.ink, default = true })
  vim.api.nvim_set_hl(0, "IcarusCommentYouBody", { fg = T.teal, default = true })
  vim.api.nvim_set_hl(0, "IcarusCommentHint", { fg = T.sun, italic = true, default = true })
  vim.api.nvim_set_hl(0, "IcarusCommentBody", { fg = T.sun, default = true })
  vim.api.nvim_set_hl(0, "IcarusAsked", { bg = T.asked, default = true })
  vim.api.nvim_set_hl(0, "IcarusProposedOld", { bg = T.removed, strikethrough = true, default = true })
  vim.api.nvim_set_hl(0, "IcarusProposedNew", { fg = T.leaf, default = true })
  vim.api.nvim_set_hl(0, "IcarusProposedHint", { fg = T.mute, italic = true, default = true })
end
highlights()

-- Unique however many come in the same second: the second, then a count kept across reloads.
local function new_id()
  _G.icarus_comment_seq = ((_G.icarus_comment_seq or 0) + 1) % 1000
  return ("%d%03d"):format(os.time(), _G.icarus_comment_seq)
end

-- The title of the agent with chat id, short.
local function agent_name(id)
  local record = id and require("icarus.chats").get(id)
  local title = record and record.title or id or "an agent"
  return vim.fn.strchars(title) > 32 and vim.fn.strcharpart(title, 0, 31) .. "…" or title
end
M.agent_name = agent_name

-- An agent's name, short enough for the end of a line.
local function short_name(id)
  local title = (agent_name(id):gsub("^⑂ ", ""))
  return vim.fn.strchars(title) > 20 and vim.fn.strcharpart(title, 0, 19) .. "…" or title
end

local function name(buf)
  return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
end

local function content(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
end

local function numbered(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do
    lines[i] = ("%4d  %s"):format(i, line)
  end
  return table.concat(lines, "\n")
end

local function session(chat_id)
  local record = chat_id and require("icarus.chats").get(chat_id)
  return record and require("icarus.acp.chat").get(record).session
end

-- Comments

local function store_file(buf)
  return ("%s/%s.json"):format(STORE, (vim.api.nvim_buf_get_name(buf):gsub("/", "%%")))
end

-- A file was renamed from from to to: its comments go with it.
function M.moved(from, to)
  local function kept(path)
    return ("%s/%s.json"):format(STORE, (path:gsub("/", "%%")))
  end
  vim.uv.fs_rename(kept(from), kept(to))
end

local function save(buf)
  local out = {}
  for _, item in ipairs(comments[buf] or {}) do
    out[#out + 1] = { id = item.id, anchor = item.anchor, text = item.text, chat = item.chat, who = item.who,
      thread = item.thread }
  end
  vim.fn.mkdir(STORE, "p")
  if #out == 0 then
    vim.fn.delete(store_file(buf))
  else
    vim.fn.writefile({ vim.json.encode(out) }, store_file(buf))
  end
end

local function find_row(buf, anchor)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do
    if line == anchor then
      return i - 1
    end
  end
  for i, line in ipairs(lines) do
    if anchor ~= "" and line:find(anchor, 1, true) then
      return i - 1
    end
  end
end

-- Where item's line is: its mark's row while that line still reads as it did; else the line that
-- does (the buffer read again from disk, say, which leaves every mark at one row); else, its text
-- gone (the line rewritten), the mark's row, the line now read as it is.
local function row_of(buf, item)
  local pos = item.mark and vim.api.nvim_buf_get_extmark_by_id(buf, NS, item.mark, { details = true }) or {}
  local count = vim.api.nvim_buf_line_count(buf)
  local at = pos[1] and math.min(pos[1], count - 1)
  if at and vim.api.nvim_buf_get_lines(buf, at, at + 1, false)[1] == item.anchor then
    item.reread = nil
    return at
  end
  local found = find_row(buf, item.anchor) or (#item.anchor >= 8 and find_row(buf, item.anchor:sub(1, 24)))
  if found then
    item.reread = nil
    return found
  end
  -- Read again from disk without its line: a reload throws marks away, so it keeps its text, to find
  -- the line if it comes back, and waits where it last was.
  if item.reread then
    return math.min(item.row or at or 0, count - 1)
  end
  if at then
    item.anchor = vim.api.nvim_buf_get_lines(buf, at, at + 1, false)[1] or item.anchor
    return at
  end
end

local function draw(buf, item)
  local row = row_of(buf, item)
  if not row then
    return
  end
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local opts = { id = item.mark, end_row = row, end_col = #line,
    hl_group = item.fresh and "IcarusAskedPulse" or item.who == "you" and "IcarusCommentYou" or "IcarusComment",
    virt_text = { { item.pending and ("  %s is %s %s"):format(short_name(item.chat), item.pending, SPINNER[(state.spin or 0) % #SPINNER + 1])
      or ("  ▸ za %s%s"):format(
      item.who == "you" and "you" or short_name(item.chat), item.thread and #item.thread > 1 and (" · " .. #item.thread) or ""),
      "IcarusCommentHint" } }, virt_text_pos = "eol", invalidate = false }
  item.mark = vim.api.nvim_buf_set_extmark(buf, NS, row, 0, opts)
  if not item.reread then
    item.row = row
  end
end

-- buf was read again from disk: where its marks are no longer says where its comments belong.
function M.reread(buf)
  for _, item in ipairs(comments[buf] or {}) do
    item.reread = true
  end
end

-- Draws buf's comments again; one whose line was deleted goes with it.
local function redraw(buf)
  local kept = {}
  for _, item in ipairs(comments[buf] or {}) do
    if row_of(buf, item) then
      kept[#kept + 1] = item
      draw(buf, item)
    elseif item.mark then
      pcall(vim.api.nvim_buf_del_extmark, buf, NS, item.mark)
    end
  end
  comments[buf] = kept
  save(buf)
end

local function comment_at_cursor(buf)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  for _, item in ipairs(comments[buf] or {}) do
    if row_of(buf, item) == row then
      return item
    end
  end
end

-- Requests

-- A request's or proposal's range. Its mark gone stale (the buffer read again, the lines changed
-- under it), it's found again by the lines it was made on (r.lines), whole lines from then on.
local function req_range(r)
  local pos = vim.api.nvim_buf_get_extmark_by_id(r.buf, NS, r.mark, { details = true })
  local stale = not pos[1] or pos[3].invalid
  if not stale and r.lines then
    local now = vim.api.nvim_buf_get_lines(r.buf, pos[1], pos[3].end_row + 1, false)
    stale = now[1] ~= r.lines[1] or #now ~= #r.lines
  end
  if not stale then
    return pos[1], pos[2], pos[3].end_row, pos[3].end_col
  end
  if not r.lines then
    return nil
  end
  local all = vim.api.nvim_buf_get_lines(r.buf, 0, -1, false)
  for i = 1, #all - #r.lines + 1 do
    if vim.deep_equal(vim.list_slice(all, i, i + #r.lines - 1), r.lines) then
      local er = i + #r.lines - 2
      r.mark = vim.api.nvim_buf_set_extmark(r.buf, NS, i - 1, 0, { id = r.mark, end_row = er, end_col = #all[er + 1] })
      return i - 1, 0, er, #all[er + 1]
    end
  end
end

-- While the agent works on a request, or has a comment's reply not yet read, its highlight breathes
-- between the background and blue.
local function any_pending()
  for _, r in pairs(reqs) do
    if r.pending then
      return true
    end
  end
  for _, items in pairs(comments) do
    for _, item in ipairs(items) do
      if item.pending or item.fresh then
        return true
      end
    end
  end
end

local function blend(a, b, t)
  local function channel(c, shift)
    return math.floor(c / 2 ^ shift) % 256
  end
  local out = 0
  for _, shift in ipairs({ 16, 8, 0 }) do
    out = out + math.floor(channel(a, shift) + (channel(b, shift) - channel(a, shift)) * t + 0.5) * 2 ^ shift
  end
  return out
end

function M.pulse_tick()
  if not any_pending() then
    state.pulse:stop()
    state.pulse:close()
    state.pulse = nil
    return
  end
  state.phase = (state.phase or 0) + 1
  state.spin = (state.spin or 0) + 1
  local t = (1 - math.cos(state.phase * math.pi / 10)) / 2
  local bg = vim.api.nvim_get_hl(0, { name = "Normal" }).bg or 0x1e1e1e
  vim.api.nvim_set_hl(0, "IcarusAskedPulse", { bg = blend(bg, T.pulse, 0.15 + 0.85 * t) })
  -- The comments that are waiting or pulsing are drawn again, so their spinner and pulse move.
  for buf, items in pairs(comments) do
    for _, item in ipairs(items) do
      if (item.pending or item.fresh) and vim.api.nvim_buf_is_valid(buf) then
        draw(buf, item)
      end
    end
  end
end

local function start_pulse()
  if state.pulse then
    return
  end
  state.pulse = assert(vim.uv.new_timer())
  state.pulse:start(0, 80, vim.schedule_wrap(function()
    require("icarus.watch").pulse_tick()
  end))
end

local function draw_req(r)
  local sr, sc, er, ec = req_range(r)
  if r.shown then
    pcall(vim.api.nvim_buf_del_extmark, r.buf, NS, r.shown)
    r.shown = nil
  end
  if not sr then
    return
  end
  -- A proposal's new lines, drawn under the struck ones, without za.
  if r.proposal and r.proposal.text and vim.api.nvim_buf_is_valid(r.buf) then
    local rows = {}
    for line in (r.proposal.text .. "\n"):gmatch("(.-)\n") do
      rows[#rows + 1] = { { line, "IcarusProposedNew" } }
    end
    r.shown = vim.api.nvim_buf_set_extmark(r.buf, NS, er, 0, { virt_lines = rows })
  end
  local opts = { id = r.mark, end_row = er, end_col = ec, hl_group = "IcarusAsked" }
  if r.pending then
    opts.hl_group = "IcarusAskedPulse"
    opts.virt_text, opts.virt_text_pos = { { ("  %s is working…"):format(short_name(r.chat)), "IcarusProposedHint" } }, "eol"
  elseif r.proposal then
    opts.hl_group = r.proposal.text and "IcarusProposedOld" or "IcarusAsked"
    opts.virt_text = { { ("  ▸ za %s from %s"):format(r.proposal.text and "proposal" or "note", short_name(r.chat)),
      "IcarusCommentHint" } }
    opts.virt_text_pos = "eol"
  end
  r.mark = vim.api.nvim_buf_set_extmark(r.buf, NS, sr, sc, opts)
end

local function close_req(r)
  pcall(vim.api.nvim_buf_del_extmark, r.buf, NS, r.mark)
  pcall(vim.api.nvim_buf_del_extmark, r.buf, NS, r.shown or 0)
  reqs[r.id] = nil
end

-- A proposal coming in replaces any that overlaps it, waiting or not, so two are never on the same
-- lines; keep is the one coming in.
local function clear_overlaps(buf, sr, er, keep)
  for _, r in pairs(reqs) do
    if r ~= keep and r.buf == buf then
      local from, _, to = req_range(r)
      if from and from <= er and to >= sr then
        close_req(r)
      end
    end
  end
end

-- Sends the request to the agent, with message, and what it proposed before if it's a reply.
---@param label? string what the chat shows for it, after "◉ "
local function emit(r, message, label)
  r.chat = r.chat or (watched[r.buf] and watched[r.buf].chat) or require("icarus").current()
  local agent = session(r.chat)
  local sr, sc, er, ec = req_range(r)
  if not (agent and sr) then
    vim.notify("No agent to ask: open a chat first", vim.log.levels.WARN)
    return close_req(r)
  end
  local selection = table.concat(vim.api.nvim_buf_get_text(r.buf, sr, sc, er, ec, {}), "\n")
  local text = {
    ("Request %s on %s, line %d%s. They selected:"):format(r.id, vim.api.nvim_buf_get_name(r.buf), sr + 1,
      er > sr and ("-" .. (er + 1)) or ""),
    "```",
    selection,
    "```",
    message ~= "" and ("Their message: " .. message) or "No message: work out what they want from the selection.",
  }
  if r.proposal then
    vim.list_extend(text, { "This is a reply to what you proposed:", "```", r.proposal.text or "", "```" })
    if r.proposal.note then
      text[#text + 1] = "with the note: " .. r.proposal.note
    end
  end
  text[#text + 1] = ("Answer in the buffer: `ica propose %s [--note <text>] <replacement...|->` puts the selection's new text up for them to accept; with --note alone it's a note. Keep notes short."):format(r.id)
  agent:prompt(table.concat(text, "\n"), nil, ("◉ %s on %s:%d%s"):format(label and label[1] or "ask", name(r.buf), sr + 1,
    (label and label[2] or message) ~= "" and (": " .. (label and label[2] or message)) or ""))
  r.pending, r.frozen, r.proposal = true, selection, nil
  draw_req(r)
  start_pulse()
end

-- A pending request's text is frozen: an edit that reaches it is put back.
local function guard(buf)
  for _, r in pairs(reqs) do
    if r.buf == buf and r.pending then
      local pos = vim.api.nvim_buf_get_extmark_by_id(buf, NS, r.mark, { details = true })
      if pos[1] then
        local now = table.concat(vim.api.nvim_buf_get_text(buf, pos[1], pos[2], pos[3].end_row, pos[3].end_col, {}), "\n")
        if now ~= r.frozen then
          local lines = vim.split(r.frozen, "\n", { plain = true })
          vim.api.nvim_buf_set_text(buf, pos[1], pos[2], pos[3].end_row, pos[3].end_col, lines)
          local er = pos[1] + #lines - 1
          local ec = (#lines == 1 and pos[2] or 0) + #lines[#lines]
          vim.api.nvim_buf_set_extmark(buf, NS, pos[1], pos[2], { id = r.mark, end_row = er, end_col = ec })
          draw_req(r)
          vim.notify("Claude is working on that part", vim.log.levels.WARN)
        end
      end
    end
  end
end

local function req_at_cursor(buf)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  for _, r in pairs(reqs) do
    if r.buf == buf and r.proposal then
      local sr, _, er = req_range(r)
      if sr and row >= sr and row <= er then
        return r
      end
    end
  end
end

-- <leader>a on a selection: asks the agent about it.
function M.ask()
  local buf = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  vim.cmd("normal! \27")
  local from, to = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  local sr, sc, er = from[2] - 1, from[3] - 1, to[2] - 1
  local last = vim.api.nvim_buf_get_lines(buf, er, er + 1, false)[1] or ""
  local ec
  if mode == "V" then
    sc, ec = 0, #last
  else
    ec = math.min(#last, to[3] + vim.str_utf_end(last, math.min(to[3], #last)))
  end
  local chat = watched[buf] and watched[buf].chat or require("icarus").current()
  local r = { id = tostring(os.time()) .. tostring(math.random(100, 999)), buf = buf, chat = chat }
  r.lines = vim.api.nvim_buf_get_lines(buf, sr, er + 1, false)
  r.mark = vim.api.nvim_buf_set_extmark(buf, NS, sr, sc, { end_row = er, end_col = ec, hl_group = "IcarusAsked" })
  reqs[r.id] = r
  M.attach(buf)
  vim.ui.input({ prompt = "Ask Claude (optional): " }, function(message)
    if message == nil then
      return close_req(r)
    end
    emit(r, message)
  end)
end

-- The proposal or comment under the cursor; r or item when called from its float.
function M.accept(r)
  r = r or req_at_cursor(vim.api.nvim_get_current_buf())
  if not (r and r.proposal and r.proposal.text) then
    return
  end
  local sr, sc, er, ec = req_range(r)
  if sr then
    local clean = not vim.bo[r.buf].modified and vim.bo[r.buf].buftype == ""
    vim.api.nvim_buf_set_text(r.buf, sr, sc, er, ec, vim.split(r.proposal.text, "\n", { plain = true }))
    -- Taken, it's on disk: an agent reads it there, and a reload can't lose it. Edits of yours not
    -- saved yet stay yours to save.
    if clean then
      require("icarus.tasks").save(r.buf)
    end
  end
  close_req(r)
end

function M.dismiss(r, item)
  local buf = r and r.buf or item and item.buf or vim.api.nvim_get_current_buf()
  if not (r or item) then
    r = req_at_cursor(buf)
    item = not r and comment_at_cursor(buf)
  end
  if r then
    return close_req(r)
  end
  if item then
    pcall(vim.api.nvim_buf_del_extmark, buf, NS, item.mark)
    comments[buf] = vim.tbl_filter(function(each)
      return each ~= item
    end, comments[buf])
    save(buf)
  end
end

function M.reply(r)
  r = r or req_at_cursor(vim.api.nvim_get_current_buf())
  if not r then
    return
  end
  vim.ui.input({ prompt = "Reply to Claude: " }, function(message)
    if message and message ~= "" then
      emit(r, message)
    end
  end)
end

local ADJUST = {
  ["+"] = { "More detail (optional): ", "Elaborate: say more, with more detail and reasoning.", "more" },
  ["-"] = { "Fewer words (optional): ", "Make it more concise: the same in fewer words.", "less" },
}

-- Asks the agent to rewrite its comment in place.
local function rewrite(item, instruction, label)
  local buf = item.buf
  item.id = item.id or new_id()
  item.chat = item.chat or (watched[buf] and watched[buf].chat) or require("icarus").current()
  local agent = session(item.chat)
  local row = row_of(buf, item)
  if not (agent and row) then
    return vim.notify("No agent to ask: open a chat first", vim.log.levels.WARN)
  end
  local path = vim.api.nvim_buf_get_name(buf)
  agent:prompt(table.concat({
    ("Your comment %s on %s, line %d (%s):"):format(item.id, path, row + 1, item.anchor),
    "```",
    item.text,
    "```",
    instruction,
    ("Rewrite it in place: `ica comment %s --replaces %s <new comment...|->`."):format(path, item.id),
  }, "\n"), nil, ("◉ %s on %s:%d%s"):format(label[1], name(buf), row + 1, label[2] ~= "" and (": " .. label[2]) or ""))
  item.pending = "rewriting"
  draw(buf, item)
end

-- <leader>+ and <leader>-: more detail or fewer words, from the proposal or comment under the
-- cursor, or r or item from its float.
---@param direction "+"|"-"
function M.adjust(direction, r, item)
  local buf = vim.api.nvim_get_current_buf()
  if not (r or item) then
    r = req_at_cursor(buf)
    item = not r and comment_at_cursor(buf)
  end
  if item then
    item.buf = item.buf or buf
  end
  if not (r or item) then
    return
  end
  local ask = ADJUST[direction]
  vim.ui.input({ prompt = ask[1] }, function(message)
    if message == nil then
      return
    end
    message = vim.trim(message)
    local instruction = ask[2] .. (message ~= "" and (" Their message: " .. message) or "")
    if r then
      emit(r, instruction, { ask[3], message })
    else
      rewrite(item, instruction, { ask[3], message })
    end
  end)
end

-- What's already open in buf, for an agent that starts watching it again and can't see them.
function M.open_notes(buf)
  local lines = {}
  for _, r in pairs(reqs) do
    local sr, er
    if r.buf == buf then
      sr, _, er = req_range(r)
    end
    if sr then
      local where = er > sr and ("lines %d-%d"):format(sr + 1, er + 1) or ("line %d"):format(sr + 1)
      lines[#lines + 1] = r.pending and ("- a request on %s (id %s), waiting on you"):format(where, r.id)
        or ("- your proposal on %s (id %s), waiting on them"):format(where, r.id)
    end
  end
  for _, item in ipairs(comments[buf] or {}) do
    local row = row_of(buf, item)
    if row then
      lines[#lines + 1] = ("- your comment on line %d (id %s): %s"):format(row + 1, item.id or "?", item.text:gsub("\n", " "):sub(1, 80))
    end
  end
  if #lines == 0 then
    return "Nothing of yours is open in it."
  end
  table.sort(lines)
  return "Already open in it, still there (don't propose or comment them again; a new proposal on the same lines replaces the old):\n"
    .. table.concat(lines, "\n")
end

-- The float showing a comment or proposal, under its line or over it, as tall as its text wraps to
-- and as the window has room for; the cursor goes into it.
local function open_float(lines, marks, actions)
  local win = vim.api.nvim_get_current_win()
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[fbuf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(fbuf, NS, mark[1], 0, { end_row = mark[1], end_col = #lines[mark[1] + 1], hl_group = mark[2] })
  end
  vim.bo[fbuf].modifiable = false
  local cols = math.max(20, vim.api.nvim_win_get_width(win) - 4)
  local float = vim.api.nvim_open_win(fbuf, false, { relative = "cursor", row = 1, col = 0, width = cols, height = 1,
    style = "minimal", border = "rounded" })
  vim.wo[float].wrap, vim.wo[float].linebreak = true, true
  vim.wo[float].winhighlight = "Normal:Normal,FloatBorder:IcarusCommentHint"
  local height = vim.api.nvim_win_text_height(float, {}).all
  local line = vim.fn.winline()
  local below, above = vim.api.nvim_win_get_height(win) - line - 2, line - 3
  local config
  if height <= below or below >= above then
    config = { row = 1, height = math.max(1, math.min(height, below)) }
  else
    config = { row = -math.min(height, above) - 2, height = math.max(1, math.min(height, above)) }
  end
  vim.api.nvim_win_set_config(float, vim.tbl_extend("force", { relative = "cursor", col = -(vim.fn.wincol() - 1) + 1 }, config))
  vim.api.nvim_set_current_win(float)
  local function close()
    if vim.api.nvim_win_is_valid(float) then
      vim.api.nvim_win_close(float, true)
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
    end
  end
  for _, lhs in ipairs({ "q", "za", "<Esc>" }) do
    vim.keymap.set("n", lhs, close, { buffer = fbuf, nowait = true, desc = "Close" })
  end
  for lhs, action in pairs(actions) do
    vim.keymap.set("n", lhs, function()
      close()
      action[1]()
    end, { buffer = fbuf, nowait = true, desc = action[2] })
  end
  vim.api.nvim_create_autocmd("WinLeave", { buffer = fbuf, once = true, callback = function()
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(float) then
        vim.api.nvim_win_close(float, true)
      end
    end)
  end })
end

-- za: opens the comment or proposal on the cursor's line in its float. False when there's none.
function M.peek()
  local buf = vim.api.nvim_get_current_buf()
  local r = req_at_cursor(buf)
  if r then
    local lines, marks = {}, {}
    if r.proposal.note then
      vim.list_extend(lines, vim.split(r.proposal.note, "\n", { plain = true }))
      for i = 1, #lines do
        marks[#marks + 1] = { i - 1, "IcarusCommentBody" }
      end
    end
    if r.proposal.text then
      if #lines > 0 then
        lines[#lines + 1] = ""
      end
      for each in (r.proposal.text .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = "+ " .. each
        marks[#marks + 1] = { #lines - 1, "IcarusProposedNew" }
      end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = (r.proposal.text and "<leader>y accept · " or "") .. "<leader>n dismiss · <leader>c reply · <leader>+ more · <leader>- less · q close"
    marks[#marks + 1] = { #lines - 1, "IcarusProposedHint" }
    local actions = {
      ["<leader>n"] = { function()
        M.dismiss(r)
      end, "Dismiss Claude's proposal" },
      ["<leader>c"] = { function()
        M.reply(r)
      end, "Reply to Claude's proposal" },
    }
    if r.proposal.text then
      actions["<leader>y"] = { function()
        M.accept(r)
      end, "Accept Claude's proposal" }
    end
    actions["<leader>+"] = { function()
      M.adjust("+", r)
    end, "Ask for more detail" }
    actions["<leader>-"] = { function()
      M.adjust("-", r)
    end, "Ask for fewer words" }
    open_float(lines, marks, actions)
    return true
  end
  local item = comment_at_cursor(buf)
  if not item then
    return false
  end
  item.buf = buf
  if item.fresh then
    item.fresh = nil
    draw(buf, item)
  end
  local lines, marks = {}, {}
  for i, entry in ipairs(M.thread(item)) do
    if i > 1 then
      lines[#lines + 1] = ""
    end
    local group = entry.who == "you" and "IcarusCommentYouBody" or "IcarusCommentBody"
    for j, each in ipairs(vim.split(entry.text, "\n", { plain = true })) do
      lines[#lines + 1] = (j == 1 and (entry.who == "you" and "you: "
        or (agent_name(entry.chat or (i == 1 and item.chat)) .. ": ")) or "") .. each
      marks[#marks + 1] = { #lines - 1, group }
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "<leader>c reply · <leader>n dismiss · <leader>+ more · <leader>- less · q close"
  marks[#marks + 1] = { #lines - 1, "IcarusProposedHint" }
  open_float(lines, marks, {
    ["<leader>c"] = { function()
      M.reply_comment(item)
    end, "Reply in the thread" },
    ["<leader>n"] = { function()
      M.dismiss(nil, item)
    end, "Dismiss the comment" },
    ["<leader>+"] = { function()
      M.adjust("+", nil, item)
    end, "Ask for more detail" },
    ["<leader>-"] = { function()
      M.adjust("-", nil, item)
    end, "Ask for fewer words" },
  })
  return true
end

-- A comment's thread: who said what, oldest first. One from before threads is the agent's, alone.
function M.thread(item)
  return item.thread or { { who = item.who or "claude", text = item.text } }
end

-- Sends the agent your comment, or your reply in a comment's thread.
local function tell(item, opening)
  local buf = item.buf
  item.chat = item.chat or (watched[buf] and watched[buf].chat) or require("icarus").current()
  local agent = session(item.chat)
  local row = row_of(buf, item)
  if not (agent and row) then
    return vim.notify("No agent to tell: open a chat first", vim.log.levels.WARN)
  end
  local path = vim.api.nvim_buf_get_name(buf)
  local text = {}
  if opening then
    text[1] = ("They commented on line %d of %s (%s), comment %s:"):format(row + 1, path, item.anchor, item.id)
    text[2] = M.thread(item)[1].text
  else
    text[1] = ("They replied in the thread of comment %s on line %d of %s (%s). The thread:"):format(item.id, row + 1, path,
      item.anchor)
    for _, entry in ipairs(M.thread(item)) do
      text[#text + 1] = ("%s: %s"):format(entry.who == "you" and "them" or "you", entry.text)
    end
  end
  text[#text + 1] = ("Answer in the thread: `ica comment %s --reply %s <reply...|->`; or, when the answer is an edit, propose it."):format(path, item.id)
  local last = M.thread(item)[#M.thread(item)].text:match("^[^\n]*")
  agent:prompt(table.concat(text, "\n"), nil, ("◉ %s on %s:%d: %s"):format(opening and "comment" or "reply", name(buf), row + 1,
    vim.fn.strcharpart(last, 0, 60)))
  item.pending = "replying"
  draw(buf, item)
  start_pulse()
end

-- <leader>c on a line with nothing on it, in a watched file: a comment of yours there.
function M.comment_line(buf)
  if not watched[buf] then
    return vim.notify("Watch it first (<leader>w): comments go to the agent watching it", vim.log.levels.WARN)
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  vim.ui.input({ prompt = "Comment: " }, function(text)
    if not text or vim.trim(text) == "" then
      return
    end
    M.attach(buf)
    local item = { id = new_id(), buf = buf, who = "you", anchor = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "",
      text = text, thread = { { who = "you", text = text } } }
    item.mark = vim.api.nvim_buf_set_extmark(buf, NS, row, 0, {})
    table.insert(comments[buf], item)
    draw(buf, item)
    save(buf)
    tell(item, true)
  end)
end

-- <leader>c on a comment: your reply in its thread.
function M.reply_comment(item)
  vim.ui.input({ prompt = "Reply: " }, function(text)
    if not text or vim.trim(text) == "" then
      return
    end
    item.thread = M.thread(item)
    table.insert(item.thread, { who = "you", text = text })
    item.fresh = nil
    draw(item.buf, item)
    save(item.buf)
    tell(item, false)
  end)
end

local function set_key(buf, lhs, fn, desc)
  if fn then
    vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc })
  else
    pcall(vim.keymap.del, "n", lhs, { buffer = buf })
  end
end

-- The proposal and comment keys, only while the cursor is on one.
local function keys(buf)
  if vim.api.nvim_get_current_buf() ~= buf then
    return
  end
  local r = req_at_cursor(buf)
  local item = not r and comment_at_cursor(buf)
  set_key(buf, "<leader>y", r and r.proposal.text and function()
    M.accept()
  end, "Accept Claude's proposal")
  set_key(buf, "<leader>c", function()
    local here_r = req_at_cursor(buf)
    local here = not here_r and comment_at_cursor(buf)
    if here_r then
      M.reply()
    elseif here then
      here.buf = buf
      M.reply_comment(here)
    else
      M.comment_line(buf)
    end
  end, r and "Reply to Claude's proposal" or item and "Reply in the comment's thread" or "Comment on this line")
  set_key(buf, "<leader>n", (r or item) and function()
    M.dismiss()
  end, r and "Dismiss Claude's proposal" or "Dismiss Claude's comment")
  set_key(buf, "<leader>+", (r or item) and function()
    M.adjust("+")
  end, "Ask Claude for more detail")
  set_key(buf, "<leader>-", (r or item) and function()
    M.adjust("-")
  end, "Ask Claude for fewer words")
end

-- Gives buf its comments (read from its store the first time), za, <leader>a and the keys above.
function M.attach(buf)
  if not comments[buf] then
    comments[buf] = {}
    local file = store_file(buf)
    if vim.fn.filereadable(file) == 1 then
      local ok, items = pcall(vim.json.decode, table.concat(vim.fn.readfile(file), "\n"))
      local missing = false
      for _, item in ipairs(ok and type(items) == "table" and items or {}) do
        missing = missing or not item.id
        table.insert(comments[buf], { id = item.id or new_id(), anchor = item.anchor, text = item.text, chat = item.chat,
          who = item.who, thread = item.thread })
      end
      -- Ids given here are written at once, so a comment has the same id however often it's read.
      if missing then
        save(buf)
      end
    end
  end
  vim.keymap.set("n", "za", function()
    if not require("icarus.watch").peek() then
      pcall(vim.cmd, "normal! za")
    end
  end, { buffer = buf, desc = "Open Claude's comment or proposal, else fold" })
  vim.keymap.set("x", "<leader>a", function()
    if not require("icarus.portal").reference() then
      require("icarus.watch").ask()
    end
  end, { buffer = buf, desc = "The selection to the router's portal, or ask Claude about it" })
  vim.keymap.set("n", "<leader>*", function()
    require("icarus.watch").full_read(buf)
  end, { buffer = buf, desc = "Read the whole file to Claude now" })
  local group = vim.api.nvim_create_augroup("icarus_comments_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, { group = group, buffer = buf, callback = function()
    keys(buf)
  end })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { group = group, buffer = buf, callback = function()
    guard(buf)
    redraw(buf)
  end })
  redraw(buf)
  for _, r in pairs(reqs) do
    if r.buf == buf then
      draw_req(r)
    end
  end
  keys(buf)
end

-- A file with comments kept from before gets them as it's opened.
local GROUP = vim.api.nvim_create_augroup("icarus_comments", { clear = true })
vim.api.nvim_create_autocmd("BufReadPost", { group = GROUP, callback = function(ev)
  if vim.bo[ev.buf].buftype == "" and (comments[ev.buf] or vim.fn.filereadable(store_file(ev.buf)) == 1) then
    require("icarus.watch").reread(ev.buf)
    require("icarus.watch").attach(ev.buf)
  end
end })
-- Read again from disk (an agent wrote the file): its comments and proposals found on their lines.
vim.api.nvim_create_autocmd("FileChangedShellPost", { group = GROUP, callback = function(ev)
  if comments[ev.buf] then
    require("icarus.watch").reread(ev.buf)
    require("icarus.watch").attach(ev.buf)
  end
end })
vim.api.nvim_create_autocmd("ColorScheme", { group = GROUP, callback = highlights })
vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, { group = GROUP, pattern = "*.md", callback = function(ev)
  require("icarus.watch").follow(ev.buf)
end })

-- Watching

local log_edit

-- Commits what's new in buf to the log.
local function record(buf, watch)
  local now = content(buf)
  if now ~= watch.logged then
    watch.logged = now
    log_edit(buf, now)
  end
end

-- What the user changed in the files chat_id watches since it last saw them, as text to go with its
-- next turn (icarus.acp.session); each file then counts as seen.
function M.catch_up(chat_id)
  local parts = {}
  for buf, watch in pairs(watched) do
    if watch.chat == chat_id and vim.api.nvim_buf_is_valid(buf) then
      local now = content(buf)
      record(buf, watch)
      if now ~= watch.base then
        local diff = (vim.text and vim.text.diff or vim.diff)(watch.base, now, { ctxlen = 2 }) --[[@as string]]
        if vim.trim(diff) ~= "" then
          parts[#parts + 1] = ("Meanwhile the user edited %s (line numbers are its new ones):\n```diff\n%s```"):format(
            vim.api.nvim_buf_get_name(buf), diff)
        end
        watch.base, watch.sent_base = now, now
      end
    end
  end
  return #parts > 0 and table.concat(parts, "\n\n") or nil
end

-- Commits buf's text to ~/.icarus/edits, one file per watched file at its own path, so a change
-- nobody saved is still in its history. The message says whether the buffer was saved.
log_edit = function(buf, text)
  local rel = vim.api.nvim_buf_get_name(buf):gsub("^/", "")
  local file = EDITS .. "/" .. rel
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  if vim.fn.isdirectory(EDITS .. "/.git") == 0 then
    vim.system({ "git", "-C", EDITS, "init", "-q" }):wait()
  end
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), file)
  local message = ("%s: %s"):format(vim.bo[buf].modified and "unsaved" or "saved", rel)
  local identity = { "git", "-C", EDITS, "-c", "user.name=icarus", "-c", "user.email=icarus@localhost" }
  vim.system(vim.list_extend(vim.list_extend({}, identity), { "add", "--", rel }), {}, vim.schedule_wrap(function()
    -- Nothing to commit (the same text as last time) exits non-zero, which is fine.
    vim.system(vim.list_extend(vim.list_extend({}, identity), { "commit", "-q", "-m", message, "--", rel }))
  end))
end

-- A new @claude line sends the agent what changed since it last saw buf, or adds to the diff still
-- waiting. Any other edit waits for the agent's next turn (M.catch_up).
function M.flush(buf)
  local watch = watched[buf]
  if not watch or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local now = content(buf)
  if now == watch.base then
    return
  end
  local asked = false
  for _, line in ipairs(vim.split(now, "\n", { plain = true })) do
    if line:find("@claude", 1, true) and not watch.base:find(line, 1, true) then
      asked = true
    end
  end
  if not asked then
    return
  end
  local agent = session(watch.chat)
  if not agent then
    return M.stop(buf)
  end
  -- Still waiting, and not taken out of the queue by hand (icarus.acp.queue).
  local pending = watch.pending and not watch.pending.sent and vim.tbl_contains(agent.queue, watch.pending) and watch.pending
  local diff = (vim.text and vim.text.diff or vim.diff)(pending and watch.sent_base or watch.base, now, { ctxlen = 2 }) --[[@as string]]
  local added, removed = 0, 0
  for line in diff:gmatch("[^\n]+") do
    if line:match("^%+") then
      added = added + 1
    elseif line:match("^%-") then
      removed = removed + 1
    end
  end
  local text = ("%s changed (line numbers are its new ones):\n```diff\n%s```"):format(vim.api.nvim_buf_get_name(buf), diff)
  local display = ("◉ %s  +%d −%d"):format(name(buf), added, removed)
  if pending then
    pending.text, pending.display = text, display
  else
    watch.sent_base = watch.base
    watch.pending = agent:prompt(text, nil, display)
  end
  watch.base = now
end

-- <leader>*: reads buf now. Its edits are logged, and the agent gets the whole buffer, numbered, as
-- the new base its next diffs are against.
function M.full_read(buf)
  local watch = watched[buf]
  if not watch then
    return vim.notify("Watch it first (<leader>w)", vim.log.levels.WARN)
  end
  record(buf, watch)
  local agent = session(watch.chat)
  if not agent then
    return M.stop(buf)
  end
  local now = content(buf)
  agent:prompt(("Full read of %s, as the user has it now (line numbers are its):\n```\n%s\n```"):format(
    vim.api.nvim_buf_get_name(buf), numbered(buf)), nil, ("◉ read %s"):format(name(buf)))
  watch.base, watch.sent_base = now, now
end

-- A file is the user's, not its watcher's: any agent on it may comment and propose there, each
-- marked with its name, and the user's replies in a thread go to the agent that started it. Watching
-- only decides whose turns carry the user's edits.

-- The open threads in the files under dir: {path, line, id, by, last}, from the buffers loaded
-- (where they are now) and the comments kept for the rest.
function M.threads_under(dir)
  local out, seen = {}, {}
  for buf, items in pairs(comments) do
    local path = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) or ""
    if vim.startswith(path, dir) then
      seen[path] = true
      for _, item in ipairs(items) do
        local row = row_of(buf, item)
        out[#out + 1] = { path = path, line = row and row + 1, item = item, owner = M.owner(buf) }
      end
    end
  end
  for name_, kind in vim.fs.dir(STORE) do
    local path = kind == "file" and name_:gsub("%.json$", ""):gsub("%%", "/")
    if path and vim.startswith(path, dir) and not seen[path] then
      local ok, items = pcall(vim.json.decode, table.concat(vim.fn.readfile(STORE .. "/" .. name_), "\n"))
      for _, item in ipairs(ok and type(items) == "table" and items or {}) do
        out[#out + 1] = { path = path, item = item }
      end
    end
  end
  return out
end

-- How many comments and how many proposals buf has open, for the statusline.
function M.counts(buf)
  local proposals = 0
  for _, r in pairs(reqs) do
    if r.buf == buf and r.proposal then
      proposals = proposals + 1
    end
  end
  return #(comments[buf] or {}), proposals
end

-- Everything of the agent from's goes to the agent to: its comment threads, here or kept on disk, and
-- its proposals (icarus.democracy's merge).
function M.reassign(from, to)
  local function swap(item)
    item.chat = item.chat == from and to or item.chat
    for _, entry in ipairs(type(item.thread) == "table" and item.thread or {}) do
      entry.chat = entry.chat == from and to or entry.chat
    end
  end
  local loaded = {}
  for buf, items in pairs(comments) do
    if vim.api.nvim_buf_is_valid(buf) then
      loaded[store_file(buf)] = true
      vim.tbl_map(swap, items)
      save(buf)
    end
  end
  for _, r in pairs(reqs) do
    r.chat = r.chat == from and to or r.chat
  end
  for file, kind in vim.fs.dir(STORE) do
    local path = STORE .. "/" .. file
    if kind == "file" and not loaded[path] then
      local ok, items = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
      if ok and type(items) == "table" then
        vim.tbl_map(swap, items)
        vim.fn.writefile({ vim.json.encode(items) }, path)
      end
    end
  end
end

-- The agent chat_id stops watching whatever it watches.
-- The agent's turn ended with nothing queued: a comment it answered with a proposal, or not at all,
-- stops waiting, so its spinner and the timer behind it don't run forever.
function M.turn_ended(chat_id)
  for buf, items in pairs(comments) do
    for _, item in ipairs(items) do
      if item.pending and item.chat == chat_id and vim.api.nvim_buf_is_valid(buf) then
        item.pending = nil
        draw(buf, item)
      end
    end
  end
end

function M.release(chat_id)
  for buf, watch in pairs(watched) do
    if watch.chat == chat_id then
      M.stop(buf)
    end
  end
end

-- The proposals waiting on the user in the files under dir: {path, line, id, chat, note}.
function M.proposals_under(dir)
  local out = {}
  for _, r in pairs(reqs) do
    local path = vim.api.nvim_buf_is_valid(r.buf) and vim.api.nvim_buf_get_name(r.buf) or ""
    if r.proposal and vim.startswith(path, dir) then
      local sr = req_range(r)
      out[#out + 1] = { path = path, line = sr and sr + 1, id = r.id, chat = r.chat, note = r.proposal.note }
    end
  end
  return out
end

-- Who watches buf, if anyone: its chat id.
function M.owner(buf)
  return watched[buf] and watched[buf].chat
end


local function mark_windows(buf)
  local watch = watched[buf]
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    watch.winbar = watch.winbar or vim.wo[win][0].winbar
    vim.wo[win][0].winbar = (watch.winbar ~= "" and watch.winbar or (" " .. name(buf))) .. "  ◉ watched by "
      .. agent_name(watch.chat):gsub("%%", "%%%%")
  end
end

-- Stops watching buf; its comments and requests stay.
function M.stop(buf)
  local watch = watched[buf]
  if not watch then
    return
  end
  pcall(vim.api.nvim_del_augroup_by_name, "icarus_watch_" .. buf)
  watched[buf] = nil
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.wo[win][0].winbar = watch.winbar or ""
  end
end

-- Your own acts on a watched buffer: leaving insert mode or changing it in normal mode can send an
-- @claude line, and :w logs it.
local function wire(buf)
  local group = vim.api.nvim_create_augroup("icarus_watch_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "InsertLeave", "TextChanged" }, { group = group, buffer = buf, callback = function()
    require("icarus.watch").flush(buf)
  end })
  vim.api.nvim_create_autocmd("BufWritePost", { group = group, buffer = buf, callback = function()
    require("icarus.watch").logged(buf)
  end })
end

function M.logged(buf)
  if watched[buf] then
    record(buf, watched[buf])
  end
end

-- The lead of the router task whose folder holds buf's markdown file, if it is one.
local function lead_of(buf)
  local tasks = require("icarus.tasks")
  local path = vim.api.nvim_buf_get_name(buf)
  local slug, rest = path:sub(#tasks.ROOT + 1):match("^/tasks/([^/]+)/(.+%.md)$")
  if not (slug and vim.startswith(path, tasks.ROOT)) or vim.startswith(rest, "agents/") then
    return nil
  end
  local orchestration = require("icarus.orchestration")
  local task = tasks.read(slug)
  if not task or task.sentinel or orchestration.style(task) ~= "router-worker" then
    return nil
  end
  for _, record in ipairs(require("icarus.chats").on_task(slug)) do
    if orchestration.leads(record) and not record.retired then
      return record.id
    end
  end
end

-- A router task's markdown is its lead's to watch, from whoever had it, with nothing said to anyone:
-- the file's edits simply come with the lead's next turn.
function M.follow(buf)
  local lead = vim.api.nvim_buf_is_valid(buf) and lead_of(buf)
  if not lead or (watched[buf] and watched[buf].chat == lead) then
    return
  end
  M.stop(buf)
  local now = content(buf)
  watched[buf] = { chat = lead, base = now, logged = now }
  wire(buf)
  M.attach(buf)
end

---@param asked? boolean the agent started it itself (ica watch), not the user
function M.start(buf, chat_id, asked)
  local agent = session(chat_id)
  if not agent then
    return
  end
  watched[buf] = { chat = chat_id, base = content(buf), logged = content(buf) }
  local path = vim.api.nvim_buf_get_name(buf)
  agent:prompt(table.concat({
    ("%s %s, the file you and they work in. Their edits come with your next turn, as a diff; a line they"
      .. " write with @claude starts one, as a request to you."):format(asked and "You're watching" or "The user turned on watch for", path),
    "Its lines now:",
    "```",
    numbered(buf),
    "```",
    M.open_notes(buf),
    "They also select text and ask about it, which comes with a request id. Talk about the file in it, not in the chat:",
    ("- `ica comment %s <line|text of the line> <comment...|->` puts a comment on a line, folded until they open it. Keep it short."):format(path),
    ("- They comment too; a comment is a thread, and you answer in one with `ica comment %s --reply <comment id> <reply...|->`. A thread that's answered or moot, resolve: `ica comment %s --resolve <comment id>` (or `--resolve-all-mine`). `ica comments %s` lists what's open."):format(path, path, path),
    ("- `ica propose %s <start> <end> [--note <text>] <replacement...|->` proposes new text for lines start..end, shown as a diff they accept or reject. Use it whenever the answer is an edit: rewriting, filling in, restructuring."):format(path),
    "- `ica propose <request id> [--note <text>] <replacement...|->` answers a selection they asked about.",
    ("- `ica buffer %s` prints it as it is now, numbered, unsaved edits included."):format(path),
  }, "\n"), nil, ("◉ watching %s"):format(name(buf)))
  wire(buf)
  M.attach(buf)
  mark_windows(buf)
end

-- The file you mean: this window's, or from the outline, main's.
local function target()
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= "" then
    return buf
  end
  buf = vim.api.nvim_win_get_buf(require("icarus").main())
  return vim.bo[buf].buftype == "" and buf or nil
end

-- <leader>w: watches the file, with the agent you're on, or stops.
function M.toggle()
  local buf = target()
  if not buf then
    return vim.notify("No file to watch: open one", vim.log.levels.WARN)
  end
  if lead_of(buf) then
    return vim.notify("This task's lead always watches its markdown", vim.log.levels.INFO)
  end
  local chat_id = require("icarus").current()
  if watched[buf] and watched[buf].chat ~= chat_id and chat_id then
    -- Watched by another agent: it goes to this one, the one you're working with now.
    local was = agent_name(watched[buf].chat)
    M.stop(buf)
    M.start(buf, chat_id)
    return vim.notify(("%s is now watched by %s, not %s"):format(name(buf), agent_name(chat_id), was))
  end
  if watched[buf] then
    M.stop(buf)
    return vim.notify("Stopped watching " .. name(buf))
  end
  if not chat_id then
    return vim.notify("No agent to watch it: open a chat first", vim.log.levels.WARN)
  end
  M.start(buf, chat_id)
end

-- The buffer of the file at path, if it's open here; or, asked by an agent whose chat is open here,
-- the file read into one (it's what the agent works in, whether or not it's on screen).
local function loaded(path, chat)
  path = vim.fs.normalize(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == path then
      require("icarus.tasks").refresh(buf)
      return buf
    end
  end
  if chat and (_G.icarus_open_chats or {})[chat] and vim.fn.filereadable(path) == 1 then
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.bo[buf].buflisted = true
    return buf
  end
end

-- ica propose <file> <start> <end>: a proposal for whole lines that nobody asked about by selection.
---@return boolean ok, string result, boolean here
function M.propose_lines(args)
  local buf = loaded(args.path, args.chat)
  if not buf then
    return false, args.path .. " isn't open in this icarus", false
  end
  local count = vim.api.nvim_buf_line_count(buf)
  local first, last = tonumber(args.start), tonumber(args["end"])
  if not (first and last and first >= 1 and last >= first and last <= count) then
    return false, ("no lines %s..%s in %s: it has %d"):format(tostring(args.start), tostring(args["end"]), name(buf), count), true
  end
  local text = args.text ~= "" and args.text or nil
  if not (text or args.note) then
    return false, "a proposal needs new text, a --note, or both", true
  end
  clear_overlaps(buf, first - 1, last - 1)
  local last_line = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ""
  local r = { id = tostring(os.time()) .. tostring(math.random(100, 999)), buf = buf,
    chat = args.chat or (watched[buf] and watched[buf].chat), proposal = { text = text, note = args.note } }
  r.lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
  r.mark = vim.api.nvim_buf_set_extmark(buf, NS, first - 1, 0, { end_row = last - 1, end_col = #last_line })
  reqs[r.id] = r
  M.attach(buf)
  draw_req(r)
  keys(buf)
  return true, "", true
end

-- ica fork: a fork of the agent with args.chat, asked args.text; it goes on as it was.
---@return boolean ok, string result, boolean here
function M.fork(args)
  -- Only the icarus the agent runs in: another has its record (chats.json is shared) but not its
  -- session, and opening the chat there would start a second one.
  local chat = args.chat and _G.icarus_open_chats and _G.icarus_open_chats[args.chat]
  if not chat then
    return false, "chat " .. tostring(args.chat) .. " isn't open in this icarus", false
  end
  local record = chat.record
  local task = record.task and require("icarus.tasks").read(record.task)
  local pin = task and not task.sentinel and task.attrs.workers_model and {
    model = task.attrs.workers_model,
    effort = task.attrs.workers_effort,
  } or nil
  local fork = require("icarus.acp.chat").fork(chat, args.text, nil, function(made)
    vim.notify(("%s forked: %s"):format(record.title or "an agent", made.title))
  end, pin)
  if not fork then
    return false, "your session isn't open yet", true
  end
  return true, "icarus://agent/" .. fork.id, true
end


-- What ica asks of this icarus. here is false when it's not this icarus's to answer (the file isn't
-- open here, or the request isn't from here), so ica tries the next.
---@return boolean ok, string result, boolean here
function M.remote(cmd, args)
  if cmd == "show" then
    return require("icarus.visual").remote(args)
  elseif cmd == "fork" then
    return M.fork(args)
  elseif cmd == "dispatch" then
    return require("icarus.today").remote(args)
  elseif cmd == "portal" then
    return require("icarus.portal").remote(args)
  elseif vim.tbl_contains(require("icarus.democracy").COMMANDS, cmd) then
    return require("icarus.democracy").remote(cmd, args)
  elseif cmd == "merge-task" then
    return require("icarus.messages").merge_task(args)
  elseif cmd == "new-task" then
    return require("icarus.messages").new_task(args)
  elseif cmd == "agents" or cmd == "msg" or cmd == "name" or cmd == "status" or cmd == "link" or cmd == "log" or cmd == "questions" then
    return require("icarus.messages")[cmd](args)
  elseif cmd == "propose" and args.path then
    return M.propose_lines(args)
  elseif cmd == "propose" then
    local r = reqs[args.id]
    if not r then
      return false, "no request " .. tostring(args.id), false
    end
    if r.chat and args.chat and r.chat ~= args.chat then
      return false, ("request %s was sent to %s (icarus://agent/%s), not you"):format(args.id, agent_name(r.chat), r.chat), true
    end
    local text = args.text ~= "" and args.text or nil
    if not (text or args.note) then
      return false, "a proposal needs new text, a --note, or both", true
    end
    r.proposal = { text = text, note = args.note }
    r.pending, r.frozen = false, nil
    local sr, _, er = req_range(r)
    if sr then
      clear_overlaps(r.buf, sr, er, r)
    end
    draw_req(r)
    keys(r.buf)
    return true, "", true
  end
  local buf = loaded(args.path, args.chat)
  if not buf then
    return false, args.path .. " isn't open in this icarus", false
  end
  local owner = M.owner(buf)
  local whose = owner and ("watched by %s (icarus://agent/%s)%s\n"):format(agent_name(owner), owner,
    owner == args.chat and ": you" or "") or "not watched\n"
  if cmd == "watch" then
    if owner == args.chat then
      return true, "you already watch " .. name(buf), true
    elseif owner then
      return false, ("%s is watched by %s (icarus://agent/%s): ask it to `ica unwatch` it, or ask the user"):format(name(buf),
        agent_name(owner), owner), true
    end
    M.start(buf, args.chat, true)
    return true, ("watching %s: the user's edits to it reach you as diffs"):format(name(buf)), true
  end
  if cmd == "unwatch" then
    if owner ~= args.chat then
      return false, owner and ("%s is watched by %s, not you"):format(name(buf), agent_name(owner)) or (name(buf) .. " isn't watched"), true
    end
    M.stop(buf)
    return true, ("stopped watching %s: its threads answer to whoever started them, and other agents may comment again"):format(name(buf)), true
  end
  if cmd == "buffer" then
    return true, whose .. numbered(buf), true
  elseif cmd == "comments" then
    M.attach(buf)
    local out = {}
    for _, item in ipairs(comments[buf] or {}) do
      local row = row_of(buf, item)
      local last = M.thread(item)[#M.thread(item)]
      out[#out + 1] = ("comment %s on line %s (%d in thread, last by %s): %s"):format(item.id, row and row + 1 or "?",
        #M.thread(item), last.who == "you" and "the user" or ((last.chat or item.chat) == args.chat and "you"
          or agent_name(last.chat or item.chat)), (last.text:gsub("\n", " ")):sub(1, 100))
    end
    for _, r in pairs(reqs) do
      local sr, _, er = (function()
        if r.buf == buf then
          return req_range(r)
        end
      end)()
      if sr then
        out[#out + 1] = ("%s %s on lines %d-%d"):format(r.pending and "request" or "proposal", r.id, sr + 1, er + 1)
      end
    end
    return true, whose .. (#out > 0 and table.concat(out, "\n") or "nothing on it"), true
  elseif cmd == "comment" and (args.resolve or args.resolve_all_mine) then
    -- A thread answered or moot: gone from the buffer, as <leader>n would take it.
    M.attach(buf)
    local gone = {}
    for _, item in ipairs(vim.list_slice(comments[buf])) do
      local mine = item.who ~= "you" and args.chat ~= nil and item.chat == args.chat
      if item.id == args.resolve or (args.resolve_all_mine and mine) then
        item.buf = buf
        M.dismiss(nil, item)
        gone[#gone + 1] = item.id
      end
    end
    if args.resolve and #gone == 0 then
      return false, ("no comment %s in %s"):format(args.resolve, name(buf)), true
    end
    return true, #gone > 0 and ("resolved " .. table.concat(gone, ", ")) or "none of yours to resolve", true
  elseif cmd == "comment" and args.reply then
    M.attach(buf)
    for _, item in ipairs(comments[buf]) do
      if item.id == args.reply then
        item.thread = M.thread(item)
        table.insert(item.thread, { who = "claude", chat = args.chat, text = args.text })
        item.pending = nil
        item.fresh = true
        draw(buf, item)
        start_pulse()
        save(buf)
        return true, "", true
      end
    end
    return false, ("no comment %s in %s"):format(args.reply, name(buf)), true
  elseif cmd == "comment" and args.replaces then
    M.attach(buf)
    for _, item in ipairs(comments[buf]) do
      if item.id == args.replaces then
        item.text, item.pending = args.text, nil
        draw(buf, item)
        save(buf)
        return true, "", true
      end
    end
    return false, ("no comment %s in %s"):format(args.replaces, name(buf)), true
  elseif cmd == "comment" then
    local row = tonumber(args.line) and tonumber(args.line) - 1 or find_row(buf, args.line)
    if not row or row < 0 or row >= vim.api.nvim_buf_line_count(buf) then
      local unsaved = vim.b[buf].icarus_disk_differs and " (its file changed on disk under unsaved edits, so the buffer has its own text: ica buffer shows it)" or ""
      return false, ("no line %s in %s%s"):format(args.line, name(buf), unsaved), true
    end
    M.attach(buf)
    local item = { id = new_id(), anchor = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1], text = args.text,
      chat = args.chat }
    item.mark = vim.api.nvim_buf_set_extmark(buf, NS, row, 0, {})
    table.insert(comments[buf], item)
    draw(buf, item)
    save(buf)
    return true, "", true
  end
  return false, "no command " .. cmd, true
end

-- From the watch before this one (a hot reload): its comments, drawn as lines always open, become
-- comments as these are; its proposals, by line number, are dropped; a buffer it watched is polled.
if state.notes then
  for buf, notes in pairs(state.notes) do
    if vim.api.nvim_buf_is_valid(buf) then
      for id, note in pairs(notes) do
        local pos = vim.api.nvim_buf_get_extmark_by_id(buf, NS, id, { details = true })
        if note.kind == "comment" and pos[1] then
          local text = vim.tbl_map(function(line)
            return (line[1][1]:gsub("^  ✻ ", ""):gsub("^    ", ""))
          end, pos[3].virt_lines or {})
          comments[buf] = comments[buf] or {}
          table.insert(comments[buf], { anchor = vim.api.nvim_buf_get_lines(buf, pos[1], pos[1] + 1, false)[1] or "",
            text = table.concat(text, "\n") })
        end
        pcall(vim.api.nvim_buf_del_extmark, buf, NS, id)
        if note.virt then
          pcall(vim.api.nvim_buf_del_extmark, buf, NS, note.virt)
        end
      end
      pcall(vim.keymap.del, "n", "ga", { buffer = buf })
      pcall(vim.keymap.del, "n", "gr", { buffer = buf })
    end
  end
  state.notes = nil
end

-- After a hot reload, the watches run on this code, and a router task's markdown goes to its lead.
for buf, watch in pairs(watched) do
  -- From when a watch had timers.
  if watch.timer then
    watch.timer:stop()
    watch.timer:close()
    watch.timer = nil
  end
  wire(buf)
end
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(buf) then
    M.follow(buf)
  end
end

-- After a hot reload, the buffers that had comments get this code's keys and autocmds, and
-- proposals are drawn as this code draws them.
for buf in pairs(comments) do
  if vim.api.nvim_buf_is_valid(buf) then
    M.attach(buf)
  end
end
-- Proposals that pile up on the same lines, from before a new one replaced the old: the newest stays.
local newest_first = vim.tbl_values(reqs)
table.sort(newest_first, function(a, b)
  return (tonumber(a.id) or 0) > (tonumber(b.id) or 0)
end)
for _, r in ipairs(newest_first) do
  if reqs[r.id] and vim.api.nvim_buf_is_valid(r.buf) then
    local sr, _, er = req_range(r)
    if sr then
      clear_overlaps(r.buf, sr, er, r)
    end
    draw_req(r)
  end
end

return M
