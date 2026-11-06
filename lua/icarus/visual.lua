-- Visuals: what an agent shows the user, one scratch buffer per task. The agent writes a file (a
-- diagram, a table, a chart drawn in text) and runs ica show <file> [--title <title>]: it's added to
-- its task's visuals (kept in the task's .visuals.json), and until you've looked, its row in the
-- outline has a ◆. <CR> there shows it in main, in the task's visual buffer. In it [ and ] step
-- through older and newer ones, q goes back, and a visual shown again (the same file) is read again.
--
-- A visual that's an image (png, jpg, gif, webp) is drawn as one (snacks.image, over the terminal's
-- graphics protocol: Ghostty, kitty). One that's a page (html) is first drawn by headless Chrome,
-- at twice the pixels, into a png beside it (.visuals/<name>.png, done again when the page
-- changes), its blank edges trimmed (ImageMagick). Anything else shows as text.
--
-- An image shows as a view of it, cut and scaled by ImageMagick to the pane's size in pixels: hjkl
-- pan, = and - zoom in and out, f fits its whole height to the pane and F its width (the view it
-- opens at, from its top).
local tasks = require("icarus.tasks")

local M = {}

---@class icarus.Visual
---@field path string
---@field title string
---@field chat? string the agent that showed it
---@field at integer
---@field seen? boolean

-- In _G, so a hot reload keeps them: per task, the visual showing.
_G.icarus_visual = _G.icarus_visual or { showing = {} }
local state = _G.icarus_visual

local function store(slug)
  return tasks.dir(slug) .. "/.visuals.json"
end

-- Read once per task and kept, as the statusline asks on every redraw; only this icarus writes it.
state.lists = state.lists or {}

---@return icarus.Visual[]
function M.list(slug)
  if not state.lists[slug] then
    local file = store(slug)
    local ok, list = pcall(vim.json.decode, vim.fn.filereadable(file) == 1 and table.concat(vim.fn.readfile(file), "") or "")
    state.lists[slug] = ok and type(list) == "table" and list or {}
  end
  return state.lists[slug]
end

local function save(slug, list)
  state.lists[slug] = list
  if vim.fn.isdirectory(tasks.dir(slug)) == 1 then
    vim.fn.writefile({ vim.json.encode(list) }, store(slug))
  end
end

local function buf_of(slug)
  local name = "icarus://visual/" .. slug
  local buf
  for _, each in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(each) == name then
      buf = each
    end
  end
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    vim.api.nvim_buf_set_name(buf, name)
  end
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, function()
      require("icarus.visual")[fn](slug)
    end, { buffer = buf, nowait = true, desc = desc })
  end
  map("[", "older", "Older visual")
  map("]", "newer", "Newer visual")
  vim.keymap.set("n", "q", function()
    require("icarus").last_view()
  end, { buffer = buf, nowait = true, desc = "Back to what main showed" })
  return buf
end

-- Draws visual i of slug (the newest by default) into its buffer, and marks it seen.
local IMAGES = { png = true, jpg = true, jpeg = true, gif = true, webp = true }
local PAGES = { html = true, htm = true }
local CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

-- The png a page is drawn into, beside it in the task's .visuals.
local function png_of(slug, path)
  return ("%s/.visuals/%s.png"):format(tasks.dir(slug), vim.fs.basename(path):gsub("%.%w+$", ""))
end

-- Draws the page at path into png with headless Chrome, trims it, then done(err?).
local function render(path, png, done)
  vim.fn.mkdir(vim.fs.dirname(png), "p")
  local profile = vim.fn.tempname()
  vim.system({ CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-first-run",
    "--user-data-dir=" .. profile, "--window-size=1100,3000", "--force-device-scale-factor=2", "--screenshot=" .. png,
    "file://" .. path },
    { timeout = 30000 }, vim.schedule_wrap(function(result)
      vim.fn.delete(profile, "rf")
      if result.code ~= 0 or vim.fn.filereadable(png) == 0 then
        return done("Chrome couldn't draw it: " .. vim.trim(result.stderr or ""):sub(1, 200))
      end
      vim.system({ "magick", png, "-trim", "+repage", "-bordercolor", "white", "-border", "48", png }, { timeout = 15000 },
        vim.schedule_wrap(function()
          done()
        end))
    end))
end


-- Draws the image file over buf, as it is.
local function attach(buf, file)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.bo[buf].modifiable = false
  require("icarus.ui").snacks().image.buf.attach(buf, { src = file })
end

-- Views: per buffer, the image shown, its size, the scale (image pixels to a screen pixel) and the
-- top left of what's in view, in image pixels.
state.views = state.views or {}
local views = state.views

