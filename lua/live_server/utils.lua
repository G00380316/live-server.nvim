-- Helper functions used across the plugin.

local M = {}

function M.notify(msg, level)
    vim.notify(msg, level or vim.log.levels.INFO, { title = "Live Server" })
end

function M.get_project_root()
    local root = vim.fs.find('.git', { upward = true, type = 'directory', path = vim.api.nvim_buf_get_name(0) })
    if root and #root > 0 then
        return vim.fn.fnamemodify(root[1], ':h')
    end
    return vim.fn.expand('%:p:h') or vim.fn.getcwd()
end

function M.open_in_browser(server_type)
    -- This requires the core module, but it's safe due to lazy loading.
    local core = require("live_server.core")
    local project_root = M.get_project_root()
    local project_state = core.get_project_state(project_root)
    local server_state = project_state[server_type]

    if not server_state then
        M.notify(string.format("Server '%s' is not running for this project.", server_type), vim.log.levels.WARN)
        return
    end
    local url = "http://localhost:" .. server_state.port

    local os = vim.loop.os_uname().sysname
    local cmd
    if os == "Linux" then
        cmd = "xdg-open"
    elseif os == "Darwin" then -- macOS
        cmd = "open"
    else -- A reasonable fallback for Windows/WSL
        cmd = "explorer.exe"
    end
    vim.fn.jobstart(string.format("%s %s", cmd, url), { detach = true })
    M.notify("Opening " .. url .. " in your browser.")
end

return M
