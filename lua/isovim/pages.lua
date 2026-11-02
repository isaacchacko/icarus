-- Pages: markdown a router writes for the user to read and comment on, as design docs are. A page
-- is iso/pages/<name>.md in a repo's iso/ (optional frontmatter as a markdown surface's: name,
-- icon, color), shown read-only as rendered markdown (isovim.surface_view, kind "page"), a plain
-- row under its repo with how many comments are open.
--
-- A page holds no state of its own: comments live beside it, in iso/pages/<name>.comments.jsonl, a
-- comment a line: {id (c1, c2...), quote (the lines it's on, as the page said then), from, to (their
-- lines in the file), heading (the headings above them, "A › B"), text, by, at, status (open or
-- resolved), replies: [{by, text, at, ask?}], resolved_by?, resolved_at?, note?}. A comment the user
-- writes goes to the repo's router as a prompt (iso send), which changes the page wherever the
-- comment asks and resolves it (iso <role> page resolve) with a note of what changed, or replies
-- (iso <role> page reply), --ask for a reply that asks the user something: that page waits on them
-- (needs_you, in the Inbox) until they reply. Their reply goes to the router too.
--
-- In the view an open comment shows where its quote is now, found again by its text after the page
-- changes (the closest match to where it was, then its first line alone, then its heading, else
-- the line it was on): a sign beside its lines and, under them, a dim line with its first line and
-- how many replies, or all of it and its replies once opened (<CR> on it). Keys: c comments on the
-- line, or on the lines selected (v, V; <CR> too), in the input box under the page; a replies to
-- the comment under the cursor; ]c [c go to the next and previous comment; r shows the resolved
-- ones too, dimmed, or hides them again.
local surfaces = require("isovim.surfaces")

local M = {}

M.dirname = "pages"

function M.dir(repo)
  return surfaces.dir(repo) .. "/" .. M.dirname
end

function M.file(repo, name)
  return M.dir(repo) .. "/" .. name .. ".md"
end

function M.comments_file(repo, name)
  return M.dir(repo) .. "/" .. name .. ".comments.jsonl"
end

---@class isovim.PageComment
---@field id string
---@field quote string
---@field from integer
---@field to integer
---@field heading string
---@field text string
---@field by string
---@field at number
---@field status "open"|"resolved"
---@field replies {by: string, text: string, at: number, ask?: boolean}[]
---@field resolved_by? string
---@field resolved_at? number
---@field note? string

-- A page's comments, oldest first, and the file's text (the page's signature takes it in).
---@return isovim.PageComment[] comments, string text
function M.comments(repo, name)
  local file = io.open(M.comments_file(repo, name), "rb")
  local text = file and file:read("*a") or ""
  if file then
    file:close()
  end
  local list = {}
  for line in text:gmatch("[^\n]+") do
    local ok, comment = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(comment) == "table" and type(comment.id) == "string" then
      comment.replies = type(comment.replies) == "table" and comment.replies or {}
      list[#list + 1] = comment
    end
  end
  return list, text
end

-- Whether the comment waits on the user: its last reply asked them something.
function M.waiting(comment)
  local last = comment.replies[#comment.replies]
  return comment.status == "open" and last ~= nil and last.ask == true and last.by ~= "user"
end

-- What the page's row and the Inbox go by: how many comments are open, how many wait on the user.
function M.summary(comments)
  local open, waiting = 0, 0
  for _, comment in ipairs(comments) do
    if comment.status == "open" then
      open = open + 1
      waiting = waiting + (M.waiting(comment) and 1 or 0)
    end
  end
  return open, waiting
end

-- Changes the page's comments with fn(comments) under the repo's surface lock, written whole (to a
-- temp file renamed over); returns what fn returns.
local function update(repo, name, fn)
  return surfaces.locked(repo, function()
    local list = M.comments(repo, name)
    local result, err = fn(list)
    if result == nil then
      return nil, err
    end
    local lines = vim.tbl_map(vim.json.encode, list)
    local path = M.comments_file(repo, name)
    local tmp = ("%s/.%s.%d.tmp"):format(vim.fs.dirname(path), vim.fs.basename(path), vim.uv.os_getpid())
    local file = assert(io.open(tmp, "wb"))
    file:write(#lines > 0 and table.concat(lines, "\n") .. "\n" or "")
    file:close()
    assert(vim.uv.fs_rename(tmp, path))
    return result
  end)
end

local function find(list, id)
  for _, comment in ipairs(list) do
    if comment.id == id then
      return comment
    end
  end
end

-- A new comment on the page; returns it.
---@param spec {quote: string, from: integer, to: integer, heading: string, text: string}
---@return isovim.PageComment
function M.add(repo, name, spec, by)
  return update(repo, name, function(list)
    local n = 0
    for _, comment in ipairs(list) do
      n = math.max(n, tonumber(comment.id:match("^c(%d+)$")) or 0)
    end
    local comment = { id = "c" .. (n + 1), quote = spec.quote, from = spec.from, to = spec.to, heading = spec.heading,
      text = spec.text, by = by or "user", at = os.time(), status = "open", replies = {} }
    list[#list + 1] = comment
    return comment
  end)
end

-- A reply under comment id; ask: it asks the user something, so the page waits on them.
---@return isovim.PageComment? comment, string? err
function M.reply(repo, name, id, by, text, ask)
  return update(repo, name, function(list)
    local comment = find(list, id)
    if not comment then
      return nil, ("%s has no comment %s"):format(name, id)
    end
    comment.replies[#comment.replies + 1] = { by = by, text = text, at = os.time(), ask = ask or nil }
    return comment
  end)
end

-- Resolves comment id, with a note of what changed; it leaves the page (r shows it again).
---@return isovim.PageComment? comment, string? err
function M.resolve(repo, name, id, by, note)
  return update(repo, name, function(list)
    local comment = find(list, id)
    if not comment then
      return nil, ("%s has no comment %s"):format(name, id)
    elseif comment.status == "resolved" then
      return nil, ("%s's %s is resolved already"):format(name, id)
    end
    comment.status, comment.resolved_by, comment.resolved_at, comment.note = "resolved", by, os.time(), note
    return comment
  end)
end

-- Anchoring: where a comment is on the page as it is now.

-- The headings above line n of lines (outside ``` fences), as "A › B".
function M.heading_at(lines, n)
  local stack, fenced = {}, false
  for i = 1, math.min(n, #lines) do
    local line = lines[i]
    if line:match("^%s*```") then
      fenced = not fenced
    elseif not fenced then
      local hashes, title = line:match("^(#+)%s+(.-)%s*#*%s*$")
      if hashes then
        for level = #hashes, #stack do
          stack[level] = nil
        end
        stack[#hashes] = title
      end
    end
  end
  local path = {}
  for level = 1, 6 do
    if stack[level] then
      path[#path + 1] = stack[level]
    end
  end
  return table.concat(path, " › ")
end

-- The lines (first, last; 1-based in lines) a comment is on now, and how it was found: "exact"
-- (its quote, the match closest to where it was), "moved" (its quote's first line alone), "heading"
-- (its heading, the quote gone), "lost" (none of them: the line it was on, kept in the page).
---@return integer first, integer last, string how
function M.anchor(lines, comment, offset)
  local quote = vim.split(comment.quote or "", "\n", { plain = true })
  local was = (comment.from or 1) - (offset or 0)
  local best
  for i = 1, #lines - #quote + 1 do
    local all = true
    for j, line in ipairs(quote) do
      if lines[i + j - 1] ~= line then
        all = false
        break
      end
    end
    if all and (not best or math.abs(i - was) < math.abs(best - was)) then
      best = i
    end
  end
  if best then
    return best, best + #quote - 1, "exact"
  end
  local first = vim.trim(quote[1] or "")
  if first ~= "" then
    for i, line in ipairs(lines) do
      if vim.trim(line) == first and (not best or math.abs(i - was) < math.abs(best - was)) then
        best = i
      end
    end
    if best then
      return best, best, "moved"
    end
  end
  local heading = (comment.heading or ""):match("([^›]+)$")
  heading = heading and vim.trim(heading)
  if heading and heading ~= "" then
    for i, line in ipairs(lines) do
      if line:match("^#+%s+(.-)%s*#*%s*$") == heading then
        return i, i, "heading"
      end
    end
  end
  local at = math.max(1, math.min(was, #lines))
  return at, at, "lost"
end

-- What the router is sent for a new comment, or a reply of the user's.
function M.prompt(repo, name, comment, reply)
  local where = ("%s/%s#%s"):format(repo, name, comment.id)
  if reply then
    return ("[page reply %s] %s\n\n(on your page %s; reply with iso <role> page reply %s %s \"...\" [--ask], resolve with iso <role> page resolve %s %s \"what changed\")")
      :format(where, reply, M.file(repo, name), name, comment.id, name, comment.id)
  end
  local quoted = vim.tbl_map(function(line)
    return "> " .. line
  end, vim.split(comment.quote, "\n", { plain = true }))
  local lines = comment.from == comment.to and ("line %d"):format(comment.from) or ("lines %d-%d"):format(comment.from, comment.to)
  return ("[page comment %s] on %s%s of %s:\n%s\n\n%s\n\n(change the page wherever this asks, then iso <role> page resolve %s %s \"what changed\"; or iso <role> page reply %s %s \"...\" [--ask] to answer or ask the user)")
    :format(where, comment.heading ~= "" and ('"' .. comment.heading .. '" ') or "", lines, M.file(repo, name),
      table.concat(quoted, "\n"), comment.text, name, comment.id, name, comment.id)
end

-- The view (the TUI's): comments drawn on a page's buffer, their keys, the input box's modes.

local NS = vim.api.nvim_create_namespace("isovim_page_comments")
local ICON = "\u{f075}" -- fa-comment

-- Sends text to the repo's router with iso send; on failure, done(false, why).
local function send(view, text, done)
  local reader = require("isovim.surface_view").reader(view.repo)
  if not reader then
    return done(false, view.repo .. " has no router to send to")
  end
  vim.system({ require("isovim.panes").bin, "send", reader, text }, { text = true }, vim.schedule_wrap(function(result)
    done(result.code == 0, vim.trim(result.stderr or ""))
  end))
end

local function short(time)
  return os.date("%b %d %H:%M", time)
end

-- The lines a comment shows under its quote: its first line and how many replies, or (opened) all
-- of it and every reply.
local function note_lines(comment, opened)
  local resolved = comment.status == "resolved"
  local hl = resolved and "Comment" or M.waiting(comment) and "DiagnosticWarn" or "DiagnosticInfo"
  local text = vim.split(comment.text, "\n", { plain = true })
  local tail = #comment.replies > 0 and (" · %d %s"):format(#comment.replies, #comment.replies == 1 and "reply" or "replies") or ""
  if resolved then
    tail = tail .. " · resolved" .. (comment.note and (": " .. comment.note) or "")
  elseif M.waiting(comment) then
    tail = tail .. " · waiting on you (a replies)"
  end
  if not opened then
    return { { { "  " .. ICON .. " " .. comment.id .. " ", hl }, { text[1] .. (#text > 1 and " …" or ""), "Comment" }, { tail, hl } } }
  end
  local lines = { { { "  " .. ICON .. " " .. comment.id .. " ", hl }, { comment.by .. " · " .. short(comment.at), "Comment" }, { tail, hl } } }
  for _, line in ipairs(text) do
    lines[#lines + 1] = { { "    " .. line, "Normal" } }
  end
  for _, reply in ipairs(comment.replies) do
    local say = vim.split(reply.text, "\n", { plain = true })
    lines[#lines + 1] = { { "    ↳ " .. reply.by .. (reply.ask and " asks" or "") .. " · " .. short(reply.at) .. ": ", reply.ask and "DiagnosticWarn" or "Comment" }, { say[1], "Normal" } }
    for i = 2, #say do
      lines[#lines + 1] = { { "      " .. say[i], "Normal" } }
    end
  end
  return lines
end

-- Draws the page's comments on its view (after the page's lines are drawn): each open one (and the
-- resolved, while r shows them) at its anchor. view.placed keeps where each one is, for the keys.
function M.draw(view, entry)
  local buf = view.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  -- The page's own lines, as surface_view drew them before its links became chips: what comments
  -- quote and are found again by.
  local lines = view.source_lines or vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local comments = M.comments(view.repo, view.name)
  view.page_offset = entry and entry.body_line and entry.body_line - 1 or view.page_offset or 0
  view.opened_comments = view.opened_comments or {}
  view.placed = {}
  for _, comment in ipairs(comments) do
    if comment.status == "open" or view.show_resolved then
      local first, last = M.anchor(lines, comment, view.page_offset)
      view.placed[#view.placed + 1] = { comment = comment, first = first, last = last }
      local hl = comment.status == "resolved" and "Comment" or M.waiting(comment) and "DiagnosticWarn" or "DiagnosticInfo"
      for row = first, last do
        vim.api.nvim_buf_set_extmark(buf, NS, row - 1, 0, { sign_text = row == first and ICON or "▎", sign_hl_group = hl })
      end
      vim.api.nvim_buf_set_extmark(buf, NS, last - 1, 0, { virt_lines = note_lines(comment, view.opened_comments[comment.id]) })
    end
  end
  table.sort(view.placed, function(a, b)
    return a.first < b.first
  end)
end

-- The comment under the cursor (on one of its lines), if any.
local function under(view)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for _, placed in ipairs(view.placed or {}) do
    if row >= placed.first and row <= placed.last then
      return placed.comment
    end
  end
end

-- The input box, typing, in a mode: commenting on lines, or replying to a comment.
local function to_input(view, mode)
  view.page_mode = mode
  local win = vim.fn.bufwinid(view.input)
  if win == -1 then
    return
  end
  vim.wo[win][0].winbar = M.winbar(view)
  vim.api.nvim_set_current_win(win)
  vim.cmd.startinsert()
end

-- The input box's title in a mode; nil out of one (surface_view's says where it goes).
function M.winbar(view)
  local mode = view.page_mode
  if not mode then
    return nil
  end
  if mode.reply then
    return (" ↳ reply to %s · <CR> sends · <C-c> cancels"):format(mode.reply)
  end
  local where = mode.from == mode.to and ("line %d"):format(mode.from) or ("lines %d-%d"):format(mode.from, mode.to)
  return (" " .. ICON .. " comment on %s%s · <CR> sends · <C-c> cancels"):format(where,
    mode.heading ~= "" and (" (" .. mode.heading:gsub("%%", "%%%%") .. ")") or "")
end

-- Comments on the lines first..last of the view (1-based rows).
local function comment_on(view, first, last)
  local lines = view.source_lines or vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
  local offset = view.page_offset or 0
  to_input(view, { quote = table.concat(vim.list_slice(lines, first, last), "\n"), from = first + offset,
    to = last + offset, heading = M.heading_at(lines, first) })
end

-- <CR> in the input box while it's in a mode: the comment (or reply) is kept and sent to the
-- router. True when it took the text.
function M.submit(view, text)
  local mode = view.page_mode
  if not mode then
    return false
  end
  local comment, err
  if mode.reply then
    comment, err = M.reply(view.repo, view.name, mode.reply, "user", text)
  else
    comment = M.add(view.repo, view.name, vim.tbl_extend("force", mode, { text = text }), "user")
  end
  if not comment then
    vim.notify("isovim: " .. tostring(err), vim.log.levels.ERROR)
    return true
  end
  view.page_mode = nil
  vim.api.nvim_buf_set_lines(view.input, 0, -1, false, { "" })
  M.draw(view)
  local win = vim.fn.bufwinid(view.input)
  if win ~= -1 then
    vim.wo[win][0].winbar = require("isovim.surface_view").winbar(view)
  end
  send(view, M.prompt(view.repo, view.name, comment, mode.reply and text or nil), function(ok, why)
    if not ok then
      vim.notify(("isovim: %s %s is kept, but its router wasn't told: %s"):format(view.name, comment.id, why), vim.log.levels.WARN)
    end
  end)
  return true
end

-- The page view's keys (surface_view's bind calls this for a page), and the input box's <C-c>.
function M.bind(view)
  require("isovim.links").attach(view.buf)
  local function on(modes, lhs, fn, desc)
    vim.keymap.set(modes, lhs, fn, { buffer = view.buf, nowait = true, desc = "isovim: " .. desc })
  end
  on("n", "c", function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    comment_on(view, row, row)
  end, "comment on this line")
  for _, lhs in ipairs({ "c", "<CR>" }) do
    on("x", lhs, function()
      local a, b = vim.fn.line("v"), vim.fn.line(".")
      vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
      comment_on(view, math.min(a, b), math.max(a, b))
    end, "comment on the lines selected")
  end
  on("n", "<CR>", function()
    local comment = under(view)
    if not comment then
      return to_input(view, nil)
    end
    view.opened_comments[comment.id] = not view.opened_comments[comment.id] or nil
    M.draw(view)
  end, "open or close the comment here (else type to the router)")
  on("n", "a", function()
    local comment = under(view)
    if comment then
      view.opened_comments[comment.id] = true
      M.draw(view)
      return to_input(view, { reply = comment.id })
    end
    to_input(view, nil)
  end, "reply to the comment here (else type to the router)")
  for _, lhs in ipairs({ "i", "o" }) do
    on("n", lhs, function()
      to_input(view, nil)
    end, "type to the repo's router")
  end
  for lhs, dir in pairs({ ["]c"] = 1, ["[c"] = -1 }) do
    on("n", lhs, function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local target
      for _, placed in ipairs(view.placed or {}) do
        if (dir > 0 and placed.first > row and (not target or placed.first < target))
          or (dir < 0 and placed.first < row and (not target or placed.first > target)) then
          target = placed.first
        end
      end
      if target then
        vim.cmd("normal! m'")
        vim.api.nvim_win_set_cursor(0, { target, 0 })
      end
    end, dir > 0 and "the next comment" or "the previous comment")
  end
  on("n", "r", function()
    view.show_resolved = not view.show_resolved or nil
    M.draw(view)
  end, "show or hide the resolved comments")
  vim.keymap.set({ "n", "i" }, "<C-c>", function()
    view.page_mode = nil
    vim.api.nvim_buf_set_lines(view.input, 0, -1, false, { "" })
    vim.cmd.stopinsert()
    local win = vim.fn.bufwinid(view.input)
    if win ~= -1 then
      vim.wo[win][0].winbar = require("isovim.surface_view").winbar(view)
    end
    local page = vim.fn.bufwinid(view.buf)
    if page ~= -1 then
      vim.api.nvim_set_current_win(page)
    end
  end, { buffer = view.input, nowait = true, desc = "isovim: cancel the comment or reply" })
end

-- The page's keys, for the help (`?` in the sidebar).
M.help_keys = {
  { "c (or V/v then c, <CR>)", "comment on the line, or the lines selected, in the box under the page" },
  { "<CR>", "open or close the comment under the cursor: all of it and its replies" },
  { "a", "reply to the comment under the cursor" },
  { "]c / [c", "the next / previous comment" },
  { "r", "show or hide the resolved comments" },
  { "u", "mark the page unread: back in the Inbox until you open it again" },
  { "i o", "type to the repo's router" },
  { "<C-c>", "in the box: cancel the comment or reply" },
}

-- A page's window: room for the comments' signs.
function M.dress(win)
  vim.wo[win][0].signcolumn = "yes:1"
end

return M
