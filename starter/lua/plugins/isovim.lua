return {
  {
    "folke/snacks.nvim",
    keys = {
      { "<leader>e", false },
      { "<leader>E", false },
      { "<leader>fe", false },
      { "<leader>fE", false },
    },
    -- isovim's landing (isovim.landing) opens in the editing area on start in its place.
    opts = { dashboard = { enabled = false } },
  },
  {
    "lewis6991/gitsigns.nvim",
    opts = function(_, opts)
      local attach = opts.on_attach
      opts.on_attach = function(buf)
        if attach then
          attach(buf)
        end
        require("isovim").review_base(buf)
      end
    end,
  },
  {
    "nvim-lualine/lualine.nvim",
    opts = function(_, opts)
      -- An image pasting into an input box: its bar, then for a moment why it failed, if it did.
      table.insert(opts.sections.lualine_x, 1, {
        function()
          return require("isovim.acp.images").status()
        end,
        cond = function()
          return package.loaded["isovim.acp.images"] ~= nil and require("isovim.acp.images").status() ~= ""
        end,
      })
    end,
  },
  {
    "akinsho/bufferline.nvim",
    opts = function(_, opts)
      -- The tab line always shows, starting right of the sidebar: over the sidebar is its title.
      opts.options.always_show_bufferline = true
      table.insert(opts.options.offsets, {
        filetype = "isovim_sidebar",
        text = function()
          local sidebar = vim.tbl_filter(function(win)
            return vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "isovim_sidebar"
          end, vim.api.nvim_tabpage_list_wins(0))[1]
          return require("isovim.sidebar").offset_text(vim.api.nvim_win_get_width(sidebar) - 2)
        end,
        highlight = "Title",
        text_align = "left",
        separator = true,
      })
      -- Each tab's name, glyph and place, isovim's own (isovim.tabs): every agent of the scope, a
      -- surface, the landing; anything else as bufferline would have it.
      local default_icon = opts.options.get_element_icon
      opts.options.get_element_icon = function(element)
        local icon, hl = require("isovim.tabs").icon(element.path)
        if icon then
          return icon, hl
        end
        return default_icon(element)
      end
      opts.options.name_formatter = function(element)
        return require("isovim.tabs").name(element.bufnr)
      end
      opts.options.sort_by = function(a, b)
        return require("isovim.tabs").before(a, b)
      end
      -- A tab's x (and its right click) closes it as <leader>bd does.
      opts.options.close_command = function(buf)
        require("isovim.tabs").bufdelete(buf)
      end
      opts.options.right_mouse_command = opts.options.close_command
    end,
  },
}
