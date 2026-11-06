-- <leader>i: what's waiting on you on the task you're in, in one float: comment threads whose last
-- word is an agent's, proposals not yet accepted or rejected, decisions the peers dispute (your call;
-- icarus.democracy), and agents whose last word to you asked something. <CR> or <Tab> goes to one.
local tasks = require("icarus.tasks")

local M = {}

local function short(text, n)
  text = vim.trim((text or ""):gsub("%s+", " "))
  return vim.fn.strchars(text) > n and vim.fn.strcharpart(text, 0, n - 1) .. "…" or text
end

local function agent(id)
  local record = id and require("icarus.chats").get(id)
  return ((record and record.title or id or "an agent"):gsub("^⑂ ", ""))
end

-- What's waiting on you on the task slug, as {text, target} rows.
function M.rows(slug)
  local watch = require("icarus.watch")
  local dir = tasks.dir(slug) .. "/"
  local rows = {}
  for _, open in ipairs(watch.threads_under(dir)) do
    local thread = watch.thread(open.item)
    local last = thread[#thread]
    if not open.line and open.item.anchor and vim.fn.filereadable(open.path) == 1 then
      open.line = vim.fn.index(vim.fn.readfile(open.path), open.item.anchor) + 1
      open.line = open.line > 0 and open.line or nil
    end
    if last and last.who ~= "you" then
      rows[#rows + 1] = { ("comment  %s:%s  %s: %s"):format(open.path:sub(#dir + 1), open.line or "?",
        short(agent(last.chat or open.item.chat), 24), short(last.text, 90)), open.path .. (open.line and (":" .. open.line) or "") }
    end
  end
  for _, p in ipairs(watch.proposals_under(dir)) do
    rows[#rows + 1] = { ("proposal %s:%s  %s%s"):format(p.path:sub(#dir + 1), p.line or "?", short(agent(p.chat), 24),
      p.note and (": " .. short(p.note, 80)) or ""), p.path .. (p.line and (":" .. p.line) or "") }
  end
  for _, d in ipairs(require("icarus.democracy").disputed(slug)) do
    local against = vim.tbl_map(function(o)
      return short(agent(o.by), 16) .. ": " .. short(o.why, 40)
    end, d.objections or {})
    rows[#rows + 1] = { ("disputed %s  %s: %s  ✗ %s"):format(d.id, short(agent(d.by), 16), short(d.text, 50),
      table.concat(against, "; ")), function()
      require("icarus.democracy").ask(slug, d.id)
    end }
  end
  for _, each in ipairs(require("icarus.democracy").landed(slug)) do
    local against = #each.against > 0 and ("  vs " .. table.concat(vim.tbl_map(agent, each.against), ", ")) or ""
    rows[#rows + 1] = { ("landed   %s: %s%s"):format(short(agent(each.id), 24), short(each.claim.what, 80), against), "icarus://agent/" .. each.id }
  end
  for _, record in ipairs(require("icarus.chats").on_task(slug)) do
    local said = require("icarus.acp.thread").said(record) or {}
    for i = #said, 1, -1 do
      if said[i].who ~= "tools" then
        if said[i].who == "agent" and vim.trim(said[i].text):match("%?%s*$") then
          rows[#rows + 1] = { ("asked    %s: %s"):format(short(agent(record.id), 24), short(vim.trim(said[i].text):match("[^\n]*$"), 90)),
            "icarus://agent/" .. record.id }
        end
        break
      end
    end
  end
  return rows
end

function M.open()
  local view = require("icarus").view()
  local record = not (view and view.task) and require("icarus").current() and require("icarus.chats").get(require("icarus").current())
  local slug = view and view.task or record and record.task
  if not slug then
    return vim.notify("No task here: open one first", vim.log.levels.WARN)
  end
  local rows = M.rows(slug)
  local lines = vim.tbl_map(function(row)
    return row[1]
  end, rows)
  if #lines == 0 then
    lines = { "nothing is waiting on you" }
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = math.min(140, math.floor(vim.o.columns * 0.8))
  local height = math.min(#lines, math.floor(vim.o.lines * 0.6))
  local win = vim.api.nvim_open_win(buf, true, { relative = "editor", width = width, height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1, col = math.floor((vim.o.columns - width) / 2), border = "rounded",
    title = " waiting on you ", title_pos = "center", footer = " <CR> go · q close ", footer_pos = "right" })
  vim.wo[win].cursorline, vim.wo[win].wrap = true, false
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true })
  end
  for _, lhs in ipairs({ "<CR>", "<Tab>" }) do
    vim.keymap.set("n", lhs, function()
      local row = rows[vim.api.nvim_win_get_cursor(win)[1]]
      if row then
        close()
        if type(row[2]) == "function" then
          row[2]()
        else
          require("icarus.links").open(row[2])
        end
      end
    end, { buffer = buf, nowait = true })
  end
end

return M
