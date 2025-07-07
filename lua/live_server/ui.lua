
local core = require("live_server.core")
local utils = require("live_server.utils")

local M = {}

function M.list_servers()
    local lines = { "⚡ Active Server Instances", "--------------------------" }
    local has_any_server = false

    for project_root, project_state in pairs(core.State) do
        if project_state.live_server or project_state.browser_sync then
            has_any_server = true

            table.insert(lines, "Project: " .. vim.fn.fnamemodify(project_root, ":t"))

            if project_state.live_server then
                table.insert(lines, "  - Live Server (Port: " .. project_state.live_server.port .. ", PID: " .. project_state.live_server.pid .. ")")
            end
            if project_state.browser_sync then
                table.insert(lines, "  - BrowserSync (Port: " .. project_state.browser_sync.port .. ", PID: " .. project_state.browser_sync.pid .. ")")
            end
            table.insert(lines, "")
        end
    end

    if not has_any_server then
        table.insert(lines, "No servers are currently running.")
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local width = 70
    local height = #lines + 2
    local win_opts = {
        relative = 'editor', width = width, height = height,
        col = (vim.o.columns - width) / 2, row = (vim.o.lines - height) / 2,
        style = 'minimal', border = 'rounded', title = 'All Running Servers', title_pos = 'center',
    }
    local win = vim.api.nvim_open_win(buf, true, win_opts)
    vim.api.nvim_win_set_option(win, 'winhl', 'Normal:NormalFloat')
end

function M.start_server_with_prompt(server_type)
    local default_port = server_type == 'live_server' and 8080 or 3000
    vim.ui.input({ prompt = "Enter Port:", default = tostring(default_port) }, function(port)
        if not port or port == "" then
            utils.notify("Server start cancelled.", vim.log.levels.WARN)
            return
        end
        local port_num = tonumber(port)
        if not port_num then
            utils.notify("Invalid port number.", vim.log.levels.ERROR)
            return
        end

        if server_type == 'live_server' then
            core.start_live_server(port_num)
        elseif server_type == 'browser_sync' then
            core.start_browser_sync(port_num)
        end
    end)
end

function M.statusline()
    local project_root = utils.get_project_root()
    -- Use pcall in case the core module isn't fully loaded yet
    local ok, core_module = pcall(require, "live_server.core")
    if not ok then return "" end

    local project_state = core_module.get_project_state(project_root)
    local parts = {}

    if project_state.live_server then table.insert(parts, " LS:" .. project_state.live_server.port) end
    if project_state.browser_sync then table.insert(parts, " BS:" .. project_state.browser_sync.port) end
    return table.concat(parts, " | ")
end

return M

