-- Watches isovim's own source and swaps in new code. Never reloaded itself, so edits here need a restart.
local M = {}

local dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local watcher, timer

local function reload()
  local old = {}
  for name, mod in pairs(package.loaded) do
    if (name == "isovim" or name:match("^isovim%.")) and name ~= "isovim.reload" then
      old[name] = mod
      package.loaded[name] = nil
    end
  end
  local ok, err = pcall(function()
    require("isovim").setup({ reload = true })
  end)
  if ok then
    Snacks.notify.info("isovim reloaded")
    return
  end
  for name, mod in pairs(old) do
    package.loaded[name] = mod
  end
  pcall(old.isovim.setup, { reload = true })
  Snacks.notify.error("isovim reload failed, kept the old code:\n" .. err)
end

-- Pilots call this instead of touching files, which would reload every running isovim.
M.reload = reload

function M.watch()
  if watcher then
    return
  end
  watcher = assert(vim.uv.new_fs_event())
  timer = assert(vim.uv.new_timer())
  -- Debounced: one editor save can fire several events (write, rename, chmod).
  watcher:start(vim.uv.fs_realpath(dir) or dir, {}, function(err, filename)
    if err or not filename or not filename:match("%.lua$") or filename == "reload.lua" then
      return
    end
    timer:stop()
    timer:start(150, 0, vim.schedule_wrap(reload))
  end)
end

return M
