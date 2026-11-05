-- Images in a prompt, as Claude Code's prompt takes them. In the composer, <C-v> in insert mode
-- pastes the clipboard's image, or, with no image there, is vim's own <C-v>. The image shows as a
-- chip, [Image #n], text you edit like any other: deleting it drops the image. The clipboard is read
-- in the background and the chip lands where the paste started.
--
-- Every image is a PNG under stdpath("data")/images. The session reads it into an ACP image block
-- when the prompt goes, or names the file in the text for an adapter that takes no images.
local M = {}

local NS = vim.api.nvim_create_namespace("icarus_acp_images")
-- Where each paste's chip will go, apart from the chips' highlights, which are redrawn as you type.
local PENDING = vim.api.nvim_create_namespace("icarus_acp_images_pending")
local GROUP = vim.api.nvim_create_augroup("icarus_acp_images", { clear = false })
local DIR = vim.fn.stdpath("data") .. "/images"

---@class icarus.acp.Image
---@field path string
---@field mimeType string

-- Each composer's images by chip number; kept across a hot reload.
---@type table<integer, {images: table<integer, icarus.acp.Image>, next: integer}>
_G.icarus_acp_images = _G.icarus_acp_images or {}
local boxes = _G.icarus_acp_images

function M.chip(n)
  return ("[Image #%d]"):format(n)
end

-- The text with its images numbered as their chips first appear in it; an image whose chip
-- isn't in the text is dropped.
---@return string text, icarus.acp.Image[] images
local function renumber(text, images)
  local order, new = {}, {}
  for n in text:gmatch("%[Image #(%d+)%]") do
    n = tonumber(n)
    if images[n] and not new[n] then
      order[#order + 1] = images[n]
      new[n] = #order
    end
  end
  text = text:gsub("%[Image #(%d+)%]", function(n)
    return new[tonumber(n)] and M.chip(new[tonumber(n)]) or nil
  end)
  return text, order
end

-- The prompt's ACP content: its text, then each image as a block when the adapter takes images
-- (promptCapabilities.image), else named in the text by its path.
---@param images? icarus.acp.Image[]
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

local function new_name()
  return ("%s-%s.png"):format(os.date("%Y%m%d-%H%M%S"), vim.fn.sha256(tostring(vim.uv.hrtime())):sub(1, 6))
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

local function highlight(buf)
  local box = boxes[buf]
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    for from, n, to in line:gmatch("()%[Image #(%d+)%]()") do
      if box.images[tonumber(n)] then
        vim.api.nvim_buf_set_extmark(buf, NS, row - 1, from - 1, { end_col = to - 1, hl_group = "IcarusAcpImage" })
      end
    end
  end
end

-- Attaches the clipboard's image at the cursor, read without blocking. With no image there, <C-v>
-- is vim's own once it's known, if nothing was typed meanwhile.
function M.paste_clipboard(buf)
  vim.fn.mkdir(DIR, "p")
  local path = DIR .. "/" .. new_name()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local mark = vim.api.nvim_buf_set_extmark(buf, PENDING, row - 1, col, { right_gravity = false })
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  clipboard_png(path, function(ok)
    if not (vim.api.nvim_buf_is_valid(buf) and boxes[buf]) then
      return
    end
    local at = vim.api.nvim_buf_get_extmark_by_id(buf, PENDING, mark, {})
    vim.api.nvim_buf_del_extmark(buf, PENDING, mark)
    if not ok then
      local untouched = vim.api.nvim_get_current_buf() == buf and vim.api.nvim_buf_get_changedtick(buf) == tick
        and vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
      if untouched then
        return vim.api.nvim_feedkeys(vim.keycode("<C-v>"), "n", false)
      end
      return vim.notify("no image on the clipboard", vim.log.levels.WARN)
    end
    local box = boxes[buf]
    local n = box.next
    box.images[n], box.next = { path = path, mimeType = "image/png" }, n + 1
    local chip = M.chip(n) .. " "
    vim.api.nvim_buf_set_text(buf, at[1], at[2], at[1], at[2], { chip })
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      local cursor = vim.api.nvim_win_get_cursor(win)
      if cursor[1] - 1 == at[1] and cursor[2] >= at[2] then
        vim.api.nvim_win_set_cursor(win, { cursor[1], cursor[2] + #chip })
      end
    end
    highlight(buf)
  end)
end

-- What the composer sends: its text and its images, numbered in the order their chips appear.
---@return string text, icarus.acp.Image[] images
function M.collect(buf, text)
  local box = boxes[buf]
  if not box then
    return text, {}
  end
  return renumber(text, box.images)
end

-- Makes buf a composer that takes images. Again (a hot reload's rebind) it maps <C-v> again and
-- keeps what's attached.
function M.setup(buf)
  vim.keymap.set("i", "<C-v>", function()
    M.paste_clipboard(buf)
  end, { buffer = buf, desc = "Paste the clipboard's image (else insert a key literally)" })
  if boxes[buf] then
    return
  end
  local box = { images = {}, next = 1 }
  boxes[buf] = box
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = GROUP,
    buffer = buf,
    callback = function()
      -- Emptied (sent, or cleared): the next image is #1 again.
      if vim.api.nvim_buf_line_count(buf) == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "" then
        box.images, box.next = {}, 1
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

return M
