-- A task's portal: one buffer per task that only its router writes, the router's current picture of
-- the task, not a history (the thread keeps that). A task with a router opens to it. Under it is the
-- router's last reply, replaced each turn, and under that the composer (icarus.acp.compose), so what
-- you type goes to the router as in its chat.
--
-- It's kept in the task's .portal/: each write a numbered version, <n>.md, and reply.md the router's
-- last reply. The one writer is `ica portal`, which refuses anyone but the task's lead: free-form
-- markdown, or --layout <name> with "## <section>" parts laid out in the layout's order. [ and ] step
-- to older and newer versions, c quotes the line under the cursor into the composer, and <leader>r
-- goes to the router's thread and back.
--
-- A router's turn that ends without a write is nudged once to write it (M.turn_ended).
local chats = require("icarus.chats")
local tasks = require("icarus.tasks")
local compose = require("icarus.acp.compose")

local M = {}

local NS = vim.api.nvim_create_namespace("icarus_portal")
local QUIET = "·"

-- The default layouts: their sections in order.
M.LAYOUTS = {
  status = { "Where it stands", "Needs you", "Workers", "Open questions", "Links" },
  decision = { "The call", "Options", "Recommendation", "Evidence" },
  board = { "Doing", "Next", "Blocked", "Done" },
}

-- In _G, so a hot reload keeps them: each task's portal buffer and the version it shows (nil: the
-- newest), and per chat the turn it last wrote on and the turn it was nudged for.
_G.icarus_portal = _G.icarus_portal or { bufs = {}, at = {}, wrote = {}, nudged = {} }
local state = _G.icarus_portal

local function dir(slug)
  return tasks.dir(slug) .. "/.portal"
end

