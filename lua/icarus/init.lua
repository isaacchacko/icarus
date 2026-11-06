-- icarus: home, then the chat it opens (icarus.acp.chat), each the whole screen, or a task's screen:
-- its agent on the left and its folder and task.md on the right (icarus.task_page). A new chat from
-- home runs in the dir icarus was started in, on "(no task)". Changing icarus's code
-- reloads it in place (icarus.reload), which runs setup({reload = true}) on the new code.
local chats = require("icarus.chats")
local chat = require("icarus.acp.chat")
local landing = require("icarus.landing")

local T = require("icarus.theme")

local M = {}

-- In _G, so a hot reload keeps them.
_G.icarus_layout = _G.icarus_layout or {}
local layout = _G.icarus_layout ---@type {current?: string, main?: integer, view?: icarus.View, last?: icarus.View, task_view?: icarus.View, last_task?: icarus.View}

---@class icarus.View
---@field kind "home"|"task"|"chat"|"graph"|"list"|"board" a task's screen, a chat alone, a task's graph, or the board
---@field task? string the task's slug
---@field chat? string the chat's id

---@return icarus.View?
function M.view()
  return layout.view
end

-- Every view in order, for <D-[> and <D-]>; a new one drops whatever was ahead of it, as a browser does.
local function remember_view(view)
  if layout.stepping then
    return
  end
  local history = layout.history or { layout.last }
  layout.at = layout.at or #history
  if not vim.deep_equal(history[layout.at], view) then
    history = vim.list_slice(history, math.max(1, layout.at - 198), layout.at)
    history[#history + 1] = view
    layout.at = #history
  end
  layout.history = history
end

-- How much of a view's name the top bar shows.
local TOP_NAME = 24

-- What the screen shows now; the view it showed before is kept for the graph's q.
---@param view icarus.View
function M.set_view(view)
  if not vim.deep_equal(view, layout.view) then
    layout.last, layout.view = layout.view, view
  end
  remember_view(view)
  -- Home is the whole screen, and the list needs no status line; every other view has both bars.
  vim.o.laststatus = (view.kind == "home" or view.kind == "list") and 0 or 3
  vim.o.showtabline = view.kind == "home" and 0 or 2
  vim.cmd.redrawtabline()
  -- The task before this one, for <leader><leader>: another task's screen, with its agent. The
  -- pinned task isn't in that order: it's reached with <leader>`, and it takes no slot.
  local task = view.kind == "task" and require("icarus.tasks").read(view.task)
  if view.kind == "task" and not (task and task.pinned) then
    if layout.task_view and layout.task_view.task ~= view.task then
      layout.last_task = layout.task_view
    end
    layout.task_view = view
  end
end

-- <leader>`: the pinned task; on it, the view before. The pinned task has no slot in <leader><leader>.
function M.toggle_pinned()
  local tasks = require("icarus.tasks")
  local pinned = tasks.pinned()
  if not pinned then
    return vim.notify("No pinned task", vim.log.levels.WARN)
  end
  local view = layout.view
  if view and view.kind == "task" and view.task == pinned.slug then
    return M.last_view()
  end
  M.open_task(tasks.read(pinned.slug) or pinned)
end

-- <leader><leader>: the task before this one, on the agent you had there; again to come back.
function M.last_task()
  local view = layout.last_task
  local task = view and require("icarus.tasks").read(view.task)
  if not task then
    return vim.notify(view and "That task is gone" or "No task before this one", vim.log.levels.WARN)
  end
  local record = view.chat and chats.get(view.chat)
  require("icarus.task_page").open(task, record and (record.task or require("icarus.tasks").SENTINEL) == task.slug and record or nil)
end

-- A view's name for the top bar; nil for one that's gone, which stepping skips too.
local function view_name(view)
  if view.kind == "home" then
    return "home"
  elseif view.kind == "list" or view.kind == "board" then
    return "list"
  elseif view.chat and view.kind == "chat" then
    local record = chats.get(view.chat)
    return record and (record.title or "new chat")
  end
  local task = view.task and require("icarus.tasks").seen(view.task)
  return task and (view.kind == "graph" and "graph: " .. task.title or task.title)
end

-- The nearest view that's still there, by steps of by from where history is.
local function neighbour(by)
  local history = layout.history or {}
  local at = (layout.at or #history) + by
  while history[at] do
    local name = view_name(history[at])
    if name then
      return name
    end
    at = at + by
  end
end

-- The bar across the top: icarus's name as home has it, then the task on screen in italics, and at
-- the right the views before and after this one.
function M.tabline()
  local tasks = require("icarus.tasks")
  local view = layout.view or {}
  local record = layout.current and chats.get(layout.current)
  local slug = view.task or (view.kind ~= "list" and record and record.task)
  local task = slug and slug ~= tasks.SENTINEL and tasks.seen(slug)
  local title = task and "   " .. task.title:gsub("%%", "%%%%") or ""
  local status = task and task.status and ("%%#IcarusTopStatus_%s#   %s %%#IcarusTopDim#%s"):format(task.status,
    tasks.GLYPHS[task.status], tasks.LABELS[task.status]) or ""
  local function short(name)
    local cut = vim.fn.strchars(name) > TOP_NAME and vim.fn.strcharpart(name, 0, TOP_NAME - 1) .. "…" or name
    return (cut:gsub("%%", "%%%%"))
  end
  local before, after = neighbour(-1), neighbour(1)
  local around = (before and "‹ " .. short(before) or "") .. (before and after and "   " or "")
    .. (after and short(after) .. " ›" or "")
  return "%#IcarusTopName# i c a r u s %#IcarusTopTask#" .. title .. status .. "%#IcarusTopBar#%=%#IcarusTopDim#" .. around .. " "
end

-- The statusline, split where the right column starts (half the screen without one): on the left
-- the chat's modes; on the right the file the
-- right column shows, whether it has changes, whether it's watched, and where its cursor is.
function M.statusline()
  local left = {} ---@type {[1]: string, [2]: string}[]
  local record = layout.current and chats.get(layout.current)
  -- The chat's modes, as vim shows its own: how chats show (the thread, or the agent's details),
  -- and whether the next message goes to a fork.
  if record then
    local details = require("icarus.acp.thread").details()
    left[#left + 1] = { details and " AGENT " or " READER ", details and "IcarusStatusAgent" or "IcarusStatusReader" }
    local open = _G.icarus_open_chats and _G.icarus_open_chats[record.id]
    if open and open.fork_next then
      left[#left + 1] = { " FORK ", "IcarusStatusFork" }
    end
    local on = require("icarus.tasks").seen(record.task or require("icarus.tasks").SENTINEL)
    -- Any task but "(no task)": a pinned one has no status, but it has its orchestration.
    if on and (on.status or on.orchestration) then
      local democracy = on.orchestration == "democracy"
      left[#left + 1] = { democracy and " DEMOCRACY " or " ROUTER ", democracy and "IcarusStatusDemocracy" or "IcarusStatusRouter" }
      if not democracy then
        left[#left + 1] = on.auto and { " AUTO ", "IcarusStatusAuto" } or { " AUTO OFF ", "IcarusStatusAutoOff" }
      end
    end
    local agent = open and open.session
    local running = agent and agent.running_at and agent:running_at()
    left[#left + 1] = { running and (" " .. running .. "   ") or " ", "IcarusStatusDim" }
  end
  local task = record and require("icarus.tasks").seen(record.task or require("icarus.tasks").SENTINEL)
  local side = require("icarus.explorer").win()
  local split = side and vim.api.nvim_win_get_position(side)[2] or math.floor(vim.o.columns / 2)
  local right = {}
  if side then
    local buf = vim.api.nvim_win_get_buf(side)
    local name = vim.api.nvim_buf_get_name(buf)
    local dir = task and require("icarus.tasks").dir(record.task or require("icarus.tasks").SENTINEL) .. "/"
    local shown = name:match("^icarus://visual/") and "visuals"
      or dir and vim.startswith(name, dir) and name:sub(#dir + 1) or vim.fn.fnamemodify(name, ":~")
    local cursor = vim.api.nvim_win_get_cursor(side)
    right[#right + 1] = { shown ~= "" and shown or "[no name]", "IcarusStatusTask" }
    if vim.bo[buf].modified then
      right[#right + 1] = { " [+]", "IcarusStatusDim" }
    end
    if _G.icarus_watch and _G.icarus_watch.bufs[buf] then
      right[#right + 1] = { " ◉ " .. require("icarus.watch").agent_name(_G.icarus_watch.bufs[buf].chat), "IcarusStatusDim" }
    end
    local notes, proposals = require("icarus.watch").counts(buf)
    if notes > 0 then
      right[#right + 1] = { (" ✻ %d"):format(notes), "IcarusStatusDim" }
    end
    if proposals > 0 then
      right[#right + 1] = { (" ± %d"):format(proposals), "IcarusStatusDim" }
    end
    right[#right + 1] = { ("   %d:%d / %d"):format(cursor[1], cursor[2] + 1, vim.api.nvim_buf_line_count(buf)), "IcarusStatusDim" }
  end
  -- A visual an agent showed that you haven't looked at.
  local view = layout.view
  local unseen = view and view.task and require("icarus.visual").unseen(view.task)
  if unseen then
    table.insert(#right > 0 and right or left, { "   ◆ new visual: " .. unseen.title .. " (<leader>v)", "IcarusStatusNag" })
  end
  -- The side of the bar your cursor is on, lit: the window you're in is left or right of the split.
  local focus = side and (vim.api.nvim_win_get_position(0)[2] >= split and "right" or "left")
  local LIT = { IcarusStatusTask = "IcarusStatusTaskLit", IcarusStatusDim = "IcarusStatusDimLit", IcarusStatusNag = "IcarusStatusNagLit" }
  local function render(parts, room, lit)
    local out, used = {}, 0
    for _, part in ipairs(parts) do
      local text = part[1]
      local width = vim.fn.strdisplaywidth(text)
      if room and used + width > room then
        text = vim.fn.strcharpart(text, 0, math.max(0, room - used - 1)) .. "…"
        width = room - used
      end
      out[#out + 1] = "%#" .. (lit and LIT[part[2]] or part[2]) .. "#" .. text:gsub("%%", "%%%%")
      used = used + width
      if room and used >= room then
        break
      end
    end
    return table.concat(out), used
  end
  local text, used = render(left, #right > 0 and split - 2 or nil, focus == "left")
  if #right == 0 then
    return " " .. text
  end
  local left_fill = focus == "left" and "%#IcarusStatusDimLit#" or "%#IcarusStatusDim#"
  local shown, width = render(right, nil, focus == "right")
  local after = focus == "right" and "%#IcarusStatusDimLit#" .. (" "):rep(math.max(0, vim.o.columns - split - width)) or ""
  return left_fill .. " " .. text .. left_fill .. (" "):rep(math.max(1, split - 1 - used)) .. shown .. after
end

-- The chat the main window shows.
function M.current()
  return layout.current
end

-- The window home and chats show in: the last one, or the first that isn't a composer or a task's
-- right column.
local function main_win()
  if layout.main and vim.api.nvim_win_is_valid(layout.main) then
    return layout.main
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if not vim.w[win].icarus_composer_of and not vim.w[win].icarus_side and not vim.w[win].icarus_queue_of
      and not vim.w[win].icarus_head_of and not vim.w[win].icarus_prs_of and not vim.w[win].icarus_agents then
      layout.main = win
      return win
    end
  end
  layout.main = vim.api.nvim_open_win(landing.buf(), false, { split = "right", win = -1 })
  return layout.main
end

-- The window home, chats and the graph show in.
function M.main()
  return main_win()
end

function M.home()
  local win = main_win()
  require("icarus.explorer").close()
  chat.hide_composer(win)
  vim.api.nvim_win_set_buf(win, landing.buf())
  vim.wo[win][0].number, vim.wo[win][0].relativenumber = false, false
  vim.api.nvim_set_current_win(win)
  landing.draw()
  landing.hide_cursor(true)
  layout.current = nil
  M.set_view({ kind = "home" })
end

---@param record icarus.ChatRecord
function M.open(record)
  layout.current = record.id
  chat.show(chat.get(record), main_win())
end

function M.new_chat()
  local record = chats.create(vim.fn.getcwd())
  M.open(record)
  M.set_view({ kind = "chat", chat = record.id })
end

-- Shows view; false if what it showed is gone.
local function show_view(view)
  local record = view.chat and chats.get(view.chat)
  if view.kind == "home" then
    M.home()
  elseif view.kind == "list" or view.kind == "board" then
    require("icarus.list").open()
  elseif view.kind == "task" or view.kind == "graph" then
    local task = require("icarus.tasks").read(view.task)
    if not task then
      return false
    end
    if view.kind == "graph" then
      require("icarus.graph").open(task)
    else
      require("icarus.task_page").open(task, record)
    end
  elseif record then
    require("icarus.explorer").close()
    M.open(record)
    M.set_view(view)
  else
    return false
  end
  return true
end

-- Back to the view before this one, whatever it was (the graph's q).
function M.last_view()
  if not layout.last then
    return vim.notify("No view before this one", vim.log.levels.WARN)
  end
  if not show_view(layout.last) then
    vim.notify("That view is gone", vim.log.levels.WARN)
  end
end

-- Escape on the list: the task you were last on, wherever it is in the history; a task that's gone is
-- skipped.
function M.previous_task()
  local history = layout.history or {}
  for at = (layout.at or #history) - 1, 1, -1 do
    local view = history[at]
    if view.kind == "task" and require("icarus.tasks").seen(view.task) and show_view(view) then
      return
    end
  end
end

-- <D-[> and <D-]>: back and forward through the views, from wherever you are: out of zen, a float
-- or insert mode first, past any view that's gone.
function M.step_view(by)
  local history = layout.history or {}
  local at = (layout.at or #history) + by
  if not history[at] then
    return
  end
  require("icarus.zen").off()
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(win).relative ~= "" and not vim.bo.filetype:match("^snacks_") then
    pcall(vim.api.nvim_win_close, win, true)
  end
  vim.cmd.stopinsert()
  layout.stepping = true
  while history[at] do
    local ok, shown = pcall(show_view, history[at])
    if ok and shown then
      layout.at = at
      break
    end
    at = at + by
  end
  layout.stepping = false
  vim.cmd.redrawtabline()
end

function M.new_task()
  require("icarus.task_page").new()
end

---@param task icarus.Task
function M.open_task(task)
  require("icarus.task_page").open(task)
end

-- What a task's row shows beside the list: its title and status, its agents, then its task.md.
local function task_preview(task)
  local lines = { "# " .. task.title, "" }
  if task.status then
    lines[#lines + 1] = "status: " .. task.status
  end
  for _, record in ipairs(chats.on_task(task.slug)) do
    lines[#lines + 1] = ("- %s · %s"):format(record.title or "new chat", chats.status(record.id))
  end
  local body = require("icarus.tasks").body(task)
  local written = vim.iter(body):any(function(line)
    return vim.trim(line) ~= ""
  end)
  vim.list_extend(lines, { "", "---", "" })
  vim.list_extend(lines, written and body or { "_nothing written yet_" })
  return { text = table.concat(lines, "\n"), ft = "markdown" }
end

-- Deletes the task: its folder goes to ~/.icarus/trash, and its chats stop and leave every list.
---@param task icarus.Task
function M.delete_task(task)
  local record = layout.current and chats.get(layout.current)
  if record and record.task == task.slug then
    M.home()
  end
  for _, each in ipairs(chats.on_task(task.slug)) do
    chat.stop(each.id)
  end
  local to = require("icarus.tasks").delete(task)
  vim.notify(("Deleted %s; its folder is in %s"):format(task.title, vim.fn.fnamemodify(to, ":~")))
  return to
end

-- Cancels the task, or puts a cancelled one back to spec.
---@param task icarus.Task
function M.toggle_cancelled(task)
  require("icarus.tasks").set_status(task, task.status == "cancelled" and "spec" or "cancelled")
end

local DONE = { cancelled = true, merged = true }

-- Picks a task to jump to, the last opened first; "(no task)" is always there. <C-x> cancels the
-- task under the cursor (or puts it back), <C-d> deletes it.
function M.pick_task()
  local tasks = require("icarus.tasks")
  local function on_task(fn)
    return function(picker, item)
      if not item or item.task.sentinel or item.task.pinned then
        return vim.notify(("%s can't be cancelled or deleted"):format(item and item.task.title or "(no task)"), vim.log.levels.WARN)
      end
      fn(picker, item.task)
    end
  end
  local keys = { ["<c-x>"] = { "cancel_task", mode = { "i", "n" } }, ["<c-d>"] = { "delete_task", mode = { "i", "n" } } }
  require("icarus.ui").snacks().picker({
    title = "Tasks  <c-x> cancel  <c-d> delete",
    finder = function()
      return vim.tbl_map(function(task)
        return { text = (task.status or "") .. " " .. task.title, task = task, preview = task_preview(task) }
      end, tasks.recent())
    end,
    format = function(item)
      local done = DONE[item.task.status]
      return { { ("%-10s"):format(item.task.status or ""), "Comment" }, { item.task.title, done and "Comment" or nil } }
    end,
    preview = "preview",
    actions = {
      cancel_task = on_task(function(picker, task)
        M.toggle_cancelled(task)
        picker:find()
      end),
      delete_task = on_task(function(picker, task)
        Snacks.picker.util.confirm(("Delete %s?"):format(task.title), function()
          M.delete_task(task)
          picker:find()
        end)
      end),
    },
    win = { input = { keys = keys }, list = { keys = keys } },
    confirm = function(picker, item)
      picker:close()
      if item then
        M.open_task(item.task)
      end
    end,
  })
end

-- Picks one of the agents on the task of the chat showing, or a new one, and shows it there.
function M.pick_agent()
  local tasks = require("icarus.tasks")
  local record = layout.current and chats.get(layout.current)
  local task = tasks.read(record and record.task or tasks.SENTINEL) or tasks.sentinel()
  local list = chats.on_task(task.slug)
  table.insert(list, { new = true })
  vim.ui.select(list, {
    prompt = "Agent on " .. task.title,
    format_item = function(each)
      return each.new and "+ new agent" or ("%-9s %s"):format(chats.status(each.id), each.title or "new chat")
    end,
  }, function(each)
    if each then
      local task_page = require("icarus.task_page")
      task_page.open(task, each.new and task_page.new_agent(task) or each)
    end
  end)
end

-- Opens or closes the explorer on the right: the task's folder, or on "(no task)" the chat's dir.
function M.toggle_explorer()
  local tasks = require("icarus.tasks")
  local record = layout.current and chats.get(layout.current)
  local task = record and tasks.read(record.task or tasks.SENTINEL)
  local root = task and not task.sentinel and task.dir or record and record.cwd or vim.fn.getcwd()
  local open = require("icarus.explorer").toggle(root)
  if layout.view and layout.view.kind == "task" then
    require("icarus.task_page").keep(layout.view.task, { explorer = open })
  end
end

-- The views, each a letter after <leader>v.

-- Here, not in init.lua, so a hot reload applies them too.
local OPTIONS = { termguicolors = true, mouse = "a", splitright = true, splitbelow = true,
  ruler = false, fillchars = "eob: ", clipboard = "unnamedplus", statusline = "%!v:lua.require'icarus'.statusline()",
  tabline = "%!v:lua.require'icarus'.tabline()" }

---@param opts? {reload?: boolean}
function M.setup(opts)
  for name, value in pairs(OPTIONS) do
    vim.o[name] = value
  end
  -- Relative line numbers in every file; icarus's own windows (chat, composer, queue, explorer,
  -- home, floats) keep theirs off. Global only, so the window you're in isn't changed whatever it is.
  vim.go.number, vim.go.relativenumber = true, true
  local function numbered(win)
    if vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "" and vim.api.nvim_win_get_config(win).relative == "" then
      vim.wo[win][0].number, vim.wo[win][0].relativenumber = true, true
    end
  end
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = vim.api.nvim_create_augroup("icarus_numbers", { clear = true }),
    callback = function()
      numbered(vim.api.nvim_get_current_win())
    end,
  })
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    numbered(win)
  end
  -- On the statusline's background, which a group of its own doesn't get.
  local bar = vim.api.nvim_get_hl(0, { name = "StatusLine", link = false })
  local dim = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  vim.api.nvim_set_hl(0, "IcarusStatusTask", { fg = bar.fg, bg = bar.bg, bold = true })
  -- The name on a darker bar than the rest: each channel at 60%.
  local base = bar.bg or 0x282c34
  local darker = 0
  for _, shift in ipairs({ 0x10000, 0x100, 1 }) do
    darker = darker + math.floor(math.floor(base / shift) % 256 * 0.6) * shift
  end
  vim.api.nvim_set_hl(0, "IcarusTopName", { fg = bar.fg, bg = darker, bold = true })
  vim.api.nvim_set_hl(0, "IcarusTopTask", { fg = bar.fg, bg = bar.bg, italic = true })
  vim.api.nvim_set_hl(0, "IcarusTopBar", { bg = bar.bg })
  vim.api.nvim_set_hl(0, "IcarusTopDim", { fg = dim.fg, bg = bar.bg })
  for status, color in pairs(require("icarus.tasks").COLORS) do
    vim.api.nvim_set_hl(0, "IcarusTopStatus_" .. status, { fg = color, bg = bar.bg })
  end
  vim.api.nvim_set_hl(0, "IcarusStatusDim", { fg = dim.fg, bg = bar.bg })
  vim.api.nvim_set_hl(0, "IcarusStatusNag", { fg = T.sun, bg = bar.bg, bold = true })
  local lit = vim.api.nvim_get_hl(0, { name = "Visual", link = false }).bg or bar.bg
  vim.api.nvim_set_hl(0, "IcarusStatusTaskLit", { fg = bar.fg, bg = lit, bold = true })
  vim.api.nvim_set_hl(0, "IcarusStatusDimLit", { fg = bar.fg, bg = lit })
  vim.api.nvim_set_hl(0, "IcarusStatusNagLit", { fg = T.sun, bg = lit, bold = true })
  vim.api.nvim_set_hl(0, "IcarusStatusReader", { fg = T.ink, bg = T.leaf, bold = true })
  vim.api.nvim_set_hl(0, "IcarusStatusAgent", { fg = T.ink, bg = T.sky, bold = true })
  vim.api.nvim_set_hl(0, "IcarusStatusFork", { fg = T.ink, bg = T.violet, bold = true })
  vim.api.nvim_set_hl(0, "IcarusStatusRouter", { fg = T.ink, bg = T.ember, bold = true })
  vim.api.nvim_set_hl(0, "IcarusStatusAuto", { fg = T.ink, bg = T.coral, bold = true })
  vim.api.nvim_set_hl(0, "IcarusStatusAutoOff", { fg = dim.fg, bg = vim.api.nvim_get_hl(0, { name = "Visual", link = false }).bg or bar.bg })
  vim.api.nvim_set_hl(0, "IcarusStatusDemocracy", { fg = T.ink, bg = T.teal, bold = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("icarus", { clear = true }),
    callback = function()
      require("icarus.acp.chat").stop_all()
    end,
  })
  -- Wrapped text breaks between words in every window, never in the middle of one.
  vim.o.linebreak = true
  -- As LazyVim has it: down and up go by screen line through wrapped text, by line with a count.
  for _, key in ipairs({ { "j", "gj" }, { "k", "gk" }, { "<Down>", "gj" }, { "<Up>", "gk" } }) do
    vim.keymap.set({ "n", "x" }, key[1], ("v:count == 0 ? '%s' : '%s'"):format(key[2], key[1] == "<Down>" and "j"
      or key[1] == "<Up>" and "k" or key[1]), { expr = true, silent = true, desc = key[2] == "gj" and "Down" or "Up" })
  end
  for _, key in ipairs({ "h", "j", "k", "l" }) do
    vim.keymap.set("n", "<C-" .. key .. ">", "<C-w>" .. key, { desc = "Go to the window " .. ({ h = "left", j = "below", k = "above", l = "right" })[key] })
  end
  vim.keymap.set("n", "<leader>`", function()
    M.toggle_pinned()
  end, { desc = "The pinned task, or back from it" })
  vim.keymap.set("n", "<leader>f", function()
    require("icarus").pick_task()
  end, { desc = "Find a task" })
  vim.keymap.set("n", "<leader>z", function()
    require("icarus.zen").toggle()
  end, { desc = "Zen: this window, the whole screen" })
  vim.keymap.set("n", "<leader>l", function()
    -- Out of zen, the sidebar shows, open already or not.
    local open = require("icarus.explorer").open_now and require("icarus.explorer").open_now()
    if require("icarus.zen").off() and open then
      return
    end
    require("icarus").toggle_explorer()
  end, { desc = "Right sidebar: the explorer" })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = vim.api.nvim_create_augroup("icarus_statusline_side", { clear = true }),
    callback = function()
      vim.cmd.redrawstatus()
    end,
  })
  for lhs, by in pairs({ ["<D-[>"] = -1, ["<D-]>"] = 1 }) do
    local desc = by < 0 and "Back a view" or "Forward a view"
    vim.keymap.set({ "n", "i", "x", "s", "t" }, lhs, function()
      M.step_view(by)
    end, { desc = desc })
    vim.keymap.set("c", lhs, ("<C-c><Cmd>lua require('icarus').step_view(%d)<CR>"):format(by), { desc = desc })
  end
  vim.keymap.set("n", "<leader><leader>", function()
    require("icarus").last_task()
  end, { desc = "Last task" })
  vim.keymap.set("n", "<leader>o", function()
    require("icarus.orchestration").cycle()
  end, { desc = "The task's orchestration: router-worker or democracy" })
  vim.keymap.set("n", "<leader>D", function()
    require("icarus.daedalus").wake()
    vim.notify("Daedalus wakes: its task is daedalus")
  end, { desc = "Wake Daedalus now, to find what agents lost" })
  vim.keymap.set("n", "<leader>A", function()
    require("icarus.orchestration").toggle_auto()
  end, { desc = "Auto mode for the task's lead, on or off" })
  vim.keymap.set("n", "<leader>i", function()
    require("icarus.inbox").open()
  end, { desc = "What's waiting on you on this task" })
  vim.keymap.set("n", "<leader>q", function()
    local record = layout.current and chats.get(layout.current)
    if record then
      require("icarus.acp.queue").focus(chat.get(record))
    end
  end, { desc = "The chat's queue" })
  vim.keymap.set("n", "<Tab>", function()
    require("icarus.links").tab()
  end, { desc = "Open the link under the cursor" })
  vim.keymap.set("n", "<leader>h", function()
    local open = require("icarus.org").open_now()
    if require("icarus.zen").off() and open then
      return
    end
    require("icarus.org").toggle()
  end, { desc = "Left sidebar: how this task's agents are organized" })
  vim.keymap.set("n", "<leader>R", function()
    local record = layout.current and chats.get(layout.current)
    if record then
      chat.restart(record)
    end
  end, { desc = "Restart this agent, so it has icarus's latest" })
  vim.keymap.set("n", "<leader>d", function()
    local details = require("icarus.acp.thread").toggle()
    vim.notify(details and "Chats show their details: tool calls, thoughts and all" or "Chats show their thread: your messages and the agent's")
  end, { desc = "Chats: details, or just the thread" })
  vim.keymap.set("n", "<leader>s", function()
    local record = layout.current and chats.get(layout.current)
    if not record then
      return vim.notify("No chat to fork", vim.log.levels.WARN)
    end
    chat.toggle_fork(record)
  end, { desc = "Fork mode: the next message goes to a fork of this agent" })
  vim.keymap.set("n", "<leader>m", function()
    require("icarus.list").open()
  end, { desc = "The list: every open task, by status" })
  vim.keymap.set("n", "<leader>g", function()
    require("icarus.graph").open()
  end, { desc = "Graph of this task's agents" })
  vim.keymap.set("n", "<leader>w", function()
    require("icarus.watch").toggle()
  end, { desc = "Watch this file with the agent, or stop" })
  vim.keymap.set("n", "<leader>a", function()
    require("icarus").pick_agent()
  end, { desc = "Agents on this task" })
  -- Keys without <leader> (a chat's <CR>, home's n) are listed here, so every key shows in which-key.
  vim.keymap.set("n", "<leader>?", function()
    local ok, wk = pcall(require, "which-key")
    if ok then
      wk.show({ global = false })
    else
      vim.cmd("map <buffer>")
    end
  end, { desc = "Keys in this buffer" })
  vim.keymap.set("n", "<leader>H", function()
    require("icarus").home()
  end, { desc = "Home" })
  vim.keymap.set("n", "<leader>v", function()
    require("icarus.visual").toggle()
  end, { desc = "The task's visuals, or back to the file" })
  -- Once start packages are on the runtimepath, after init.lua.
  vim.schedule(function()
    require("icarus.ui").enable()
    -- So a file with comments kept from before shows them as it opens, and links are underlined.
    require("icarus.watch")
    require("icarus.links")
    require("icarus.link_cursor")
    require("icarus.head")
    require("icarus.bugs").watch()
    require("icarus.democracy").resume()
    require("icarus.daedalus").start()
  end)
  require("icarus.reload").watch()
  if opts and opts.reload then
    chat.rebind()
    -- Home as this code draws it, when that's what's showing.
    if not layout.current then
      M.home()
    end
    return
  end
  layout.main = vim.api.nvim_get_current_win()
  M.home()
end

return M
