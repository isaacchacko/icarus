-- Pilot mode: an agent asks to drive the TUI, and once allowed reads the screen and types into
-- it through `iso pilot`. Any Esc the agent didn't send itself hands control back. One agent at a
-- time: the holder is the one asking or driving, and only it may type, read or release.
local M = {}

local ns = vim.api.nvim_create_namespace("isovim_pilot")

-- Global so a hot reload keeps an ongoing session.
---@type {state: "off"|"asking"|"active"|"denied", pilot?: string, asks?: integer, own_escs: integer}
_G.isovim_pilot = _G.isovim_pilot or { state = "off", own_escs = 0 }
local session = _G.isovim_pilot

local function notify(message, level)
  Snacks.notify(message, { id = "isovim_pilot", title = "isovim pilot", level = level, timeout = level == "warn" and false or nil })
end

local function hand_back(message)
  if session.state == "active" then
    notify(message or (session.pilot .. " handed control back"), "info")
  end
  session.state = "off"
  session.pilot = nil
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
    hand_back("You have control back")
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

-- The holder, as anyone else is told: nil when no one is asking or driving.
local function holder()
  if session.state == "active" then
    return "held by " .. session.pilot
  elseif session.state == "asking" then
    return session.pilot .. " is asking"
  end
end

-- The pilot takes control when the countdown ends. Accepting skips the wait; declining, or closing
-- the prompt, cancels. Returns why not when another pilot holds control.
function M.request(pilot, reason)
  if holder() then
    return session.pilot ~= pilot and "busy: " .. holder() or nil
  end
  session.state = "asking"
  session.pilot = pilot
  session.asks = (session.asks or 0) + 1
  -- An earlier request's prompt or timer can outlive it by up to a second.
  local ask = session.asks
  local function still_asking()
    return session.state == "asking" and session.asks == ask
  end
  local left = M.countdown
  local function title()
    return ("%s wants to drive isovim: %s · taking control in %ds"):format(pilot, reason, left)
  end
  local picker = Snacks.picker.select({ "Accept now", "Decline" }, { prompt = title() }, function(choice)
    if not still_asking() then
      return
    end
    if choice == "Accept now" then
      grant(pilot)
    else
      session.state = "denied"
      session.pilot = nil
    end
  end)
  local timer = assert(vim.uv.new_timer())
  timer:start(1000, 1000, vim.schedule_wrap(function()
    if not still_asking() then
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

function M.status()
  return { state = session.state, holder = (session.state == "active" or session.state == "asking") and session.pilot or nil }
end

-- What only the pilot driving may do.
local holder_only = {}

---@param keys string in nvim key notation, e.g. "<C-h>j<CR>"
function holder_only.keys(keys)
  local escs = select(2, vim.fn.keytrans(vim.keycode(keys)):gsub("<Esc>", ""))
  session.own_escs = session.own_escs + escs
  vim.api.nvim_input(keys)
end

-- The screen as drawn, floats included, one string per row.
function holder_only.screen()
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

function holder_only.release()
  hand_back()
end

-- Runs one of holder_only's actions for `pilot`: { result = ... }, or { refused = why } when it
-- isn't the pilot driving.
function M.as_holder(pilot, action, ...)
  if session.state == "active" and session.pilot == pilot then
    return { result = holder_only[action](...) }
  end
  return { refused = session.pilot ~= pilot and holder() or "pilot mode is not active" }
end

return M
