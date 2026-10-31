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

-- Seconds a request waits before the pilot takes control on its own.
M.countdown = 10

local function grant(pilot)
  session.state = "active"
  session.own_escs = 0
  vim.on_key(watch_esc, ns)
  notify(pilot .. " is driving isovim. Press Esc to take control back.", "warn")
end

-- The pilot takes control when the countdown ends. Accepting skips the wait; declining, or closing
-- the prompt, cancels.
function M.request(pilot, reason)
  if session.state == "active" or session.state == "asking" then
    return
  end
  session.state = "asking"
  session.pilot = pilot
  local left = M.countdown
  local function title()
    return ("%s wants to drive isovim: %s · taking control in %ds"):format(pilot, reason, left)
  end
  local picker = Snacks.picker.select({ "Accept now", "Decline" }, { prompt = title() }, function(choice)
    if session.state ~= "asking" then
      return
    end
    if choice == "Accept now" then
      grant(pilot)
    else
      session.state = "denied"
    end
  end)
  local timer = assert(vim.uv.new_timer())
  timer:start(1000, 1000, vim.schedule_wrap(function()
    if session.state ~= "asking" then
      return timer:close()
    end
    left = left - 1
    if left > 0 then
      picker.title = title()
      return picker:update_titles()
    end
    timer:close()
    grant(pilot)
    picker:close()
  end))
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
