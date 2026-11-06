-- snacks, LazyVim's pickers, inputs and explorer, which icarus shows its lists and questions in.
local M = {}

-- snacks, set up the first time; a start package isn't on the runtimepath while init.lua runs.
function M.snacks()
  local snacks = require("snacks")
  if not snacks.did_setup then
    snacks.setup({})
  end
  return snacks
end

-- <leader>u, as LazyVim has it: ui toggles, each saying in which-key whether it's on.
local function toggles(snacks)
  local toggle = snacks.toggle
  toggle.option("spell", { name = "Spelling" }):map("<leader>us")
  toggle.option("wrap", { name = "Wrap" }):map("<leader>uw")
  toggle.option("relativenumber", { name = "Relative Number" }):map("<leader>uL")
  toggle.diagnostics():map("<leader>ud")
  toggle.line_number():map("<leader>ul")
  toggle.option("conceallevel", { off = 0, on = vim.o.conceallevel > 0 and vim.o.conceallevel or 2, name = "Conceal Level" })
    :map("<leader>uc")
  toggle.option("showtabline", { off = 0, on = vim.o.showtabline > 0 and vim.o.showtabline or 2, name = "Tabline" })
    :map("<leader>uA")
  toggle.treesitter():map("<leader>uT")
  toggle.option("background", { off = "light", on = "dark", name = "Dark Background" }):map("<leader>ub")
  toggle.dim():map("<leader>uD")
  toggle.animate():map("<leader>ua")
  toggle.indent():map("<leader>ug")
  toggle.scroll():map("<leader>uS")
  toggle.zoom():map("<leader>uZ")
  toggle.zen():map("<leader>uz")
  vim.keymap.set("n", "<leader>ur", "<Cmd>nohlsearch<Bar>diffupdate<Bar>normal! <C-L><CR>",
    { desc = "Redraw / Clear hlsearch / Diff Update" })
  vim.keymap.set("n", "<leader>ui", vim.show_pos, { desc = "Inspect Pos" })
  vim.keymap.set("n", "<leader>uI", function()
    vim.treesitter.inspect_tree()
    vim.api.nvim_input("I")
  end, { desc = "Inspect Tree" })
  vim.keymap.set("n", "<leader>uC", function()
    snacks.picker.colorschemes()
  end, { desc = "Colorschemes" })
  local ok, wk = pcall(require, "which-key")
  if ok then
    wk.add({ { "<leader>u", group = "ui" } })
  end
end

-- A snacks explorer with opts. Not Snacks.explorer, which closes the one open instead of opening a
-- second: icarus has two, the right column's and the agent sidebar.
function M.explorer(opts)
  M.snacks()
  return require("snacks.picker.core.picker").new(vim.tbl_extend("force", { source = "explorer" }, opts))
end

-- vim.ui.select and vim.ui.input open snacks' modals, and <leader>u's toggles are mapped.
function M.enable()
  local snacks = M.snacks()
  vim.ui.select = snacks.picker.select
  vim.ui.input = snacks.input.input
  toggles(snacks)
end

return M
