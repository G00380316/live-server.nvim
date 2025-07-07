
local utils = require("live_server.utils")

local M = {}

M.State = {}

local config = {}

function M.init(opts)
    config = vim.tbl_deep_extend("force", {
        browser_sync_port = 3000,
        live_server_port = 8080,
        files_to_watch = '"*.html, *.css, *.js"',
        auto_open_browser = true,
    }, opts or {})
end

local function is_port_in_use(port_to_check)
    for project_root, project_state in pairs(M.State) do
        if project_state.live_server and project_state.live_server.port == port_to_check then
            return true, vim.fn.fnamemodify(project_root, ":t")
        end
        if project_state.browser_sync and project_state.browser_sync.port == port_to_check then
            return true, vim.fn.fnamemodify(project_root, ":t")
        end
    end
    return false, nil
end

function M.get_project_state(project_root)
    if not M.State[project_root] then
        M.State[project_root] = { live_server = nil, browser_sync = nil }
    end
    return M.State[project_root]
end

function M.start_live_server(port)
    local project_root = utils.get_project_root()
    local project_state = M.get_project_state(project_root)

    if project_state.live_server then
        utils.notify("Live Server is already running for this project.", vim.log.levels.WARN)
        return
    end

    local port_num = tonumber(port) or config.live_server_port

    local in_use, project_name = is_port_in_use(port_num)
    if in_use then
        utils.notify("Port " .. port_num .. " is in use by '" .. project_name .. "'.", vim.log.levels.WARN)
        require("live_server.ui").start_server_with_prompt('live_server')
        return
    end

    local cmd = string.format("live-server --port=%d", port_num)
    local job_id = vim.fn.jobstart(cmd, { detach = true, cwd = project_root })

    if job_id > 0 then
        project_state.live_server = { pid = job_id, port = port_num, cwd = project_root }
        utils.notify("Live Server started for '" .. vim.fn.fnamemodify(project_root, ":t") .. "' on port " .. port_num)
        if config.auto_open_browser then
            vim.defer_fn(function() utils.open_in_browser('live_server') end, 1000)
        end
    else
        utils.notify("Failed to start Live Server. Is the port available?", vim.log.levels.ERROR)
    end
end

function M.kill_live_server()
    local project_root = utils.get_project_root()
    local project_state = M.get_project_state(project_root)
    if not project_state.live_server then return end

    vim.fn.jobstop(project_state.live_server.pid)
    utils.notify("Live Server on port " .. project_state.live_server.port .. " terminated.")
    project_state.live_server = nil
end

function M.start_browser_sync(port)
    local project_root = utils.get_project_root()
    local project_state = M.get_project_state(project_root)

    if project_state.browser_sync then
        utils.notify("BrowserSync is already running for this project.", vim.log.levels.WARN)
        return
    end

    local port_num = tonumber(port) or config.browser_sync_port

    local in_use, project_name = is_port_in_use(port_num)
    if in_use then
        utils.notify("Port " .. port_num .. " is in use by '" .. project_name .. "'.", vim.log.levels.WARN)
        require("live_server.ui").start_server_with_prompt('browser_sync')
        return
    end

    local cmd = string.format("browser-sync start --no-notify --server --port=%d --files %s", port_num, config.files_to_watch)
    local job_id = vim.fn.jobstart(cmd, { detach = true, cwd = project_root })

    if job_id > 0 then
        project_state.browser_sync = { pid = job_id, port = port_num, cwd = project_root }
        utils.notify("BrowserSync started for '" .. vim.fn.fnamemodify(project_root, ":t") .. "' on port " .. port_num)
        if config.auto_open_browser then
            vim.defer_fn(function() utils.open_in_browser('browser_sync') end, 1000)
        end
    else
        utils.notify("Failed to start BrowserSync. Is the port available?", vim.log.levels.ERROR)
    end
end

function M.kill_browser_sync()
    local project_root = utils.get_project_root()
    local project_state = M.get_project_state(project_root)
    if not project_state.browser_sync then return end

    vim.fn.jobstop(project_state.browser_sync.pid)
    utils.notify("BrowserSync server on port " .. project_state.browser_sync.port .. " terminated.")
    project_state.browser_sync = nil
end

function M.toggle_live_server(port)
    local project_root = utils.get_project_root()
    local project_state = M.get_project_state(project_root)
    if project_state.live_server then M.kill_live_server() else M.start_live_server(port) end
end

function M.toggle_browser_sync(port)
    local project_root = utils.get_project_root()
    local project_state = M.get_project_state(project_root)
    if project_state.browser_sync then M.kill_browser_sync() else M.start_browser_sync(port) end
end

function M.kill_all_servers()
    for _, project_state in pairs(M.State) do
        if project_state.live_server then
            vim.fn.jobstop(project_state.live_server.pid)
        end
        if project_state.browser_sync then
            vim.fn.jobstop(project_state.browser_sync.pid)
        end
    end
    M.State = {} -- Clear the state table
    utils.notify("All managed server instances have been terminated.")
end

return M

