---@mod live_server.store Small JSON-backed key/value stores
---
--- Used for port pins, project-config trust records and the live process
--- registry. Writes are atomic and debounced; a corrupt or hand-edited file is
--- reported once and then replaced rather than crashing the plugin.

local log = require("live_server.log")
local util = require("live_server.util")

local M = {}

---@class live_server.Store
---@field private path string
---@field private data table<string, any>
---@field private loaded boolean
---@field private dirty boolean
local Store = {}
Store.__index = Store

---@type table<string, live_server.Store>
local instances = {}

--- Open (or reuse) a store.
---@param name string file name without extension
---@param opts? { scope?: "data"|"state" } `data` persists user intent (pins,
---       trust), `state` holds machine-local runtime facts (pids)
---@return live_server.Store
function M.open(name, opts)
  opts = opts or {}
  local scope = opts.scope or "data"
  local key = scope .. "/" .. name
  if instances[key] then
    return instances[key]
  end
  local dir = vim.fn.stdpath(scope) .. "/live-server.nvim"
  local store = setmetatable({
    path = dir .. "/" .. name .. ".json",
    data = {},
    loaded = false,
    dirty = false,
  }, Store)
  instances[key] = store
  return store
end

---@return string
function Store:file()
  return self.path
end

--- Load from disk if we have not already. Missing files are normal.
---@return live_server.Store
function Store:load()
  if self.loaded then
    return self
  end
  self.loaded = true
  local raw = util.read_file(self.path)
  if not raw then
    return self
  end
  local decoded, err = util.json_decode(raw)
  if type(decoded) ~= "table" then
    log.warn("store is not valid JSON, starting empty", { path = self.path, err = err })
    -- Keep the bad file around; the user may want to recover hand-written pins.
    pcall(util.uv.fs_rename, self.path, self.path .. ".corrupt")
    return self
  end
  self.data = decoded
  return self
end

---@param key string
---@return any
function Store:get(key)
  self:load()
  return self.data[key]
end

---@param key string
---@param value any nil deletes the entry
---@return live_server.Store
function Store:set(key, value)
  self:load()
  if self.data[key] == value then
    return self
  end
  self.data[key] = value
  self.dirty = true
  return self
end

---@param key string
---@return live_server.Store
function Store:delete(key)
  return self:set(key, nil)
end

--- Every entry. The returned table is a copy; mutate through `set`.
---@return table<string, any>
function Store:all()
  self:load()
  return vim.deepcopy(self.data)
end

---@return live_server.Store
function Store:clear()
  self:load()
  self.data = {}
  self.dirty = true
  return self
end

--- Persist to disk. No-op when nothing changed since the last save.
---@param opts? { force?: boolean }
---@return boolean ok
function Store:save(opts)
  if not self.dirty and not (opts and opts.force) then
    return true
  end
  -- vim.json encodes an empty Lua table as `[]`; keep the file a JSON object so
  -- a later decode still yields a map.
  local payload = self.data
  if next(payload) == nil then
    payload = vim.empty_dict()
  end
  local encoded, encode_err = util.json_encode(payload)
  if not encoded then
    log.error("failed to encode store", { path = self.path, err = encode_err })
    return false
  end
  local ok, err = util.write_file(self.path, encoded)
  if not ok then
    log.error("failed to write store", { path = self.path, err = err })
    return false
  end
  self.dirty = false
  return true
end

--- Save on the next tick, coalescing bursts of writes into one.
function Store:save_soon()
  if self._scheduled then
    return
  end
  self._scheduled = true
  vim.schedule(function()
    self._scheduled = false
    self:save()
  end)
end

--- Forget every cached instance. Test-suite hook.
function M.reset()
  instances = {}
end

return M