-- The pane's size in pixels: its window's cells, less the winbar's row, by the terminal's cell.
local function pane(buf)
  local win = vim.fn.win_findbuf(buf)[1]
  if not win then
    return nil
  end
  local size = require("icarus.ui").snacks().image.terminal.size()
  local rows = vim.api.nvim_win_get_height(win) - (vim.wo[win].winbar ~= "" and 1 or 0)
  return vim.api.nvim_win_get_width(win) * size.cell_width, math.max(1, rows) * size.cell_height
end

-- Cuts the view out of the image and draws it; a newer view on its way drops this one.
local function show_view(buf)
  local view = views[buf]
  local pw, ph = pane(buf)
  if not (view and pw) then
    return
  end
  local vw, vh = math.min(view.w, pw * view.scale), math.min(view.h, ph * view.scale)
  view.x = math.max(0, math.min(view.w - vw, view.x))
  view.y = math.max(0, math.min(view.h - vh, view.y))
  view.n = (view.n or 0) + 1
  local n = view.n
  local out = ("%s.view-%d.png"):format(view.png:gsub("%.png$", ""), n)
  local geometry = ("%dx%d+%d+%d"):format(math.floor(vw), math.floor(vh), math.floor(view.x), math.floor(view.y))
  local size = ("%dx%d"):format(math.max(1, math.floor(vw / view.scale)), math.max(1, math.floor(vh / view.scale)))
  vim.system({ "magick", view.png, "-crop", geometry, "+repage", "-resize", size, out }, { timeout = 15000 },
    vim.schedule_wrap(function(result)
      if views[buf] ~= view or view.n ~= n or result.code ~= 0 or not vim.api.nvim_buf_is_valid(buf) then
        vim.fn.delete(out)
        return
      end
      attach(buf, out)
      if view.shown then
        vim.fn.delete(view.shown)
      end
      view.shown = out
    end))
end

-- f and F: the scale that fits the whole height, or width, to the pane.
local function fit(buf, by)
  local view = views[buf]
  local pw, ph = pane(buf)
  if view and pw then
    view.scale = by == "height" and view.h / ph or view.w / pw
  end
end

local PAN = 0.15

-- The keys that move about an image, on buf while it shows one; gone when it shows text.
local function view_keys(buf, on)
  local keys = {
    h = { "Pan left", function(v, vw) v.x = v.x - vw * PAN end },
    l = { "Pan right", function(v, vw) v.x = v.x + vw * PAN end },
    k = { "Pan up", function(v, _, vh) v.y = v.y - vh * PAN end },
    j = { "Pan down", function(v, _, vh) v.y = v.y + vh * PAN end },
    ["="] = { "Zoom in", function(v, vw, vh) v.x, v.y, v.scale = v.x + vw * 0.1, v.y + vh * 0.1, v.scale / 1.25 end },
    ["-"] = { "Zoom out", function(v, vw, vh) v.x, v.y, v.scale = v.x - vw * 0.125, v.y - vh * 0.125, v.scale * 1.25 end },
    f = { "Fit its height to the pane", function() fit(buf, "height") end },
    F = { "Fit its width to the pane", function() fit(buf, "width") end },
  }
  for lhs, key in pairs(keys) do
    if on then
      vim.keymap.set("n", lhs, function()
        local view = views[buf]
        local pw, ph = pane(buf)
        if view and pw then
          key[2](view, math.min(view.w, pw * view.scale), math.min(view.h, ph * view.scale))
          show_view(buf)
        end
      end, { buffer = buf, nowait = true, desc = key[1] })
    else
      pcall(vim.keymap.del, "n", lhs, { buffer = buf })
    end
  end
end

-- The image placement on buf, gone (a text visual takes the buffer), and its view with it.
local function unplace(buf)
  pcall(function()
    Snacks.image.placement.clean(buf)
  end)
  local view = views and views[buf]
  if view then
    if view.shown then
      vim.fn.delete(view.shown)
    end
    views[buf] = nil
    view_keys(buf, false)
  end
end

-- Draws the image file at png over buf as a view, fitted to the pane's width from the top.
local function place(buf, png)
  local result = vim.system({ "magick", "identify", "-format", "%w %h", png }, { text = true }):wait(5000)
  local w, h = (result.stdout or ""):match("(%d+) (%d+)")
  if not w then
    return attach(buf, png)
  end
  local old = views[buf]
  if old and old.shown then
    vim.fn.delete(old.shown)
  end
  views[buf] = { png = png, w = tonumber(w), h = tonumber(h), x = 0, y = 0, scale = 1 }
  fit(buf, "width")
  view_keys(buf, true)
  show_view(buf)
end

