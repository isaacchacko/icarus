-- iso attach on an ACP agent: a minimal nvim (no config, no plugins) showing just the agent's chat
-- and composer (isovim.acp.chat), as the TUI does, from any terminal or over ssh. It talks to the
-- agent's supervisor like the TUI does, so it can run beside an open TUI. Closing the chat (or
-- :qa) quits.
local M = {}

-- The command iso attach runs: this tree's isovim on the runtimepath of a clean nvim.
function M.cmd(ws, agent)
  local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))))
  local call = ("lua require('isovim.acp.attach').run(%q, %q)"):format(ws, agent)
  return { vim.v.progpath, "--clean", "--cmd", "set rtp^=" .. vim.fn.fnameescape(repo), "-c", call }
end

function M.run(ws, agent)
  vim.g.mapleader = " "
  vim.o.termguicolors = true
  -- One status line at the bottom, naming the agent; the bar above the composer says what it does.
  vim.o.laststatus = 3
  vim.o.ruler = false
  vim.o.showmode = true
  vim.o.title = true
  local spec = require("isovim.store").agent(ws, agent) or {}
  vim.o.titlestring = "isovim · " .. (spec.name or agent)
  vim.o.statusline = ("%%#StatusLine# isovim · %s/%s · %s%%=:qa leaves "):format(ws, agent, (spec.name or agent):gsub("%%", "%%%%"))
  local chat = require("isovim.acp.chat").open(ws, agent, vim.api.nvim_get_current_win())
  -- The empty buffer nvim started with goes.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= chat.buf and buf ~= chat.composer and vim.api.nvim_buf_get_name(buf) == "" then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    callback = function()
      vim.schedule(function()
        if vim.fn.bufwinid(chat.buf) == -1 then
          vim.cmd("qa!")
        end
      end)
    end,
  })
  vim.keymap.set("n", "<leader>iq", function()
    require("isovim.acp.queue").open(ws, agent, vim.fn.bufwinid(chat.composer))
  end, { desc = "isovim: the prompt queue" })
  vim.keymap.set("n", "<leader>iu", function()
    require("isovim.acp.chat").rewind_at_cursor()
  end, { desc = "isovim: rewind at your prompt under the cursor" })
  vim.keymap.set("n", "<leader>if", function()
    require("isovim.acp.chat").fork_at_cursor()
  end, { desc = "isovim: fork at the message under the cursor" })
  require("isovim.acp.chat").focus_composer(ws, agent)
  require("isovim.status").mark_seen(ws, agent)
end

return M
