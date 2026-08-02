---@mod live_server.port Port allocation and per-project pins
---
--- The goal is that a project keeps the *same* URL forever: bookmarks, open
--- devtools sessions, CORS allowlists, OAuth redirect URIs and QR codes taped
--- to a test phone all stay valid across restarts and across machines.
---
--- Resolution order, first match wins:
---   1. an explicit port from the command line
---   2. a port pinned to this project + adapter
---   3. a port from the configured strategy
---   4. the next free port in the configured range
---
--- Every candidate is verified against the operating system before use.

local log = require("live_server.log")
local net = require("live_server.net")
local store = require("live_server.store")
local util = require("live_server.util")

local M = {}

---@return live_server.Config
local function config()
  return require("live_server.config").get()
end

---@return live_server.Store
local function db()
  return store.open("ports")
end

--- Ports handed out during this resolution pass but not yet bound by a child
--- process. Without this, starting two servers back to back can race and both
--- receive the same "free" port.
---@type table<integer, boolean>
local reserved = {}

---@param root string
---@param adapter string
---@return string
local function pin_key(root, adapter)
  return util.normalize(root) .. "::" .. adapter
end

--- Port pinned to a project + adapter, if any.
---@param root string
---@param adapter string
---@return integer?
function M.get_pin(root, adapter)
  local record = db():get(pin_key(root, adapter))
  if type(record) == "table" and type(record.port) == "number" then
    return record.port
  end
  -- Tolerate a hand-written `{"/path::live_server": 5500}`.
  if type(record) == "number" then
    return record
  end
  return nil
end

--- Pin `port` so this project always reopens on the same URL.
---@param root string
---@param adapter string
---@param port integer
function M.pin(root, adapter, port)
  db()
    :set(pin_key(root, adapter), {
      port = port,
      root = util.normalize(root),
      adapter = adapter,
      at = os.time(),
    })
    :save()
  log.info("pinned port", { root = root, adapter = adapter, port = port })
end

---@param root string
---@param adapter string
---@return boolean removed
function M.unpin(root, adapter)
  local key = pin_key(root, adapter)
  local database = db()
  if database:get(key) == nil then
    return false
  end
  database:delete(key):save()
  log.info("removed port pin", { root = root, adapter = adapter })
  return true
end

--- Every pin, newest first.
---@return { root: string, adapter: string, port: integer, at: integer }[]
function M.pins()
  local out = {}
  for key, record in pairs(db():all()) do
    if type(record) == "table" and record.port then
      out[#out + 1] = {
        root = record.root or key:gsub("::.*$", ""),
        adapter = record.adapter or key:gsub("^.*::", ""),
        port = record.port,
        at = record.at or 0,
      }
    end
  end
  table.sort(out, function(a, b)
    if a.root == b.root then
      return a.adapter < b.adapter
    end
    return a.root < b.root
  end)
  return out
end

--- Remove pins whose project directory no longer exists.
---@return integer removed
function M.prune()
  local database = db()
  local removed = 0
  for key, record in pairs(database:all()) do
    local root = type(record) == "table" and record.root or key:gsub("::.*$", "")
    if root and root ~= "" and not util.is_dir(root) then
      database:delete(key)
      removed = removed + 1
    end
  end
  if removed > 0 then
    database:save()
    log.info("pruned stale port pins", { removed = removed })
  end
  return removed
end

--- Deterministic port for a project: the same checkout produces the same port
--- on every machine, without any shared state.
---@param root string
---@param adapter string
---@param range integer[]
---@return integer
function M.stable_port(root, adapter, range)
  local low = math.max(range[1], net.MIN_PORT)
  local high = math.min(range[2], net.MAX_PORT)
  local span = math.max(1, high - low + 1)
  local hash = util.hash(util.normalize(root) .. "::" .. adapter)
  return low + (hash % span)
end

---@class live_server.PortResult
---@field port integer
---@field source "explicit"|"pin"|"default"|"stable"|"scan"
---@field fallback boolean the preferred port was taken and we moved
---@field preferred integer? what we wanted before falling back

--- Choose a port for a server that is about to start.
---@param opts { root: string, adapter: string, host: string, requested?: integer|string, project_port?: integer }
---@return live_server.PortResult? result
---@return string? err
function M.resolve(opts)
  local cfg = config()
  local range = cfg.port.range
  local host = opts.host

  ---@type integer?
  local preferred
  ---@type "explicit"|"pin"|"default"|"stable"|"scan"
  local source

  if opts.requested ~= nil and opts.requested ~= "" then
    local ok, err = net.valid_port(opts.requested)
    if not ok then
      return nil, err
    end
    preferred, source = tonumber(opts.requested), "explicit"
  elseif opts.project_port then
    local ok, err = net.valid_port(opts.project_port)
    if not ok then
      return nil, ("project file: %s"):format(err)
    end
    preferred, source = tonumber(opts.project_port), "explicit"
  elseif cfg.port.strategy == "pin" then
    preferred = M.get_pin(opts.root, opts.adapter)
    source = preferred and "pin" or "default"
    preferred = preferred or cfg.port.defaults[opts.adapter]
  elseif cfg.port.strategy == "stable" then
    preferred, source = M.stable_port(opts.root, opts.adapter, range), "stable"
  elseif cfg.port.strategy == "fixed" then
    preferred, source = cfg.port.defaults[opts.adapter], "default"
  else -- "scan"
    preferred, source = range[1], "scan"
  end

  if not preferred then
    preferred, source = range[1], "scan"
  end

  if not reserved[preferred] and net.is_free(host, preferred) then
    reserved[preferred] = true
    return { port = preferred, source = source, fallback = false }, nil
  end

  -- `fixed` means the user asked for exactly this port; silently moving would
  -- break whatever they hard-coded it into.
  if cfg.port.strategy == "fixed" and source == "default" then
    return nil, ("port %d is already in use"):format(preferred)
  end

  local found = net.find_free(host, preferred, range, cfg.port.max_attempts, reserved)
  if not found then
    return nil,
      ("no free port between %d and %d (tried %d)"):format(range[1], range[2], cfg.port.max_attempts)
  end

  reserved[found] = true
  return { port = found, source = "scan", fallback = true, preferred = preferred }, nil
end

--- Release a reservation once the server has actually bound the port (or
--- failed to start).
---@param port integer
function M.release(port)
  reserved[port] = nil
end

--- Explicit port validation shared by the command layer and the UI prompts.
---@param value any
---@param host string
---@return integer? port
---@return string? err
function M.validate(value, host)
  local ok, err = net.valid_port(value)
  if not ok then
    return nil, err
  end
  local port = tonumber(value)
  if not net.is_free(host, port) then
    return nil, ("port %d is already in use"):format(port)
  end
  return port, nil
end

return M
