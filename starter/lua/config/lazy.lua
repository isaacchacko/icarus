local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

-- Lazy's lockfile and LazyVim's extras are this host's, in isovim's home, so :Lazy update and
-- :LazyExtras never dirty isovim's checkout, which self-update needs clean. bin/iso seeds the
-- lockfile from starter/lazy-lock.json and replaces it when that changes. The extras start as
-- starter/lazyvim.json's, and when that changes, the extras it added or dropped since are added to
-- or dropped from this host's; the ones you toggled stay.
local home = vim.env.ISOVIM_HOME or vim.fn.expand("~/.isovim")
vim.fn.mkdir(home, "p")
vim.g.lazyvim_json = home .. "/lazyvim.json"
do
  local function read(path)
    local file = io.open(path)
    if not file then
      return nil
    end
    local ok, value = pcall(vim.json.decode, file:read("*a"))
    file:close()
    return ok and type(value) == "table" and value or nil
  end
  local function write(path, value)
    local file = io.open(path, "w")
    if file then
      file:write(vim.json.encode(value))
      file:close()
    end
  end
  local shipped = read(vim.fn.stdpath("config") .. "/lazyvim.json") or { extras = {} }
  local seeded_path = home .. "/lazyvim.seeded.json"
  local mine, seeded = read(vim.g.lazyvim_json), read(seeded_path)
  if not mine then
    write(vim.g.lazyvim_json, shipped)
    write(seeded_path, shipped)
  elseif not vim.deep_equal(shipped.extras, (seeded or {}).extras) then
    local was = {}
    for _, extra in ipairs((seeded or {}).extras or {}) do
      was[extra] = true
    end
    local now, extras = {}, {}
    for _, extra in ipairs(shipped.extras or {}) do
      now[extra] = true
    end
    for _, extra in ipairs(mine.extras or {}) do
      if now[extra] or not was[extra] then
        extras[extra] = true
      end
    end
    for extra in pairs(now) do
      if not was[extra] then
        extras[extra] = true
      end
    end
    mine.extras = vim.tbl_keys(extras)
    table.sort(mine.extras)
    write(vim.g.lazyvim_json, mine)
    write(seeded_path, shipped)
  end
end

require("lazy").setup({
  spec = {
    -- add LazyVim and import its plugins
    { "LazyVim/LazyVim", import = "lazyvim.plugins" },
    -- import/override with your plugins
    -- isovim itself: the repo this starter lives in.
    { dir = vim.fs.dirname(vim.uv.fs_realpath(vim.fn.stdpath("config"))), name = "isovim", lazy = false },
    { import = "plugins" },
  },
  defaults = {
    -- By default, only LazyVim plugins will be lazy-loaded. Your custom plugins will load during startup.
    -- If you know what you're doing, you can set this to `true` to have all your custom plugins lazy-loaded by default.
    lazy = false,
    -- It's recommended to leave version=false for now, since a lot the plugin that support versioning,
    -- have outdated releases, which may break your Neovim install.
    version = false, -- always use the latest git commit
    -- version = "*", -- try installing the latest stable version for plugins that support semver
  },
  lockfile = home .. "/lazy-lock.json",
  install = { colorscheme = { "tokyonight", "habamax" } },
  checker = {
    enabled = false, -- versions are pinned in lazy-lock.json
    notify = false, -- notify on update
  }, -- automatically check for plugin updates
  -- Its "Reloading..." re-reads the specs but applies nothing to loaded plugins; isovim.reload
  -- says when a change here needs a restart.
  change_detection = { enabled = false },
  performance = {
    rtp = {
      -- disable some rtp plugins
      disabled_plugins = {
        "gzip",
        -- "matchit",
        -- "matchparen",
        -- "netrwPlugin",
        "tarPlugin",
        "tohtml",
        "tutor",
        "zipPlugin",
      },
    },
  },
})
