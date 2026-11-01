-- Images in what you send an agent, as Claude Code's prompt takes them. In a composer (the chat's,
-- or a surface's input box) <C-v> in insert mode pastes the clipboard's image, or, with no image
-- there, is vim's own <C-v>; a path to an image pasted or dropped in (a terminal types a drop as a
-- bracketed paste of its path, often quoted or backslash-escaped) attaches that file, and so does
-- one typed in, once you send. Each shows in the box as a chip, [Image #n], text you edit like any
-- other: deleting it drops the image.
--
-- Every image is a file under the repo's iso/images/: the clipboard's is written there as a PNG,
-- and a dropped file is copied there, since a screenshot dragged from macOS's thumbnail is a temp
-- file that's soon gone. A prompt carries its images by path ({path, mimeType}), so the queue keeps
-- them small (iso/journal/aN.queue.json) and the supervisor reads them into ACP image blocks only
-- when the prompt goes (isovim.acp.host), or names the files in the text for an adapter that takes
-- no images. An image's number is its place in the prompt's list: [Image #1] is images[1].
local M = {}

local NS = vim.api.nvim_create_namespace("isovim_acp_images")
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

local function run(cmd)
  local ok, result = pcall(function()
    return vim.system(cmd):wait(5000)
  end)
  return ok and result or { code = 1, stdout = "" }
end

local function is_png(path)
  local file = io.open(path, "rb")
  local head = file and file:read(4)
  if file then
    file:close()
  end
  return head == "\137PNG"
end

-- Writes the clipboard's image to path as a PNG: pngpaste if it's there, else osascript on macOS;
-- wl-paste on Wayland, xclip on X. False when the clipboard holds no image.
local function clipboard_png(path)
  if vim.fn.executable("pngpaste") == 1 then
    run({ "pngpaste", path })
  elseif vim.fn.has("mac") == 1 then
    run({ "osascript", "-e", "on run argv", "-e", "set png to (the clipboard as «class PNGf»)",
      "-e", "set f to open for access (POSIX file (item 1 of argv)) with write permission",
      "-e", "set eof f to 0", "-e", "write png to f", "-e", "close access f", "-e", "end run", path })
  else
    local list, read
    if vim.env.WAYLAND_DISPLAY and vim.fn.executable("wl-paste") == 1 then
      list, read = { "wl-paste", "--list-types" }, { "wl-paste", "--no-newline", "--type", "image/png" }
    elseif vim.fn.executable("xclip") == 1 then
      list, read = { "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" }, { "xclip", "-selection", "clipboard", "-t", "image/png", "-o" }
    else
      return false
    end
    if not (run(list).stdout or ""):find("image/png", 1, true) then
      return false
    end
    local png = run(read)
    local file = png.code == 0 and png.stdout ~= "" and io.open(path, "wb")
    if file then
      file:write(png.stdout)
      file:close()
    end
  end
  if is_png(path) then
    return true
  end
  os.remove(path)
  return false
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

-- Attaches image to the box and puts its chip at the cursor.
local function attach(buf, image)
  local box = boxes[buf]
  local n = box.next
  box.images[n], box.next = image, n + 1
  local chip = M.chip(n) .. " "
  if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    vim.api.nvim_buf_set_text(buf, row - 1, col, row - 1, col, { chip })
    vim.api.nvim_win_set_cursor(0, { row, col + #chip })
  else
    vim.api.nvim_put({ chip }, "c", true, true)
  end
  highlight(buf)
end

-- Attaches a copy of the image file at path.
function M.attach_file(buf, path)
  local box = boxes[buf]
  vim.fn.mkdir(box.dir, "p")
  local copy = box.dir .. "/" .. new_name((path:match("%.(%w+)$") or "png"):lower())
  local ok, err = vim.uv.fs_copyfile(path, copy)
  if not ok then
    return vim.notify("isovim: could not attach " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
  end
  attach(buf, { path = copy, mimeType = M.mime(path) })
end

-- Attaches the clipboard's image; false when it holds none.
function M.paste_clipboard(buf)
  local box = boxes[buf]
  vim.fn.mkdir(box.dir, "p")
  local path = box.dir .. "/" .. new_name("png")
  if not clipboard_png(path) then
    return false
  end
  attach(buf, { path = path, mimeType = "image/png" })
  return true
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
    if not M.paste_clipboard(buf) then
      vim.api.nvim_feedkeys(vim.keycode("<C-v>"), "n", false)
    end
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
  for _, path in ipairs(found) do
    M.attach_file(buf, path)
  end
  return true
end

return M
