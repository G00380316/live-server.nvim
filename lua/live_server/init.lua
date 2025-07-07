local core = require("live-server.nvim.core")
local ui = require("live-server.nvim.ui")
local utils = require("live-server.nvim.utils")

local M = {}

function M.setup(opts)
    core.init(opts)

    vim.api.nvim_create_user_command('LiveServerToggle', function(a) core.toggle_live_server(a.fargs[1]) end,
        { nargs = "?", desc = "Toggle the Live Server" })
    vim.api.nvim_create_user_command('BrowserSyncToggle', function(a) core.toggle_browser_sync(a.fargs[1]) end,
        { nargs = "?", desc = "Toggle the BrowserSync Server" })
    vim.api.nvim_create_user_command('LiveServerList', ui.list_servers, { desc = "List all running server instances" })
    vim.api.nvim_create_user_command('LiveServerPrompt', function() ui.start_server_with_prompt('live_server') end,
        { desc = "Start Live Server with a port prompt" })
    vim.api.nvim_create_user_command('BrowserSyncPrompt', function() ui.start_server_with_prompt('browser_sync') end,
        { desc = "Start BrowserSync with a port prompt" })
    vim.api.nvim_create_user_command('LiveServerOpen', function() utils.open_in_browser('live_server') end,
        { desc = "Open Live Server URL in browser" })
    vim.api.nvim_create_user_command('BrowserSyncOpen', function() utils.open_in_browser('browser_sync') end,
        { desc = "Open BrowserSync URL in browser" })

    -- Autocommand to clean up all server processes when Neovim exits.
    local group = vim.api.nvim_create_augroup('LiveServerNvimCleanup', { clear = true })
    vim.api.nvim_create_autocmd('VimLeave', {
        group = group,
        pattern = '*',
        callback = core.kill_all_servers,
        desc = "Kill all running server instances on exit."
    })
end

-- Expose the statusline function for external use (e.g., lualine).
M.statusline = ui.statusline

return M
