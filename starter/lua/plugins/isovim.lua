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
      local default_icon = opts.options.get_element_icon
      opts.options.get_element_icon = function(element)
        if element.path:match("^isovim://") then
          local buf = vim.fn.bufnr(element.path)
          return require("isovim.icons").get(buf > 0 and vim.b[buf].isovim_agent_kind or "claude")
        end
        return default_icon(element)
      end
      opts.options.name_formatter = function(element)
        if element.path:match("^isovim://") then
          local name = vim.b[element.bufnr].isovim_agent_name or "isovim"
          -- Its status, as in the sidebar: working, finished unread, or waiting on you.
          local ws, agent = vim.b[element.bufnr].isovim_id, vim.b[element.bufnr].isovim_agent
          local status = ws and require("isovim.status").get(ws, agent or "main")
          local mark = ({ working = " …", unread = " ●", attention = " ●!" })[status or ""]
          return name .. (mark or "")
        end
      end
    end,
  },
}
