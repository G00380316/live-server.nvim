-- Core logic for starting, stopping, and managing server processes.

local utils = require("live-server.nvim.utils")

local M = {}

-- State table to manage running server processes.
M.State = {
    live_server = nil,
    browser_sync = nil,
}

-- Default configuration options.
local config = {
    browser_sync_port = 3000,
    live_server_port = 8080,
    files_to_watch = '"*.html, *.css, *.js"',
    auto_open_browser = true,
}

--- Initializes the core module with user options.
function M.init(opts)
    config = vim.tbl_deep_extend("force", config, opts or {})
end

function M.start_live_server(port)
    if M.State.live_server then
        utils.notify("Live Server is already running.", vim.log.levels.WARN)
        return
    end
    local port_num = tonumber(port) or config.live_server_port
    local cwd = utils.get_project_root()
    local cmd = string.format("live-server --port=%d", port_num)
    local job_id = vim.fn.jobstart(cmd, { detach = true, cwd = cwd })

    if job_id > 0 then
        M.State.live_server = { pid = job_id, port = port_num, cwd = cwd }
        utils.notify("Live Server started in '" .. cwd .. "' on port " .. port_num)
        if config.auto_open_browser then
            vim.defer_fn(function() utils.open_in_browser('live_server') end, 1000)
        end
    else
        utils.notify("Failed to start Live Server.", vim.log.levels.ERROR)
    end
end

function M.kill_live_server()
    if not M.State.live_server then return end
    vim.fn.jobstop(M.State.live_server.pid)
    utils.notify("Live Server on port " .. M.State.live_server.port .. " terminated.")
    M.State.live_server = nil
end

function M.start_browser_sync(port)
    if M.State.browser_sync then
        utils.notify("BrowserSync is already running.", vim.log.levels.WARN)
        return
    end
    local port_num = tonumber(port) or config.browser_sync_port
    local cwd = utils.get_project_root()
    local cmd = string.format("browser-sync start --no-notify --server --port=%d --files %s", port_num,
        config.files_to_watch)
    local job_id = vim.fn.jobstart(cmd, { detach = true, cwd = cwd })

    if job_id > 0 then
        M.State.browser_sync = { pid = job_id, port = port_num, cwd = cwd }
        utils.notify("BrowserSync started in '" .. cwd .. "' on port " .. port_num)
        if config.auto_open_browser then
            vim.defer_fn(function() utils.open_in_browser('browser_sync') end, 1000)
        end
    else
        utils.notify("Failed to start BrowserSync.", vim.log.levels.ERROR)
    end
end

function M.kill_browser_sync()
    if not M.State.browser_sync then return end
    vim.fn.jobstop(M.State.browser_sync.pid)
    utils.notify("BrowserSync server on port " .. M.State.browser_sync.port .. " terminated.")
    M.State.browser_sync = nil
end

function M.toggle_live_server(port)
    if M.State.live_server then M.kill_live_server() else M.start_live_server(port) end
end

function M.toggle_browser_sync(port)
    if M.State.browser_sync then M.kill_browser_sync() else M.start_browser_sync(port) end
end

function M.kill_all_servers()
    if M.State.live_server then M.kill_live_server() end
    if M.State.browser_sync then M.kill_browser_sync() end
end

return M
