---@mod live_server.utils Deprecated pre-1.0 helpers
---
--- Forwards to the current modules. New code should use `live_server.util`,
--- `live_server.project` and `live_server.browser`.

local M = {}

---@param msg string
---@param level? integer a `vim.log.levels` value
function M.notify(msg, level)
  local names = {
    [vim.log.levels.TRACE] = "trace",
    [vim.log.levels.DEBUG] = "debug",
    [vim.log.levels.INFO] = "info",
    [vim.log.levels.WARN] = "warn",
    [vim.log.levels.ERROR] = "error",
  }
  require("live_server.log").notify(msg, names[level] or "info")
end

---@return string
function M.get_project_root()
  return require("live_server.project").get().root
end

---@param server_type? string
function M.open_in_browser(server_type)
  local manager = require("live_server.manager")
  local root = require("live_server.project").get().root
  local server = manager.find_active(root, server_type) or manager.find_active(root)
  if not server then
    require("live_server.log").notify("No server is running for this project.", "warn")
    return
  end
  require("live_server.browser").open(server)
end

return M
