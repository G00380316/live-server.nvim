---@mod live_server.ui UI entry points
---
--- Thin façade over the panels, plus the pre-1.0 function names so existing
--- keymaps in people's configs keep working.

local M = {}

M.dashboard = setmetatable({}, {
  __index = function(_, key)
    return require("live_server.ui.dashboard")[key]
  end,
})

M.logs = setmetatable({}, {
  __index = function(_, key)
    return require("live_server.ui.logs")[key]
  end,
})

M.prompt = setmetatable({}, {
  __index = function(_, key)
    return require("live_server.ui.prompt")[key]
  end,
})

--- Open the server manager.
function M.open()
  require("live_server.ui.dashboard").open()
end

function M.toggle()
  require("live_server.ui.dashboard").toggle()
end

function M.close()
  require("live_server.ui.dashboard").close()
end

--------------------------------------------------------------------------------
-- Compatibility with the pre-1.0 API
--------------------------------------------------------------------------------

--- Deprecated: use `require("live_server").dashboard()`.
function M.list_servers()
  require("live_server.ui.dashboard").open()
end

--- Deprecated: use `require("live_server").start({ adapter = ..., port = ... })`.
---@param server_type? string
function M.start_server_with_prompt(server_type)
  local manager = require("live_server.manager")
  local prompt = require("live_server.ui.prompt")
  local project = require("live_server.project").get()
  local adapter = server_type or require("live_server.config").get().server

  prompt.port({
    default = require("live_server.port").get_pin(project.root, adapter)
      or require("live_server.config").get().port.defaults[adapter],
    prompt = "Port: ",
  }, function(port)
    if port then
      manager.start({ adapter = adapter ~= "auto" and adapter or nil, port = port })
    end
  end)
end

--- Deprecated: use `require("live_server").statusline()`.
---@return string
function M.statusline()
  return require("live_server.statusline").component()
end

return M
