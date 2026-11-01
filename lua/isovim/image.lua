-- Images, drawn by Snacks.image with the kitty graphics protocol (Ghostty, kitty, WezTerm). The TUI's
-- code runs in an nvim --embed server (bin/iso), but Snacks writes its escapes through nvim_ui_send,
-- which hands them to the TUI client and so to the terminal, and finds the terminal by its XTVERSION
-- answer, which the client passes back as a TermResponse: once the starter enables it, an image
-- file (png, jpg, gif, webp…) opened anywhere isovim opens files (isovim.show: gf from a chat, a
-- file surface, a pinned path, a pick) is an image buffer and a tab, and a markdown surface or page
-- draws its images inline. What isovim adds here:
-- - where the terminal can't draw images (iso attach over ssh, one without the protocol), an image
--   buffer is one quiet line instead of Snacks' notes;
-- - a surface's relative image path resolves against its repo's iso/ (and iso/pages/);
-- - M.open_chip: <CR> on an [Image #n] chip in a chat's conversation opens that image as a tab;
-- - M.open: a file opens as a tab; a URL (a PR's image) is fetched under run/<repo>/images/ first,
--   with gh's token for GitHub's, else it opens in the browser.
local store = require("isovim.store")

local M = {}

-- Whether the terminal draws images.
function M.drawn()
  return Snacks ~= nil and Snacks.image ~= nil and Snacks.image.supports_terminal()
end

-- Where a surface's markdown points an image: its repo's iso/, or iso/pages/ for a page.
function M.resolve(file, src)
  if src:match("^%a+://") or src:match("^/") then
    return nil
  end
  local buf = vim.fn.bufnr(file)
  local id = buf > 0 and vim.b[buf].isovim_surface
  local view = id and package.loaded["isovim.surface_view"] and require("isovim.surface_view").views[id]
  if not view then
    return nil
  end
  local dir = require("isovim.surfaces").dir(view.repo)
  for _, base in ipairs({ dir, dir .. "/pages" }) do
    local path = vim.fs.normalize(base .. "/" .. src)
    if vim.uv.fs_stat(path) then
      return path
    end
  end
end

-- An image buffer where the terminal can't draw it: one line, not Snacks' notes on the protocol.
function M.setup()
  local ok, buf = pcall(require, "snacks.image.buf")
  if not ok or buf.isovim then
    return
  end
  local attach = buf._attach
  buf.isovim = true
  buf._attach = function(b, opts)
    local file = opts and opts.src or vim.api.nvim_buf_get_name(b)
    if vim.api.nvim_buf_is_valid(b) and Snacks.image.supports_file(file) and not M.drawn() then
      vim.bo[b].modifiable = true
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { ("image: %s · this terminal doesn't draw images"):format(vim.fn.fnamemodify(file, ":t")) })
      vim.bo[b].modifiable, vim.bo[b].modified, vim.bo[b].filetype = false, false, "isovim_image"
      return
    end
    return attach(b, opts)
  end
end

local EXT = { ["image/png"] = "png", ["image/jpeg"] = "jpg", ["image/gif"] = "gif", ["image/webp"] = "webp", ["image/svg+xml"] = "svg" }

-- An image as a tab: a file as isovim.show opens one; a URL fetched first (in the background), the
-- browser if it can't be.
---@param src string a path or a URL
---@param repo? string the repo key whose run/ keeps a fetched one
function M.open(src, repo)
  if not src:match("^https?://") then
    local path = vim.fs.normalize(src)
    if not vim.uv.fs_stat(path) then
      return vim.notify("isovim: no image " .. src, vim.log.levels.WARN)
    end
    return require("isovim").show(path)
  end
  local dir = store.run_dir(repo or store.GENERAL) .. "/images"
  local stem = dir .. "/" .. vim.fn.sha256(src):sub(1, 16)
  for _, ext in pairs(EXT) do
    if vim.uv.fs_stat(stem .. "." .. ext) then
      return require("isovim").show(stem .. "." .. ext)
    end
  end
  vim.fn.mkdir(dir, "p")
  local safe = require("isovim.safe")
  local function fetch(token)
    local cmd = { "curl", "-fsSL", "--max-time", "30", "-w", "%{content_type}", "-o", stem .. ".part", src }
    if token and src:match("^https://[%w.-]*github") then
      vim.list_extend(cmd, { "-H", "Authorization: token " .. token })
    end
    vim.system(cmd, { text = true }, safe.schedule_wrap("fetching an image", function(result)
      local ext = EXT[vim.trim(result.stdout or ""):match("^[^;]+") or ""] or src:match("%.(%a+)$")
      if result.code ~= 0 or not ext then
        os.remove(stem .. ".part")
        return vim.ui.open(src)
      end
      vim.uv.fs_rename(stem .. ".part", stem .. "." .. ext)
      require("isovim").show(stem .. "." .. ext)
    end))
  end
  vim.notify("isovim: fetching the image…")
  vim.system({ "gh", "auth", "token" }, { text = true }, safe.schedule_wrap("fetching an image", function(result)
    fetch(result.code == 0 and vim.trim(result.stdout or "") or nil)
  end))
end

-- The image of the [Image #n] chip under the cursor in a chat's conversation (its prompt's images,
-- as the journal gave them), opened as a tab. False when there's no chip there.
function M.open_chip(chat)
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  for from, n, to in line:gmatch("()%[Image #(%d+)%]()") do
    if col >= from and col < to then
      local said = vim.trim((line:gsub("^%s*❯%s*", "")))
      for text, images in pairs(chat.history_images or {}) do
        local image = images[tonumber(n)]
        if image and text:find(said, 1, true) then
          M.open(image.path)
          return true
        end
      end
      vim.notify("isovim: can't find the file of [Image #" .. n .. "]", vim.log.levels.WARN)
      return true
    end
  end
  return false
end

-- A markdown line's images (![alt](src), <img src="…">): {alt, src} each.
function M.in_markdown(line)
  local found = {}
  for alt, src in line:gmatch("!%[([^%]]*)%]%(([^%)%s]+)[^%)]*%)") do
    found[#found + 1] = { alt = alt, src = src }
  end
  for tag in line:gmatch("<img[^>]*>") do
    local src = tag:match('src="([^"]+)"') or tag:match("src='([^']+)'")
    if src then
      found[#found + 1] = { alt = tag:match('alt="([^"]*)"') or "", src = src }
    end
  end
  return found
end

return M
