-- A markdown surface or the Task Board as you see it on Enter: rendered, not the raw file, with an
-- input box under it. The view is a read-only markdown buffer (render-markdown draws it, as
-- LazyVim's markdown extra sets it up): a markdown surface's body without its frontmatter, the
-- Task Board as a list under its five headings. It follows the file: each rescan that changes the
-- surface (isovim.surfaces.watch) redraws it, and one that's gone says so. The input box is a buffer
-- like the chat's composer; <CR> sends what's in it to the repo's router (the host root for the
-- root pseudo-repo) with iso send, so it goes into the router's queue through its supervisor, as
-- any prompt of yours does, and starts the router if it isn't running.
local surfaces = require("isovim.surfaces")
local store = require("isovim.store")

local M = {}

---@class isovim.SurfaceView
---@field repo string
---@field name string
---@field buf integer the rendered view
---@field input integer the input box

---@type table<string, isovim.SurfaceView> by <repo>/<name>
M.views = {}

local function key(repo, name)
  return repo .. "/" .. name
end

local function scratch(name, filetype)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    return existing
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].filetype = filetype
  return buf
end

-- Who reads what's typed under a surface: the repo's router, or for the root pseudo-repo (the host
-- root's surfaces) the host root.
---@return string? address <key>/aN
function M.reader(repo)
  if repo == "root" then
    for _, ws in ipairs(store.list()) do
      for _, agent in ipairs(store.agents(ws.id)) do
        if store.role(agent) == "root" then
          return ws.id .. "/" .. agent.id
        end
      end
    end
    return nil
  end
  return store.router(repo)
end

-- The lines the view shows for a surface: a markdown surface's body, the Task Board as a list.
---@param entry isovim.Surface
---@return string[]
function M.lines(entry)
  local lines = {}
  if entry.error then
    lines[#lines + 1] = ("> **%s is broken:** %s"):format(entry.base, entry.error)
    lines[#lines + 1] = ""
  end
  if entry.type == "tasks" then
    lines[#lines + 1] = "# Task Board"
    for _, status in ipairs(surfaces.statuses) do
      local under = vim.tbl_filter(function(task)
        return task.status == status
      end, entry.tasks or {})
      lines[#lines + 1] = ""
      lines[#lines + 1] = ("## %s%s (%d)"):format(status:sub(1, 1):upper(), status:sub(2), #under)
      if #under > 0 then
        lines[#lines + 1] = ""
      end
      for _, task in ipairs(under) do
        lines[#lines + 1] = ("- [%s] %s"):format(status == "done" and "x" or " ", task.text)
      end
    end
    return lines
  end
  if entry.title and entry.title ~= entry.name then
    lines[#lines + 1] = "# " .. entry.title
    lines[#lines + 1] = ""
  end
  local body = vim.split(entry.body or "", "\n", { plain = true })
  while #body > 0 and vim.trim(body[1]) == "" do
    table.remove(body, 1)
  end
  while #body > 0 and vim.trim(body[#body]) == "" do
    table.remove(body)
  end
  vim.list_extend(lines, body)
  return lines
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

local function winbar(view)
  local reader = M.reader(view.repo)
  return reader and (" ↳ to %s · <CR> sends"):format(reader:gsub("%%", "%%%%"))
    or (" no router in %s to send to"):format(view.repo)
end

-- Sends the input box's text to the reader and empties it; on failure the text stays.
function M.submit(view)
  local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(view.input, 0, -1, false), "\n"))
  if text == "" then
    return
  end
  local reader = M.reader(view.repo)
  if not reader then
    return vim.notify(("isovim: %s has no router to send to"):format(view.repo), vim.log.levels.WARN)
  end
  local message = ("[on the %s surface %s] %s"):format(view.repo, view.name, text)
  vim.api.nvim_buf_set_lines(view.input, 0, -1, false, { "" })
  vim.system({ require("isovim.panes").bin, "send", reader, message }, { text = true }, vim.schedule_wrap(function(result)
    if result.code ~= 0 then
      vim.api.nvim_buf_set_lines(view.input, 0, -1, false, vim.split(text, "\n", { plain = true }))
      vim.notify("isovim: could not send to " .. reader .. ": " .. vim.trim(result.stderr or ""), vim.log.levels.ERROR)
    end
  end))
end

local function make(entry)
  local id = key(entry.repo, entry.name)
  local view = M.views[id]
  if view and vim.api.nvim_buf_is_valid(view.buf) and vim.api.nvim_buf_is_valid(view.input) then
    return view
  end
  view = { repo = entry.repo, name = entry.name }
  view.buf = scratch(("isovim-surface://%s"):format(id), "markdown")
  vim.b[view.buf].isovim_surface = id
  view.input = scratch(("isovim-surface://%s/input"):format(id), "isovim_surface_input")
  vim.b[view.input].isovim_surface_input = id
  vim.b[view.input].completion = false
  local function map(modes, lhs, fn, desc)
    vim.keymap.set(modes, lhs, fn, { buffer = view.input, nowait = true, desc = "isovim: " .. desc })
  end
  map({ "n", "i" }, "<CR>", function()
    M.submit(view)
  end, "send to the repo's router")
  map("i", "<S-CR>", "<CR>", "new line")
  map("i", "<C-j>", "<CR>", "new line")
  map({ "n", "i" }, "<C-k>", function()
    vim.cmd.stopinsert()
    local win = vim.fn.bufwinid(view.buf)
    if win ~= -1 then
      vim.api.nvim_set_current_win(win)
    end
  end, "go to the surface")
  for _, lhs in ipairs({ "i", "a", "o", "<CR>" }) do
    vim.keymap.set("n", lhs, function()
      local win = vim.fn.bufwinid(view.input)
      if win ~= -1 then
        vim.api.nvim_set_current_win(win)
        vim.cmd.startinsert()
      end
    end, { buffer = view.buf, nowait = true, desc = "isovim: type to the repo's router" })
  end
  M.views[id] = view
  return view
end

local function view_window(win)
  local wo = vim.wo[win][0]
  wo.wrap, wo.linebreak, wo.conceallevel = true, true, 2
  wo.number, wo.relativenumber, wo.signcolumn, wo.spell = false, false, "no", false
end

-- A window for the view in this tab: beside a chat when one shows (in the window beside it, else a
-- split to its right), else in the main window (the biggest that isn't the sidebar or a float).
local function place(buf)
  local chat, others = nil, {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_win_get_config(win).relative == "" and not vim.b[b].isovim_sidebar
      and vim.bo[b].filetype ~= "isovim_sidebar" and vim.bo[b].filetype ~= "isovim_composer" and not vim.b[b].isovim_surface_input then
      if vim.bo[b].filetype == "isovim_acp" or vim.b[b].isovim_id then
        chat = chat or win
      else
        others[#others + 1] = win
      end
    end
  end
  table.sort(others, function(a, b)
    return vim.api.nvim_win_get_width(a) * vim.api.nvim_win_get_height(a) > vim.api.nvim_win_get_width(b) * vim.api.nvim_win_get_height(b)
  end)
  local win = others[1]
  if chat and not win then
    win = vim.api.nvim_open_win(buf, true, { split = "right", win = chat })
  elseif win then
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd("vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  end
  return win
end

-- Opens the surface rendered, beside the chat, with its input box under it.
---@param entry isovim.Surface
function M.open(entry)
  local view = make(entry)
  set_lines(view.buf, M.lines(entry))
  local win = vim.fn.bufwinid(view.buf)
  if win == -1 then
    win = place(view.buf)
  else
    vim.api.nvim_set_current_win(win)
  end
  view_window(win)
  if vim.fn.bufwinid(view.input) == -1 then
    local input_win = vim.api.nvim_open_win(view.input, false, { split = "below", win = win, height = 3 })
    vim.wo[input_win][0].winbar = winbar(view)
    vim.wo[input_win][0].winfixheight = true
    vim.wo[input_win][0].number, vim.wo[input_win][0].relativenumber = false, false
  end
  -- render-markdown loads on the first markdown buffer and skips that one (its FileType has gone
  -- by), so the view's FileType goes again once it's loaded, which attaches it.
  if not vim.b[view.buf].isovim_rendered and pcall(require, "render-markdown") then
    vim.b[view.buf].isovim_rendered = true
    vim.api.nvim_win_call(win, function()
      vim.bo[view.buf].filetype = "markdown"
    end)
  end
  return view
end

-- A rescan of repo changed its surfaces: open views redraw, and one whose surface went says so.
function M.changed(repo, entries)
  for _, view in pairs(M.views) do
    if view.repo == repo and vim.api.nvim_buf_is_valid(view.buf) then
      local entry = vim.iter(entries):find(function(each)
        return each.name == view.name
      end)
      set_lines(view.buf, entry and M.lines(entry) or { ("> %s/%s is gone: its router removed it."):format(view.repo, view.name) })
      local input_win = vim.fn.bufwinid(view.input)
      if input_win ~= -1 then
        vim.wo[input_win][0].winbar = winbar(view)
      end
    end
  end
end

return M
