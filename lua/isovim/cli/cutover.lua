-- iso cutover --dry-run | --yes: the move to v0 (isovim.cutover). The dry run only looks, and writes
-- its plan to ~/.isovim/cutover-plan.txt; --yes carries out that plan, as long as a fresh dry run
-- still matches it word for word, so what runs is what the user read.
local store = require("isovim.store")
local c = require("isovim.cli.common")

local out = c.out
local fail = c.fail

local commands = {}

-- The open TUI holds workspaces in memory and writes into them.
local function tui_open()
  local ok, lines = pcall(vim.fn.readfile, store.lock_file)
  local pid = ok and tonumber(lines[1])
  return pid and vim.uv.kill(pid, 0) == 0 and pid or nil
end

local function diff(old, new)
  local text = vim.diff(old, new, { ctxlen = 1 }) or ""
  local lines = vim.split(text, "\n", { trimempty = true })
  if #lines > 40 then
    lines = vim.list_extend(vim.list_slice(lines, 1, 40), { ("... and %d more lines"):format(#lines - 40) })
  end
  return table.concat(lines, "\n")
end

function commands.cutover(args)
  local cutover = require("isovim.cutover")
  local dry = c.flag(args, "--dry-run")
  local yes = c.flag(args, "--yes")
  if #args > 0 or dry == yes then
    fail("usage: iso cutover --dry-run, then iso cutover --yes to carry out the plan it wrote")
  end
  if dry then
    local text = cutover.render(cutover.plan())
    io.stdout:write(text)
    local file = io.open(cutover.plan_file, "w")
    if not file then
      fail("could not write " .. cutover.plan_file)
    end
    file:write(text)
    file:close()
    io.stderr:write(("iso: plan written to %s; iso cutover --yes carries it out\n"):format(store.home_relative(cutover.plan_file)))
    return
  end
  if require("isovim.root").caller() then
    fail("iso cutover is yours: run it from a plain shell, outside isovim's agents (it stops them all)")
  end
  local pid = tui_open()
  if pid then
    fail(("close the isovim TUI first (pid %d): it writes into the workspaces being moved"):format(pid))
  end
  local ok, lines = pcall(vim.fn.readfile, cutover.plan_file)
  if not ok then
    fail("no plan to carry out: run iso cutover --dry-run and read it first")
  end
  local approved = table.concat(lines, "\n") .. "\n"
  local plan = cutover.plan()
  local fresh = cutover.render(plan)
  if fresh ~= approved then
    fail(("things changed since the plan in %s was written, so it isn't what you approved:\n%s\nrun iso cutover --dry-run again and read the new plan")
      :format(store.home_relative(cutover.plan_file), diff(approved, fresh)))
  end
  if #plan.blocked > 0 then
    fail("the plan is blocked:\n  " .. table.concat(plan.blocked, "\n  "))
  end
  local done, err = cutover.run(plan)
  if not done then
    fail(("cutover stopped: %s (see %s)"):format(err, store.home_relative(cutover.log_file)))
  end
  out("cut over; the log is " .. store.home_relative(cutover.log_file))
end

return commands
