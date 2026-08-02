---@mod live_server.event Internal pub/sub plus `User` autocommands
---
--- Everything that changes server state publishes here. The dashboard and the
--- statusline subscribe instead of polling, which is what keeps the plugin at
--- zero cost when nothing is happening.

local M = {}

---@alias live_server.EventName
---| "starting"  server process spawned, not yet accepting connections
---| "ready"     port is accepting connections
---| "stopping"  stop requested
---| "stopped"   process exited cleanly or on request
---| "crashed"   process exited unexpectedly
---| "output"    a line of stdout/stderr arrived
---| "changed"   catch-all: any state mutation, fired after the specific event

---@type table<string, table<integer, fun(payload: table)>>
local handlers = {}

---@type integer
local next_id = 0

--- Bumped on every emit. Cheap way for consumers (statusline) to cache.
---@type integer
M.version = 0

--- Subscribe to an event.
---@param name live_server.EventName|"*"
---@param fn fun(payload: table)
---@return fun() unsubscribe
function M.on(name, fn)
  handlers[name] = handlers[name] or {}
  next_id = next_id + 1
  local id = next_id
  handlers[name][id] = fn
  return function()
    if handlers[name] then
      handlers[name][id] = nil
    end
  end
end

---@param name string
---@param payload table
local function dispatch(name, payload)
  local list = handlers[name]
  if not list then
    return
  end
  -- Snapshot: a handler may unsubscribe itself while we iterate.
  local snapshot = {}
  for id, fn in pairs(list) do
    snapshot[#snapshot + 1] = { id = id, fn = fn }
  end
  for _, entry in ipairs(snapshot) do
    local ok, err = pcall(entry.fn, payload)
    if not ok then
      require("live_server.log").error("event handler failed", { event = name, err = tostring(err) })
    end
  end
end

--- Publish an event to subscribers, the `*` wildcard, and a `User`
--- autocommand named `LiveServer<Event>` (e.g. `LiveServerReady`).
---@param name live_server.EventName
---@param payload? table
function M.emit(name, payload)
  payload = payload or {}
  payload.event = name
  M.version = M.version + 1

  dispatch(name, payload)
  if name ~= "changed" then
    dispatch("changed", payload)
  end
  dispatch("*", payload)

  -- Autocommands must not run in a fast event context.
  local pattern = "LiveServer" .. name:sub(1, 1):upper() .. name:sub(2)
  local data = payload.server and payload.server:info() or payload
  vim.schedule(function()
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = pattern, data = data, modeline = false })
  end)
end

--- Drop every subscriber. Used by the test suite and on re-`setup()`.
function M.reset()
  handlers = {}
end

return M
