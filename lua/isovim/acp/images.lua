-- Images in what you send an agent, as Claude Code's prompt takes them. In a composer (the chat's,
-- or a surface's input box) <C-v> in insert mode pastes the clipboard's image, or, with no image
-- there, is vim's own <C-v>; a path to an image pasted or dropped in (a terminal types a drop as a
-- bracketed paste of its path, often quoted or backslash-escaped) attaches that file, and so does
-- one typed in, once you send. Each shows in the box as a chip, [Image #n], text you edit like any
-- other: deleting it drops the image. Neither blocks: the clipboard is read and a file copied in
-- the background, the statusline showing a bar meanwhile (M.status, a lualine component), and the
-- chip lands where the paste started.
--
-- Every image is a file under the repo's iso/images/: the clipboard's is written there as a PNG,
-- and a dropped file is copied there, since a screenshot dragged from macOS's thumbnail is a temp
-- file that's soon gone. A prompt carries its images by path ({path, mimeType}), so the queue keeps
-- them small (iso/journal/aN.queue.json) and the supervisor reads them into ACP image blocks only
-- when the prompt goes (isovim.acp.host), or names the files in the text for an adapter that takes
-- no images. An image's number is its place in the prompt's list: [Image #1] is images[1].
local M = {}

local NS = vim.api.nvim_create_namespace("isovim_acp_images")
-- Where each paste's chip will go, apart from the chips' highlights, which are redrawn as you type.
local PENDING = vim.api.nvim_create_namespace("isovim_acp_images_pending")
-- Its own group, which a chat's rebind (isovim.acp.chat) leaves alone, as it keeps the box.
local GROUP = vim.api.nvim_create_augroup("isovim_acp_images", { clear = false })

local MIME = { png = "image/png", jpg = "image/jpeg", jpeg = "image/jpeg", gif = "image/gif", webp = "image/webp" }

---@class isovim.acp.Image
---@field path string
---@field mimeType string

---@type table<integer, {dir: string, images: table<integer, isovim.acp.Image>, next: integer}>
_G.isovim_acp_images = _G.isovim_acp_images or {}
local boxes = _G.isovim_acp_images

function M.chip(n)
  return ("[Image #%d]"):format(n)
end

function M.mime(path)
  return MIME[(path:match("%.(%w+)$") or ""):lower()]
end

-- The text and images with the images numbered as their chips first appear in the text. An image
-- whose chip isn't in the text is dropped, or with missing = "append" given a chip at the end.
---@param images table<integer, isovim.acp.Image> by number (a list, or a box's sparse map)
---@return string text, isovim.acp.Image[] images
function M.renumber(text, images, missing)
  local order, new = {}, {}
  for n in text:gmatch("%[Image #(%d+)%]") do
    n = tonumber(n)
    if images[n] and not new[n] then
      order[#order + 1] = images[n]
      new[n] = #order
    end
  end
  if missing == "append" then
    local unchipped = vim.tbl_filter(function(n)
      return not new[n]
    end, vim.tbl_keys(images))
    table.sort(unchipped)
    for _, n in ipairs(unchipped) do
      order[#order + 1] = images[n]
      new[n] = #order
      text = text .. (text == "" and "" or " ") .. M.chip(n)
    end
  end
  text = text:gsub("%[Image #(%d+)%]", function(n)
    return new[tonumber(n)] and M.chip(new[tonumber(n)]) or nil
  end)
  return text, order
end

-- The prompt's ACP content: its text, then each image as a block when the adapter takes images
-- (promptCapabilities.image), else named in the text by its path.
---@param images? isovim.acp.Image[]
function M.blocks(text, images, takes_images)
  local blocks, refs = {}, {}
  for n, image in ipairs(images or {}) do
    local file = takes_images and io.open(image.path, "rb")
    if file then
      blocks[#blocks + 1] = { type = "image", mimeType = image.mimeType, data = vim.base64.encode(file:read("a")) }
      file:close()
    else
      refs[#refs + 1] = ("%s: %s"):format(M.chip(n), image.path)
    end
  end
  if #refs > 0 then
    text = text .. "\n\n" .. table.concat(refs, "\n")
  end
  table.insert(blocks, 1, { type = "text", text = text })
  return blocks
end

-- A pasted text's words as a shell would split them: quotes and backslash escapes undone.
local function words(text)
  local out, word, quote, i = {}, nil, nil, 1
  while i <= #text do
    local ch = text:sub(i, i)
    if quote then
      if ch == quote then
        quote = nil
      else
        word = word .. ch
      end
    elseif ch == "\\" and i < #text then
      i = i + 1
      word = (word or "") .. text:sub(i, i)
    elseif ch == "'" or ch == '"' then
      quote, word = ch, word or ""
    elseif ch:match("%s") then
      out[#out + 1], word = word, nil
    else
      word = (word or "") .. ch
    end
    i = i + 1
  end
  out[#out + 1] = word
  return not quote and out or {}
end

-- The image file a word names (a path, ~/…, or a file:// URL), if it is one.
local function image_file(word)
  word = word:gsub("^file://", ""):gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  word = word:gsub("^~/", vim.env.HOME .. "/")
  if word:sub(1, 1) == "/" and M.mime(word) and vim.fn.filereadable(word) == 1 then
    return word
  end
end

-- The image files a pasted text is, when it's nothing but paths to them (or one path, spaces and all).
function M.paths(text)
  local whole = image_file(vim.trim(text))
  if whole then
    return { whole }
  end
  local found = {}
  for _, word in ipairs(words(vim.trim(text))) do
    local path = image_file(word)
    if not path then
      return nil
    end
    found[#found + 1] = path
  end
  return #found > 0 and found or nil
end

local function new_name(ext)
  return ("%s-%s.%s"):format(os.date("%Y%m%d-%H%M%S"), vim.fn.sha256(tostring(vim.uv.hrtime())):sub(1, 6), ext)
end

-- Runs cmd without waiting on it, then done(result) on the main loop; one that can't start fails.
local function run(cmd, done)
  if not pcall(vim.system, cmd, { timeout = 10000 }, vim.schedule_wrap(done)) then
    done({ code = 1, stdout = "" })
  end
end

local function is_png(path)
  local file = io.open(path, "rb")
  local head = file and file:read(4)
  if file then
    file:close()
  end
  return head == "\137PNG"
end

-- Writes the clipboard's image to path as a PNG, then done(true): pngpaste if it's there, else
-- osascript on macOS; wl-paste on Wayland, xclip on X. done(false) when the clipboard holds none.
local function clipboard_png(path, done)
  local function written()
    if is_png(path) then
      return done(true)
    end
    os.remove(path)
    done(false)
  end
  if vim.fn.executable("pngpaste") == 1 then
    return run({ "pngpaste", path }, written)
  elseif vim.fn.has("mac") == 1 then
    return run({ "osascript", "-e", "on run argv", "-e", "set png to (the clipboard as «class PNGf»)",
      "-e", "set f to open for access (POSIX file (item 1 of argv)) with write permission",
      "-e", "set eof f to 0", "-e", "write png to f", "-e", "close access f", "-e", "end run", path }, written)
  end
  local list, read
  if vim.env.WAYLAND_DISPLAY and vim.fn.executable("wl-paste") == 1 then
    list, read = { "wl-paste", "--list-types" }, { "wl-paste", "--no-newline", "--type", "image/png" }
  elseif vim.fn.executable("xclip") == 1 then
    list, read = { "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" }, { "xclip", "-selection", "clipboard", "-t", "image/png", "-o" }
  else
    return done(false)
  end
  run(list, function(types)
    if not (types.stdout or ""):find("image/png", 1, true) then
      return done(false)
    end
    run(read, function(png)
      local file = png.code == 0 and png.stdout ~= "" and io.open(path, "wb")
      if file then
        file:write(png.stdout)
        file:close()
      end
      written()
    end)
  end)
end

-- Copies from to to a chunk at a time, counting job.done of job.total bytes, then done(err).
local CHUNK = 256 * 1024
local function copy(from, to, job, done)
  local uv = vim.uv
  done = vim.schedule_wrap(done)
  uv.fs_open(from, "r", 438, function(open_err, src)
    if not src then
      return done(open_err)
    end
    job.total = (uv.fs_fstat(src) or {}).size
    uv.fs_open(to, "w", 420, function(err, dst)
      if not dst then
        uv.fs_close(src)
        return done(err)
      end
      local function step()
        uv.fs_read(src, CHUNK, job.done, function(read_err, data)
          if read_err or not data or data == "" then
            uv.fs_close(src)
            uv.fs_close(dst)
            return done(read_err)
          end
          uv.fs_write(dst, data, job.done, function(write_err)
            if write_err then
              uv.fs_close(src)
              uv.fs_close(dst)
              return done(write_err)
            end
            job.done = job.done + #data
            step()
          end)
        end)
      end
      step()
    end)
  end)
end

local function highlight(buf)
  local box = boxes[buf]
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    for from, n, to in line:gmatch("()%[Image #(%d+)%]()") do
      if box.images[tonumber(n)] then
        vim.api.nvim_buf_set_extmark(buf, NS, row - 1, from - 1, { end_col = to - 1, hl_group = "IsovimAcpImage" })
      end
    end
  end
end

-- The statusline while an image pastes: a bar, filling with the bytes copied when that's known,
-- else sweeping; then, for a few seconds, what went wrong if it failed (M.status).
---@type {buf: integer, mark: integer, done: integer, total?: integer, tick: integer}[]
local jobs = {}
local notice ---@type {text: string, till: number}?
local timer ---@type uv.uv_timer_t?
local CELLS = 6

function M.status()
  local job = jobs[#jobs]
  if job then
    local cells = {}
    local filled = job.total and job.total > 0 and math.floor(job.done / job.total * CELLS + 0.5)
    local head = math.floor(vim.uv.now() / 120) % (CELLS + 3)
    for i = 1, CELLS do
      local on = filled and i <= filled or (not filled and i > head - 3 and i <= head)
      cells[i] = on and "▰" or "▱"
    end
    return "󰋩 pasting image " .. table.concat(cells)
  end
  return notice and vim.uv.now() < notice.till and "󰋩 " .. notice.text or ""
end

local function redraw()
  pcall(vim.cmd, "redrawstatus!")
end

local function animate()
  if timer then
    return
  end
  timer = vim.uv.new_timer()
  timer:start(0, 120, vim.schedule_wrap(function()
    redraw()
    if #jobs == 0 and M.status() == "" and timer then
      timer:stop()
      timer:close()
      timer = nil
    end
  end))
end

-- A paste starts: the chip will go where the cursor is now (at, if given), whatever's typed meanwhile.
local function begin(buf, at)
  if not at then
    local win = vim.fn.bufwinid(buf)
    local row, col = unpack(vim.api.nvim_win_get_cursor(win ~= -1 and win or 0))
    -- In normal mode it goes after the character under the cursor, as p puts it.
    if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
      col = math.min(col + 1, #(vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""))
    end
    at = { row - 1, col }
  end
  local job = { buf = buf, done = 0, tick = vim.api.nvim_buf_get_changedtick(buf),
    mark = vim.api.nvim_buf_set_extmark(buf, PENDING, at[1], at[2], { right_gravity = false }) }
  jobs[#jobs + 1] = job
  animate()
  return job
end

-- A paste ends: image's chip goes in at its place, or, failed, the statusline says why for a while.
-- Returns where the chip ends.
local function finish(job, image, err)
  jobs = vim.tbl_filter(function(each)
    return each ~= job
  end, jobs)
  if err then
    notice = { text = err, till = vim.uv.now() + 4000 }
    animate()
  end
  local buf = job.buf
  if not (vim.api.nvim_buf_is_valid(buf) and boxes[buf]) then
    return
  end
  local row, col = unpack(vim.api.nvim_buf_get_extmark_by_id(buf, PENDING, job.mark, {}))
  vim.api.nvim_buf_del_extmark(buf, PENDING, job.mark)
  redraw()
  if not image then
    return
  end
  local box = boxes[buf]
  local n = box.next
  box.images[n], box.next = image, n + 1
  local chip = M.chip(n) .. " "
  vim.api.nvim_buf_set_text(buf, row, col, row, col, { chip })
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local cursor = vim.api.nvim_win_get_cursor(win)
    if cursor[1] - 1 == row and cursor[2] >= col then
      vim.api.nvim_win_set_cursor(win, { cursor[1], cursor[2] + #chip })
    end
  end
  highlight(buf)
  return { row, col + #chip }
end

-- Attaches copies of the image files at paths, one after the other, each chip after the last.
function M.attach_files(buf, paths, at)
  local path = table.remove(paths, 1)
  if not path then
    return
  end
  local box = boxes[buf]
  vim.fn.mkdir(box.dir, "p")
  local dest = box.dir .. "/" .. new_name((path:match("%.(%w+)$") or "png"):lower())
  local job = begin(buf, at)
  copy(path, dest, job, function(err)
    if err then
      os.remove(dest)
      finish(job, nil, ("could not attach %s: %s"):format(vim.fs.basename(path), err))
      return M.attach_files(buf, paths)
    end
    M.attach_files(buf, paths, finish(job, { path = dest, mimeType = M.mime(path) }))
  end)
end

-- Attaches the clipboard's image, read without blocking. With no image there, <C-v> is vim's own
-- once it's known, if nothing was typed meanwhile.
function M.paste_clipboard(buf)
  local box = boxes[buf]
  vim.fn.mkdir(box.dir, "p")
  local path = box.dir .. "/" .. new_name("png")
  local job = begin(buf)
  clipboard_png(path, function(ok)
    if ok then
      return finish(job, { path = path, mimeType = "image/png" })
    end
    local untouched = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_current_buf() == buf
      and vim.api.nvim_buf_get_changedtick(buf) == job.tick and vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
    finish(job, nil, not untouched and "no image on the clipboard" or nil)
    if untouched then
      vim.api.nvim_feedkeys(vim.keycode("<C-v>"), "n", false)
    end
  end)
end

-- What the box sends: its text, an image path typed into it made an attachment, and its images
-- numbered in the order their chips appear.
---@return string text, isovim.acp.Image[] images
function M.collect(buf, text)
  local box = boxes[buf]
  if not box then
    return text, {}
  end
  text = text:gsub("%S+", function(word)
    local path = image_file(words(word)[1] or "")
    if not path then
      return nil
    end
    local n = box.next
    box.images[n], box.next = { path = path, mimeType = M.mime(path) }, n + 1
    return M.chip(n)
  end)
  return M.renumber(text, box.images)
end

-- Gives the box these images (a prompt put back in it), numbered as their chips in its text are.
---@param images? isovim.acp.Image[]
function M.set(buf, images)
  local box = boxes[buf]
  box.images, box.next = {}, 1
  for n, image in ipairs(images or {}) do
    box.images[n], box.next = image, n + 1
  end
  highlight(buf)
end

-- Makes buf a box that takes images, saved under dir. Again (a hot reload's rebind) it maps <C-v>
-- again and keeps what's attached.
function M.setup(buf, dir)
  vim.keymap.set("i", "<C-v>", function()
    M.paste_clipboard(buf)
  end, { buffer = buf, desc = "isovim: paste the clipboard's image (else insert a key literally)" })
  if boxes[buf] then
    return
  end
  boxes[buf] = { dir = dir, images = {}, next = 1 }
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = GROUP,
    buffer = buf,
    callback = function()
      -- Emptied (sent, or cleared): the next image is #1 again.
      if vim.api.nvim_buf_line_count(buf) == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "" then
        boxes[buf].images, boxes[buf].next = {}, 1
      end
      highlight(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = GROUP,
    buffer = buf,
    callback = function()
      boxes[buf] = nil
    end,
  })
end

-- A paste into a box that's nothing but image paths (a file dropped on the terminal) attaches them.
local paste = _G.isovim_acp_paste or vim.paste
_G.isovim_acp_paste = paste
vim.paste = function(lines, phase)
  local buf = vim.api.nvim_get_current_buf()
  local found = boxes[buf] and phase == -1 and M.paths(table.concat(lines, "\n"))
  if not found then
    return paste(lines, phase)
  end
  M.attach_files(buf, found)
  return true
end

return M
