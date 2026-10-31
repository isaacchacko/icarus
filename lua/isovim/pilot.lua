-- Pilot mode: an agent asks to drive the TUI, and once allowed reads the screen and types into
-- it through `iso pilot`. Any Esc the agent didn't send itself hands control back.
local M = {}

local ns = vim.api.nvim_create_namespace("isovim_pilot")

-- Global so a hot reload keeps an ongoing session.
---@type {state: "off"|"asking"|"active"|"denied", pilot?: string, own_escs: integer}
_G.isovim_pilot = _G.isovim_pilot or { state = "off", own_escs = 0 }
local session = _G.isovim_pilot

local function notify(message, level)
  Snacks.notify(message, { id = "isovim_pilot", title = "isovim pilot", level = level, timeout = level == "warn" and false or nil })
end

function M.release(message)
  if session.state == "active" then
    notify(message or (session.pilot .. " handed control back"), "info")
  end
  session.state = "off"
  session.own_escs = 0
  vim.on_key(nil, ns)
end

-- on_key sees the pilot's keys too, so Escs it sent are counted off before one counts as yours.
local function watch_esc(key)
  if vim.fn.keytrans(key) ~= "<Esc>" then
    return
  end
  if session.own_escs > 0 then
    session.own_escs = session.own_escs - 1
    return
  end
  vim.schedule(function()
    M.release("You have control back")
  end)
end

function M.request(pilot, reason)
  if session.state == "active" or session.state == "asking" then
    return
  end
  session.state = "asking"
  session.pilot = pilot
  local prompt = ("%s wants to drive isovim: %s"):format(pilot, reason)
  vim.ui.select({ "Allow", "Deny" }, { prompt = prompt }, function(choice)
    if choice ~= "Allow" then
      session.state = "denied"
      return
    end
    session.state = "active"
    session.own_escs = 0
    vim.on_key(watch_esc, ns)
    notify(pilot .. " is driving isovim. Press Esc to take control back.", "warn")
  end)
end

function M.state()
  return session.state
end

---@param keys string in nvim key notation, e.g. "<C-h>j<CR>"
function M.input(keys)
  assert(session.state == "active", "pilot mode is not active")
  local escs = select(2, vim.fn.keytrans(vim.keycode(keys)):gsub("<Esc>", ""))
  session.own_escs = session.own_escs + escs
  vim.api.nvim_input(keys)
end

-- The screen as drawn, floats included, one string per row.
function M.screen()
  assert(session.state == "active", "pilot mode is not active")
  local rows = {}
  for row = 1, vim.o.lines do
    local cells = {}
    for col = 1, vim.o.columns do
      cells[#cells + 1] = vim.fn.screenstring(row, col)
    end
    rows[row] = table.concat(cells):gsub("%s+$", "")
  end
  return table.concat(rows, "\n")
end

return M
