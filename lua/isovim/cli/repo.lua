-- iso repo: by-hand helpers for a repo's personal config (isovim.repoconf), until the commands that
-- use it land.
local c = require("isovim.cli.common")

local out = c.out
local fail = c.fail

local commands = {}

local function absolute(dir)
  return vim.fs.normalize(vim.fn.fnamemodify(dir, ":p"))
end

function commands.repo(args)
  local sub = table.remove(args, 1)
  local repoconf, repos = require("isovim.repoconf"), require("isovim.repos")
  if sub == "import" then
    local dir = absolute(args[1] or ".")
    local name = repos.of(dir) or fail(dir .. " has no origin to name its repo by")
    out(repoconf.import(dir) and "imported into " .. repos.dir(name) .. "/config.json" or "nothing to import")
  elseif sub == "base" then
    local from = c.option(args, "--from")
    local name = args[1] and repos.normalize(args[1]) or fail("usage: iso repo base <owner/repo> [--from <checkout>]")
    local path, err = repoconf.base(name, from and absolute(from))
    out(path or fail(err))
  else
    fail("usage: iso repo import [<dir>] | iso repo base <owner/repo> [--from <checkout>]")
  end
end

return commands
