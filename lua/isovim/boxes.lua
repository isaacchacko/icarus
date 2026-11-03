-- Lines drawn by isovim with their highlights, in boxes as the PR view (isovim.pr_view) and threads
-- draw them: a line is {text, marks = {{col, end_col, hl}}} (bytes from its start), built with seg
-- and cat, cut or padded to a width with fit; a box is top, side for each line, bottom; markdown
-- gives text's lines no wider than a width, its marks taken out and drawn as highlights so a box's
-- right edge stays put. The IsovimPr* colors come from the chat's palette (isovim.acp.look),
-- Claude's dark and light, set again when the colorscheme or the background changes.
local M = {}

-- Colors, from the chat's palette (isovim.acp.look: Claude's dark and light), set again when the
-- colorscheme or the background changes.
local PURPLE = { dark = "#A371F7", light = "#8250DF" }

function M.highlights()
  local look = require("isovim.acp.look")
  look.highlights()
  local mode = vim.o.background == "light" and "light" or "dark"
  local c = look.palette[mode]
  local groups = {
    IsovimPrBorder = { fg = c.rule },
    IsovimPrTitle = { fg = c.text, bold = true },
    IsovimPrDim = { fg = c.dim },
    IsovimPrOk = { fg = c.success },
    IsovimPrError = { fg = c.error },
    IsovimPrPending = { fg = c.accent },
    IsovimPrLink = { fg = c.code },
    IsovimPrAdd = { fg = c.add_nr },
    IsovimPrDelete = { fg = c.del_nr },
    IsovimPrPillOpen = { fg = c.chip_fg, bg = c.success, bold = true },
    IsovimPrPillDraft = { fg = c.chip_fg, bg = c.dim, bold = true },
    IsovimPrPillMerged = { fg = c.chip_fg, bg = PURPLE[mode], bold = true },
    IsovimPrPillClosed = { fg = c.chip_fg, bg = c.error, bold = true },
  }
  for name, spec in pairs(groups) do
    vim.api.nvim_set_hl(0, name, spec)
  end
end

vim.api.nvim_create_autocmd({ "ColorScheme", "OptionSet" }, {
  group = vim.api.nvim_create_augroup("isovim_pr_view_colors", { clear = true }),
  callback = function(ev)
    if ev.event == "ColorScheme" or ev.match == "background" then
      M.highlights()
    end
  end,
})

