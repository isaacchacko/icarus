-- The landing: a page in the editing area for someone new to isovim. What it is, what waits on you,
-- quick actions on single keys, the repos set up here and the keys that matter. Every key's words
-- come from its table (isovim.keys, the sidebar's), so the page reads as `?` does and never goes
-- stale. It opens on start when the editing area has nothing else to show, and <leader>il brings
-- it back. Like the dashboard before it, it belongs to no workspace (isovim.layout leaves it out).
local keys = require("isovim.keys")
local repos = require("isovim.repos")

local M = {}

local NS = vim.api.nvim_create_namespace("isovim_landing")
local FILETYPE = "isovim_landing"

local function sidebar()
  return require("isovim.sidebar")
end

-- In the style meter's look (isovim.meter): a bold accent, italic dim phrases, Comment for chrome.
local function define_highlights()
  local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  vim.api.nvim_set_hl(0, "IsovimLandingTitle", { fg = "#7aa2f7", bold = true, default = true })
  vim.api.nvim_set_hl(0, "IsovimLandingKey", { fg = "#7aa2f7", bold = true, default = true })
  vim.api.nvim_set_hl(0, "IsovimLandingTerm", { bold = true, default = true })
  vim.api.nvim_set_hl(0, "IsovimLandingPhrase", { fg = comment.fg, italic = true, default = true })
end

local NAMES = { cr = "enter", tab = "tab", lt = "<", space = "space", esc = "esc" }

-- A key as you'd say it: "<leader>is" is "space i s", "<c-j>" is "ctrl-j".
local function spoken(lhs)
  local leader = vim.g.mapleader == " " and "space" or (vim.g.mapleader or "\\")
  local words, i = {}, 1
  while i <= #lhs do
    local token = lhs:match("^<[^<>]+>", i)
    if token then
      local name = token:sub(2, -2):lower()
      words[#words + 1] = name == "leader" and leader or NAMES[name] or (name:gsub("^c%-", "ctrl-"))
      i = i + #token
    else
      words[#words + 1] = lhs:sub(i, i)
      i = i + 1
    end
  end
  return table.concat(words, " ")
end

-- A description up to its first aside: "pick a project (or Root)" reads "pick a project".
local function short(text)
  return (text:gsub("%s*%(.*$", ""):gsub("[,:;].*$", ""))
end

-- The key's words in its table ({lhs, action, description}).
local function described(list, lhs)
  for _, key in ipairs(list) do
    if key[1] == lhs then
      return short(key[#key])
    end
  end
  return "?"
end

-- Where the key works: anywhere for keys.GLOBAL and keys.GROUP (under <leader>i), else the sidebar.
local function where(list, lhs)
  if list == keys.GROUP then
    return spoken("<leader>i" .. lhs)
  elseif list == keys.GLOBAL then
    return spoken(lhs)
  end
  return spoken(lhs) .. " in the sidebar"
end

-- s: pick a repo set up here (or General), then spawn there, as s on its row in the sidebar. The
-- page belongs to no repo, so it asks rather than spawn where <leader>is would.
local function spawn()
  vim.ui.select(vim.list_extend(repos.list(), { "general" }), { prompt = "Spawn a worker in which project?" }, function(name)
    if name then
      sidebar().spawn(name)
    end
  end)
end

-- m: pick a repo set up here, then the host, as m on its row in the sidebar.
local function send_repo()
  vim.ui.select(repos.list(), { prompt = "Send which project to another host?" }, function(name)
    if name then
      sidebar().actions.isovim_move({ kind = "repo", ws = name, repo_key = name, ws_name = name })
    end
  end)
end

-- {page key, what it runs, the table and key its words come from}.
local function actions()
  return {
    { "s", spawn, keys.GROUP, "s" },
    { "c", keys.create_project, keys.GROUP, "C" },
    { "p", keys.jump, keys.GLOBAL, "<leader><leader>" },
    { "j", require("isovim.jump").picker, keys.GROUP, "j" },
    { "i", function()
      sidebar().focus_inbox("host")
    end, keys.GROUP, "h" },
    { "n", keys.new_terminal, keys.GROUP, "N" },
    { "m", send_repo, sidebar().LIST_KEYS, "m" },
    { "?", sidebar().help, sidebar().COLUMN_KEYS, "?" },
  }
end

local function width_of(chunks)
  local n = 0
  for _, chunk in ipairs(chunks) do
    n = n + vim.api.nvim_strwidth(chunk[1])
  end
  return n
end

local function padded(text, width)
  return text .. (" "):rep(math.max(0, width - vim.api.nvim_strwidth(text)))
end

local function inbox_row()
  local here = sidebar().inbox_count()
  if here == 0 then
    return { { "Nothing waits on you.", "IsovimLandingPhrase" } }
  end
  return { { tostring(here), "DiagnosticWarn" }, { " waiting on you here" }, { "   i opens the Inbox", "IsovimLandingPhrase" } }
end

-- The repos in rows of up to width cells, each in its glyph and color.
local function repo_rows(width)
  local names = repos.list()
  if #names == 0 then
    return { { { "None yet: s spawns an agent in the project you're in.", "IsovimLandingPhrase" } } }
  end
  local rows, row = {}, {}
  for _, name in ipairs(names) do
    -- repos.style gives a repo its color the first time it's seen, writing its config (which then
    -- syncs); the page only reads, so a repo with no color yet shows the default glyph, dim.
    local style = (repos.config(name) or {}).color and repos.style(name)
    local item = { style and { style.glyph, repos.highlight(style.color) } or { repos.defaults().glyph, "Comment" }, { " " .. name } }
    if #row > 0 and width_of(row) + 3 + width_of(item) > width then
      rows[#rows + 1], row = row, {}
    end
    if #row > 0 then
      row[#row + 1] = { "   " }
    end
    vim.list_extend(row, item)
  end
  rows[#rows + 1] = row
  return rows
end

-- The page's rows, each a list of {text, highlight} chunks; {} is a blank line.
local function page()
  local rows = {}
  local function add(row)
    rows[#rows + 1] = row
  end
  add({ { "isovim", "IsovimLandingTitle" }, { "  ·  ", "Comment" }, { "agents at work in your projects; what needs you comes to you", "IsovimLandingPhrase" } })
  add({})
  add(inbox_row())
  add({})
  for _, line in ipairs({
    { "Projects", "a repo, General or Terminals: the sidebar shows one at a time ([ and ])" },
    { "Agents", "each one an ACP session with a role: worker < router < repo-root < root" },
    { "Inbox", "surfaces an agent left for you: a question, a file, a chat" },
    { "Terminals", "shells of your own, beside the agents" },
  }) do
    add({ { padded(line[1], 11), "IsovimLandingTerm" }, { line[2] } })
  end
  add({})
  add({ { "start here", "Comment" } })
  local labels = {}
  for _, action in ipairs(actions()) do
    labels[#labels + 1] = described(action[3], action[4])
  end
  local label_width = math.max(unpack(vim.tbl_map(vim.api.nvim_strwidth, labels)))
  for i, action in ipairs(actions()) do
    add({ { "  " .. padded(action[1], 4), "IsovimLandingKey" }, { padded(labels[i], label_width + 4) }, { where(action[3], action[4]), "Comment" } })
  end
  add({})
  add({ { "projects on this host", "Comment" } })
  for _, row in ipairs(repo_rows(70)) do
    table.insert(row, 1, { "  " })
    add(row)
  end
  add({})
  -- Two columns: keys that work anywhere, and the sidebar's.
  local anywhere = {
    { spoken("<leader>e"), short((vim.fn.maparg("<leader>e", "n", false, true).desc or ""):gsub("^isovim: ", "")) },
  }
  for _, key in ipairs({ { keys.GROUP, "n" }, { keys.GROUP, "i" }, { keys.GROUP, "r" }, { keys.GLOBAL, "<leader>ff" } }) do
    anywhere[#anywhere + 1] = { where(key[1], key[2]), described(key[1], key[2]) }
  end
  local in_sidebar = {}
  for _, key in ipairs({ { sidebar().LIST_KEYS, "<cr>" }, { sidebar().LIST_KEYS, "<Tab>" }, { sidebar().LIST_KEYS, "s" },
    { sidebar().LIST_KEYS, "d" }, { sidebar().COLUMN_KEYS, "<c-l>" } }) do
    in_sidebar[#in_sidebar + 1] = { spoken(key[2]), described(key[1], key[2]) }
  end
  local function column_width(list, field)
    return math.max(unpack(vim.tbl_map(function(entry)
      return vim.api.nvim_strwidth(entry[field])
    end, list)))
  end
  local key_width, text_width = column_width(anywhere, 1), column_width(anywhere, 2)
  local side_width = column_width(in_sidebar, 1)
  add({ { padded("anywhere", key_width + text_width + 8), "Comment" }, { "in the sidebar", "Comment" } })
  for i = 1, math.max(#anywhere, #in_sidebar) do
    local row = { { "  " } }
    local left, right = anywhere[i], in_sidebar[i]
    vim.list_extend(row, left and { { padded(left[1], key_width + 2), "IsovimLandingKey" }, { padded(left[2], text_width + 4) } }
      or { { (" "):rep(key_width + text_width + 6) } })
    if right then
      vim.list_extend(row, { { padded(right[1], side_width + 2), "IsovimLandingKey" }, { right[2] } })
    end
    add(row)
  end
  add({})
  add({ { where(keys.GROUP, "l"), "IsovimLandingKey" }, { " brings this page back · ", "IsovimLandingPhrase" },
    { "?", "IsovimLandingKey" }, { " lists every key", "IsovimLandingPhrase" } })
  return rows
end

local function buffer()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == FILETYPE then
      return buf
    end
  end
end

-- Draws the page centered in the window showing it; the Inbox count is read again each time. A no-op
-- when the page isn't on screen.
function M.refresh()
  local buf = buffer()
  local win = buf and vim.fn.bufwinid(buf) or -1
  if win == -1 then
    return
  end
  define_highlights()
  local rows = page()
  local width = 0
  for _, row in ipairs(rows) do
    width = math.max(width, width_of(row))
  end
  local left = math.max(2, math.floor((vim.api.nvim_win_get_width(win) - width) / 2))
  local top = math.max(1, math.floor((vim.api.nvim_win_get_height(win) - #rows) / 2))
  local lines, marks = {}, {}
  for _ = 1, top do
    lines[#lines + 1] = ""
  end
  for _, row in ipairs(rows) do
    local line = (" "):rep(left)
    for _, chunk in ipairs(row) do
      if chunk[2] then
        marks[#marks + 1] = { #lines, #line, #line + #chunk[1], chunk[2] }
      end
      line = line .. chunk[1]
    end
    lines[#lines + 1] = line:gsub("%s+$", "")
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, mark in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, mark[1], mark[2], { end_col = math.min(mark[3], #lines[mark[1] + 1]), hl_group = mark[4] })
  end
end

local function window_options(win)
  local wo = vim.wo[win][0]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn, wo.statuscolumn = false, false, "no", "0", ""
  wo.cursorline, wo.cursorcolumn, wo.colorcolumn, wo.list, wo.wrap, wo.spell = false, false, "", false, false, false
end

-- One tab, "isovim", in every scope (it has none, so isovim.scope leaves it listed); named, as
-- bufferline finds a tab's icon by its buffer's name.
local function create()
  local buf = vim.api.nvim_create_buf(true, true)
  pcall(vim.api.nvim_buf_set_name, buf, "isovim-landing://isovim")
  vim.b[buf].isovim_tab = { name = "isovim", icon = require("isovim.icons").map.landing[1], hl = require("isovim.icons").map.landing[2] }
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = FILETYPE
  vim.bo[buf].modifiable = false
  -- Snacks pickers give focus back to a file's window unless a buffer says it's a main one.
  vim.b[buf].snacks_indent, vim.b[buf].snacks_main = false, true
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = buf,
    callback = function()
      window_options(vim.api.nvim_get_current_win())
      require("isovim.safe").schedule("the landing", M.refresh)
    end,
  })
  for _, action in ipairs(actions()) do
    vim.keymap.set("n", action[1], action[2], { buffer = buf, nowait = true, desc = "isovim: " .. described(action[3], action[4]) })
  end
  local group = vim.api.nvim_create_augroup("isovim_landing", { clear = true })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, { group = group, callback = require("isovim.safe").wrap("the landing", M.refresh) })
  return buf
end

-- Where the page goes: the window in focus, or the editing area's when the sidebar has it.
local function target()
  local isovim = require("isovim")
  local win = vim.api.nvim_get_current_win()
  if isovim.is_sidebar(win) then
    win = isovim.main_win()
  end
  return win
end

-- An empty, nameless, unmodified buffer, as nvim starts with.
local function blank(buf)
  return vim.api.nvim_buf_get_name(buf) == "" and vim.bo[buf].buftype == "" and not vim.bo[buf].modified
    and vim.api.nvim_buf_line_count(buf) == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
end

-- Shows the page, focused: where it already is, else in place of what the focused window shows. A
-- blank buffer it replaces goes, so the tab bar doesn't keep a [No Name].
function M.open()
  vim.cmd.stopinsert()
  local buf = buffer()
  local win = buf and vim.fn.bufwinid(buf) or -1
  if win == -1 then
    win = target()
    local old = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_win_set_buf(win, buf or create())
    if blank(old) and #vim.fn.win_findbuf(old) == 0 then
      pcall(vim.api.nvim_buf_delete, old, {})
    end
  end
  vim.api.nvim_set_current_win(win)
  M.refresh()
end

-- On start, after the layout is resumed: only when every editing window is blank, so a resumed chat
-- or file is never covered. It takes focus, so its keys work at once.
function M.open_if_empty()
  local isovim = require("isovim")
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if not isovim.is_sidebar(win) and not blank(vim.api.nvim_win_get_buf(win)) then
      return
    end
  end
  M.open()
end

return M
