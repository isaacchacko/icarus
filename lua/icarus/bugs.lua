-- The bugs agents file with ica bug (~/.icarus/bugs/<id>.json, icarus.cli) go to the agent that
-- looks after icarus: the chat whose id is in ~/.icarus/bugs/.to. icarus watches the folder; each
-- report not sent yet is sent to that chat as a prompt (shown in it as one line), and marked sent
-- ({sent: {to, at}}), so none goes twice. With no .to, they wait.
local tasks = require("icarus.tasks")

local M = {}

M.dir = tasks.ROOT .. "/bugs"

-- In _G, so a hot reload keeps one watcher.
_G.icarus_bugs = _G.icarus_bugs or {}
local state = _G.icarus_bugs

local function read(path)
  local ok, report = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  return ok and type(report) == "table" and report or nil
end

-- The chat bugs go to, if there's one.
function M.handler()
  local file = M.dir .. "/.to"
  local id = vim.fn.filereadable(file) == 1 and vim.trim(vim.fn.readfile(file)[1] or "") or ""
  return id ~= "" and require("icarus.chats").get(id) or nil
end

-- Sends each report not sent yet to the handler.
function M.deliver()
  local record = M.handler()
  if not record or vim.fn.isdirectory(M.dir) == 0 then
    return
  end
  for name, kind in vim.fs.dir(M.dir) do
    local path = M.dir .. "/" .. name
    local report = kind == "file" and name:match("^[%w-]+%.json$") and read(path)
    if report and not report.sent then
      local from = report.reporter ~= "user" and require("icarus.chats").get(report.reporter)
      local text = {
        ("Bug %s, filed with ica bug by %s at %s, from %s:"):format(report.id, from and ("the agent " .. (from.title or report.reporter)
          .. " (icarus://agent/" .. report.reporter .. ")") or report.reporter, os.date("%H:%M", report.time), report.cwd),
        "",
        report.text,
      }
      if report.images then
        text[#text + 1] = ""
        text[#text + 1] = "Images filed with it: " .. table.concat(report.images, ", ")
      end
      vim.list_extend(text, { "", ("It's in %s. Fix it in icarus, or say why not; then record what you did in it as resolution."):format(path) })
      require("icarus.acp.chat").get(record).session:prompt(table.concat(text, "\n"), nil,
        ("◉ bug %s: %s"):format(report.id, vim.fn.strcharpart(report.text:match("^[^\n]*"), 0, 70)))
      report.sent = { to = record.id, at = os.time() }
      vim.fn.writefile({ vim.json.encode(report) }, path)
    end
  end
end

-- Watches the folder, delivering a moment after it changes, and what's waiting now.
function M.watch()
  vim.fn.mkdir(M.dir, "p")
  if state.watcher then
    state.watcher:stop()
  end
  local timer = state.timer or assert(vim.uv.new_timer())
  state.timer = timer
  state.watcher = assert(vim.uv.new_fs_event())
  state.watcher:start(M.dir, {}, function()
    timer:start(500, 0, vim.schedule_wrap(function()
      require("icarus.bugs").deliver()
    end))
  end)
  vim.schedule(M.deliver)
end

return M