-- A line under construction: its text and its highlights {col, end_col, hl}, bytes from its start.
function M.seg(text, hl)
  return { text = text, marks = hl and text ~= "" and { { 0, #text, hl } } or {} }
end

function M.cat(...)
  local out = { text = "", marks = {} }
  for _, part in ipairs({ ... }) do
    for _, mark in ipairs(part.marks) do
      out.marks[#out.marks + 1] = { mark[1] + #out.text, mark[2] + #out.text, mark[3], mark[4] }
    end
    out.text = out.text .. part.text
  end
  return out
end

function M.cells(line)
  return vim.fn.strdisplaywidth(line.text)
end

-- line cut or padded to exactly width cells.
function M.fit(line, width)
  local shown = M.cells(line)
  if shown <= width then
    return M.cat(line, M.seg((" "):rep(width - shown)))
  end
  local text = line.text
  while vim.fn.strdisplaywidth(text) > width - 1 do
    text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
  end
  local out = { text = text .. "…", marks = {} }
  for _, mark in ipairs(line.marks) do
    if mark[1] < #text then
      out.marks[#out.marks + 1] = { mark[1], math.min(mark[2], #text), mark[3], mark[4] }
    end
  end
  return out
end

-- A box's top: ╭─ title ───╮ width cells wide; its bottom with a dim note in it, or none; a side.
function M.top(width, title, border)
  border = border or "IsovimPrBorder"
  local head = M.cat(M.seg("╭─ ", border), title, M.seg(" ", border))
  local rest = width - M.cells(head) - 1
  if rest < 0 then
    head = M.fit(head, width - 2)
    rest = width - M.cells(head) - 1
  end
  return M.cat(head, M.seg(("─"):rep(math.max(0, rest)) .. "╮", border))
end

function M.bottom(width, note, border)
  border = border or "IsovimPrBorder"
  local head = note and M.cat(M.seg("╰─ ", border), M.seg(note, "IsovimPrDim"), M.seg(" ", border)) or M.seg("╰", border)
  return M.cat(head, M.seg(("─"):rep(math.max(0, width - M.cells(head) - 1)) .. "╯", border))
end

function M.side(width, content, border)
  border = border or "IsovimPrBorder"
  return M.cat(M.seg("│ ", border), M.fit(content, width - 4), M.seg(" │", border))
end

-- text (markdown) as lines no wider than width: `code`, **bold** and # headings drawn, their marks
-- taken out so the box's right edge stays put, a ``` fence dimmed; tables as the chat boxes them.
function M.markdown(text, width)
  local look = require("isovim.acp.look")
  -- Its iso: addresses as chips in their place (isovim.links), joined by no-break spaces so the
  -- wrapping keeps each whole; found again in the lines below to mark them with their address.
  local links = require("isovim.links")
  local chips = {}
  text = text or ""
  local pieces, at = {}, 1
  for _, link in ipairs(links.scan(text)) do
    local parts = links.parts(link[3], links.NBSP)
    local chip = table.concat(vim.tbl_map(function(part)
      return part[1]
    end, parts))
    chips[#chips + 1] = { chip = chip, addr = link[3], parts = parts }
    pieces[#pieces + 1] = text:sub(at, link[1])
    pieces[#pieces + 1] = chip
    at = link[2] + 1
  end
  pieces[#pieces + 1] = text:sub(at)
  text = table.concat(pieces)
  local body = vim.split(vim.trim(text:gsub("\r", "")), "\n", { plain = true })
  local out, fenced, i = {}, false, 1
  local function wrapped(line, base)
    local plain, spans = look.plain(line)
    for _, piece in ipairs(look.wrap(plain, width)) do
      local part = { text = plain:sub(piece[1] + 1, piece[2]), marks = {} }
      for _, span in ipairs(base and { { 0, #plain, base } } or {}) do
        part.marks[#part.marks + 1] = { 0, #part.text, span[3] }
      end
      for _, span in ipairs(spans) do
        local from, to = math.max(span[1], piece[1]), math.min(span[2], piece[2])
        if from < to then
          part.marks[#part.marks + 1] = { from - piece[1], to - piece[1], span[3] }
        end
      end
      out[#out + 1] = part
    end
  end
  while i <= #body do
    local line = body[i]
    if line:match("^%s*```") then
      fenced = not fenced
      out[#out + 1] = M.seg(line, "IsovimPrDim")
      i = i + 1
    elseif fenced then
      out[#out + 1] = M.seg(line, "IsovimAcpCode")
      i = i + 1
    elseif look.table_row(line) and body[i + 1] and look.table_alignments(body[i + 1]) then
      local rows = {}
      while body[i] and look.table_row(body[i]) do
        rows[#rows + 1] = body[i]
        i = i + 1
      end
      local drawn, spans = look.table(rows, width)
      for r, text_ in ipairs(drawn) do
        out[#out + 1] = { text = text_, marks = {} }
        for _, span in ipairs(spans) do
          if span[1] == r - 1 then
            table.insert(out[#out].marks, { span[2], span[3], span[4] == "IsovimAcpRule" and "IsovimPrBorder" or span[4] })
          end
        end
      end
    elseif #require("isovim.image").in_markdown(line) > 0 then
      -- An image: a line naming it, <CR> opening it (isovim.image), and what else the line says.
      for _, image in ipairs(require("isovim.image").in_markdown(line)) do
        local name = image.alt ~= "" and image.alt or vim.fn.fnamemodify((image.src:gsub("[?#].*$", "")), ":t")
        local item = M.cat(M.seg("\u{f03e} ", "IsovimPrLink"), M.seg("image: " .. name, "IsovimPrLink"), M.seg("  <CR> opens", "IsovimPrDim"))
        item.image = image.src
        out[#out + 1] = item
      end
      local rest = vim.trim((line:gsub("!%[[^%]]*%]%([^%)]*%)", ""):gsub("<img[^>]*>", "")))
      if rest ~= "" then
        wrapped(rest)
      end
      i = i + 1
    else
      local heading = line:match("^#+%s+(.*)$")
      if line == "" then
        out[#out + 1] = M.seg("")
      else
        wrapped(heading or line, heading and "IsovimAcpHeading" or nil)
      end
      i = i + 1
    end
  end
  -- Each chip's parts highlighted, and the whole of it marked with its address (mark[4]). They come
  -- in the text's order, so each is the next one found: several can read the same (one host's long
  -- URLs), or one begin as another does. One that didn't survive (cut in a table) is passed over.
  local upto = 1
  for _, line in ipairs(out) do
    local from = 1
    while true do
      local index, s, e
      for k = upto, #chips do
        s, e = line.text:find(chips[k].chip, from, true)
        if s then
          index = k
          break
        end
      end
      if not index then
        break
      end
      local each, at = chips[index], s - 1
      for _, part in ipairs(each.parts) do
        line.marks[#line.marks + 1] = { at, at + #part[1], part[2] }
        at = at + #part[1]
      end
      line.marks[#line.marks + 1] = { s - 1, e, nil, each.addr }
      upto, from = index + 1, e + 1
    end
  end
  return out
end


return M
