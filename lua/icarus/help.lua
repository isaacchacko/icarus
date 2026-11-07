-- ?: the keys you have here, read from the keymaps themselves as it opens, so it can't go out of date.
-- First what's bound on this buffer, then icarus's own that work anywhere. Keys that do the same thing
-- share a line. q, <Esc> or ? closes it.
local M = {}

local WIDTH = 72

-- What to call a key.
local function key_name(lhs)
  return (lhs:gsub("<Space>", "<leader>"):gsub(" ", "<leader>"))
end

-- Whether a global map is icarus's, not vim's or a plugin's.
local function ours(map)
  if not (map.callback and map.desc) then
    return false
  end
  return debug.getinfo(map.callback, "S").source:find("/lua/icarus/", 1, true) ~= nil
end

-- maps as lines: a line per description, its keys together, sorted by the first key.
local function lines_of(maps, skip)
  local keys, order = {}, {}
  for _, map in ipairs(maps) do
    if map.desc and map.desc ~= "" and not map.desc:match("^which%-key") and not skip[map.lhs] then
      if not keys[map.desc] then
        keys[map.desc] = {}
        order[#order + 1] = map.desc
      end
      table.insert(keys[map.desc], key_name(map.lhs))
    end
  end
  for _, each in pairs(keys) do
    table.sort(each)
  end
  table.sort(order, function(a, b)
    return keys[a][1]:lower() < keys[b][1]:lower()
  end)
  local width = 0
  for _, desc in ipairs(order) do
    width = math.max(width, #table.concat(keys[desc], " "))
  end
  width = math.min(width, 26)
  return vim.tbl_map(function(desc)
    return ("  %-" .. width .. "s  %s"):format(table.concat(keys[desc], " "), desc)
  end, order)
end

-- The view's name, for the panel's title.
local function title()
  local view = require("icarus").view() or {}
  if view.kind == "task" then
    local outline = vim.bo.filetype == "icarus_outline"
    return outline and "outline" or view.chat and "chat" or view.visual and "visual" or view.header and "header" or "file"
  end
  return view.kind or "icarus"
end

function M.open()
  local here = vim.api.nvim_buf_get_keymap(0, "n")
  local skip = {}
  for _, map in ipairs(here) do
    skip[map.lhs] = true
  end
  local lines = { "here" }
  vim.list_extend(lines, lines_of(here, {}))
  if #lines == 1 then
    lines[2] = "  nothing of its own"
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "everywhere"
  vim.list_extend(lines, lines_of(vim.tbl_filter(ours, vim.api.nvim_get_keymap("n")), skip))
  local width = WIDTH
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line) + 1)
  end
  width = math.min(width, vim.o.columns - 6)
  local height = math.min(#lines, vim.o.lines - 6)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local NS = vim.api.nvim_create_namespace("icarus_help")
  for row, line in ipairs(lines) do
    if line == "here" or line == "everywhere" then
      vim.api.nvim_buf_set_extmark(buf, NS, row - 1, 0, { end_col = #line, hl_group = "Title" })
    end
  end
  local win = vim.api.nvim_open_win(buf, true, { relative = "editor", width = width, height = height, style = "minimal",
    row = math.floor((vim.o.lines - height) / 2) - 1, col = math.floor((vim.o.columns - width) / 2), border = "rounded",
    title = " " .. title() .. " keys ", title_pos = "center" })
  for _, lhs in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", lhs, function()
      vim.api.nvim_win_close(win, true)
    end, { buffer = buf, nowait = true })
  end
end

return M