-- A pane resized: its view cut again for the new size.
vim.api.nvim_create_autocmd("WinResized", {
  group = vim.api.nvim_create_augroup("icarus_visual", { clear = true }),
  callback = function()
    for buf in pairs(views) do
      if vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) > 0 then
        show_view(buf)
      end
    end
  end,
})

local function draw(slug, i)
  local list = M.list(slug)
  local buf = buf_of(slug)
  i = i and math.max(1, math.min(#list, i)) or #list
  local lines, title = { "no visuals yet: agents show them with ica show <file>" }, "visuals"
  local visual = list[i]
  local ext = visual and (visual.path:match("%.(%w+)$") or ""):lower()
  unplace(buf)
  if visual and vim.fn.filereadable(visual.path) == 1 and (IMAGES[ext] or PAGES[ext]) then
    title = ("%s  ·  %d/%d  ·  %s"):format(visual.title, i, #list, os.date("%H:%M", visual.at))
    if not visual.seen then
      visual.seen = true
      save(slug, list)
    end
    state.showing[slug] = i
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      vim.wo[win][0].winbar = " " .. title:gsub("%%", "%%%%") .. "  ·  [ ] older/newer · q back"
    end
    vim.cmd.redrawstatus()
    if IMAGES[ext] then
      place(buf, visual.path)
      return buf
    end
    local png = png_of(slug, visual.path)
    local stale = vim.fn.getftime(png) < vim.fn.getftime(visual.path)
    if not stale then
      place(buf, png)
      return buf
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "drawing " .. vim.fs.basename(visual.path) .. "…" })
    vim.bo[buf].modifiable = false
    render(visual.path, png, function(err)
      -- Still the visual showing, when Chrome's done.
      if state.showing[slug] ~= i or not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if err then
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.list_extend({ err, "" }, vim.fn.readfile(visual.path)))
        vim.bo[buf].modifiable = false
        vim.bo[buf].filetype = "html"
        return
      end
      place(buf, png)
    end)
    return buf
  end
  if visual then
    lines = vim.fn.filereadable(visual.path) == 1 and vim.fn.readfile(visual.path) or { "(" .. visual.path .. " is gone)" }
    title = ("%s  ·  %d/%d  ·  %s"):format(visual.title, i, #list, os.date("%H:%M", visual.at))
    if not visual.seen then
      visual.seen = true
      save(slug, list)
    end
    local ext = visual.path:match("%.(%w+)$")
    vim.bo[buf].filetype = ext and (vim.filetype.match({ filename = visual.path }) or ext) or "markdown"
  end
  state.showing[slug] = i
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.wo[win][0].winbar = " " .. title:gsub("%%", "%%%%") .. "  ·  [ ] older/newer · q back"
  end
  vim.cmd.redrawstatus()
  return buf
end

-- The task the screen is on, if it's a task.
local function current()
  local view = require("icarus").view()
  return view and view.task
end

-- Shows visual i of slug in main; returns the i it showed.
---@return integer
function M.show(slug, i)
  local main = require("icarus").main()
  vim.api.nvim_win_set_buf(main, buf_of(slug))
  for option, value in pairs({ number = false, relativenumber = false, wrap = false }) do
    vim.wo[main][0][option] = value
  end
  draw(slug, i)
  return state.showing[slug]
end

local function step(slug, by)
  require("icarus.task_page").show(tasks.read(slug), { visual = math.max(1, math.min(#M.list(slug), state.showing[slug] + by)) })
end

function M.older(slug)
  step(slug, -1)
end

function M.newer(slug)
  step(slug, 1)
end

-- ica show: adds path to the visuals of the task the agent with chat is on (or the screen's), shown
-- at once if its buffer is showing.
---@return boolean ok, string result, boolean here
function M.remote(args)
  local record = args.chat and require("icarus.chats").get(args.chat)
  local slug = args.task or (record and (record.task or tasks.SENTINEL)) or current()
  if not record and not args.task and args.chat then
    return false, "no chat " .. args.chat .. " in this icarus", false
  end
  if not (slug and tasks.read(slug)) then
    return false, "no task to show it on", true
  end
  if vim.fn.filereadable(args.path) == 0 then
    return false, args.path .. " isn't a file", true
  end
  local list = M.list(slug)
  local title = args.title or vim.fn.fnamemodify(args.path, ":t")
  local found
  for i, visual in ipairs(list) do
    if visual.path == args.path then
      found = table.remove(list, i)
      break
    end
  end
  found = found or {}
  found.path, found.title, found.chat, found.at, found.seen = args.path, title, args.chat, os.time(), false
  list[#list + 1] = found
  save(slug, list)
  if #vim.fn.win_findbuf(buf_of(slug)) > 0 then
    draw(slug)
  end
  vim.cmd.redrawstatus()
  return true, "", true
end

return M
