local t = require("harness")
local config = require("live_server.config")
local dashboard = require("live_server.ui.dashboard")
local icons = require("live_server.ui.icons")
local highlights = require("live_server.ui.highlights")
local manager = require("live_server.manager")
local server_mod = require("live_server.server")
local adapters = require("live_server.adapters")
local statusline = require("live_server.statusline")
local commands = require("live_server.commands")

---@return string[]
local function dashboard_lines()
  dashboard.open()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  dashboard.close()
  return lines
end

---@param lines string[]
---@return string
local function joined(lines)
  return table.concat(lines, "\n")
end

t.describe("icons", function()
  t.it("returns an empty string in text mode", function()
    config.did_setup = false
    config.setup({ ui = { icons = "text" } })
    t.eq(icons.get("running"), "")
    t.eq(icons.prefix("running"), "", "no stray padding when there is no icon")
    t.eq(icons.status_width(), 0)
    config.did_setup = false
    config.setup({})
  end)

  t.it("returns ASCII glyphs in ascii mode", function()
    config.did_setup = false
    config.setup({ ui = { icons = "ascii" } })
    t.eq(icons.get("running"), "*")
    for _, name in ipairs({ "running", "stopped", "crashed", "starting" }) do
      t.eq(#icons.get(name), 1, name .. " must be a single ASCII cell")
    end
    config.did_setup = false
    config.setup({})
  end)

  t.it("stops animating when the spinner is disabled", function()
    config.did_setup = false
    config.setup({ ui = { icons = "ascii", spinner = false } })
    t.eq(icons.spinner(1), icons.spinner(2), "a disabled spinner must not change between ticks")
    config.did_setup = false
    config.setup({})
  end)

  t.it("cycles frames when the spinner is enabled", function()
    config.did_setup = false
    config.setup({ ui = { icons = "ascii", spinner = true } })
    t.neq(icons.spinner(0), icons.spinner(1))
    config.did_setup = false
    config.setup({})
  end)
end)

t.describe("highlights", function()
  t.it("defines every group", function()
    highlights.apply()
    for _, group in ipairs({
      "LiveServerRunning",
      "LiveServerStopped",
      "LiveServerCrashed",
      "LiveServerUrl",
      "LiveServerKey",
      "LiveServerHint",
    }) do
      local hl = vim.api.nvim_get_hl(0, { name = group })
      t.truthy(next(hl) ~= nil, group .. " is not defined")
    end
  end)

  t.it("lets a user override a group", function()
    config.did_setup = false
    config.setup({ ui = { highlights = { LiveServerRunning = { fg = "#00ff00" } } } })
    highlights.apply()
    local hl = vim.api.nvim_get_hl(0, { name = "LiveServerRunning" })
    t.eq(hl.fg, 0x00ff00)
    config.did_setup = false
    config.setup({})
    highlights.apply()
  end)

  t.it("maps each status to a group", function()
    t.eq(highlights.for_status("running"), "LiveServerRunning")
    t.eq(highlights.for_status("crashed"), "LiveServerCrashed")
    t.eq(highlights.for_status("nonsense"), "LiveServerStopped", "unknown statuses must still render")
  end)
end)

t.describe("dashboard", function()
  local function fake_server(overrides)
    local server = server_mod.new(vim.tbl_extend("force", {
      adapter = adapters.get("live_server"),
      project = {
        root = "/tmp/fake-project",
        name = "fake-project",
        serve_dir = "/tmp/fake-project",
        config = {},
        privileged = {},
      },
      host = "127.0.0.1",
      port = 5501,
    }, overrides or {}))
    return server
  end

  t.it("shows an empty state with a way forward", function()
    manager.reset()
    local lines = joined(dashboard_lines())
    t.contains(lines, "Nothing is running yet")
    t.contains(lines, "start a server")
  end)

  t.it("opens and closes cleanly", function()
    manager.reset()
    dashboard.open()
    t.truthy(dashboard.is_open())
    dashboard.close()
    t.falsy(dashboard.is_open())
  end)

  t.it("is idempotent", function()
    manager.reset()
    dashboard.open()
    dashboard.open()
    t.truthy(dashboard.is_open())
    dashboard.close()
    t.falsy(dashboard.is_open())
  end)

  t.it("names the status in words, not only colour", function()
    config.did_setup = false
    config.setup({ ui = { icons = "text" } })
    manager.reset()

    local server = fake_server()
    server.status = "running"
    server.ready_at = require("live_server.util").now()
    server.started_at = server.ready_at
    -- Register it the way the manager would.
    local registry_server = server
    local original = manager.servers
    manager.servers = function()
      return { registry_server }
    end

    local lines = joined(dashboard_lines())
    t.contains(lines, "running", "status must be readable as text")
    t.contains(lines, "live-server")
    t.contains(lines, "5501")
    t.contains(lines, "fake-project")

    manager.servers = original
    config.did_setup = false
    config.setup({})
  end)

  t.it("renders every status without error", function()
    manager.reset()
    local original = manager.servers
    for _, status in ipairs({ "starting", "running", "unhealthy", "stopping", "stopped", "crashed" }) do
      local server = fake_server()
      server.status = status
      manager.servers = function()
        return { server }
      end
      local ok, err = pcall(dashboard_lines)
      t.truthy(ok, "rendering status " .. status .. " failed: " .. tostring(err))
    end
    manager.servers = original
  end)

  t.it("fits inside a narrow window", function()
    manager.reset()
    local previous = vim.o.columns
    vim.o.columns = 60
    local ok, err = pcall(dashboard_lines)
    vim.o.columns = previous
    t.truthy(ok, "narrow terminal rendering failed: " .. tostring(err))
  end)

  t.it("never emits a line wider than the window", function()
    manager.reset()
    local original = manager.servers
    local server = fake_server()
    server.status = "running"
    server.started_at = require("live_server.util").now()
    server.ready_at = server.started_at
    manager.servers = function()
      return { server }
    end

    dashboard.open()
    local win = vim.api.nvim_get_current_win()
    local width = vim.api.nvim_win_get_width(win)
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    dashboard.close()
    manager.servers = original

    for _, line in ipairs(lines) do
      t.truthy(
        vim.fn.strdisplaywidth(line) <= width,
        ("line wider than the window (%d > %d): %q"):format(vim.fn.strdisplaywidth(line), width, line)
      )
    end
  end)
end)

t.describe("statusline", function()
  t.it("is empty when nothing runs", function()
    manager.reset()
    t.eq(statusline.component(), "")
    t.falsy(statusline.active())
  end)

  t.it("provides a lualine spec", function()
    local component = statusline.lualine()
    t.eq(type(component[1]), "function")
    t.eq(type(component.cond), "function")
    t.eq(type(component.on_click), "function")
  end)
end)

t.describe("commands", function()
  t.it("registers the entry point", function()
    require("live_server").setup({})
    t.eq(vim.fn.exists(":LiveServer"), 2)
  end)

  t.it("registers the pre-1.0 names when enabled", function()
    config.did_setup = false
    require("live_server").setup({ legacy_commands = true })
    for _, name in ipairs({ "LiveServerToggle", "BrowserSyncToggle", "LiveServerList" }) do
      t.eq(vim.fn.exists(":" .. name), 2, name .. " should exist")
    end
  end)

  t.it("completes subcommand names", function()
    local completions = commands.complete("", "LiveServer ", 11)
    t.includes(completions, "start")
    t.includes(completions, "stop")
    t.includes(completions, "pin")
    t.includes(completions, "dashboard")
  end)

  t.it("filters completions by prefix", function()
    local completions = commands.complete("pi", "LiveServer pi", 13)
    t.includes(completions, "pin")
    t.includes(completions, "pins")
    t.falsy(vim.tbl_contains(completions, "stop"))
  end)

  t.it("completes adapter names for `start`", function()
    local completions = commands.complete("", "LiveServer start ", 17)
    t.includes(completions, "live_server")
    t.includes(completions, "auto")
  end)

  t.it("handles an unknown subcommand without throwing", function()
    local ok = pcall(commands.dispatch, { "not_a_subcommand" })
    t.truthy(ok, "an unknown subcommand must be reported, not raised")
  end)

  t.it("runs read-only subcommands", function()
    manager.reset()
    for _, name in ipairs({ "status", "pins", "trust" }) do
      t.truthy(pcall(commands.dispatch, { name }), name .. " raised")
    end
  end)
end)

t.describe("0.x compatibility", function()
  local core = require("live_server.core")

  t.it("exposes State as a real table so pairs() works", function()
    -- `__pairs` is Lua 5.2 and LuaJIT does not implement it, so a metatable
    -- trick here would silently break every existing `for _ in pairs(State)`.
    t.eq(getmetatable(core.State), nil, "State must not rely on __pairs")
    t.eq(type(core.State), "table")
    local ok = pcall(function()
      for _ in pairs(core.State) do
      end
    end)
    t.truthy(ok)
  end)

  t.it("keeps the old function names available", function()
    for _, name in ipairs({
      "init",
      "start_live_server",
      "kill_live_server",
      "start_browser_sync",
      "kill_browser_sync",
      "toggle_live_server",
      "toggle_browser_sync",
      "kill_all_servers",
      "get_project_state",
    }) do
      t.eq(type(core[name]), "function", "core." .. name .. " is missing")
    end
  end)

  t.it("keeps the old utils module working", function()
    local utils = require("live_server.utils")
    t.eq(type(utils.get_project_root()), "string")
    t.eq(type(utils.notify), "function")
    t.eq(type(utils.open_in_browser), "function")
  end)

  t.it("keeps the old ui entry points working", function()
    local ui = require("live_server.ui")
    t.eq(type(ui.list_servers), "function")
    t.eq(type(ui.start_server_with_prompt), "function")
    t.eq(type(ui.statusline()), "string")
  end)

  t.it("returns the old shape from get_project_state", function()
    local state = core.get_project_state("/tmp/nowhere")
    t.eq(type(state), "table")
    t.eq(state.live_server, nil)
    t.eq(state.browser_sync, nil)
  end)

  t.it("does not break on a 0.x config", function()
    local issues = require("live_server.config").validate({
      browser_sync_port = 3000,
      live_server_port = 8080,
      files_to_watch = '"*.html, *.css, *.js"',
      auto_open_browser = true,
    })
    t.eq(#issues, 4, "each removed option should be named")
    -- The point is that setup survives it.
    t.truthy(pcall(require("live_server").setup, {
      browser_sync_port = 3000,
      live_server_port = 8080,
      files_to_watch = "x",
      auto_open_browser = true,
    }))
    require("live_server").setup({})
  end)
end)
