---@mod live_server.log Notifications and the on-disk debug log
---
--- Two audiences, deliberately separated:
---   * `notify()` talks to the user and respects `notify.level`.
---   * `debug()`/`warn()`/… write to a rotating file for bug reports and are
---     controlled independently by `log.level`.

local util = require("live_server.util")

local M = {}

---@type table<string, integer>
local LEVELS = { trace = 0, debug = 1, info = 2, warn = 3, error = 4, off = 5 }

---@type table<string, integer>
local VIM_LEVELS = {
  trace = vim.log.levels.TRACE,
  debug = vim.log.levels.DEBUG,
  info = vim.log.levels.INFO,
  warn = vim.log.levels.WARN,
  error = vim.log.levels.ERROR,
}

local MAX_BYTES = 512 * 1024

---@return live_server.Config
local function config()
  return require("live_server.config").get()
end

--- Absolute path of the debug log.
---@return string
function M.path()
  local dir = vim.fn.stdpath("state") .. "/live-server.nvim"
  return dir .. "/live-server.log"
end

---@type file*|nil
local handle = nil
---@type boolean
local open_failed = false

---@return file*|nil
local function get_handle()
  if handle or open_failed then
    return handle
  end
  local path = M.path()
  local dir = vim.fs.dirname(path)
  if not util.is_dir(dir) then
    local ok = util.mkdirp(dir)
    if not ok then
      open_failed = true
      return nil
    end
  end
  -- Rotate before opening so a long-lived session cannot grow without bound.
  local stat = util.uv.fs_stat(path)
  if stat and stat.size > MAX_BYTES then
    pcall(util.uv.fs_rename, path, path .. ".old")
  end
  local file = io.open(path, "a")
  if not file then
    open_failed = true
    return nil
  end
  handle = file
  return handle
end

---@param level string
---@param msg string
---@param context? table
local function write(level, msg, context)
  local cfg = config()
  local threshold = LEVELS[cfg.log.level] or LEVELS.warn
  if threshold >= LEVELS.off or (LEVELS[level] or 0) < threshold then
    return
  end
  local file = get_handle()
  if not file then
    return
  end
  local line = ("%s [%s] %s"):format(os.date("%Y-%m-%dT%H:%M:%S"), level:upper(), msg)
  if context and next(context) then
    local encoded = util.json_encode(context)
    if encoded then
      line = line .. " " .. encoded
    end
  end
  pcall(function()
    file:write(line, "\n")
    file:flush()
  end)
end

---@param msg string
---@param context? table
function M.trace(msg, context)
  write("trace", msg, context)
end

---@param msg string
---@param context? table
function M.debug(msg, context)
  write("debug", msg, context)
end

---@param msg string
---@param context? table
function M.info(msg, context)
  write("info", msg, context)
end

---@param msg string
---@param context? table
function M.warn(msg, context)
  write("warn", msg, context)
end

---@param msg string
---@param context? table
function M.error(msg, context)
  write("error", msg, context)
end

--- Show a message to the user and mirror it into the debug log.
---@param msg string
---@param level? "trace"|"debug"|"info"|"warn"|"error"
---@param opts? { title?: string, once?: boolean, context?: table }
function M.notify(msg, level, opts)
  level = level or "info"
  opts = opts or {}
  write(level, msg, opts.context)

  local cfg = config()
  if not cfg.notify.enabled then
    return
  end
  if (LEVELS[level] or 2) < (LEVELS[cfg.notify.level] or 2) then
    return
  end

  local fn = opts.once and vim.notify_once or vim.notify
  util.schedule(function()
    fn(msg, VIM_LEVELS[level] or vim.log.levels.INFO, { title = opts.title or "Live Server" })
  end)
end

--- Drop the file handle, e.g. before deleting the log.
function M.close()
  if handle then
    pcall(function()
      handle:close()
    end)
    handle = nil
  end
  open_failed = false
end

return M
