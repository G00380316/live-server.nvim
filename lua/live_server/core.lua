---@mod live_server.core Deprecated pre-1.0 API
---
--- Kept so existing keymaps such as
--- `require("live_server.core").toggle_live_server()` keep working. Each entry
--- forwards to the current API and warns once. New code should use
--- `require("live_server")`.

local M = {}

---@type table<string, boolean>
local warned = {}

---@param old string
---@param new string
local function deprecate(old, new)
  if warned[old] then
    return
  end
  warned[old] = true
  vim.schedule(function()
    vim.notify_once(
      ("live-server.nvim: `live_server.core.%s` is deprecated, use `%s`"):format(old, new),
      vim.log.levels.WARN,
      { title = "Live Server" }
    )
  end)
end

---@param opts? table
function M.init(opts)
  deprecate("init", 'require("live_server").setup()')
  require("live_server").setup(opts)
end

---@param port? integer|string
function M.start_live_server(port)
  deprecate("start_live_server", 'require("live_server").start({ adapter = "live_server" })')
  require("live_server.manager").start({ adapter = "live_server", port = port })
end

function M.kill_live_server()
  deprecate("kill_live_server", 'require("live_server").stop()')
  local manager = require("live_server.manager")
  local server = manager.find_active(require("live_server.project").get().root, "live_server")
  if server then
    manager.stop(server)
  end
end

---@param port? integer|string
function M.start_browser_sync(port)
  deprecate("start_browser_sync", 'require("live_server").start({ adapter = "browser_sync" })')
  require("live_server.manager").start({ adapter = "browser_sync", port = port })
end

function M.kill_browser_sync()
  deprecate("kill_browser_sync", 'require("live_server").stop()')
  local manager = require("live_server.manager")
  local server = manager.find_active(require("live_server.project").get().root, "browser_sync")
  if server then
    manager.stop(server)
  end
end

---@param port? integer|string
function M.toggle_live_server(port)
  deprecate("toggle_live_server", 'require("live_server").toggle({ adapter = "live_server" })')
  require("live_server.manager").toggle({ adapter = "live_server", port = port })
end

---@param port? integer|string
function M.toggle_browser_sync(port)
  deprecate("toggle_browser_sync", 'require("live_server").toggle({ adapter = "browser_sync" })')
  require("live_server.manager").toggle({ adapter = "browser_sync", port = port })
end

function M.kill_all_servers()
  deprecate("kill_all_servers", 'require("live_server").stop_all()')
  require("live_server.manager").stop_all()
end

---@param project_root? string
---@return table
function M.get_project_state(project_root)
  deprecate("get_project_state", 'require("live_server").servers()')
  local root = project_root or require("live_server.project").get().root
  local state = { live_server = nil, browser_sync = nil }
  for _, server in ipairs(require("live_server.manager").for_project(root, { active_only = true })) do
    state[server.adapter.name] = { pid = server.pid, port = server.port, cwd = server.project.root }
  end
  return state
end

--- Legacy view of the old `State` table: a map of project root to
--- `{ live_server = {...}, browser_sync = {...} }`.
---
--- This has to be a *real* table, not a metatable trick: `__pairs` is a Lua 5.2
--- feature that LuaJIT does not implement, so any config doing
--- `for root, state in pairs(core.State)` would silently see nothing. It is
--- kept in sync from the event bus instead.
---@type table<string, table>
M.State = {}

local function sync_state()
  for key in pairs(M.State) do
    M.State[key] = nil
  end
  for _, server in ipairs(require("live_server.manager").servers({ active_only = true })) do
    local entry = M.State[server.project.root] or { live_server = nil, browser_sync = nil }
    entry[server.adapter.name] = { pid = server.pid, port = server.port, cwd = server.project.root }
    M.State[server.project.root] = entry
  end
end

-- Requiring this module is itself the opt-in: nobody on the current API pays
-- for the subscription.
require("live_server.event").on("changed", sync_state)
sync_state()

return M