-- The task's versions, as numbers, oldest first.
function M.versions(slug)
  local out = {}
  if vim.fn.isdirectory(dir(slug)) == 1 then
    for name in vim.fs.dir(dir(slug)) do
      local n = tonumber(name:match("^(%d+)%.md$"))
      if n then
        out[#out + 1] = n
      end
    end
  end
  table.sort(out)
  return out
end

local function read(path)
  return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or nil
end

-- The task's router: its lead, the open one first.
---@return icarus.ChatRecord?
function M.lead(task)
  if not task or task.sentinel then
    return nil
  end
  local orchestration = require("icarus.orchestration")
  local found
  for _, record in ipairs(chats.on_task(task.slug)) do
    if not record.retired and orchestration.leads(record) then
      if (_G.icarus_open_chats or {})[record.id] then
        return record
      end
      found = found or record
    end
  end
  return found
end

-- text laid out as layout: its "## <section>" parts in the layout's order, a missing one as "—", and
-- any the layout doesn't name after them.
function M.lay_out(layout, text)
  local parts, order, current = {}, {}, nil
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    local heading = line:match("^##%s+(.-)%s*$")
    if heading then
      current = heading:lower()
      if not parts[current] then
        parts[current], order[#order + 1] = { title = heading, lines = {} }, current
      end
    elseif current then
      table.insert(parts[current].lines, line)
    elseif vim.trim(line) ~= "" then
      current = M.LAYOUTS[layout][1]:lower()
      parts[current] = parts[current] or { title = M.LAYOUTS[layout][1], lines = {} }
      order[#order + 1] = current
      table.insert(parts[current].lines, line)
    end
  end
  local out = {}
  local function section(title, lines)
    while #lines > 0 and vim.trim(lines[#lines]) == "" do
      table.remove(lines)
    end
    while #lines > 0 and vim.trim(lines[1]) == "" do
      table.remove(lines, 1)
    end
    if #out > 0 then
      out[#out + 1] = ""
    end
    out[#out + 1] = "## " .. title
    vim.list_extend(out, #lines > 0 and lines or { "—" })
  end
  for _, title in ipairs(M.LAYOUTS[layout]) do
    local part = parts[title:lower()]
    section(title, part and part.lines or {})
    parts[title:lower()] = nil
  end
  for _, key in ipairs(order) do
    if parts[key] then
      section(parts[key].title, parts[key].lines)
      parts[key] = nil
    end
  end
  return table.concat(out, "\n")
end

-- The first line that says something: the board's line for the task.
local function headline(lines)
  for _, line in ipairs(lines) do
    local text = vim.trim((line:gsub("^#+%s*", ""):gsub("^[-*]%s+", "")))
    if text ~= "" and not line:match("^#") and text ~= "—" then
      return vim.fn.strchars(text) > 200 and vim.fn.strcharpart(text, 0, 199) .. "…" or text
    end
  end
end

-- The lines main shows: the version (the newest by default), then the router's last reply.
local function render(slug, at)
  local versions = M.versions(slug)
  local n = at or versions[#versions]
  local lines = n and read(("%s/%d.md"):format(dir(slug), n)) or { "(The router hasn't written this portal yet.)" }
  lines = vim.list_slice(lines)
  local reply = read(dir(slug) .. "/reply.md")
  if reply and #reply > 0 then
    vim.list_extend(lines, { "", "---", "", "**From the router**", "" })
    vim.list_extend(lines, reply)
  end
  return lines, n, #versions
end

-- Draws the task's portal buffer again, if it has one.
function M.redraw(slug)
  local buf = state.bufs[slug]
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local versions = M.versions(slug)
  if state.at[slug] and not vim.tbl_contains(versions, state.at[slug]) then
    state.at[slug] = nil
  end
  local lines, n, count = render(slug, state.at[slug])
  compose.write(buf, function()
    vim.api.nvim_buf_set_lines(buf, 0, compose.start(buf), false, lines)
  end)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  if state.at[slug] then
    vim.api.nvim_buf_set_extmark(buf, NS, 0, 0, { virt_lines_above = true, virt_lines = {
      { { (" version %d of %d, an older one: ] for newer "):format(n, count), "IcarusPortalOld" } }, { { "" } } } })
  end
end

local function lead_chat(slug)
  local record = M.lead(tasks.read(slug))
  return record and require("icarus.acp.chat").get(record)
end

-- [ and ]: an older version, or a newer one.
function M.step(slug, by)
  local versions = M.versions(slug)
  if #versions == 0 then
    return
  end
  local at = vim.fn.index(versions, state.at[slug] or versions[#versions]) + 1 + by
  at = math.max(1, math.min(#versions, at))
  state.at[slug] = at < #versions and versions[at] or nil
  M.redraw(slug)
end

-- c: the line under the cursor, quoted in the composer, for you to say what about it.
local function quote(chat, buf)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  if compose.inside(buf, row) then
    return
  end
  local line = vim.trim(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")
  if line == "" then
    return
  end
  compose.set(chat, { "On the portal's line \"" .. line .. "\": ", })
  require("icarus.acp.chat").focus(chat.record.id)
  vim.cmd.startinsert({ bang = true })
end

-- Sends the draft to the router, as its chat does.
local function send(chat)
  local text = vim.trim(table.concat(compose.lines(compose.holder(chat)), "\n"))
  if text == "" then
    return
  end
  compose.clear(chat)
  chat.session:prompt(text)
end

-- The task's portal buffer, made the first time, its composer the router's.
local function buf_for(slug, chat)
  local buf = state.bufs[slug]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = "icarus_portal"
  pcall(vim.api.nvim_buf_set_name, buf, "icarus://portal/" .. slug)
  pcall(vim.treesitter.start, buf, "markdown")
  vim.bo[buf].modifiable = false
  compose.init(chat, buf)
  compose.keys(buf, chat)
  state.bufs[slug] = buf
  local function map(modes, lhs, fn, desc)
    vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end
  map("n", "[", function()
    require("icarus.portal").step(slug, -1)
  end, "The portal's older version")
  map("n", "]", function()
    require("icarus.portal").step(slug, 1)
  end, "The portal's newer version")
  map("n", "c", function()
    quote(chat, buf)
  end, "Quote this line to the router")
  map("i", "<CR>", function()
    send(chat)
  end, "Send to the router")
  for _, key in ipairs({ "<S-CR>", "<M-CR>" }) do
    map("i", key, "<CR>", "New line")
  end
  for _, key in ipairs({ "i", "a", "o", "I", "A", "O" }) do
    vim.keymap.set("n", key, function()
      if compose.inside(buf) then
        return key
      end
      return ("<Cmd>lua require('icarus.acp.chat').focus(%q)<CR>"):format(chat.record.id)
    end, { buffer = buf, nowait = true, expr = true, desc = "Type to the router" })
  end
  map({ "n", "i" }, "<C-c>", function()
    chat.session:cancel()
  end, "Interrupt the router")
  M.redraw(slug)
  return buf
end

local WINDOW = { wrap = true, linebreak = true, breakindent = true, conceallevel = 2, concealcursor = "nc",
  smoothscroll = true, number = false, relativenumber = false, signcolumn = "no", list = false, cursorline = false }

-- Shows task's portal in win; false if the task has no router.
function M.show(task, win)
  local record = M.lead(task)
  if not record then
    return false
  end
  require("icarus").on_agent(record)
  local chat = require("icarus.acp.chat").get(record)
  local buf = buf_for(task.slug, chat)
  compose.carry(chat, buf)
  vim.api.nvim_win_set_buf(win, buf)
  for name, value in pairs(WINDOW) do
    vim.wo[win][0][name] = value
  end
  vim.api.nvim_set_current_win(win)
  pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
  return true
end

-- <leader>r: from a portal to its router's thread, and from a router's chat to its portal.
function M.toggle()
  local icarus = require("icarus")
  local view = icarus.view()
  local task = view and view.task and tasks.read(view.task)
  local record = M.lead(task)
  if not record then
    return vim.notify("This task has no router, so no portal", vim.log.levels.WARN)
  end
  local page = require("icarus.task_page")
  if view.portal then
    page.show(task, { chat = record.id })
  else
    page.show(task, { portal = true })
  end
end

-- ica portal [--layout <name>] <content...|-> | --show | --layouts
---@return boolean ok, string result, boolean here
function M.remote(args)
  if args.layouts then
    local out = {}
    for _, name in ipairs(vim.tbl_keys(M.LAYOUTS)) do
      out[#out + 1] = ("%s: %s"):format(name, table.concat(M.LAYOUTS[name], " · "))
    end
    table.sort(out)
    return true, table.concat(out, "\n") .. "\nPass the sections as \"## <section>\" parts: ica portal --layout status -", true
  end
  local me = args.chat and (_G.icarus_open_chats or {})[args.chat]
  if not me then
    return false, "chat " .. tostring(args.chat) .. " isn't open in this icarus", false
  end
  local record = me.record
  local task = record.task and tasks.read(record.task)
  if not task or task.sentinel then
    return false, "you're not on a task", true
  end
  if args.show then
    local versions = M.versions(task.slug)
    return true, #versions > 0 and table.concat(read(("%s/%d.md"):format(dir(task.slug), versions[#versions])), "\n")
      or "(no portal yet)", true
  end
  if not require("icarus.orchestration").leads(record) then
    return false, "only the task's router writes its portal; tell your lead what should be on it", true
  end
  local text = vim.trim(args.text or "")
  if text == "" then
    return false, "usage: ica portal [--layout <name>] <content...|->", true
  end
  if args.layout then
    if not M.LAYOUTS[args.layout] then
      return false, ("no layout %s: ica portal --layouts lists them"):format(args.layout), true
    end
    text = M.lay_out(args.layout, text)
  end
  local versions = M.versions(task.slug)
  local n = (versions[#versions] or 0) + 1
  vim.fn.mkdir(dir(task.slug), "p")
  local lines = vim.split(text, "\n", { plain = true })
  vim.fn.writefile(lines, ("%s/%d.md"):format(dir(task.slug), n))
  state.wrote[record.id] = (me.turns or 0) + 1
  state.at[task.slug] = nil
  local now = headline(lines)
  if now then
    tasks.set(task, { now = now })
  end
  M.redraw(task.slug)
  return true, ("portal of %s: version %d"):format(task.title, n), true
end

-- A turn ended (icarus.orchestration): a router's last reply goes under its portal, and a router that
-- didn't write the portal is asked to, once.
function M.turn_ended(chat)
  local record = chat.record
  if not require("icarus.orchestration").leads(record) then
    return
  end
  local task = tasks.read(record.task)
  local said = require("icarus.acp.thread").said(record) or {}
  local parts = {}
  for i = #said, 1, -1 do
    if said[i].who ~= "agent" then
      break
    end
    table.insert(parts, 1, said[i].text)
  end
  local reply = vim.trim(table.concat(parts, "\n\n"))
  if reply == QUIET then
    return
  end
  if reply ~= "" then
    vim.fn.mkdir(dir(task.slug), "p")
    vim.fn.writefile(vim.split(reply, "\n", { plain = true }), dir(task.slug) .. "/reply.md")
    M.redraw(task.slug)
  end
  local turn = chat.turns or 0
  if state.wrote[record.id] == turn or state.nudged[record.id] == turn then
    return
  end
  state.nudged[record.id] = turn + 1
  chat.session:prompt("icarus: your turn ended without updating this task's portal, which is all the user reads."
    .. " Write it now with `ica portal` (`ica portal --layouts` lists the default layouts, or write your own):"
    .. " the current picture, not a log, with what needs them on its lines. Your last reply already shows under it.",
    nil, "◉ asked to update the portal")
end

-- Highlights, again on a colorscheme change.
local function highlights()
  vim.api.nvim_set_hl(0, "IcarusPortalOld", { fg = require("icarus.theme").ink, bg = require("icarus.theme").sun, bold = true })
end
highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("icarus_portal", { clear = true }),
  callback = highlights,
})

return M
