-- All UI-related functions, such as floating windows and prompts.

local core = require("live-server.nvim.core")
local utils = require("live-server.nvim.utils")

local M = {}

function M.list_servers()
    local lines = { "⚡ Active Server Instances", "--------------------------" }
    local has_servers = false
    local State = core.State

    if State.live_server then
        has_servers = true
        table.insert(lines, "Type: Live Server")
        table.insert(lines, "  - Port: " .. State.live_server.port)
        table.insert(lines, "  - PID: " .. State.live_server.pid)
        table.insert(lines, "  - Directory: " .. State.live_server.cwd)
        table.insert(lines, "")
    end

    if State.browser_sync then
        has_servers = true
        table.insert(lines, "Type: BrowserSync")
        table.insert(lines, "  - Port: " .. State.browser_sync.port)
        table.insert(lines, "  - PID: " .. State.browser_sync.pid)
        table.insert(lines, "  - Directory: " .. State.browser_sync.cwd)
        table.insert(lines, "")
    end

    if not has_servers then
        table.insert(lines, "No servers are currently running.")
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local width = 60
    local height = #lines + 2
    local win_opts = {
        relative = 'editor', width = width, height = height,
        col = (vim.o.columns - width) / 2, row = (vim.o.lines - height) / 2,
        style = 'minimal', border = 'rounded', title = 'Running Servers', title_pos = 'center',
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
    local parts = {}
    local State = core.State
    if State.live_server then table.insert(parts, " LS:" .. State.live_server.port) end
    if State.browser_sync then table.insert(parts, " BS:" .. State.browser_sync.port) end
    return table.concat(parts, " | ")
end

return M

